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

// 毎フレーム走る処理（描く順・被覆・見える範囲・読み込み順・ラベルの出方）の答えを固定する。
// 参照は素朴に書いた実装（以前の TerrainWorld と同じ規則）で、速くした実装と突き合わせる
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/dem_tiles.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_lifted.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_world.dart';
import 'package:root_maps/core/terrain/terrain_world_painter.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

TerrainTile _tile(TileKey key) {
  const n = 256;
  final mpp = WebMercator.metersPerPixel(key.z);
  final h = Float32List(n * n);
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      h[r * n + c] = key.z * 10.0 + r * 0.3 + c * 0.1;
    }
  }
  return TerrainTile(
    key: key,
    raw: DemGrid(cols: n, rows: n, originX: key.west + mpp / 2, originY: key.south + mpp / 2, cellSize: mpp, heights: h),
  );
}

TerrainWorld _world({TileLoader? loader, int concurrency = 4}) => TerrainWorld(
      demSources: const [DemTileSource.aws],
      demFetcher: (s, z, x, y) async => null,
      textureFetcher: (z, x, y) async => null,
      concurrency: concurrency,
      tileLoader: loader,
    );

// ── 参照の実装（素朴版） ──

List<TileKey> _refIdeal(TileRange range, TerrainCamera camera) {
  final eastFar = math.sin(camera.bearing) > 0;
  final northFar = math.cos(camera.bearing) > 0;
  final ys = [for (var y = range.y0; y <= range.y1; y++) y];
  final xs = [for (var x = range.x0; x <= range.x1; x++) x];
  if (!northFar) ys.setAll(0, ys.reversed.toList());
  if (!eastFar) xs.setAll(0, xs.reversed.toList());
  return [for (final y in ys) for (final x in xs) TileKey(range.z, x, y)];
}

List<TileKey> _refChildren(TileKey key, TerrainCamera camera) =>
    _refIdeal(TileRange(z: key.z + 1, x0: key.x * 2, y0: key.y * 2, x1: key.x * 2 + 1, y1: key.y * 2 + 1), camera);

List<TileKey> _refCoverSet(Set<TileKey> have, TileRange range, TerrainCamera camera, {int maxAncestorLevels = 8}) {
  final out = <TileKey>[];
  void emit(TileKey k) {
    if (!out.contains(k)) out.add(k);
  }

  for (final key in _refIdeal(range, camera)) {
    if (have.contains(key)) {
      emit(key);
      continue;
    }
    var k = key;
    TileKey? ancestor;
    for (var i = 0; i < maxAncestorLevels && k.z > 0; i++) {
      k = k.parent;
      if (have.contains(k)) {
        ancestor = k;
        break;
      }
    }
    if (ancestor != null) {
      emit(ancestor);
      continue;
    }
    for (final c in _refChildren(key, camera)) {
      if (have.contains(c)) {
        emit(c);
        continue;
      }
      for (final g in _refChildren(c, camera)) {
        if (have.contains(g)) emit(g);
      }
    }
  }
  return out;
}

