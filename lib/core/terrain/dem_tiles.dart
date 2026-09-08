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
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'dem_grid.dart';
import 'web_mercator.dart';

/// 標高タイルの符号化
enum DemEncoding {
  /// Terrarium: `h = R*256 + G + B/256 - 32768`（AWS Terrain Tiles）
  terrarium,

  /// Mapbox Terrain-RGB: `h = -10000 + (R*65536 + G*256 + B) * 0.1`
  mapboxRgb,
}

/// 標高タイルの出どころ（プリセット構造。アプリは中身を知らない）
class DemTileSource {
  const DemTileSource({
    required this.urlTemplate,
    required this.encoding,
    required this.attribution,
    this.minZoom = 0,
    this.maxZoom = 15,
  });

  final String urlTemplate;
  final DemEncoding encoding;
  final String attribution;
  final int minZoom;
  final int maxZoom;

  /// AWS Terrain Tiles（全球・キー不要・Terrarium）。既定のプリセット
  static const aws = DemTileSource(
    urlTemplate: 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
    encoding: DemEncoding.terrarium,
    attribution: 'Terrain Tiles (Mapzen / AWS Open Data)',
    maxZoom: 15,
  );

  String url(int z, int x, int y) => urlTemplate
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y');

  double decode(int r, int g, int b) => switch (encoding) {
        DemEncoding.terrarium => r * 256 + g + b / 256 - 32768,
        DemEncoding.mapboxRgb => -10000 + (r * 65536 + g * 256 + b) * 0.1,
      };
}

/// XYZ タイルの矩形範囲
class TileRange {
  const TileRange({required this.z, required this.x0, required this.y0, required this.x1, required this.y1});

  final int z;
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  int get width => x1 - x0 + 1;
  int get height => y1 - y0 + 1;
  int get count => width * height;

  /// 中心 (lon, lat) を含み、その周りに [tilesAcross] × [tilesAcross] 枚
  ///
  /// 中心がタイルの端に寄らないよう、小数部で隣を選ぶ
  factory TileRange.around(double lonDeg, double latDeg, int z, int tilesAcross) {
    final fx = WebMercator.tileXFraction(lonDeg, z);
    final fy = WebMercator.tileYFraction(latDeg, z);
    final n = 1 << z;
    final cx = (fx - tilesAcross / 2).round().clamp(0, n - tilesAcross);
    final cy = (fy - tilesAcross / 2).round().clamp(0, n - tilesAcross);
    return TileRange(z: z, x0: cx, y0: cy, x1: cx + tilesAcross - 1, y1: cy + tilesAcross - 1);
  }

  /// この範囲をズーム [dz] 段深くしたときの範囲
  TileRange zoomIn(int dz) => TileRange(
        z: z + dz,
        x0: x0 << dz,
        y0: y0 << dz,
        x1: ((x1 + 1) << dz) - 1,
        y1: ((y1 + 1) << dz) - 1,
      );

  /// 西端・南端の Mercator 座標
  double get west => WebMercator.tileWest(x0, z);
  double get south => WebMercator.tileNorth(y1 + 1, z);
  double get widthMeters => width * WebMercator.tileSpan(z);
  double get heightMeters => height * WebMercator.tileSpan(z);
}

/// 進捗通知（読み込んだ枚数 / 全枚数）
typedef TileProgress = void Function(int done, int total);

/// タイル 1 枚の取得。取れなければ null
///
/// 既定は URL テンプレートへの http。アプリでは `BaseMapService.getTile`
/// （キャッシュ → ネット → 祖先タイルからの切り出し）を渡して同じ絵・同じオフライン挙動にする。
typedef TileFetcher = Future<Uint8List?> Function(int z, int x, int y);

/// URL テンプレートから http で取る [TileFetcher]
TileFetcher httpTileFetcher(String urlTemplate, {http.Client? client, Map<String, String>? headers}) {
  final c = client ?? http.Client();
  return (z, x, y) async {
    final uri = Uri.parse(
      urlTemplate.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y'),
    );
    try {
      final res = await c.get(uri, headers: headers);
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null; // 取れなかったタイルは null（DEM は 0m、テクスチャは空）
    }
  };
}

