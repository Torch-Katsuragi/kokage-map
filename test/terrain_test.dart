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

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';

void main() {
  group('DemGrid', () {
    test('双一次補間が格子点と中点で正しい', () {
      final dem = DemGrid(
        cols: 2,
        rows: 2,
        originX: 100,
        originY: 200,
        cellSize: 10,
        heights: Float32List.fromList([0, 10, 20, 30]),
      );
      expect(dem.elevationAt(100, 200), 0);
      expect(dem.elevationAt(110, 200), 10);
      expect(dem.elevationAt(100, 210), 20);
      expect(dem.elevationAt(105, 205), 15);
      // 格子外は端に寄せる
      expect(dem.elevationAt(-1000, -1000), 0);
      expect(dem.elevationAt(1000, 1000), 30);
    });

    test('合成地形は起伏の範囲に収まる', () {
      final dem = DemGrid.synthetic(cols: 51, rows: 51, relief: 300);
      final minH = dem.heights.reduce(math.min);
      final maxH = dem.heights.reduce(math.max);
      expect(minH, closeTo(200, 1e-3));
      expect(maxH, closeTo(500, 1e-3));
    });
  });

  group('TerrainCamera', () {
    test('pitch 0 では標高が画面位置に影響しない（真上 = 2D）', () {
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1, zScale: 1.2);
      expect(cam.project(30, 40, 0), cam.project(30, 40, 500));
    });

    test('pitch 0・bearing 0 は北が画面上', () {
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1);
      final p = cam.project(0, 100, 0);
      expect(p.dx, closeTo(0, 1e-9));
      expect(p.dy, closeTo(-100, 1e-9));
    });

    test('bearing 90° では東が画面上', () {
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1, bearing: math.pi / 2);
      final p = cam.project(100, 0, 0);
      expect(p.dx, closeTo(0, 1e-9));
      expect(p.dy, closeTo(-100, 1e-9));
    });

    test('傾けると高い点ほど画面上に上がり、手前（奥行き小）になる', () {
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1, pitch: math.pi / 4);
      final low = cam.project(0, 0, 0);
      final high = cam.project(0, 0, 100);
      expect(high.dy, lessThan(low.dy));
      expect(cam.depth(0, 0, 100), lessThan(cam.depth(0, 0, 0)));
      // 北（奥）の点は遠い
      expect(cam.depth(0, 100, 0), greaterThan(cam.depth(0, 0, 0)));
    });

    test('unprojectPan は project の逆（z 一定）', () {
      final cam = TerrainCamera(
        centerX: 0,
        centerY: 0,
        scale: 2,
        bearing: 0.7,
        pitch: 0.5,
      );
      final world = cam.unprojectPan(const Offset(40, -30));
      final p = cam.project(world.dx, world.dy, 0) * cam.scale;
      expect(p.dx, closeTo(40, 1e-9));
      expect(p.dy, closeTo(-30, 1e-9));
    });
  });

  group('TerrainMesh', () {
    test('帯は奥から手前に並び、全セルがどれかの帯に入る', () {
      final dem = DemGrid.synthetic(cols: 21, rows: 21, cellSize: 10);
      final cam = TerrainCamera(
        centerX: 100,
        centerY: 100,
        scale: 1,
        bearing: 0.3,
        pitch: 0.6,
      );
      final mesh = TerrainMesh.build(
        dem,
        cam,
        textureWidth: 256,
        textureHeight: 256,
        cellsPerBand: 50,
      );
      const cellCount = 20 * 20;
      expect(mesh.cellBand.length, cellCount);
      expect(mesh.bands.fold<int>(0, (a, b) => a + b.cellCount), cellCount);
      expect(mesh.bands.length, (cellCount / 50).ceil());
      // 隠面順: 視線の地上投影に沿って手前にあるセルは、必ず後（大きい帯番号か同じ帯）に描かれる
      // 帯番号しか外から見えないので、帯をまたぐ組だけ検査する
      final eastFar = math.sin(cam.bearing) > 0;
      final northFar = math.cos(cam.bearing) > 0;
      for (var a = 0; a < cellCount; a++) {
        for (var b = 0; b < cellCount; b++) {
          final dc = (b % 20) - (a % 20); // b が a より東にある分
          final dr = (b ~/ 20) - (a ~/ 20);
          final bNearerX = eastFar ? dc < 0 : dc > 0;
          final bNearerY = northFar ? dr < 0 : dr > 0;
          final bInFront = (bNearerX && (bNearerY || dr == 0)) || (bNearerY && dc == 0);
          if (bInFront) {
            expect(mesh.cellBand[b], greaterThanOrEqualTo(mesh.cellBand[a]),
                reason: 'cell $b (手前) が cell $a より先の帯にある');
          }
        }
      }
    });
  });
}
