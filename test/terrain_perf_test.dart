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
// 1 万面の最適化で入れた仕組みの検算（増分の束、標高参照の近道）
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_painter.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

DemGrid _rampDem(TileKey key) {
  const n = 256;
  final mpp = WebMercator.metersPerPixel(key.z);
  final h = Float32List(n * n);
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      h[r * n + c] = key.z * 1000.0 + r + c * 0.5; // 段ごとに違う値にして、どのタイルから引いたか分かるように
    }
  }
  return DemGrid(cols: n, rows: n, originX: key.west + mpp / 2, originY: key.south + mpp / 2, cellSize: mpp, heights: h);
}

void main() {
  group('PolygonBatch の増分', () {
    late TerrainMesh mesh;
    late List<LiftedPolygon> polys;

    setUp(() {
      final dem = DemGrid.synthetic(cols: 41, rows: 41, cellSize: 10);
      final cam = TerrainCamera(centerX: 200, centerY: 200, scale: 1, bearing: 0.4, pitch: 0.7);
      mesh = TerrainMesh.build(dem, cam, textureWidth: 256, textureHeight: 256, chunkSize: 8);
      final rnd = math.Random(7);
      polys = [
        for (var i = 0; i < 30; i++)
          () {
            final x = rnd.nextDouble() * 340 + 20;
            final y = rnd.nextDouble() * 340 + 20;
            final s = rnd.nextDouble() * 60 + 10;
            return LiftedPolygon.lift(
              [Offset(x, y), Offset(x + s, y), Offset(x + s, y + s), Offset(x, y + s), Offset(x, y)],
              mesh,
              color: Color(0xFF000000 | rnd.nextInt(0xFFFFFF)),
              clipCells: 1 + rnd.nextInt(4),
            );
          }(),
      ];
    });

    test('from で足した束を concat すると一度に作った束と同じ', () {
      final whole = PolygonBatch.byChunk(polys);
      final parts = <int, List<PolygonBatch>>{};
      var from = 0;
      for (final end in [4, 9, 17, polys.length]) {
        final sub = polys.sublist(0, end);
        for (final e in PolygonBatch.byChunk(sub, from: from).entries) {
          (parts[e.key] ??= []).add(e.value);
        }
        from = end;
      }
      expect(parts.keys.toSet(), whole.keys.toSet());
      for (final e in whole.entries) {
        final joined = PolygonBatch.concat(parts[e.key]!);
        expect(joined.xyz, e.value.xyz, reason: 'chunk ${e.key} xyz');
        expect(joined.colors, e.value.colors, reason: 'chunk ${e.key} colors');
        expect(joined.projected.length, joined.xyz.length ~/ 3 * 2);
      }
    });

    test('束の頂点数は面の三角形の合計', () {
      final whole = PolygonBatch.byChunk(polys);
      final tri = polys.fold<int>(0, (a, p) => a + p.triangleCount);
      final inBatches = whole.values.fold<int>(0, (a, b) => a + b.xyz.length ~/ 9);
      expect(inBatches, tri);
    });
  });

  group('TerrainWorld.elevationAt の近道', () {
    test('タイルが重なっていても、一番細かい段から引く（走査と同じ答え）', () {
      final w = TerrainWorld(
        demSources: const [DemTileSource.aws],
        demFetcher: (s, z, x, y) async => null,
        textureFetcher: (z, x, y) async => null,
      );
      addTearDown(w.dispose);
      const keys = [TileKey(14, 100, 200), TileKey(15, 200, 400), TileKey(15, 201, 400), TileKey(15, 200, 401)];
      for (final k in keys) {
        w.addTileForTest(TerrainTile(key: k, raw: _rampDem(k)));
      }
      // 参照: 全タイルを走査して最細のものを選ぶ
      double? slow(double x, double y) {
        TerrainTile? best;
        for (final t in w.tiles) {
          if (best != null && t.key.z <= best.key.z) continue;
          final b = t.key.bounds;
          if (x >= b.left && x < b.right && y >= b.top && y < b.bottom) best = t;
        }
        return best?.raw.elevationAt(x, y);
      }

      final parent = const TileKey(14, 100, 200).bounds;
      final rnd = math.Random(3);
      var hits15 = 0, hits14 = 0, outside = 0;
      for (var i = 0; i < 3000; i++) {
        // 同じ辺りを続けて引く（ラベルの並び）のと、飛ぶのを混ぜる
        final x = parent.left + rnd.nextDouble() * parent.width * 1.2 - parent.width * 0.1;
        final y = parent.top + rnd.nextDouble() * parent.height * 1.2 - parent.height * 0.1;
        final fast = w.elevationAt(x, y);
        final ref = slow(x, y);
        expect(fast, ref, reason: 'at ($x, $y)');
        if (ref == null) {
          outside++;
        } else if (ref >= 15000) {
          hits15++;
        } else {
          hits14++;
        }
      }
      expect(hits15, greaterThan(0));
      expect(hits14, greaterThan(0));
      expect(outside, greaterThan(0));
    });

    test('タイルが増減しても古い近道を使わない', () {
      final w = TerrainWorld(
        demSources: const [DemTileSource.aws],
        demFetcher: (s, z, x, y) async => null,
        textureFetcher: (z, x, y) async => null,
      );
      addTearDown(w.dispose);
      const k14 = TileKey(14, 100, 200);
      const k15 = TileKey(15, 200, 400);
      w.addTileForTest(TerrainTile(key: k14, raw: _rampDem(k14)));
      final b = k15.bounds;
      final x = b.left + b.width / 2, y = b.top + b.height / 2;
      expect(w.elevationAt(x, y)! < 15000, isTrue);
      w.addTileForTest(TerrainTile(key: k15, raw: _rampDem(k15)));
      expect(w.elevationAt(x, y)! >= 15000, isTrue, reason: '細かい段が届いたらそちら');
      w.clear();
      expect(w.elevationAt(x, y), isNull);
    });
  });
}
