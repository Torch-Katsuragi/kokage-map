// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// GDAL の C API（gdal_utils.h）を dart:ffi で呼ぶ実装。Android は libgdal.so、ホスト VM テストは QGIS の gdal*.dll か apt の libgdal。
// 設計: docs/technical/gdal.md ／ ビルド: third_party/gdal/README.md
//
// ## スレッドとアイソレート
// - 呼び出しは 1 回ごとに `Isolate.run` で別アイソレート（= 別の OS スレッド）に出す。UI アイソレートは塞がない。
//   ライブラリはアイソレートごとに `DynamicLibrary.open` する（dlopen はプロセスで 1 つなので実体は共有）
// - GDAL は「1 つのデータセットのハンドルを複数スレッドで同時に触らない」限りスレッド安全。ここでは呼び出しごとに
//   開いて閉じるので、ハンドルがアイソレートをまたぐことはない
// - エラー（CPLGetLastErrorMsg）はスレッドごと。開いてから閉じるまでを await の無い同期処理で済ませるので、
//   読む時も同じスレッドにいる
// - プロセス全体に効く設定（ドライバ登録・PROJ_DATA・設定オプション・エラーハンドラ）は最初の 1 回だけ、
//   ほかの呼び出しより先に済ませる（[_ready]）。呼び出しごとに変えたいもの（shp の文字コードなど）は
//   設定オプションでなくオープンオプション（`-oo`）で渡す
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'gdal.dart';

/// Android / ホスト VM の既定の [Gdal]（gdal_provider.dart の取り決め）
Gdal createGdal() => GdalFfi();

/// ライブラリの場所とデータの置き場。Android では指定しない（既定が libgdal.so と、アセットから書き出した proj.db / GDAL_DATA）
class GdalFfiConfig {
  const GdalFfiConfig({
    required this.libraryPath,
    this.dllSearchDir,
    this.projDataDir,
    this.gdalDataDir,
    this.tempDir,
  });

  /// `DynamicLibrary.open` に渡す名前かパス
  final String libraryPath;

  /// Windows: 依存 DLL を探すフォルダ（QGIS の bin）。`SetDllDirectoryW` に渡す
  final String? dllSearchDir;

  /// proj.db のあるフォルダ（`OSRSetPROJSearchPaths`）。null なら GDAL/PROJ の既定
  final String? projDataDir;

  /// GDAL_DATA（DXF の雛形、GML のレジストリ・基盤地図情報の .gfs、タイル方式など）
  final String? gdalDataDir;

  /// CPL_TMPDIR（一時ファイルを書くドライバがある）
  final String? tempDir;
}

/// shp の文字コードの既定: `.cpg` が無く DBF の LDID も 0 のとき CP932 とみなす。
///
/// GDAL 単体はこの場合に文字コードを決めず、バイト列をそのまま返す（Shift_JIS が壊れた UTF-8 になる）。
/// QGIS は「システムの文字コード」で読み直すので、日本語版 Windows の QGIS では CP932 として見える。
/// その見え方に合わせる。`.cpg` か LDID があればそちら（GDAL の判定）に任せる。
const shapefileFallbackEncoding = 'CP932';

class GdalFfi implements Gdal {
  /// [config] を省くと Android の既定（libgdal.so、proj.db はアセットから書き出す）
  GdalFfi([GdalFfiConfig? config]) : _config = config;

  final GdalFfiConfig? _config;
  Future<GdalFfiConfig>? _ready;

  /// 初回: 設定を決め（Android は proj.db と GDAL_DATA をファイルに書き出す。rootBundle を使うので UI アイソレートで）、
  /// 1 つのアイソレートでドライバ登録とプロセス全体の設定を済ませる
  Future<GdalFfiConfig> _init() => _ready ??= _initOnce(_config);

  Future<T> _run<T>(T Function(_GdalLib g) f) async => _runIn(await _init(), f);

  @override
  Future<String> version() => _run(_version);

  @override
  Future<Map<String, dynamic>> rasterInfo(String path, {List<String> args = const []}) =>
      _run((g) => g.rasterInfo(path, args));

  @override
  Future<Map<String, dynamic>> vectorInfo(String path, {List<String> args = const []}) =>
      _run((g) => g.vectorInfo(path, args));

  @override
  Future<void> vectorTranslate(String src, String dst, {List<String> args = const []}) =>
      _run((g) => g.vectorTranslate(src, dst, args));

  @override
  Future<void> warp(String src, String dst, {List<String> args = const []}) => _run((g) => g.warp(src, dst, args));