/// [range] の全タイルを並列に取ってくる（行優先・北から）
Future<List<Uint8List?>> _fetchRange(
  TileFetcher fetch,
  TileRange range, {
  int concurrency = 8,
  TileProgress? onProgress,
}) async {
  final coords = <(int, int)>[];
  for (var ty = range.y0; ty <= range.y1; ty++) {
    for (var tx = range.x0; tx <= range.x1; tx++) {
      coords.add((tx, ty));
    }
  }
  final results = List<Uint8List?>.filled(coords.length, null);
  var next = 0;
  var done = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= coords.length) return;
      final (tx, ty) = coords[i];
      results[i] = await fetch(range.z, tx, ty);
      done++;
      onProgress?.call(done, coords.length);
    }
  }

  await Future.wait([for (var k = 0; k < concurrency; k++) worker()]);
  return results;
}

/// 標高タイルを [DemGrid] に組み立てる
class DemTileLoader {
  DemTileLoader({required this.source, TileFetcher? fetcher})
      : _fetch = fetcher ?? httpTileFetcher(source.urlTemplate);

  final DemTileSource source;
  final TileFetcher _fetch;

  /// [range] の全タイルを 1 枚の格子にする。格子点はピクセル中心
  Future<DemGrid> load(TileRange range, {TileProgress? onProgress}) async {
    final z = range.z;
    final bytesList = await _fetchRange(_fetch, range, onProgress: onProgress);
    const ts = WebMercator.tileSize;
    final cols = range.width * ts;
    final rows = range.height * ts;
    final heights = Float32List(cols * rows);
    var k = 0;
    for (var ty = range.y0; ty <= range.y1; ty++) {
      for (var tx = range.x0; tx <= range.x1; tx++) {
        final bytes = bytesList[k++];
        if (bytes == null) continue;
        final decoded = img.decodePng(bytes);
        if (decoded == null) continue;
        final rgb = decoded.convert(format: img.Format.uint8, numChannels: 3).toUint8List();
        final baseC = (tx - range.x0) * ts;
        // タイル画像は北が 0 行目。DemGrid は南が 0 行目
        final baseR = (range.y1 - ty) * ts;
        for (var iy = 0; iy < ts; iy++) {
          final r = baseR + (ts - 1 - iy);
          final rowOff = r * cols + baseC;
          final src = iy * ts * 3;
          for (var ix = 0; ix < ts; ix++) {
            final p = src + ix * 3;
            heights[rowOff + ix] = source.decode(rgb[p], rgb[p + 1], rgb[p + 2]);
          }
        }
      }
    }
    final mpp = WebMercator.metersPerPixel(z);
    return DemGrid(
      cols: cols,
      rows: rows,
      originX: range.west + mpp / 2,
      originY: range.south + mpp / 2,
      cellSize: mpp,
      heights: heights,
    );
  }
}

/// ラスタタイル（背景地図）を 1 枚の画像に合成する
///
/// 設計どおり「表示範囲のタイルを 1 枚に合成してから ImageShader で貼る」。
class RasterTileComposer {
  RasterTileComposer({String? urlTemplate, TileFetcher? fetcher})
      : assert(urlTemplate != null || fetcher != null),
        _fetch = fetcher ?? httpTileFetcher(urlTemplate!);

  final TileFetcher _fetch;

  /// [range] のタイルを敷き詰めた画像を返す（幅 = width×256）
  Future<ui.Image> compose(TileRange range, {TileProgress? onProgress}) async {
    final bytesList = await _fetchRange(_fetch, range, onProgress: onProgress);
    const ts = WebMercator.tileSize;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, range.width * ts * 1.0, range.height * ts * 1.0),
      ui.Paint()..color = const ui.Color(0xFFDDDDDD),
    );
    var k = 0;
    final images = <ui.Image>[];
    for (var ty = range.y0; ty <= range.y1; ty++) {
      for (var tx = range.x0; tx <= range.x1; tx++) {
        final bytes = bytesList[k++];
        if (bytes == null) continue;
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        images.add(frame.image);
        canvas.drawImage(
          frame.image,
          ui.Offset((tx - range.x0) * ts * 1.0, (ty - range.y0) * ts * 1.0),
          ui.Paint(),
        );
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(range.width * ts, range.height * ts);
    picture.dispose();
    for (final i in images) {
      i.dispose();
    }
    return image;
  }
}
