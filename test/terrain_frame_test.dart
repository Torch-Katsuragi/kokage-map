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
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_frame.dart';
import 'package:root_maps/core/terrain/terrain_worker.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

int _square(int x) => x * x;

int _throwing(int x) => throw StateError('boom $x');

DemGrid _flatDem(TileKey key, {double height = 300}) {
  const n = 256;
  final mpp = WebMercator.metersPerPixel(key.z);
  return DemGrid(
    cols: n,
    rows: n,
    originX: key.west + mpp / 2,
    originY: key.south + mpp / 2,
    cellSize: mpp,
    heights: Float32List(n * n)..fillRange(0, n * n, height),
  );
}

void main() {
  group('TileRange の親・余白・包含', () {
    const r = TileRange(z: 14, x0: 100, y0: 200, x1: 103, y1: 202);

    test('parent は座標を半分にする（端の丸めは切り捨て）', () {
      final p = r.parent;
      expect((p.z, p.x0, p.y0, p.x1, p.y1), (13, 50, 100, 51, 101));
    });

    test('grow は周りに余白を足し、世界の端で止まる', () {
      final g = r.grow(1);
      expect((g.x0, g.y0, g.x1, g.y1), (99, 199, 104, 203));
      expect(r.grow(0), same(r));
      const corner = TileRange(z: 2, x0: 0, y0: 0, x1: 0, y1: 0);
      final c = corner.grow(5);
      expect((c.x0, c.y0, c.x1, c.y1), (0, 0, 3, 3));
    });

    test('contains は段まで見る', () {
      expect(r.contains(14, 100, 200), isTrue);
      expect(r.contains(14, 104, 200), isFalse);
      expect(r.contains(13, 100, 200), isFalse);
    });
  });

  group('DemGrid.heightRange', () {
    test('最小・最大を返し、2 回目はキャッシュ（同じレコード）', () {
      final h = Float32List.fromList([3, 1, 4, 1, 5, 9, 2, 6, 5]);
      final dem = DemGrid(cols: 3, rows: 3, originX: 0, originY: 0, cellSize: 1, heights: h);
      expect(dem.heightRange, (1.0, 9.0));
      h[0] = 100; // キャッシュ後に書き換えても走査し直さない（DEM は不変の前提）
      expect(dem.heightRange, (1.0, 9.0));
    });
  });

  group('TerrainWorld.ancestorRanges', () {
    final world = TerrainWorld(
      demSource: DemTileSource.aws,
      demFetcher: (z, x, y) async => null,
      textureFetcher: (z, x, y) async => null,
    );

    test('粗い方から並び、3 段目以降に余白が付く', () {
      const r = TileRange(z: 14, x0: 100, y0: 200, x1: 103, y1: 202);
      final rs = world.ancestorRanges(r, levels: 4);
      expect(rs.map((x) => x.z), [10, 11, 12, 13]);
      // z13 と z12（1〜2 段上）: 余白なし。z11 と z10（3 段以上上）: 余白 1
      expect(rs[3].count, r.parent.count);
      expect(rs[2].count, r.parent.parent.count);
      expect(rs[1].count, r.parent.parent.parent.grow(1).count);
      expect(rs[0].count, r.parent.parent.parent.parent.grow(1).count);
    });

    test('minZoom で止まる', () {
      const r = TileRange(z: 1, x0: 0, y0: 0, x1: 1, y1: 1);
      expect(world.ancestorRanges(r, levels: 4).map((x) => x.z), [0]);
    });

    test('heightRange はタイルごとの範囲を畳む', () {
      final w = TerrainWorld(
        demSource: DemTileSource.aws,
        demFetcher: (z, x, y) async => null,
        textureFetcher: (z, x, y) async => null,
      );
      expect(w.heightRange, isNull);
      w.addTileForTest(TerrainTile(key: const TileKey(15, 1, 1), raw: _flatDem(const TileKey(15, 1, 1), height: 100)));
      w.addTileForTest(TerrainTile(key: const TileKey(15, 2, 1), raw: _flatDem(const TileKey(15, 2, 1), height: 900)));
      expect(w.heightRange, (100.0, 900.0));
    });
  });

  group('TerrainTile.placeholderBuilder', () {
    test('同期で step 16 のビルダーを返し、2 段制限に数えない', () async {
      const key = TileKey(15, 1, 1);
      final tile = TerrainTile(key: key, raw: _flatDem(key));
      final b = tile.placeholderBuilder();
      expect(b.step, 16);
      expect(identical(tile.placeholderBuilder(), b), isTrue);
      await tile.builderFor(1);
      await tile.builderFor(2);
      await tile.builderFor(4);
      expect(tile.builders.keys.toSet(), {16, 2, 4}, reason: '16 は数えず、1 は 4 から遠いので捨てる');
    });
  });

  group('TerrainFramePlanner.demZoomFor', () {
    TerrainCamera cam(double zoom, {double pitchDeg = 45}) => TerrainCamera(
          centerX: WebMercator.xFromLon(135.97),
          centerY: WebMercator.yFromLat(33.93),
          scale: TerrainCamera.scaleForZoom(zoom),
          pitch: pitchDeg * math.pi / 180,
          zScale: WebMercator.zScaleAt(33.93),
        );
    final world = TerrainWorld(
      demSource: DemTileSource.aws,
      demFetcher: (z, x, y) async => null,
      textureFetcher: (z, x, y) async => null,
    );
    const size = Size(1080, 2000);

    test('画面に掛かる枚数が上限を超える間は段を下げる', () {
      final planner = TerrainFramePlanner(world, maxCoreTiles: 10);
      final flat = world.groundBounds(cam(16), size, heightRange: 600);
      final z = planner.demZoomFor(cam(16), flat);
      expect(z, lessThanOrEqualTo(15));
      expect(TerrainWorld.tileRangeFor(flat, z).count, lessThanOrEqualTo(10));
      // 寝かせるほど画面が広い → 段は同じか下がる
      final wide = world.groundBounds(cam(16, pitchDeg: 70), size, heightRange: 600);
      expect(TerrainFramePlanner(world, maxCoreTiles: 10).demZoomFor(cam(16, pitchDeg: 70), wide), lessThanOrEqualTo(z));
    });

    test('境目で往復しない: 粗い段に居たら枚数が上限の 6 割を超える間は留まる', () {
      final planner = TerrainFramePlanner(world, maxCoreTiles: 10);
      var crossings = 0;
      int? prev;
      for (var i = 0; i <= 40; i++) {
        final zoom = 15 + i * 0.05; // 15 → 17 をゆっくり
        final b = world.groundBounds(cam(zoom), size, heightRange: 600);
        final z = planner.demZoomFor(cam(zoom), b);
        if (prev != null && z != prev) crossings++;
        prev = z;
      }
      expect(crossings, lessThanOrEqualTo(2), reason: '2 段ぶん寄るので切り替わりは 2 回まで');
    });
  });

  group('TerrainWorker', () {
    test('静的関数を isolate で実行して結果を返す', () async {
      final w = TerrainWorker(size: 2);
      final results = await Future.wait([for (var i = 0; i < 6; i++) w.run(_square, i)]);
      expect(results, [0, 1, 4, 9, 16, 25]);
      expect(w.pending, 0);
      w.dispose();
    });

    test('例外は呼び出し側に届き、ワーカーは生き続ける', () async {
      final w = TerrainWorker(size: 1);
      await expectLater(w.run(_throwing, 7), throwsA(contains('boom 7')));
      expect(await w.run(_square, 3), 9);
      w.dispose();
    });
  });
}
