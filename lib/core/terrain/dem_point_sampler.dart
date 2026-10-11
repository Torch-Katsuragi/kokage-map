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
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'dem_tiles.dart';
import 'terrain_worker.dart';
import 'terrain_world.dart' show DemFetcher;
import 'web_mercator.dart';

/// 緯度経度の点ごとに標高を引く（3D 地形と同じ標高タイル・同じ取り方）
///
/// ソースは細かい方から試す（[DemTileSource.defaultCascade]: DEM1A → DEM5A → DEM10B → AWS）。
/// 各ソースの最大ズームのタイルを 1 枚ずつ取り、タイル内を双一次補間する。無効値（海・整備範囲外）や
/// 取れないタイルは次のソースへ。どれでも取れない点は null。
///
/// タイルは [DemFetcher]（アプリでは `BaseMapService.getTile`: キャッシュ → ネット）で取るので、
/// 3D で見た辺りならオフラインでも引ける。PNG の展開は [TerrainWorker] で（UI を止めない）
class DemPointSampler {
  DemPointSampler({required this.fetch, this.sources = DemTileSource.defaultCascade, this.cacheTiles = 16});

  final DemFetcher fetch;
  final List<DemTileSource> sources;

  /// 展開したタイルを何枚覚えておくか（続けて保存する地物は同じ辺り）
  final int cacheTiles;

  final Map<String, Float32List?> _tiles = {};

  /// [points]（経度, 緯度）の標高（m）。引けない点は null
  Future<List<double?>> sample(List<(double lon, double lat)> points) async {
    final out = List<double?>.filled(points.length, null);
    var pending = [for (var i = 0; i < points.length; i++) i];
    for (final s in sources) {
      if (pending.isEmpty) break;
      final z = s.maxZoom;
      // タイルごとにまとめる
      final byTile = <(int, int), List<int>>{};
      for (final i in pending) {
        final (lon, lat) = points[i];
        final fx = WebMercator.tileXFraction(lon, z);
        final fy = WebMercator.tileYFraction(lat, z);
        byTile.putIfAbsent((fx.floor(), fy.floor()), () => []).add(i);
      }
      final next = <int>[];
      for (final MapEntry(key: (tx, ty), value: idx) in byTile.entries) {
        final h = await _tile(s, z, tx, ty);
        for (final i in idx) {
          final (lon, lat) = points[i];
          final v = h == null
              ? double.nan
              : _bilinear(h, WebMercator.tileXFraction(lon, z) - tx, WebMercator.tileYFraction(lat, z) - ty);
          if (v.isNaN) {
            next.add(i);
          } else {
            out[i] = v;
          }
        }
      }
      pending = next;
    }
    return out;
  }

  Future<Float32List?> _tile(DemTileSource s, int z, int x, int y) async {
    final key = '${s.id}/$z/$x/$y';
    if (_tiles.containsKey(key)) {
      final h = _tiles.remove(key);
      _tiles[key] = h; // 新しい方へ
      return h;
    }
    Float32List? heights;
    try {
      final bytes = await fetch(s, z, x, y);
      if (bytes != null) heights = await TerrainWorker.instance.run(_decodeTile, (bytes, s.encoding));
    } catch (_) {
      heights = null;
    }
    _tiles[key] = heights;
    while (_tiles.length > cacheTiles) {
      _tiles.remove(_tiles.keys.first);
    }
    return heights;
  }

  /// タイル内の位置（0〜1、北が 0）の標高。格子点はピクセル中心。どれかが無効なら NaN
  static double _bilinear(Float32List h, double u, double v) {
    const n = WebMercator.tileSize;
    final fx = (u * n - 0.5).clamp(0.0, n - 1.0);
    final fy = (v * n - 0.5).clamp(0.0, n - 1.0);
    final c0 = fx.floor().clamp(0, n - 2);
    final r0 = fy.floor().clamp(0, n - 2);
    final tx = fx - c0;
    final ty = fy - r0;
    double at(int c, int r) => h[r * n + c];
    return (at(c0, r0) * (1 - tx) + at(c0 + 1, r0) * tx) * (1 - ty) +
        (at(c0, r0 + 1) * (1 - tx) + at(c0 + 1, r0 + 1) * tx) * ty;
  }
}

/// PNG → 標高（行優先・北が 0 行目、無効値は NaN）。isolate で走る
Float32List? _decodeTile((Uint8List, DemEncoding) a) {
  final (bytes, encoding) = a;
  final decoded = img.decodePng(bytes);
  if (decoded == null) return null;
  const n = WebMercator.tileSize;
  if (decoded.width != n || decoded.height != n) return null;
  final rgb = decoded.convert(format: img.Format.uint8, numChannels: 3).toUint8List();
  final out = Float32List(n * n);
  for (var i = 0; i < n * n; i++) {
    out[i] = DemTileSource.decodeWith(encoding, rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]);
  }
  return out;
}
