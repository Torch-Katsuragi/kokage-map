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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'dem_grid.dart';
import 'terrain_worker.dart';
import 'web_mercator.dart';

/// 標高タイルの符号化
enum DemEncoding {
  /// Terrarium: `h = R*256 + G + B/256 - 32768`（AWS Terrain Tiles）
  terrarium,

  /// Mapbox Terrain-RGB: `h = -10000 + (R*65536 + G*256 + B) * 0.1`
  mapboxRgb,

  /// 地理院 標高タイル PNG: `x = 2^16 R + 2^8 G + B`、x < 2^23 なら `h = 0.01 x`、x > 2^23 なら `h = 0.01 (x − 2^24)`、
  /// x = 2^23（RGB = 128,0,0）は無効（海・データなし）
  gsiPng,
}

/// 標高タイルの出どころ（プリセット構造。アプリは中身を知らない）
class DemTileSource {
  const DemTileSource({
    required this.id,
    required this.urlTemplate,
    required this.encoding,
    required this.attribution,
    this.minZoom = 0,
    this.maxZoom = 15,
    this.lastResort = false,
  });

  /// タイルキャッシュの擬似プロバイダ ID にも使う（重複不可）
  final String id;

  /// 前のソースが 1 枚も取れなかったときだけ取りに行く（遠くて遅い。海や整備範囲の縁の穴は埋めない）
  final bool lastResort;

  final String urlTemplate;
  final DemEncoding encoding;
  final String attribution;
  final int minZoom;
  final int maxZoom;

  /// AWS Terrain Tiles（全球・キー不要・Terrarium）。日本は 30m 級を引き伸ばしたもの。最後の受け皿
  static const aws = DemTileSource(
    id: 'aws_terrarium',
    urlTemplate: 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
    encoding: DemEncoding.terrarium,
    attribution: 'Terrain Tiles (Mapzen / AWS Open Data)',
    maxZoom: 15,
    lastResort: true,
  );

  /// 地理院 標高タイル DEM1A（航空レーザ 1m メッシュ、精度 0.3m 以内、整備範囲のみ。2025-03 に範囲拡大）
  static const gsiDem1a = DemTileSource(
    id: 'gsi_dem1a_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem1a_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 17,
  );

  /// 地理院 標高タイル DEM5A（航空レーザ 5m メッシュ、精度 0.3m 以内、整備範囲のみ）
  static const gsiDem5a = DemTileSource(
    id: 'gsi_dem5a_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem5a_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 15,
  );

  /// 地理院 標高タイル DEM10B（1/2.5 万地形図の等高線由来、全国）
  static const gsiDem10b = DemTileSource(
    id: 'gsi_dem10b_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 14,
  );

  /// 既定の並び: 細かい方から試し、無ければ次へ（DEM1A → DEM5A → DEM10B → AWS）
  static const defaultCascade = [gsiDem1a, gsiDem5a, gsiDem10b, aws];

  String url(int z, int x, int y) => urlTemplate
      .replaceAll('{z}', '$z')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y');

  /// 無効値は NaN
  double decode(int r, int g, int b) => switch (encoding) {
        DemEncoding.terrarium => r * 256 + g + b / 256 - 32768,
        DemEncoding.mapboxRgb => -10000 + (r * 65536 + g * 256 + b) * 0.1,
        DemEncoding.gsiPng => _decodeGsi((r << 16) | (g << 8) | b),
      };

  static double _decodeGsi(int x) {
    const half = 1 << 23;
    if (x == half) return double.nan;
    return (x < half ? x : x - (1 << 24)) * 0.01;
  }
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

  /// 1 段粗い親の範囲
  TileRange get parent => TileRange(z: z - 1, x0: x0 >> 1, y0: y0 >> 1, x1: x1 >> 1, y1: y1 >> 1);

  /// 周りに [margin] 枚の余白を足した範囲（世界の端で切る）
  TileRange grow(int margin) {
    if (margin <= 0) return this;
    final n = 1 << z;
    return TileRange(
      z: z,
      x0: (x0 - margin).clamp(0, n - 1),
      y0: (y0 - margin).clamp(0, n - 1),
      x1: (x1 + margin).clamp(0, n - 1),
      y1: (y1 + margin).clamp(0, n - 1),
    );
  }