  @override
  Future<void> translate(String src, String dst, {List<String> args = const []}) =>
      _run((g) => g.translate(src, dst, args));

  @override
  Future<List<String>> fileList(String path) => _run((g) => g.fileList(path));
}

// アイソレートに渡すクロージャは GdalFfi の外（トップレベル）で作る。メソッドの中で作ると this（未完了の Future を持つ
// _ready）まで連れていき、実機では「object is unsendable」で落ちる（2026-10-11 Pixel 9。ホストのテストでは出なかった）
Future<GdalFfiConfig> _initOnce(GdalFfiConfig? config) async {
  final c = config ?? await _androidConfig();
  await Isolate.run(() => _GdalLib.open(c).initProcess(c));
  return c;
}

Future<T> _runIn<T>(GdalFfiConfig c, T Function(_GdalLib g) f) => Isolate.run(() => f(_GdalLib.open(c)));

String _version(_GdalLib g) => g.version();

// ---------------------------------------------------------------------------
// Android の既定の設定（proj.db と GDAL_DATA の書き出し）

/// 書き出したデータを入れ替える目印。build_android.sh で GDAL / PROJ を上げたらここも変える
const _dataStamp = 'GDAL 3.13.3 / PROJ 9.9.0';
const _projDbAsset = 'assets/gdal/proj.db';
const _gdalDataAsset = 'assets/gdal/gdal_data.zip';

/// アプリの support dir の `gdal/`（`proj/proj.db` と `data/`）。アプリの更新で版が変わったら書き直す。
/// 途中で落ちても目印を最後に書くので、次の起動で書き直される
Future<GdalFfiConfig> _androidConfig() async {
  if (!Platform.isAndroid) {
    throw UnsupportedError('GdalFfi の既定の設定は Android 用。ホストでは GdalFfiConfig を渡す');
  }
  final support = await getApplicationSupportDirectory();
  final root = Directory(p.join(support.path, 'gdal'));
  final projDir = Directory(p.join(root.path, 'proj'));
  final dataDir = Directory(p.join(root.path, 'data'));
  final stamp = File(p.join(root.path, 'version'));
  final current = await stamp.exists() ? await stamp.readAsString() : null;
  if (current != _dataStamp) {
    if (await root.exists()) await root.delete(recursive: true);
    await projDir.create(recursive: true);
    await dataDir.create(recursive: true);
    final db = await rootBundle.load(_projDbAsset);
    await File(p.join(projDir.path, 'proj.db'))
        .writeAsBytes(db.buffer.asUint8List(db.offsetInBytes, db.lengthInBytes), flush: true);
    final zip = await rootBundle.load(_gdalDataAsset);
    final archive = ZipDecoder().decodeBytes(zip.buffer.asUint8List(zip.offsetInBytes, zip.lengthInBytes));
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final out = File(p.join(dataDir.path, p.normalize(f.name)));
      if (!p.isWithin(dataDir.path, out.path)) continue;
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content);
    }
    await stamp.writeAsString(_dataStamp, flush: true);
  }
  final temp = await getTemporaryDirectory();
  return GdalFfiConfig(
    libraryPath: 'libgdal.so',
    projDataDir: projDir.path,
    gdalDataDir: dataDir.path,
    tempDir: temp.path,
  );
}

// ---------------------------------------------------------------------------
// C API

typedef _Ptr = Pointer<Void>;
typedef _Str = Pointer<Utf8>;
typedef _StrList = Pointer<Pointer<Utf8>>;

typedef _VoidFnC = Void Function();
typedef _VoidFnD = void Function();
typedef _StrToStrC = _Str Function(_Str);
typedef _SetConfigC = Void Function(_Str, _Str);
typedef _SetConfigD = void Function(_Str, _Str);
typedef _SetPathsC = Void Function(_StrList);
typedef _SetPathsD = void Function(_StrList);
typedef _GetStrC = _Str Function();
typedef _IntFnC = Int32 Function();
typedef _IntFnD = int Function();
typedef _SetHandlerC = _Ptr Function(_Ptr);
typedef _OpenExC = _Ptr Function(_Str, Uint32, _StrList, _StrList, _StrList);
typedef _OpenExD = _Ptr Function(_Str, int, _StrList, _StrList, _StrList);
typedef _CloseC = Int32 Function(_Ptr);
typedef _CloseD = int Function(_Ptr);
typedef _FreeC = Void Function(_Ptr);
typedef _FreeD = void Function(_Ptr);
typedef _OptsNewC = _Ptr Function(_StrList, _Ptr);
typedef _InfoC = _Str Function(_Ptr, _Ptr);
typedef _MultiC = _Ptr Function(_Str, _Ptr, Int32, Pointer<_Ptr>, _Ptr, Pointer<Int32>);
typedef _MultiD = _Ptr Function(_Str, _Ptr, int, Pointer<_Ptr>, _Ptr, Pointer<Int32>);
typedef _TranslateC = _Ptr Function(_Str, _Ptr, _Ptr, Pointer<Int32>);
typedef _FileListC = _StrList Function(_Ptr);

