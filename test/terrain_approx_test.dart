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

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

DemGrid _dem(TileKey key, double Function(int c, int r) f) {
  const n = 256;
  final mpp = WebMercator.metersPerPixel(key.z);
  final h = Float32List(n * n);
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      h[r * n + c] = f(c, r);
    }
  }
  return DemGrid(cols: n, rows: n, originX: key.west + mpp / 2, originY: key.south + mpp / 2, cellSize: mpp, heights: h);
}

void main() {
  group('DemTileSource.decode（地理院 PNG）', () {
    const gsi = DemTileSource.gsiDem1a;
    test('正・負・無効', () {
      // x = 12345 → 123.45m
      expect(gsi.decode(0, 0x30, 0x39), closeTo(123.45, 1e-6));
      // x = 2^24 - 500 → -5.00m
      const x = (1 << 24) - 500;
      expect(gsi.decode((x >> 16) & 255, (x >> 8) & 255, x & 255), closeTo(-5.0, 1e-6));
      // (128, 0, 0) = 無効
      expect(gsi.decode(128, 0, 0).isNaN, isTrue);
      // Terrarium は従来どおり
      expect(DemTileSource.aws.decode(128, 100, 0), closeTo(100, 1e-6));
    });
  });

  group('upsampleFromParent（親から高さの空間で補間）', () {
    test('一定の親 → 一定の子', () {
      final parent = Float32List(256 * 256)..fillRange(0, 256 * 256, 500);
      final child = upsampleFromParent(UpsampleArgs(parent: parent, levels: 1, childX: 3, childY: 7));
      expect(child.length, 256 * 256);
      expect(child.every((v) => (v - 500).abs() < 1e-3), isTrue);
    });

    test('東西の傾斜は滑らかに（階段にならない）、子の位置で切り出す', () {
      // 親: 高さ = 列番号（西 0 → 東 255）
      final parent = Float32List(256 * 256);
      for (var r = 0; r < 256; r++) {
        for (var c = 0; c < 256; c++) {
          parent[r * 256 + c] = c.toDouble();
        }
      }
      // 2 段上の親の中で、子 x=5 は 5 & 3 = 1 → 親の列 64〜127 に当たる
      final child = upsampleFromParent(UpsampleArgs(parent: parent, levels: 2, childX: 5, childY: 0));
      final mid = child[128 * 256 + 0];
      expect(mid, closeTo(64 - 0.375, 0.01), reason: '西端は親の列 64 の少し手前');
      expect(child[128 * 256 + 255], closeTo(127 + 0.375, 0.01));
      // 隣の格子点との差が一定（= 滑らか。RGB 拡大なら 4 点ごとの階段）
      for (var c = 1; c < 255; c++) {
        expect(child[128 * 256 + c] - child[128 * 256 + c - 1], closeTo(0.25, 1e-3));
      }
    });

    test('南北の向き: タイル y は北から、DemGrid は南が 0 行目', () {
      // 親: 高さ = 行番号（南 0 → 北 255）
      final parent = Float32List(256 * 256);
      for (var r = 0; r < 256; r++) {
        for (var c = 0; c < 256; c++) {
          parent[r * 256 + c] = r.toDouble();
        }
      }
      // 1 段上の親で、子 y が偶数（北側の子）→ 親の北半分（行 128〜255）
      final north = upsampleFromParent(UpsampleArgs(parent: parent, levels: 1, childX: 0, childY: 10));
      final south = upsampleFromParent(UpsampleArgs(parent: parent, levels: 1, childX: 0, childY: 11));
      expect(north[0], greaterThan(127));
      expect(south[255 * 256], lessThan(128.5));
    });
  });

  group('TerrainWorld の近似タイル', () {
    test('近似（親から）は本物が届いたら差し替わり、本物は近似で上書きされない', () {
      fakeAsync((async) {
        const key = TileKey(15, 100, 200);
        var exactAvailable = false;
        final world = TerrainWorld(
          demSources: const [DemTileSource.aws],
          demFetcher: (s, z, x, y) async => null,
          textureFetcher: (z, x, y) async => null,
          tileLoader: (k) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            if (exactAvailable) return TerrainTile(key: k, raw: _dem(k, (c, r) => 700));
            return TerrainTile(key: k, raw: _dem(k, (c, r) => 500), sourceZoom: k.z - 2);
          },
        );
        const range = TileRange(z: 15, x0: 100, y0: 200, x1: 100, y1: 200);
        world.ensure(range, centerX: key.west, centerY: key.south);
        async.elapse(const Duration(milliseconds: 50));
        expect(world.has(key), isTrue);
        expect(world.tiles.first.approximate, isTrue);
        expect(world.tiles.first.raw.heights[0], 500);
        // 失敗直後は取り直さない
        world.ensure(range, centerX: key.west, centerY: key.south);
        expect(world.pendingCount, 0);
        // 待ち時間が過ぎたら本物を取りに行き、差し替わる（DateTime.now は fake_async では進まないので中を直接進める）
        exactAvailable = true;
        world.debugClearFailures();
        world.ensure(range, centerX: key.west, centerY: key.south);
        expect(world.pendingCount, 1);
        async.elapse(const Duration(milliseconds: 50));
        expect(world.tiles.first.approximate, isFalse);
        expect(world.tiles.first.raw.heights[0], 700);
        // 本物がある所には近似も本物も再要求しない
        world.ensure(range, centerX: key.west, centerY: key.south);
        expect(world.pendingCount, 0);
      });
    });
  });
}
