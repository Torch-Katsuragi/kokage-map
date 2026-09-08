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

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_frame.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

/// タイルの読み込みを遅延つきの擬似タイルで置き換えた世界を作る
TerrainWorld simWorld({Duration latency = const Duration(milliseconds: 300), int maxTiles = 40}) {
  return TerrainWorld(
    demSource: DemTileSource.aws,
    demFetcher: (z, x, y) async => null,
    textureFetcher: (z, x, y) async => null,
    maxTiles: maxTiles,
    tileLoader: (key) async {
      await Future<void>.delayed(latency);
      const n = 256;
      final h = Float32List(n * n);
      for (var i = 0; i < h.length; i++) {
        h[i] = 300 + 100 * math.sin(i / 997.0);
      }
      final mpp = WebMercator.metersPerPixel(key.z);
      return TerrainTile(
        key: key,
        raw: DemGrid(cols: n, rows: n, originX: key.west + mpp / 2, originY: key.south + mpp / 2, cellSize: mpp, heights: h),
      );
    },
  );
}

/// カメラを動かしながら計画を立て続け、被覆が欠けたフレームを数える
class _Drive {
  _Drive(this.world, this.camera, this.size) : planner = TerrainFramePlanner(world);

  final TerrainWorld world;
  final TerrainCamera camera;
  final Size size;
  final TerrainFramePlanner planner;
  final gaps = <String>[];
  int frames = 0;
  int maxLoaded = 0;
  int maxPending = 0;

  TerrainFramePlan step(FakeAsync async, String label, {Duration dt = const Duration(milliseconds: 50)}) {
    final plan = planner.plan(camera, size);
    frames++;
    maxLoaded = math.max(maxLoaded, world.loadedCount);
    maxPending = math.max(maxPending, world.pendingCount);
    if (!plan.coverage.full) {
      gaps.add('$label z=${camera.zoom.toStringAsFixed(1)} ${plan.coverage}');
    }
    async.elapse(dt);
    return plan;
  }