const _ofRaster = 0x02;
const _ofVector = 0x04;
const _ofVerboseError = 0x40;
const _ceFailure = 3;

/// 1 アイソレートぶんの関数表。アイソレートの static に持つ（同じアイソレートでは作り直さない）
class _GdalLib {
  _GdalLib._(DynamicLibrary l)
      : _allRegister = l.lookupFunction<_VoidFnC, _VoidFnD>('GDALAllRegister'),
        _driverCount = l.lookupFunction<_IntFnC, _IntFnD>('GDALGetDriverCount'),
        _versionInfo = l.lookupFunction<_StrToStrC, _StrToStrC>('GDALVersionInfo'),
        _setConfig = l.lookupFunction<_SetConfigC, _SetConfigD>('CPLSetConfigOption'),
        _setProjPaths = l.lookupFunction<_SetPathsC, _SetPathsD>('OSRSetPROJSearchPaths'),
        _errorReset = l.lookupFunction<_VoidFnC, _VoidFnD>('CPLErrorReset'),
        _lastErrorMsg = l.lookupFunction<_GetStrC, _GetStrC>('CPLGetLastErrorMsg'),
        _lastErrorType = l.lookupFunction<_IntFnC, _IntFnD>('CPLGetLastErrorType'),
        _setErrorHandler = l.lookupFunction<_SetHandlerC, _SetHandlerC>('CPLSetErrorHandler'),
        _quietHandler = l.lookup<Void>('CPLQuietErrorHandler'),
        _pushErrorHandler = l.lookupFunction<_FreeC, _FreeD>('CPLPushErrorHandler'),
        _popErrorHandler = l.lookupFunction<_VoidFnC, _VoidFnD>('CPLPopErrorHandler'),
        _setThreadConfig = l.lookupFunction<_SetConfigC, _SetConfigD>('CPLSetThreadLocalConfigOption'),
        _openEx = l.lookupFunction<_OpenExC, _OpenExD>('GDALOpenEx'),
        _close = l.lookupFunction<_CloseC, _CloseD>('GDALClose'),
        _vsiFree = l.lookupFunction<_FreeC, _FreeD>('VSIFree'),
        _cslDestroy = l.lookupFunction<_FreeC, _FreeD>('CSLDestroy'),
        _infoOptsNew = l.lookupFunction<_OptsNewC, _OptsNewC>('GDALInfoOptionsNew'),
        _infoOptsFree = l.lookupFunction<_FreeC, _FreeD>('GDALInfoOptionsFree'),
        _info = l.lookupFunction<_InfoC, _InfoC>('GDALInfo'),
        _vInfoOptsNew = l.lookupFunction<_OptsNewC, _OptsNewC>('GDALVectorInfoOptionsNew'),
        _vInfoOptsFree = l.lookupFunction<_FreeC, _FreeD>('GDALVectorInfoOptionsFree'),
        _vInfo = l.lookupFunction<_InfoC, _InfoC>('GDALVectorInfo'),
        _vtOptsNew = l.lookupFunction<_OptsNewC, _OptsNewC>('GDALVectorTranslateOptionsNew'),
        _vtOptsFree = l.lookupFunction<_FreeC, _FreeD>('GDALVectorTranslateOptionsFree'),
        _vt = l.lookupFunction<_MultiC, _MultiD>('GDALVectorTranslate'),
        _warpOptsNew = l.lookupFunction<_OptsNewC, _OptsNewC>('GDALWarpAppOptionsNew'),
        _warpOptsFree = l.lookupFunction<_FreeC, _FreeD>('GDALWarpAppOptionsFree'),
        _warp = l.lookupFunction<_MultiC, _MultiD>('GDALWarp'),
        _trOptsNew = l.lookupFunction<_OptsNewC, _OptsNewC>('GDALTranslateOptionsNew'),
        _trOptsFree = l.lookupFunction<_FreeC, _FreeD>('GDALTranslateOptionsFree'),
        _tr = l.lookupFunction<_TranslateC, _TranslateC>('GDALTranslate'),
        _fileList = l.lookupFunction<_FileListC, _FileListC>('GDALGetFileList');