ui.Rect _refGroundBounds(TerrainWorld w, TerrainCamera camera, ui.Size size, double heightRange) {
  final z0 = w.elevationAt(camera.centerX, camera.centerY) ?? 0;
  final pc = camera.project(0, 0, z0);
  final corners = [ui.Offset.zero, ui.Offset(size.width, 0), ui.Offset(0, size.height), ui.Offset(size.width, size.height)];
  if (camera.perspective && camera.viewport != ui.Size.zero) {
    var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0;
    final maxDist = camera.eyeDistance * TerrainCamera.fogEndFactor;
    for (final c in corners) {
      for (final z in [z0 - heightRange / 2, z0 + heightRange / 2]) {
        final p = camera.groundPointPerspective(c, z0, z, maxDistance: maxDist);
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
    }
    return ui.Rect.fromLTRB(camera.centerX + minX, camera.centerY + minY, camera.centerX + maxX, camera.centerY + maxY);
  }
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final c in corners) {
    final projected = ui.Offset(pc.dx + (c.dx - size.width / 2) / camera.scale, pc.dy + (c.dy - size.height / 2) / camera.scale);
    for (final z in [z0 - heightRange / 2, z0 + heightRange / 2]) {
      final p = camera.unprojectAtHeight(projected, z);
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
  }
  return ui.Rect.fromLTRB(camera.centerX + minX, camera.centerY + minY, camera.centerX + maxX, camera.centerY + maxY);
}

TileRange _refTileRange(ui.Rect bounds, int z, {int margin = 0}) {
  final n = 1 << z;
  final span = WebMercator.tileSpan(z);
  int tx(double x) => ((x + WebMercator.halfCircumference) / span).floor();
  int ty(double y) => ((WebMercator.halfCircumference - y) / span).floor();
  return TileRange(
    z: z,
    x0: (tx(bounds.left) - margin).clamp(0, n - 1),
    x1: (tx(bounds.right) + margin).clamp(0, n - 1),
    y0: (ty(bounds.bottom) - margin).clamp(0, n - 1),
    y1: (ty(bounds.top) + margin).clamp(0, n - 1),
  );
}

String _r(TileRange r) => '${r.z}/${r.x0}-${r.x1}/${r.y0}-${r.y1}';

void main() {
  const bearings = [0.0, 0.3, math.pi / 2, 2.0, math.pi, 3.7, 3 * math.pi / 2, 5.9, -0.4];

  group('描く順・被覆は参照と同じ', () {
    test('ランダムな手持ちで drawOrder / coverSet / coverage が素朴版と一致', () {
      final rnd = math.Random(11);
      for (var trial = 0; trial < 40; trial++) {
        final w = _world();
        final have = <TileKey>{};
        const z = 14;
        const x0 = 14000, y0 = 6400;
        // 理想の段・親・子・孫を混ぜる
        for (var i = 0; i < 25; i++) {
          final dz = rnd.nextInt(5) - 2; // -2..2
          final zz = z + dz;
          final s = dz >= 0 ? (1 << dz) : 1;
          final bx = dz >= 0 ? x0 * s : x0 >> -dz;
          final by = dz >= 0 ? y0 * s : y0 >> -dz;
          final k = TileKey(zz, bx + rnd.nextInt(5 * s), by + rnd.nextInt(4 * s));
          if (have.add(k)) w.addTileForTest(_tile(k));
        }
        const range = TileRange(z: z, x0: x0, y0: y0, x1: x0 + 4, y1: y0 + 3);
        for (final b in bearings) {
          final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1, bearing: b);
          expect(w.coverSet(range, cam).map((t) => t.key).toList(), _refCoverSet(have, range, cam), reason: 'trial $trial bearing $b');
          final ref = _refIdeal(range, cam).where(have.contains).toList();
          expect(w.drawOrder(range, cam).map((t) => t.key).toList(), ref, reason: 'drawOrder trial $trial bearing $b');
        }
        // coverage の数え方（子は 4 枚そろって 1 枚、孫まで）
        var exact = 0, anc = 0, child = 0;
        bool coveredBy(TileKey k, int depth) =>
            have.contains(k) || (depth > 0 && k.children.every((c) => coveredBy(c, depth - 1)));
        for (var y = range.y0; y <= range.y1; y++) {
          for (var x = range.x0; x <= range.x1; x++) {
            final key = TileKey(z, x, y);
            if (have.contains(key)) {
              exact++;
              continue;
            }
            var k = key;
            var found = false;
            for (var i = 0; i < 8 && k.z > 0; i++) {
              k = k.parent;
              if (have.contains(k)) {
                found = true;
                break;
              }
            }
            if (found) {
              anc++;
            } else if (coveredBy(key, 2)) {
              child++;
            }
          }
        }
        final rep = w.coverage(range);
        expect((rep.exact, rep.byAncestor, rep.byChild, rep.ideal), (exact, anc, child, range.count), reason: 'coverage trial $trial');
        w.dispose();
      }
    });
  });

  group('見える範囲は参照と同じ', () {
    test('groundBounds / tileRangeFor（正射影・透視、方位・傾きいろいろ）', () {
      final w = _world();
      const k = TileKey(14, 14380, 6510);
      w.addTileForTest(_tile(k));
      final cx = k.west + k.span * 0.4, cy = k.south + k.span * 0.6;
      const size = Size(800, 600);
      for (final persp in [false, true]) {
        for (final b in bearings) {
          for (final p in [0.0, 0.5, 1.1]) {
            final cam = TerrainCamera(centerX: cx, centerY: cy, scale: 0.3, bearing: b, pitch: p)
              ..perspective = persp
              ..viewport = size;
            for (final hr in [0.0, 600.0]) {
              final got = w.groundBounds(cam, size, heightRange: hr);
              final ref = _refGroundBounds(w, cam, size, hr);
              expect(got, ref, reason: 'persp $persp bearing $b pitch $p hr $hr');
              for (final z in [12, 14, 15]) {
                for (final m in [0, 1]) {
                  expect(_r(TerrainWorld.tileRangeFor(got, z, margin: m)), _r(_refTileRange(ref, z, margin: m)));
                }
              }
            }
          }
        }
      }
      // 世界の端で切る
      expect(_r(TerrainWorld.tileRangeFor(const Rect.fromLTRB(-3e7, -3e7, 3e7, 3e7), 3, margin: 2)), '3/0-7/0-7');
      w.dispose();
    });
  });

  group('読み込み順', () {
    test('ensure は中心に近い順に読み、replaceQueue: false は重複を足さない', () async {
      final loaded = <TileKey>[];
      final w = _world(
        concurrency: 1,
        loader: (k) async {
          loaded.add(k);
          return null;
        },
      );
      const range = TileRange(z: 14, x0: 100, y0: 200, x1: 104, y1: 203);
      const c = TileKey(14, 102, 201);
      final cx = c.west + c.span * 0.3, cy = c.south + c.span * 0.8;
      w.ensure(range, centerX: cx, centerY: cy);
      w.ensure(range.parent, centerX: cx, centerY: cy, replaceQueue: false);
      w.ensure(range, centerX: cx, centerY: cy, replaceQueue: false); // 重複は足さない
      for (var i = 0; i < 100 && w.pendingCount > 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      double d(TileKey k) {
        final x = k.west + k.span / 2 - cx, y = k.south + k.span / 2 - cy;
        return x * x + y * y;
      }

      List<TileKey> keys(TileRange r) => [
            for (var y = r.y0; y <= r.y1; y++)
              for (var x = r.x0; x <= r.x1; x++) TileKey(r.z, x, y),
          ]..sort((a, b) => d(a).compareTo(d(b)));
      expect(loaded, [...keys(range), ...keys(range.parent)]);
      w.dispose();
    });
  });

  group('ラベルの出方', () {
    test('方位・傾きを変えながら描いたときの見えるラベルの並び（固定値）', () {
      final rnd = math.Random(5);
      final drawables = <TerrainTileDrawable>[];
      final cam0 = TerrainCamera(centerX: 960, centerY: 960, scale: 0.4);
      for (var j = 0; j < 2; j++) {
        for (var i = 0; i < 2; i++) {
          final dem = DemGrid.synthetic(cols: 33, rows: 33, cellSize: 30, originX: i * 960.0, originY: j * 960.0, seed: i + j * 2);
          final mesh = TerrainMesh.build(dem, cam0, textureWidth: 64, textureHeight: 64, chunkSize: 8);
          drawables.add(TerrainTileDrawable(
            originX: dem.originX,
            originY: dem.originY,
            mesh: mesh,
            texture: null,
            labels: [
              for (var k = 0; k < 120; k++)
                TerrainLabel(
                  x: rnd.nextDouble() * 960,
                  y: rnd.nextDouble() * 960,
                  text: 'L' * (1 + rnd.nextInt(6)),
                  style: const TextStyle(fontSize: 12),
                  markerGap: rnd.nextBool() ? null : 6,
                ),
            ],
          ));
        }
      }
      final painter = TerrainWorldPainter(
        camera: cam0,
        tiles: drawables,
        elevationAt: (x, y) => 300,
        heightRange: (200, 500),
        stepMeters: 30,
      );
      final frames = <String>[];
      for (final (b, p, s) in [(0.0, 0.0, 0.4), (0.0, 0.0, 0.4), (0.7, 0.5, 0.4), (2.4, 0.9, 0.6), (4.0, 0.3, 0.25), (4.0, 0.3, 0.25)]) {
        painter.camera = TerrainCamera(centerX: 960, centerY: 960, scale: s, bearing: b, pitch: p);
        final rec = ui.PictureRecorder();
        painter.paint(Canvas(rec), const Size(800, 600));
        rec.endRecording().dispose();
        final v = painter.visibleLabels.toList()..sort();
        frames.add('${v.length}:${painter.deferredLayouts}:${v.fold<int>(0, (a, e) => (a * 31 + e) & 0x3fffffff)}');
      }
      // 書き換え前の実装で取った値
      expect(frames, _expectedLabelFrames);
    });
  });
}

const _expectedLabelFrames = <String>[
  '38:366:703545622',
  '73:285:44001769',
  '88:226:582662829',
  '96:125:417568203',
  '95:115:89729779',
  '128:5:313931673',
];
