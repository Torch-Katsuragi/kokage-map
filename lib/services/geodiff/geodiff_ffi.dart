// geodiff の C API を dart:ffi で呼ぶ（Android の libgeodiff.so ／ ホスト VM の geodiff.dll）。
//
// 使うのは Drive 同期の 3-way rebase に要る分だけ。C API 全体は geodiff.h。
// 戻り値は 0 成功・1 失敗・2 衝突あり・3 未対応の変更（[GeodiffResult]）。
// ⚠ web ではこのファイルは読まれない（`geodiff.dart` の条件 import で stub に落ちる）。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _VersionC = Pointer<Utf8> Function();
typedef _CreateCtxC = Pointer<Void> Function();
typedef _DestroyCtxC = Void Function(Pointer<Void>);
typedef _DestroyCtxD = void Function(Pointer<Void>);
typedef _LastErrC = Pointer<Utf8> Function(Pointer<Void>);
typedef _S1C = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _S1D = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _S2C = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _S2D = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _S3C = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _S3D = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _S4C = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _S4D = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

/// geodiff の戻り値
abstract final class GeodiffResult {
  static const success = 0;
  static const error = 1;
  static const conflicts = 2;
  static const unsupportedChange = 3;
}

/// geodiff の 1 コンテキスト。使い終わったら [dispose]。
class Geodiff {
  Geodiff() : _lib = _open() {
    _version = _lib.lookupFunction<_VersionC, _VersionC>('GEODIFF_version');
    _createCtx = _lib.lookupFunction<_CreateCtxC, _CreateCtxC>('GEODIFF_createContext');
    _destroyCtx = _lib.lookupFunction<_DestroyCtxC, _DestroyCtxD>('GEODIFF_CX_destroy');
    _lastErr = _lib.lookupFunction<_LastErrC, _LastErrC>('GEODIFF_CX_lastError');
    _createChangeset = _lib.lookupFunction<_S3C, _S3D>('GEODIFF_createChangeset');
    _applyChangeset = _lib.lookupFunction<_S2C, _S2D>('GEODIFF_applyChangeset');
    _hasChanges = _lib.lookupFunction<_S1C, _S1D>('GEODIFF_hasChanges');
    _changesCount = _lib.lookupFunction<_S1C, _S1D>('GEODIFF_changesCount');
    _rebase = _lib.lookupFunction<_S4C, _S4D>('GEODIFF_rebase');
    _makeCopy = _lib.lookupFunction<_S2C, _S2D>('GEODIFF_makeCopySqlite');
    _summary = _lib.lookupFunction<_S2C, _S2D>('GEODIFF_listChangesSummary');
    _list = _lib.lookupFunction<_S2C, _S2D>('GEODIFF_listChanges');
    _ctx = _createCtx();
    if (_ctx == nullptr) throw StateError('GEODIFF_createContext が null を返した');
  }

  /// web 以外で使えるか
  static bool get isSupported => Platform.isAndroid || Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// ホスト VM テスト用: dll の場所を差し替える（既定は repo の `third_party/geodiff/windows/geodiff.dll`）
  static String? libraryPathOverride;

  static DynamicLibrary _open() {
    final o = libraryPathOverride;
    if (o != null) return DynamicLibrary.open(o);
    if (Platform.isAndroid) return DynamicLibrary.open('libgeodiff.so');
    if (Platform.isWindows) return DynamicLibrary.open('third_party/geodiff/windows/geodiff.dll');
    if (Platform.isLinux) return DynamicLibrary.open('libgeodiff.so');
    if (Platform.isMacOS) return DynamicLibrary.open('libgeodiff.dylib');
    throw UnsupportedError('geodiff はこのプラットフォームでは使えない');
  }

  final DynamicLibrary _lib;
  late final _VersionC _version;
  late final _CreateCtxC _createCtx;
  late final _DestroyCtxD _destroyCtx;
  late final _LastErrC _lastErr;
  late final _S3D _createChangeset;
  late final _S2D _applyChangeset;
  late final _S1D _hasChanges;
  late final _S1D _changesCount;
  late final _S4D _rebase;
  late final _S2D _makeCopy;
  late final _S2D _summary;
  late final _S2D _list;
  late final Pointer<Void> _ctx;

  String get version => _version().toDartString();
  String get lastError => _lastErr(_ctx).toDartString();
  void dispose() => _destroyCtx(_ctx);

  T _withUtf8<T>(List<String> args, T Function(List<Pointer<Utf8>> p) f) {
    final ps = args.map((a) => a.toNativeUtf8()).toList();
    try {
      return f(ps);
    } finally {
      for (final p in ps) {
        malloc.free(p);
      }
    }
  }

  /// base → modified の差分を [changeset] に書く
  int createChangeset(String base, String modified, String changeset) =>
      _withUtf8([base, modified, changeset], (p) => _createChangeset(_ctx, p[0], p[1], p[2]));

  /// [changeset] を [base] に当てる（在ればそのまま）
  int applyChangeset(String base, String changeset) =>
      _withUtf8([base, changeset], (p) => _applyChangeset(_ctx, p[0], p[1]));

  /// -1 エラー・0 変更なし・1 変更あり
  int hasChanges(String changeset) => _withUtf8([changeset], (p) => _hasChanges(_ctx, p[0]));

  /// 変更の件数（-1 エラー）
  int changesCount(String changeset) => _withUtf8([changeset], (p) => _changesCount(_ctx, p[0]));

  /// [mine] を「base → [theirs]」の上に載せ直す。[mine] はその場で書き換わり、
  /// 同じ行・同じ列の衝突は mine 優先で解いて [conflictFile] に JSON で残す。
  int rebase(String base, String theirs, String mine, String conflictFile) =>
      _withUtf8([base, theirs, mine, conflictFile], (p) => _rebase(_ctx, p[0], p[1], p[2], p[3]));

  /// sqlite のバックアップ API で安全にコピーする
  int makeCopySqlite(String src, String dst) => _withUtf8([src, dst], (p) => _makeCopy(_ctx, p[0], p[1]));

  /// テーブルごとの insert/update/delete 件数を JSON に
  int listChangesSummary(String changeset, String jsonFile) =>
      _withUtf8([changeset, jsonFile], (p) => _summary(_ctx, p[0], p[1]));

  /// 変更の全行を JSON に
  int listChanges(String changeset, String jsonFile) =>
      _withUtf8([changeset, jsonFile], (p) => _list(_ctx, p[0], p[1]));
}
