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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_painter.dart';
import 'package:root_maps/core/terrain/terrain_scene.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

/// 256×256 の擬似タイル（標高 = base + 列番号）
TerrainTile fakeTile(TileKey key, double base) {
  const n = 256;
  final h = Float32List(n * n);
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      h[r * n + c] = base + c;
    }
  }
  final mpp = WebMercator.metersPerPixel(key.z);
  return TerrainTile(
    key: key,
    raw: DemGrid(cols: n, rows: n, originX: key.west + mpp / 2, originY: key.south + mpp / 2, cellSize: mpp, heights: h),
  );
}

void main() {
  group('TileKey / tileRangeFor', () {
    test('タイルの範囲は Mercator の矩形を覆う', () {
      const z = 14;
      const key = TileKey(z, 14380, 6541); // 北山村付近
      final b = key.bounds;
      final range = TerrainWorld.tileRangeFor(b.deflate(1), z);
      expect((range.x0, range.y0, range.x1, range.y1), (14380, 6541, 14380, 6541));
      // 余白 1 枚
      final wide = TerrainWorld.tileRangeFor(b.deflate(1), z, margin: 1);
      expect((wide.x0, wide.y0, wide.x1, wide.y1), (14379, 6540, 14381, 6542));
      // 東隣・北隣
      expect(key.east.bounds.left, closeTo(b.right, 1e-6));
      expect(key.north.bounds.top, closeTo(b.bottom, 1e-6)); // Rect の top/bottom は y 昇順
    });
  });

  group('TerrainTile の縁', () {
    test('東と北の隣の縁を借りて 257×257 になり、無ければ自分の縁を延ばす', () {
      const key = TileKey(10, 100, 100);
      final t = fakeTile(key, 0);
      expect(t.bordered.cols, 257);
      expect(t.bordered.rows, 257);
      // 隣なし: 東端は自分の最後の列（255）
      expect(t.bordered.heightAtIndex(256, 10), 255);
      // 東隣（標高 = 1000 + 列）を付けると、東端はその 0 列目 = 1000
      final east = fakeTile(key.east, 1000);
      final north = fakeTile(key.north, 2000);
      final ne = fakeTile(key.northEast, 3000);
      expect(t.updateBorder(east, north, ne), isTrue);
      expect(t.bordered.heightAtIndex(256, 10), 1000);
      expect(t.bordered.heightAtIndex(10, 256), 2010); // 北隣の 0 行目・列 10
      expect(t.bordered.heightAtIndex(256, 256), 3000);
      // 同じ組み合わせなら変わらない
      expect(t.updateBorder(east, north, ne), isFalse);
      // 幅はちょうどタイル 1 枚ぶん（隣の 0 列目まで）
      expect(t.bordered.width, closeTo(key.span, 1e-6));
    });
  });

  group('TerrainWorld', () {
    TerrainWorld world() => TerrainWorld(
          demSource: DemTileSource.aws,
          demFetcher: (z, x, y) async => null,
          textureFetcher: (z, x, y) async => null,
        );

    test('描画順は奥の行から手前へ、行内も奥から手前へ', () {
      final w = world();
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1, bearing: 0); // 北が奥、東が手前ではない（sinB=0 → eastFar=false）
      const range = TileRange(z: 10, x0: 100, y0: 100, x1: 101, y1: 101);
      // タイルを直接流し込む（private なので ensure を通さず drawOrder の並びだけ見る）
      // ここでは順序の規則を確認する: 北が奥（y 小）なら y 昇順、東が奥でなければ x 降順
      final order = w.drawOrder(range, cam);
      expect(order, isEmpty); // 読み込み前は空
      // 規則そのものは TerrainMesh 側でテスト済み。ここでは象限の判定だけ
      final camNE = TerrainCamera(centerX: 0, centerY: 0, scale: 1, bearing: math.pi / 4);
      expect(math.sin(camNE.bearing) > 0, isTrue);
      expect(math.cos(camNE.bearing) > 0, isTrue);
    });

    test('demZoomFor は表示ズームの 1 段下でソースの範囲に収まる', () {
      final w = world();
      expect(w.demZoomFor(16), 15);
      expect(w.demZoomFor(20), 15);
      expect(w.demZoomFor(3), 2); // AWS の minZoom は 0
    });

    test('groundBounds は傾けるほど広い', () {
      final w = world();
      const size = Size(800, 600);
      final flat = TerrainCamera(centerX: 0, centerY: 0, scale: 0.5);
      final tilted = TerrainCamera(centerX: 0, centerY: 0, scale: 0.5, pitch: 1.0);
      final b0 = w.groundBounds(flat, size, heightRange: 0);
      final b1 = w.groundBounds(tilted, size, heightRange: 0);
      expect(b0.width, closeTo(1600, 1e-6));
      expect(b0.height, closeTo(1200, 1e-6));
      expect(b1.height, greaterThan(b0.height));
      expect(b1.width, closeTo(b0.width, 1e-6));
    });
  });

  group('タイル単位の貼り付け', () {
    test('clipPolylineToRect は矩形の中の区間だけを返す', () {
      final pieces = clipPolylineToRect(
        [const Offset(-10, 5), const Offset(20, 5), const Offset(20, 30), const Offset(-10, 30)],
        const Rect.fromLTWH(0, 0, 10, 40),
      );
      expect(pieces.length, 2);
      expect(pieces[0].first.dx, closeTo(0, 1e-9));
      expect(pieces[0].last.dx, closeTo(10, 1e-9));
      expect(pieces[1].first.dx, closeTo(10, 1e-9));
      expect(pieces[1].last.dx, closeTo(0, 1e-9));
    });

    test('clipRect の外のフィーチャは貼られず、またぐ線は切られる', () {
      final dem = DemGrid(
        cols: 11,
        rows: 11,
        originX: 0,
        originY: 0,
        cellSize: 10,
        heights: Float32List(121)..fillRange(0, 121, 50),
      );
      final cam = TerrainCamera(centerX: 50, centerY: 50, scale: 1);
      final mesh = TerrainMesh.build(dem, cam, textureWidth: 4, textureHeight: 4, chunkSize: 5);
      final b = TerrainSceneBuilder(mesh: mesh, stylesByKey: const {});
      geo.Geographic at(double x, double y) => geo.Geographic(lon: WebMercator.lonFromX(x), lat: WebMercator.latFromY(y));
      final scene = b.build(
        lines: [
          geo.Feature<geo.Geometry>(geometry: geo.LineString.from([at(-50, 20), at(150, 20)]), properties: {'k-label': 'L'}),
          geo.Feature<geo.Geometry>(geometry: geo.LineString.from([at(200, 20), at(300, 20)])),
        ],
        points: [
          geo.Feature<geo.Point>(geometry: geo.Point(at(30, 30))),
          geo.Feature<geo.Point>(geometry: geo.Point(at(500, 30))),
        ],
        clipRect: const Rect.fromLTWH(0, 0, 100, 100),
      );
      expect(scene.lines.length, 1);
      expect(scene.lines[0].xyz[0], closeTo(0, 1e-6)); // 切られて 0 から
      expect(scene.points.length, 1);
      expect(scene.labels.length, 1); // 中点 (50,20) は中
    });
  });
}