  static _GdalLib? _cached;
  static String? _cachedPath;

  static _GdalLib open(GdalFfiConfig c) {
    final hit = _cached;
    if (hit != null && _cachedPath == c.libraryPath) return hit;
    final dir = c.dllSearchDir;
    if (Platform.isWindows && dir != null) _setDllDirectory(dir);
    final g = _GdalLib._(DynamicLibrary.open(c.libraryPath));
    _cached = g;
    _cachedPath = c.libraryPath;
    // ドライバ登録はここでしない（initProcess で GDAL_DATA などを決めてから。登録中にデータの在処を引いて覚える）
    return g;
  }

  final _VoidFnD _allRegister;
  final _IntFnD _driverCount;
  final _StrToStrC _versionInfo;
  final _SetConfigD _setConfig;
  final _SetPathsD _setProjPaths;
  final _VoidFnD _errorReset;
  final _GetStrC _lastErrorMsg;
  final _IntFnD _lastErrorType;
  final _SetHandlerC _setErrorHandler;
  final Pointer<Void> _quietHandler;
  final _FreeD _pushErrorHandler;
  final _VoidFnD _popErrorHandler;
  final _SetConfigD _setThreadConfig;
  final _OpenExD _openEx;
  final _CloseD _close;
  final _FreeD _vsiFree;
  final _FreeD _cslDestroy;
  final _OptsNewC _infoOptsNew;
  final _FreeD _infoOptsFree;
  final _InfoC _info;
  final _OptsNewC _vInfoOptsNew;
  final _FreeD _vInfoOptsFree;
  final _InfoC _vInfo;
  final _OptsNewC _vtOptsNew;
  final _FreeD _vtOptsFree;
  final _MultiD _vt;
  final _OptsNewC _warpOptsNew;
  final _FreeD _warpOptsFree;
  final _MultiD _warp;
  final _OptsNewC _trOptsNew;
  final _FreeD _trOptsFree;
  final _TranslateC _tr;
  final _FileListC _fileList;

  /// プロセス全体の設定。最初の 1 回だけ（[GdalFfi._init]）
  void initProcess(GdalFfiConfig c) {
    // stderr に書かせない（失敗は CPLGetLastErrorMsg で拾って例外にする）
    _setErrorHandler(_quietHandler);
    _withArena((a) {
      void set(String k, String? v) => _setConfig(k.toNativeUtf8(allocator: a), v == null ? nullptr : v.toNativeUtf8(allocator: a));
      final proj = c.projDataDir;
      if (proj != null) {
        _setProjPaths(_cStrList([proj], a));
        set('PROJ_DATA', proj);
      }
      if (c.gdalDataDir != null) set('GDAL_DATA', c.gdalDataDir);
      if (c.tempDir != null) set('CPL_TMPDIR', c.tempDir);
      // ネットワークには出ない（PROJ のグリッド取得も含めて）
      set('PROJ_NETWORK', 'OFF');
    });
    if (_driverCount() == 0) _allRegister();
  }

  String version() => _withArena((a) => _versionInfo('RELEASE_NAME'.toNativeUtf8(allocator: a)).toDartString());

  Map<String, dynamic> rasterInfo(String path, List<String> args) => _call((a) {
        final src = _SourceArgs.split(args);
        final ds = _openDataset(path, _ofRaster, src, a);
        try {
          final opts = _infoOptsNew(_cStrList(['-json', ...src.rest], a), nullptr);
          if (opts == nullptr) throw _error('gdalinfo の引数が不正: ${src.rest.join(' ')}');
          try {
            return _takeJson(_info(ds, opts), 'gdalinfo');
          } finally {
            _infoOptsFree(opts);
          }
        } finally {
          _close(ds);
        }
      });

  Map<String, dynamic> vectorInfo(String path, List<String> args) => _call((a) {
        final src = _SourceArgs.split(args)..addShapefileEncoding(path);
        final ds = _openDataset(path, _ofVector, src, a);
        try {
          final opts = _vInfoOptsNew(_cStrList(['-json', ...src.rest], a), nullptr);
          if (opts == nullptr) throw _error('ogrinfo の引数が不正: ${src.rest.join(' ')}');
          try {
            return _takeJson(_vInfo(ds, opts), 'ogrinfo');
          } finally {
            _vInfoOptsFree(opts);
          }
        } finally {
          _close(ds);
        }
      });

