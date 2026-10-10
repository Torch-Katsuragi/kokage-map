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
/// web の [Gdal]（gdal3.js）。設計は docs/technical/gdal.md「web」
///
/// gdal3.js は自前の worker（`web/gdal3/worker.js`）の中で動かす。最初に呼ばれたときに worker を起こし、
/// WASM（約 28 MB）とデータ（約 12 MB）を取る。gpkg しか開かない利用者には何も読み込まない。
///
/// ファイルの受け渡し:
/// - 入力: [path] と同じフォルダの「同じ名前.何か」（shp の付属一式、`.aux.xml` `.ovr` `.tfw` …）を
///   `File` のまま worker に渡す。worker は WORKERFS で mount し、GDAL が読む分だけ切り出す（全体をコピーしない）
/// - 出力: worker の MEMFS に書かせ、できたファイルを全部受け取って `fs` の書き出し先のフォルダに書く
///   （shp なら付属ファイルも、PNG なら `.aux.xml` も）。出力はメモリに丸ごと載る
/// - 書き出し先が既にあれば（gdal_translate 以外）中身を worker に渡しておく。`-update` `-append` や
///   gdalwarp の既存への上書き、何も付けないときの「既にある」エラーがコマンドラインと同じになる
///
/// ⚠ 引数の中のパス（`-clipsrc other.shp` など）は渡らない。入力は [path] 一式だけ
/// ⚠ フォルダのデータセット（FileGDB など）は未対応
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:path/path.dart' as p;
import 'package:web/web.dart' as web;

import '../../utils/app_logger.dart';
import '../fs/k_file_system.dart';
import '../fs/k_file_system_web.dart';
import 'gdal.dart';

/// 置いている gdal3.js の版（`web/gdal3/<版>/`、`tool/web/fetch_gdal3.sh` の VERSION と揃える）
const kGdal3Version = '2.8.1';

/// gdal3.js 2.8.1 に入っている GDAL の版。`GDALVersionInfo` が WASM から書き出されていないので、版と一緒に持つ
const _gdalRelease = '3.8.4';

Gdal createGdal() => GdalWeb.instance;

class GdalWeb implements Gdal {
  GdalWeb._();

  static final GdalWeb instance = GdalWeb._();

  web.Worker? _worker;
  Future<void>? _ready;
  int _nextId = 0;
  final Map<int, Completer<JSObject>> _pending = {};

  /// 初回の読み込みにかかった時間（計測用）
  Duration? loadTime;

  @override
  Future<String> version() async {
    await _ensure();
    return _gdalRelease;
  }

  @override
  Future<Map<String, dynamic>> rasterInfo(String path, {List<String> args = const []}) async =>
      jsonDecode(await _info('rasterInfo', path, args)) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> vectorInfo(String path, {List<String> args = const []}) async =>
      jsonDecode(await _info('vectorInfo', path, args)) as Map<String, dynamic>;

  @override
  Future<void> vectorTranslate(String src, String dst, {List<String> args = const []}) =>
      _utility('vectorTranslate', src, dst, args);

  @override
  Future<void> warp(String src, String dst, {List<String> args = const []}) => _utility('warp', src, dst, args);

  @override
  Future<void> translate(String src, String dst, {List<String> args = const []}) =>
      _utility('translate', src, dst, args);

  @override
  Future<List<String>> fileList(String path) async {
    final result = await _call('fileList', {
      'main': p.basename(path).toJS,
      'files': (await _siblings(path)).toJS,
    });
    final dir = p.dirname(path);
    return (result as JSArray<JSString>).toDart.map((s) => p.join(dir, s.toDart)).toList();
  }

  // =============================================
  // 受け渡し
  // =============================================

  /// `/vsizip/<fs のパス>`（KMZ など）は、fs のパスと GDAL に付ける接頭辞に分ける
  static (String vsi, String path) _splitVsi(String path) =>
      path.startsWith('/vsizip/') ? ('/vsizip/', path.substring('/vsizip'.length)) : ('', path);

  Future<String> _info(String op, String rawPath, List<String> args) async {
    final (vsi, path) = _splitVsi(rawPath);
    final result = await _call(op, {
      'vsi': vsi.toJS,
      'main': p.basename(path).toJS,
      'files': (await _siblings(path)).toJS,
      'args': _strings(args),
    });
    return (result as JSString).toDart;
  }

  Future<void> _utility(String op, String rawSrc, String dst, List<String> args) async {
    final (vsi, src) = _splitVsi(rawSrc);
    // 書き出し先が既にあればその一式も渡す（gdal_translate は常に作り直すので要らない）
    final dstFiles = op != 'translate' && await fs.exists(dst) ? await _siblings(dst) : <web.File>[];
    final result = await _call(op, {
      'vsi': vsi.toJS,
      'main': p.basename(src).toJS,
      'files': (await _siblings(src)).toJS,
      'dstName': p.basename(dst).toJS,
      'dstFiles': dstFiles.toJS,
      'args': _strings(args),
    });
    final dir = p.dirname(dst);
    for (final out in (result as JSArray<JSObject>).toDart) {
      final rel = (out['rel'] as JSString).toDart;
      final bytes = (out['bytes'] as JSUint8Array).toDart;
      await fs.writeAsBytes(p.join(dir, rel), bytes);
    }
  }