  bool contains(int tz, int tx, int ty) => tz == z && tx >= x0 && tx <= x1 && ty >= y0 && ty <= y1;

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

  /// [range] の全タイルを 1 枚の格子にする。格子点はピクセル中心。1 枚でも取れなければ例外
  Future<DemGrid> load(TileRange range, {TileProgress? onProgress}) async {
    final dem = await tryLoad(range, onProgress: onProgress);
    if (dem == null) throw StateError('DEM タイルが取れない: ${range.z}/${range.x0}/${range.y0}');
    return dem;
  }

  /// [load] の null 版。1 枚でも取れなければ null
  /// （⚠ 以前は取れなかったタイルが 0m の平面になっていた）
  ///
  /// [fillInvalid] が false なら無効値（地理院タイルの海・データなし）を NaN のまま返す
  /// （呼び出し側が別ソースで埋める）。true なら [fillInvalidHeights] で埋める
  Future<DemGrid?> tryLoad(TileRange range, {TileProgress? onProgress, bool fillInvalid = true}) async {
    final z = range.z;
    final sw = Stopwatch()..start();
    final bytesList = await _fetchRange(_fetch, range, onProgress: onProgress);
    if (bytesList.any((b) => b == null)) return null;
    final fetchMs = sw.elapsedMilliseconds;
    // PNG のデコードと格子の組み立ては純 Dart で数百 ms 掛かるので isolate へ（web では同じスレッド）
    final heights = await TerrainWorker.instance.run(
      _assembleHeights,
      _AssembleArgs(bytesList: bytesList, width: range.width, height: range.height, encoding: source.encoding),
    );
    if (sw.elapsedMilliseconds > 800) {
      debugPrint('[3D] dem ${range.z}/${range.x0}/${range.y0} fetch ${fetchMs}ms assemble ${sw.elapsedMilliseconds - fetchMs}ms');
    }
    if (fillInvalid) fillInvalidHeights(heights);
    const ts = WebMercator.tileSize;
    final cols = range.width * ts;
    final rows = range.height * ts;
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

class _AssembleArgs {
  const _AssembleArgs({required this.bytesList, required this.width, required this.height, required this.encoding});

  final List<Uint8List?> bytesList;
  final int width;
  final int height;
  final DemEncoding encoding;
}

/// タイル画像列 → 標高格子（南が 0 行目）。isolate で走る
/// 親タイル（[levels] 段上）の高さから、子タイル (childX, childY) の 256×256 を高さの空間で双一次補間して作る
///
/// PNG の RGB を拡大すると 2×2〜8×8 のブロック状の階段になる（Terrarium の桁が独立に補間される）。
/// 高さに直してから補間すれば、粗いだけで滑らかな地形になる
class UpsampleArgs {
  const UpsampleArgs({required this.parent, required this.levels, required this.childX, required this.childY});

  /// 親の高さ（256×256・南が 0 行目）
  final Float32List parent;
  final int levels;
  final int childX;
  final int childY;
}

Float32List upsampleFromParent(UpsampleArgs a) {
  const n = WebMercator.tileSize;
  final f = 1 << a.levels; // 親 1 枚に子が f×f
  final sub = n ~/ f; // 子 1 枚ぶんの親の格子点数
  final cx = a.childX & (f - 1);
  final cyNorth = a.childY & (f - 1); // タイル y は北から。DemGrid は南が 0 行目
  final c0 = cx * sub;
  final r0 = (f - 1 - cyNorth) * sub;
  final out = Float32List(n * n);
  // 子の格子点 i（ピクセル中心）は親の格子座標で (i + 0.5) / f - 0.5
  for (var r = 0; r < n; r++) {
    final py = r0 + (r + 0.5) / f - 0.5;
    final ry0 = py.floor().clamp(0, n - 1);
    final ry1 = (ry0 + 1).clamp(0, n - 1);
    final ty = (py - ry0).clamp(0.0, 1.0);
    for (var c = 0; c < n; c++) {
      final px = c0 + (c + 0.5) / f - 0.5;
      final cx0 = px.floor().clamp(0, n - 1);
      final cx1 = (cx0 + 1).clamp(0, n - 1);
      final tx = (px - cx0).clamp(0.0, 1.0);
      final h00 = a.parent[ry0 * n + cx0];
      final h10 = a.parent[ry0 * n + cx1];
      final h01 = a.parent[ry1 * n + cx0];
      final h11 = a.parent[ry1 * n + cx1];
      out[r * n + c] = (h00 * (1 - tx) + h10 * tx) * (1 - ty) + (h01 * (1 - tx) + h11 * tx) * ty;
    }
  }
  return out;
}

Float32List _assembleHeights(_AssembleArgs a) {
  const ts = WebMercator.tileSize;
  final cols = a.width * ts;
  final rows = a.height * ts;
  final heights = Float32List(cols * rows);
  double decode(int r, int g, int b) => switch (a.encoding) {
        DemEncoding.terrarium => r * 256 + g + b / 256 - 32768,
        DemEncoding.mapboxRgb => -10000 + (r * 65536 + g * 256 + b) * 0.1,
        DemEncoding.gsiPng => DemTileSource._decodeGsi((r << 16) | (g << 8) | b),
      };
  var k = 0;
  for (var ty = 0; ty < a.height; ty++) {
    for (var tx = 0; tx < a.width; tx++) {
      final bytes = a.bytesList[k++];
      if (bytes == null) continue;
      final decoded = img.decodePng(bytes);
      if (decoded == null) continue;
      final rgb = decoded.convert(format: img.Format.uint8, numChannels: 3).toUint8List();
      final baseC = tx * ts;
      // タイル画像は北が 0 行目。DemGrid は南が 0 行目
      final baseR = (a.height - 1 - ty) * ts;
      for (var iy = 0; iy < ts; iy++) {
        final r = baseR + (ts - 1 - iy);
        final rowOff = r * cols + baseC;
        final src = iy * ts * 3;
        for (var ix = 0; ix < ts; ix++) {
          final p = src + ix * 3;
          heights[rowOff + ix] = decode(rgb[p], rgb[p + 1], rgb[p + 2]);
        }
      }
    }
  }
  return heights;
}

/// 無効値（NaN。地理院タイルの海・データなし・水面）を埋める: 直前の有効値。先頭が無効なら最初の有効値、全部無効なら 0（海面）
///
/// ⚠ 整備範囲の縁のタイルは大半が無効で、これで埋めると行ごとの縞と巨大な台地になる。
/// 世界（TerrainWorld）は先に次のソースで埋め（[TerrainWorld] の連なり）、残りだけこれで埋める
void fillInvalidHeights(Float32List h) {
  var last = 0.0;
  for (var i = 0; i < h.length; i++) {
    if (!h[i].isNaN) {
      last = h[i];
      break;
    }
  }
  for (var i = 0; i < h.length; i++) {
    final v = h[i];
    if (v.isNaN) {
      h[i] = last;
    } else {
      last = v;
    }
  }
}

/// テクスチャに上描きする手（オーバーレイ画像など）。canvas は [range] の左上が原点、1 タイル = 256px
typedef TextureDecorator = void Function(ui.Canvas canvas, TileRange range);

/// ラスタタイル（背景地図）を 1 枚の画像に合成する
///
/// 設計どおり「表示範囲のタイルを 1 枚に合成してから ImageShader で貼る」。
class RasterTileComposer {
  RasterTileComposer({String? urlTemplate, TileFetcher? fetcher, TileImageCache? imageCache})
      : assert(urlTemplate != null || fetcher != null),
        _fetch = fetcher ?? httpTileFetcher(urlTemplate!),
        _imageCache = imageCache;

  final TileFetcher _fetch;
  final TileImageCache? _imageCache;

  /// [range] のタイルを敷き詰めた画像を返す（幅 = width×256）
  Future<ui.Image> compose(TileRange range, {TileProgress? onProgress, TextureDecorator? decorate}) =>
      composeLayers(range, [(_fetch, 1.0)], onProgress: onProgress, decorate: decorate);

  /// 複数のタイル層を opacity で重ねて 1 枚にする（背景地図のブレンド。MapLibre 側と同じ累積補正済み opacity を渡す）。
  /// [decorate] は最後に呼ばれ、オーバーレイ画像などを上に描ける（座標は範囲左上原点のピクセル）
  Future<ui.Image> composeLayers(
    TileRange range,
    List<(TileFetcher, double)> layers, {
    TileProgress? onProgress,
    TextureDecorator? decorate,
  }) async {
    const ts = WebMercator.tileSize;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, range.width * ts * 1.0, range.height * ts * 1.0),
      ui.Paint()..color = const ui.Color(0xFFDDDDDD),
    );
    final owned = <ui.Image>[]; // キャッシュに入れなかった画像（合成後に捨てる）
    var doneTotal = 0;
    final total = range.count * layers.length;
    for (var li = 0; li < layers.length; li++) {
      final (fetch, opacity) = layers[li];
      final cache = _imageCache;
      // キャッシュに無いタイルだけ取る
      final missing = <(int, int)>[];
      for (var ty = range.y0; ty <= range.y1; ty++) {
        for (var tx = range.x0; tx <= range.x1; tx++) {
          if (cache == null || cache.get(li, range.z, tx, ty) == null) missing.add((tx, ty));
        }
      }
      final fetched = <(int, int), Uint8List?>{};
      if (missing.isNotEmpty) {
        var next = 0;
        var done = 0;
        Future<void> worker() async {
          while (true) {
            final i = next++;
            if (i >= missing.length) return;
            final (tx, ty) = missing[i];
            fetched[(tx, ty)] = await fetch(range.z, tx, ty);
            done++;
            onProgress?.call(doneTotal + done, total);
          }
        }

        await Future.wait([for (var k = 0; k < 8; k++) worker()]);
      }
      doneTotal += range.count;
      final paint = ui.Paint()..color = ui.Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
      for (var ty = range.y0; ty <= range.y1; ty++) {
        for (var tx = range.x0; tx <= range.x1; tx++) {
          var image = cache?.get(li, range.z, tx, ty);
          if (image == null) {
            final bytes = fetched[(tx, ty)];
            if (bytes == null) continue;
            try {
              final codec = await ui.instantiateImageCodec(bytes);
              final frame = await codec.getNextFrame();
              image = frame.image;
            } catch (_) {
              continue; // 壊れたタイルは飛ばす
            }
            if (cache != null) {
              cache.put(li, range.z, tx, ty, image);
            } else {
              owned.add(image);
            }
          }
          canvas.drawImage(
            image,
            ui.Offset((tx - range.x0) * ts * 1.0, (ty - range.y0) * ts * 1.0),
            paint,
          );
        }
      }
    }
    decorate?.call(canvas, range);
    final picture = recorder.endRecording();
    final image = await picture.toImage(range.width * ts, range.height * ts);
    picture.dispose();
    for (final i in owned) {
      i.dispose();
    }
    return image;
  }
}

/// デコード済みタイル画像の LRU（層番号・z・x・y で引く）
///
/// パンで隣へ読み直すとき、重なるタイルを再取得・再デコードしないため。
class TileImageCache {
  TileImageCache({this.capacity = 512});

  final int capacity;
  final _map = <String, ui.Image>{};

  String _key(int layer, int z, int x, int y) => '$layer/$z/$x/$y';

  ui.Image? get(int layer, int z, int x, int y) {
    final k = _key(layer, z, x, y);
    final v = _map.remove(k);
    if (v != null) _map[k] = v; // 末尾へ（最近使った）
    return v;
  }

  void put(int layer, int z, int x, int y, ui.Image image) {
    _map[_key(layer, z, x, y)] = image;
    while (_map.length > capacity) {
      final oldest = _map.keys.first;
      _map.remove(oldest)?.dispose();
    }
  }

  void clear() {
    for (final i in _map.values) {
      i.dispose();
    }
    _map.clear();
  }
}