  void vectorTranslate(String srcPath, String dst, List<String> args) => _call((a) {
        final src = _SourceArgs.split(args)..addShapefileEncoding(srcPath);
        final ds = _openDataset(srcPath, _ofVector, src, a);
        try {
          final opts = _vtOptsNew(_cStrList(src.rest, a), nullptr);
          if (opts == nullptr) throw _error('ogr2ogr の引数が不正: ${src.rest.join(' ')}');
          try {
            _runMulti(_vt, dst, ds, opts, 'ogr2ogr', a);
          } finally {
            _vtOptsFree(opts);
          }
        } finally {
          _close(ds);
        }
      });

  void warp(String srcPath, String dst, List<String> args) => _call((a) {
        final src = _SourceArgs.split(args);
        final ds = _openDataset(srcPath, _ofRaster, src, a);
        try {
          final opts = _warpOptsNew(_cStrList(src.rest, a), nullptr);
          if (opts == nullptr) throw _error('gdalwarp の引数が不正: ${src.rest.join(' ')}');
          try {
            _runMulti(_warp, dst, ds, opts, 'gdalwarp', a);
          } finally {
            _warpOptsFree(opts);
          }
        } finally {
          _close(ds);
        }
      });

  void translate(String srcPath, String dst, List<String> args) => _call((a) {
        final src = _SourceArgs.split(args);
        final ds = _openDataset(srcPath, _ofRaster, src, a);
        try {
          final opts = _trOptsNew(_cStrList(src.rest, a), nullptr);
          if (opts == nullptr) throw _error('gdal_translate の引数が不正: ${src.rest.join(' ')}');
          try {
            _errorReset();
            final usage = a<Int32>()..value = 0;
            final out = _tr(dst.toNativeUtf8(allocator: a), ds, opts, usage);
            if (out == nullptr) throw _error('gdal_translate に失敗した', usage: usage.value != 0);
            _closeOut(out, 'gdal_translate');
          } finally {
            _trOptsFree(opts);
          }
        } finally {
          _close(ds);
        }
      });

  List<String> fileList(String path) => _call((a) {
        final ds = _openDataset(path, _ofRaster | _ofVector, _SourceArgs.split(const []), a);
        try {
          final list = _fileList(ds);
          if (list == nullptr) return <String>[path];
          try {
            final out = <String>[];
            for (var i = 0; list[i] != nullptr; i++) {
              out.add(_decode(list[i]));
            }
            return out;
          } finally {
            _cslDestroy(list.cast());
          }
        } finally {
          _close(ds);
        }
      });

  // ---- 共通

  /// 1 回の呼び出し。このスレッドだけに静かなエラーハンドラを積み、CPL_ACCUM_ERROR_MSG で途中のエラーも
  /// 最後のメッセージに溜める（ogr2ogr は最後に「途中で止めた」としか言わないので、原因はその前にある）。
  /// ハンドラは GDAL 自身の関数なので、GDAL が内部の作業スレッドへ引き継いでも安全（Dart のコールバックは使わない）
  T _call<T>(T Function(Arena a) f) => _withArena((a) {
        final key = 'CPL_ACCUM_ERROR_MSG'.toNativeUtf8(allocator: a);
        _pushErrorHandler(_quietHandler);
        _setThreadConfig(key, 'ON'.toNativeUtf8(allocator: a));
        try {
          return f(a);
        } finally {
          _setThreadConfig(key, nullptr);
          _popErrorHandler();
        }
      });

  _Ptr _openDataset(String path, int kind, _SourceArgs src, Arena a) {
    _errorReset();
    final ds = _openEx(
      path.toNativeUtf8(allocator: a),
      kind | _ofVerboseError,
      src.drivers.isEmpty ? nullptr : _cStrList(src.drivers, a),
      src.openOptions.isEmpty ? nullptr : _cStrList(src.openOptions, a),
      nullptr,
    );
    if (ds == nullptr) throw _error('開けない: $path');
    return ds;
  }

  void _runMulti(_MultiD f, String dst, _Ptr srcDs, _Ptr opts, String what, Arena a) {
    final arr = a<_Ptr>()..value = srcDs;
    final usage = a<Int32>()..value = 0;
    _errorReset();
    final out = f(dst.toNativeUtf8(allocator: a), nullptr, 1, arr, opts, usage);
    if (out == nullptr) throw _error('$what に失敗した', usage: usage.value != 0);
    _closeOut(out, what);
  }

