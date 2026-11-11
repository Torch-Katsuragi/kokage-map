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
import 'package:image/image.dart' as img;
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/wakayama_potree_dem.dart';
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
  group('DemTileSource.decode（地理院 PNG・RGBA 透明 NoData）', () {
    const gsi = DemTileSource.gsiDem1a;
    test('正・負・無効・透明ピクセル（alpha=0）', () {
      // x = 12345 → 123.45m
      expect(gsi.decode(0, 0x30, 0x39), closeTo(123.45, 1e-6));
      // x = 2^24 - 500 → -5.00m
      const x = (1 << 24) - 500;
      expect(gsi.decode((x >> 16) & 255, (x >> 8) & 255, x & 255), closeTo(-5.0, 1e-6));
      // (128, 0, 0) = 無効
      expect(gsi.decode(128, 0, 0).isNaN, isTrue);
      // 地域別 DEM タイルの範囲外ピクセル（RGBA = 0,0,0,0）は 0.00m ではなく NaN になる
      expect(gsi.decode(0, 0, 0, 0).isNaN, isTrue);
      // Terrarium は従来どおり
      expect(DemTileSource.aws.decode(128, 100, 0), closeTo(100, 1e-6));
      expect(DemTileSource.aws.decode(0, 0, 0, 0).isNaN, isTrue);
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

  group('TerrainWorld のソースの重ね合わせ', () {
    // 地理院 PNG（x = 2^16R + 2^8G + B、0.01m）。左半分が無効 (128,0,0)、右半分 200m のタイル
    Uint8List gsiTile({required bool leftInvalid, required double height, bool transparentInvalid = false}) {
      final im = img.Image(width: 256, height: 256, numChannels: 4);
      final x = (height * 100).round();
      for (var y = 0; y < 256; y++) {
        for (var c = 0; c < 256; c++) {
          if (leftInvalid && c < 128) {
            if (transparentInvalid) {
              im.setPixelRgba(c, y, 0, 0, 0, 0);
            } else {
              im.setPixelRgba(c, y, 128, 0, 0, 255);
            }
          } else {
            im.setPixelRgba(c, y, (x >> 16) & 255, (x >> 8) & 255, x & 255, 255);
          }
        }
      }
      return Uint8List.fromList(img.encodePng(im));
    }

    test('細かいソースの無効な点は次のソースで埋まり、縞や台地にならない', () async {
      final fine = gsiTile(leftInvalid: true, height: 200);
      final coarse = gsiTile(leftInvalid: false, height: 50);
      var fetches = <String>[];
      final world = TerrainWorld(
        demSources: const [DemTileSource.gsiDem1a, DemTileSource.gsiDem5a, DemTileSource.aws],
        demFetcher: (s, z, x, y) async {
          fetches.add(s.id);
          if (s == DemTileSource.gsiDem1a) return fine;
          if (s == DemTileSource.gsiDem5a) return coarse;
          return null;
        },
        textureFetcher: (z, x, y) async => null,
      );
      final dem = await world.debugLoadDem(const TileKey(15, 100, 200));
      expect(dem, isNotNull);
      expect(dem!.heights[128 * 256 + 10], closeTo(50, 0.01), reason: '左は 5A の値');
      expect(dem.heights[128 * 256 + 200], closeTo(200, 0.01), reason: '右は 1A の値');
      expect(fetches, ['gsi_dem1a_png', 'gsi_dem5a_png'], reason: '穴が埋まったら AWS までは聞かない');
      // 2 回目: 無かったソースは覚えていて聞かない
      fetches = [];
      final world2 = TerrainWorld(
        demSources: const [DemTileSource.gsiDem1a, DemTileSource.aws],
        demFetcher: (s, z, x, y) async {
          fetches.add(s.id);
          return s == DemTileSource.aws ? coarse : null; // AWS は Terrarium だが符号化の違いはここでは見ない
        },
        textureFetcher: (z, x, y) async => null,
      );
      await world2.debugLoadDem(const TileKey(15, 1, 1));
      await world2.debugLoadDem(const TileKey(15, 1, 1));
      expect(fetches.where((f) => f == 'gsi_dem1a_png').length, 1, reason: '404 は 1 回だけ');
    });

    test('高度な3D地図: 地域別 bbox フィルタと RGBA 透明 NoData のフォールバック合成', () async {
      // 紀伊半島南部（z17/115035/52382）のタイルでは東京・静岡のソースは bbox 外なので呼ばれない
      final regionalFine = gsiTile(leftInvalid: true, height: 320, transparentInvalid: true);
      final gsiFallback = gsiTile(leftInvalid: false, height: 310);
      final requested = <String>[];
      final world = TerrainWorld(
        demSources: DemTileSource.highPrecisionCascade,
        demFetcher: (s, z, x, y) async {
          requested.add(s.id);
          if (s == DemTileSource.wakayama1gPotree) return regionalFine;
          if (s == DemTileSource.gsiDem1a) return gsiFallback;
          return null;
        },
        textureFetcher: (z, x, y) async => null,
      )..highPrecision = true;

      final dem = await world.debugLoadDem(const TileKey(17, 115035, 52382));
      expect(dem, isNotNull);
      expect(requested, ['wakayama_1g_potree', 'gsi_dem1a_png'], reason: 'bbox 外の都県ソースは一切呼ばれない');
      expect(dem!.heights[128 * 256 + 10], closeTo(310, 0.01), reason: '透明ピクセル (A=0) は DEM1A で埋まる');
      expect(dem.heights[128 * 256 + 200], closeTo(320, 0.01), reason: '有効ピクセルは和歌山 1m グリッドの値');

      // 場所ごとの maxZoom: 東京駅は z19、静岡は z18、和歌山は z17
      expect(
        world.maxZoomForPoint(WebMercator.xFromLon(139.767), WebMercator.yFromLat(35.681)),
        19,
      );
      expect(
        world.maxZoomForPoint(WebMercator.xFromLon(138.383), WebMercator.yFromLat(34.975)),
        18,
      );
      expect(
        world.maxZoomForPoint(WebMercator.xFromLon(135.952), WebMercator.yFromLat(33.965)),
        17,
      );
    });
  });

  group('和歌山県 1m グリッド（EPSG:6674 河瀬投影・図郭解決・1px 孤立スパイク除去）', () {
    test('EPSG:6674 座標変換と 1:2,500 国土基本図の図郭コード解決', () {
      final (eMin, nMin) = lonLatToEpsg6674(135.9460, 33.9610);
      final (eMax, nMax) = lonLatToEpsg6674(135.9585, 33.9705);
      // 紀伊半島南部周辺: 東向き約 -5.0km〜-3.8km、北向き約 -226.2km〜-225.1km
      expect(eMin, closeTo(-4991.5, 5.0));
      expect(nMin, closeTo(-226183.3, 5.0));
      final meshes = epsg6674ToWakayamaMeshes(eMin, nMin, eMax, nMax);
      expect(meshes, ['06RD582', '06RD591']);
    });

    test('despikeIsolated1px: 1px の孤立針スパイクだけ除去し、線状の堰堤・法肩は保持する', () {
      const w = 7, h = 7;
      final grid = Float32List(w * h)..fillRange(0, w * h, 100.0);
      // (2, 2) に 1px 孤立スパイク (+12m)
      grid[2 * w + 2] = 112.0;
      // 5 行目に線状の砂防堰堤・擁壁の段差 (+8m が横に貫通して連なる)
      for (var c = 0; c < w; c++) {
        grid[5 * w + c] = 108.0;
      }
      final cleaned = despikeIsolated1px(grid, w, h);
      expect(cleaned[2 * w + 2], closeTo(100.0, 1e-5), reason: '1px 孤立スパイクは周囲の中央値に戻る');
      for (var c = 1; c < w - 1; c++) {
        expect(cleaned[5 * w + c], closeTo(108.0, 1e-5), reason: '隣接点がある構造物の角は削られない');
      }
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