  /// [path] と、同じフォルダの「同じ名前.何か」（大文字小文字は問わない）。[path] が先頭
  ///
  /// GDAL が実際に読む付属ファイルはこの中から GDAL が選ぶ。余分に渡しても、WORKERFS は読まれた分しか
  /// 取り出さないので重くならない
  Future<List<web.File>> _siblings(String path) async {
    if (await fs.isDirectory(path)) {
      throw GdalException('web ではフォルダのデータセットに未対応: $path');
    }
    final dir = p.dirname(path);
    final name = p.basename(path);
    final stem = '${p.basenameWithoutExtension(path).toLowerCase()}.';
    final names = [name];
    for (final entry in await fs.list(dir)) {
      if (entry.isDirectory) continue;
      final n = p.basename(entry.path);
      if (n != name && n.toLowerCase().startsWith(stem)) names.add(n);
    }
    return [for (final n in names) await _file(p.join(dir, n))];
  }

  Future<web.File> _file(String path) async {
    final files = fs;
    if (files is WebFileSystem) {
      final file = await files.fileObject(path);
      if (file == null) throw GdalException('ファイルが無い: $path');
      return file;
    }
    // テストなどで fs が差し替えられているとき
    final bytes = await files.readAsBytes(path);
    return web.File(<web.BlobPart>[bytes.toJS].toJS, p.basename(path));
  }

  JSArray<JSString> _strings(List<String> args) => [for (final a in args) a.toJS].toJS;

  // =============================================
  // worker
  // =============================================

  Future<void> _ensure() => _ready ??= _start();

  Future<void> _start() async {
    final base = Uri.parse(web.document.baseURI);
    final sw = Stopwatch()..start();
    final worker = web.Worker(base.resolve('gdal3/worker.js').toString().toJS);
    worker.onmessage = ((web.MessageEvent e) => _onMessage(e.data as JSObject)).toJS;
    worker.onerror = ((web.Event e) {
      final message = e.isA<web.ErrorEvent>() ? (e as web.ErrorEvent).message : 'worker の読み込みに失敗';
      _fail('gdal3.js: $message（web/gdal3/ が配られているか。tool/web/fetch_gdal3.sh）');
    }).toJS;
    _worker = worker;
    try {
      await _post('init', {'base': base.resolve('gdal3/$kGdal3Version/').toString().toJS});
    } catch (e) {
      _reset();
      rethrow;
    }
    loadTime = sw.elapsed;
    AppLogger.debug('[Gdal] gdal3.js $kGdal3Version（GDAL $_gdalRelease）を読み込んだ: ${sw.elapsedMilliseconds} ms');
  }

  Future<JSAny?> _call(String op, Map<String, JSAny?> params) async {
    await _ensure();
    final sw = Stopwatch()..start();
    try {
      return await _post(op, params);
    } finally {
      AppLogger.debug('[Gdal] $op: ${sw.elapsedMilliseconds} ms');
    }
  }

  Future<JSAny?> _post(String op, Map<String, JSAny?> params) async {
    final worker = _worker;
    if (worker == null) throw GdalException('gdal3.js が動いていない');
    final id = _nextId++;
    final msg = JSObject()
      ..['id'] = id.toJS
      ..['op'] = op.toJS;
    params.forEach((k, v) => msg[k] = v);
    final completer = Completer<JSObject>();
    _pending[id] = completer;
    worker.postMessage(msg);
    final reply = await completer.future;
    final log = reply['log'] as JSArray<JSString>?;
    if (log != null && log.length > 0) {
      AppLogger.debug('[Gdal] $op: ${log.toDart.map((s) => s.toDart).join(' / ')}');
    }
    if ((reply['ok'] as JSBoolean).toDart) return reply['result'];
    final error = (reply['error'] as JSString?)?.toDart ?? '不明なエラー';
    if ((reply['fatal'] as JSBoolean?)?.toDart ?? false) {
      // WASM が abort した（メモリ不足など）。待っている呼び出しも落とし、次の呼び出しで読み込み直す
      _fail('gdal3.js が停止した: $error');
    }
    throw GdalException(error);
  }

  void _onMessage(JSObject data) {
    final id = (data['id'] as JSNumber).toDartInt;
    _pending.remove(id)?.complete(data);
  }

  /// 待っている呼び出しを全部 [message] で落とし、worker を捨てる
  void _fail(String message) {
    final pending = Map.of(_pending);
    _pending.clear();
    _reset();
    for (final c in pending.values) {
      c.completeError(GdalException(message));
    }
  }

  void _reset() {
    _worker?.terminate();
    _worker = null;
    _ready = null;
  }
}