  /// 書き出し先を閉じる（ここで書き切る。閉じる時の失敗も失敗として返す）
  void _closeOut(_Ptr out, String what) {
    // 戻り値は見ない（GDALClose が CPLErr を返すのは 3.7 から。apt の古い版では void）
    _errorReset();
    _close(out);
    if (_lastErrorType() >= _ceFailure) throw _error('$what の書き出しを閉じるときに失敗した');
  }

  Map<String, dynamic> _takeJson(_Str s, String what) {
    if (s == nullptr) throw _error('$what に失敗した');
    try {
      return jsonDecode(_decode(s)) as Map<String, dynamic>;
    } finally {
      _vsiFree(s.cast());
    }
  }

  GdalException _error(String fallback, {bool usage = false}) {
    final msg = _decode(_lastErrorMsg());
    return GdalException([if (usage) '引数の誤り', if (msg.isNotEmpty) msg else fallback].join(': '));
  }
}

/// 元のデータセットを開くための引数（`-oo` `-if`）と、ユーティリティに渡す残り。
/// C API ではデータセットを呼ぶ側が開くので、コマンドラインならユーティリティが拾う `-oo` `-if` はここで抜き出す
class _SourceArgs {
  _SourceArgs(this.openOptions, this.drivers, this.rest);

  factory _SourceArgs.split(List<String> args) {
    final oo = <String>[], drivers = <String>[], rest = <String>[];
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if ((a == '-oo' || a == '-if') && i + 1 < args.length) {
        (a == '-oo' ? oo : drivers).add(args[++i]);
      } else {
        rest.add(a);
      }
    }
    return _SourceArgs(oo, drivers, rest);
  }

  final List<String> openOptions;
  final List<String> drivers;
  final List<String> rest;

  /// [shapefileFallbackEncoding] を足す（呼ぶ側が ENCODING を指定していれば何もしない）
  void addShapefileEncoding(String path) {
    if (openOptions.any((o) => o.toUpperCase().startsWith('ENCODING='))) return;
    if (needsShapefileFallbackEncoding(path)) openOptions.add('ENCODING=$shapefileFallbackEncoding');
  }
}

/// [path] が `.cpg` も LDID も無い shp（か dbf）か。ほかの形式・読めないときは false
bool needsShapefileFallbackEncoding(String path) {
  final ext = p.extension(path).toLowerCase();
  if (ext != '.shp' && ext != '.dbf') return false;
  final base = p.withoutExtension(path);
  for (final e in const ['.cpg', '.CPG', '.Cpg']) {
    if (File('$base$e').existsSync()) return false;
  }
  File? dbf;
  for (final e in const ['.dbf', '.DBF', '.Dbf']) {
    final f = File('$base$e');
    if (f.existsSync()) {
      dbf = f;
      break;
    }
  }
  if (dbf == null) return false;
  try {
    final raf = dbf.openSync();
    try {
      final head = raf.readSync(32);
      return head.length == 32 && head[29] == 0; // LDID（言語ドライバ ID）
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    return false;
  }
}

T _withArena<T>(T Function(Arena a) f) => using(f);

/// NULL 終端の char*[]（CSL）。中身は [a] が解放する
_StrList _cStrList(List<String> items, Arena a) {
  final arr = a<Pointer<Utf8>>(items.length + 1);
  for (var i = 0; i < items.length; i++) {
    arr[i] = items[i].toNativeUtf8(allocator: a);
  }
  arr[items.length] = nullptr;
  return arr;
}

/// GDAL の文字列は UTF-8 のはずだが、文字コード不明の shp の属性などは生のバイト列のまま来る。壊れたバイトで落とさない
String _decode(_Str s) {
  if (s == nullptr) return '';
  return utf8.decode(s.cast<Uint8>().asTypedList(s.length), allowMalformed: true);
}

typedef _SetDllDirC = Int32 Function(Pointer<Utf16>);
typedef _SetDllDirD = int Function(Pointer<Utf16>);

/// Windows: 依存 DLL（QGIS の bin にある proj・sqlite など）を見つけられるようにする
void _setDllDirectory(String dir) {
  final f = DynamicLibrary.open('kernel32.dll').lookupFunction<_SetDllDirC, _SetDllDirD>('SetDllDirectoryW');
  using((a) => f(dir.toNativeUtf16(allocator: a)));
}
