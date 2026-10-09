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
/// 開発用: `window.kokageGdal` に [Gdal] の各メソッドを出す（docs/technical/gdal.md「web の確かめ方」）。
///
/// パスは `fs` のパス（OPFS のプロジェクトを `#/map?project=opfs:<名前>` で開いていれば `/<名前>/...`）。
/// どれも Promise で、JSON 文字列 `{ok, ms, result}` か `{ok: false, ms, error}` を返す。
///
/// ```js
/// JSON.parse(await kokageGdal.version())
/// JSON.parse(await kokageGdal.vectorTranslate('/t/a.shp', '/t/a.gpkg', ['-f', 'GPKG']))
/// ```
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../utils/app_logger.dart';
import 'gdal.dart';
import 'gdal_web.dart';

void installGdalDebugHook() {
  final gdal = createGdal();
  List<String> strings(JSArray<JSString>? a) => a == null ? const [] : [for (final s in a.toDart) s.toDart];

  final hook = JSObject()
    ..['version'] = (() => _run('version', gdal.version)).toJS
    ..['loadMs'] = (() => GdalWeb.instance.loadTime?.inMilliseconds.toJS).toJS
    ..['rasterInfo'] = ((JSString path, JSArray<JSString>? args) =>
            _run('rasterInfo', () => gdal.rasterInfo(path.toDart, args: strings(args))))
        .toJS
    ..['vectorInfo'] = ((JSString path, JSArray<JSString>? args) =>
            _run('vectorInfo', () => gdal.vectorInfo(path.toDart, args: strings(args))))
        .toJS
    ..['vectorTranslate'] = ((JSString src, JSString dst, JSArray<JSString>? args) =>
            _run('vectorTranslate', () => gdal.vectorTranslate(src.toDart, dst.toDart, args: strings(args))))
        .toJS
    ..['warp'] = ((JSString src, JSString dst, JSArray<JSString>? args) =>
            _run('warp', () => gdal.warp(src.toDart, dst.toDart, args: strings(args))))
        .toJS
    ..['translate'] = ((JSString src, JSString dst, JSArray<JSString>? args) =>
            _run('translate', () => gdal.translate(src.toDart, dst.toDart, args: strings(args))))
        .toJS
    ..['fileList'] = ((JSString path) => _run('fileList', () => gdal.fileList(path.toDart))).toJS;
  globalContext['kokageGdal'] = hook;
  AppLogger.debug('[Gdal] window.kokageGdal を差し込んだ（開発用）');
}

JSPromise<JSString> _run(String name, Future<Object?> Function() body) {
  Future<JSString> go() async {
    final sw = Stopwatch()..start();
    try {
      final result = await body();
      AppLogger.debug('[Gdal] $name 完了: ${sw.elapsedMilliseconds} ms');
      return jsonEncode({'ok': true, 'ms': sw.elapsedMilliseconds, 'result': result}).toJS;
    } catch (e) {
      AppLogger.debug('[Gdal] $name 失敗: ${sw.elapsedMilliseconds} ms: $e');
      return jsonEncode({'ok': false, 'ms': sw.elapsedMilliseconds, 'error': '$e'}).toJS;
    }
  }

  return go().toJS;
}