  /// 被覆が埋まるまで待つ（最大 [maxSeconds] 秒）
  void warmUp(FakeAsync async, {int maxSeconds = 30}) {
    for (var i = 0; i < maxSeconds * 10; i++) {
      final plan = planner.plan(camera, size);
      if (plan.coverage.full && world.pendingCount == 0) return;
      async.elapse(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  const size = Size(1080, 2000);
  TerrainCamera kitayamaCamera(double zoom) => TerrainCamera(
        centerX: WebMercator.xFromLon(135.97),
        centerY: WebMercator.yFromLat(33.93),
        scale: TerrainCamera.scaleForZoom(zoom),
        pitch: 45 * math.pi / 180,
        zScale: WebMercator.zScaleAt(33.93),
      );

  test('静止: 温まれば被覆 100%、先読みも含めて枚数は上限内', () {
    fakeAsync((async) {
      final world = simWorld();
      final d = _Drive(world, kitayamaCamera(16), size);
      d.warmUp(async);
      final plan = d.step(async, 'idle');
      expect(plan.coverage.full, isTrue, reason: '${plan.coverage}');
      // 核（1 周り外まで 20 枚 + 親 4 段 ≈ 30 枚 + 寄る方向の先読み ≈ 8 枚）は上限に関わらず残す。それを超える先読みは trim される
      expect(world.loadedCount, lessThanOrEqualTo(world.maxTiles + 24), reason: 'loaded ${world.loadedCount}');
    });
  });

  test('パン: 温まった後に東へ 6km（2 本指ドラッグ相当）動かしても被覆が欠けない', () {
    fakeAsync((async) {
      final world = simWorld();
      final d = _Drive(world, kitayamaCamera(16), size);
      d.warmUp(async);
      // 1 ステップ 50ms で 60m（秒速 1.2km = かなり速いドラッグ）
      for (var i = 0; i < 100; i++) {
        d.camera.centerX += 60;
        d.step(async, 'pan#$i');
      }
      expect(d.gaps, isEmpty, reason: d.gaps.take(5).join('\n'));
    });
  });

  test('ズームアウト → ズームイン: 段が変わるたびに親か子で埋まっている', () {
    fakeAsync((async) {
      final world = simWorld();
      final d = _Drive(world, kitayamaCamera(16), size);
      d.warmUp(async);
      for (var i = 0; i < 60; i++) {
        d.camera.zoom = 16 - i * 0.1; // 16 → 10
        d.step(async, 'out#$i');
      }
      for (var i = 0; i < 70; i++) {
        d.camera.zoom = 10 + i * 0.1; // 10 → 17
        d.step(async, 'in#$i');
      }
      expect(d.gaps, isEmpty, reason: d.gaps.take(8).join('\n'));
    });
  });

  test('乱暴なズームアウト（1 秒に 4 段）: 欠けても数フレームまで', () {
    fakeAsync((async) {
      final world = simWorld();
      final d = _Drive(world, kitayamaCamera(16), size);
      d.warmUp(async);
      for (var i = 0; i < 30; i++) {
        d.camera.zoom = 16 - i * 0.2;
        d.step(async, 'fast#$i');
      }
      expect(d.gaps.length, lessThanOrEqualTo(6), reason: d.gaps.join('\n'));
    });
  });

  test('寄る: 手が空いている間に内側半分を 1 段細かく先読みしているので、1 段寄った瞬間に細かい段が出る', () {
    fakeAsync((async) {
      final world = simWorld();
      final d = _Drive(world, kitayamaCamera(15), size);
      d.warmUp(async);
      final before = d.step(async, 'before');
      d.camera.zoom = 16;
      final after = d.step(async, 'after');
      expect(after.demZoom, before.demZoom + 1, reason: '1 段寄ったら理想の段も 1 つ上がる');
      expect(after.coverage.full, isTrue, reason: '${after.coverage}');
      expect(after.coverage.exact, greaterThanOrEqualTo(after.coverage.ideal - 2), reason: '内側はほぼ理想の段で描ける: ${after.coverage}');
    });
  });

  test('回転と傾け: 見える範囲が変わっても欠けない', () {
    fakeAsync((async) {
      final world = simWorld();
      final d = _Drive(world, kitayamaCamera(15), size);
      d.warmUp(async);
      for (var i = 0; i < 72; i++) {
        d.camera.bearing = i * 5 * math.pi / 180;
        d.camera.pitch = (35 + 35 * math.sin(i / 10)) * math.pi / 180;
        d.step(async, 'rot#$i');
      }
      expect(d.gaps, isEmpty, reason: d.gaps.take(8).join('\n'));
    });
  });

  test('パンしながらズーム: 実運用に近い複合操作', () {
    fakeAsync((async) {
      final world = simWorld(latency: const Duration(milliseconds: 500));
      final d = _Drive(world, kitayamaCamera(16), size);
      d.warmUp(async);
      final rnd = math.Random(3);
      for (var i = 0; i < 300; i++) {
        d.camera.centerX += (rnd.nextDouble() - 0.5) * 80;
        d.camera.centerY += (rnd.nextDouble() - 0.5) * 80;
        d.camera.zoom = (d.camera.zoom + (rnd.nextDouble() - 0.5) * 0.3).clamp(11, 17);
        d.camera.bearing += (rnd.nextDouble() - 0.5) * 0.05;
        d.step(async, 'mix#$i');
      }
      expect(d.gaps, isEmpty, reason: '${d.gaps.length} gaps, e.g.\n${d.gaps.take(8).join('\n')}');
      // メモリ: 読み込み済みは 上限 + 核（親 4 段と余白）に収まる
      expect(d.maxLoaded, lessThanOrEqualTo(world.maxTiles + 24), reason: 'maxLoaded ${d.maxLoaded}');
    });
  });
}
