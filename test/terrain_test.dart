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
import 'package:root_maps/core/terrain/contours.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_painter.dart';
import 'package:root_maps/core/terrain/terrain_scene.dart';
import 'package:root_maps/core/terrain/web_mercator.dart';

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
        chunkSize: 5,
      );
      const cellCount = 20 * 20;
      expect(mesh.cellBand.length, cellCount);
      expect(mesh.bands.fold<int>(0, (a, b) => a + b.cellCount), cellCount);
      expect(mesh.bands.length, 16); // 20/5 = 4 チャンク × 4
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

  group('TerrainMeshBuilder.cellTriangles', () {
    const sw = 0, se = 1, nw = 2, ne = 3;
    const far = {0: sw, 1: se, 2: nw, 3: ne}; // bit0 = 東が奥、bit1 = 北が奥
    const near = {0: ne, 1: nw, 2: se, 3: sw};

    test('奥の角を含む三角形を先に描き、対角線は奥と手前の角を結ばない', () {
      for (var q = 0; q < 4; q++) {
        final t = TerrainMeshBuilder.cellTriangles(q, sw: sw, se: se, nw: nw, ne: ne);
        expect(t.length, 6);
        final first = t.sublist(0, 3), second = t.sublist(3);
        expect(first, contains(far[q]), reason: 'quadrant $q: 奥の角が先');
        expect(first, isNot(contains(near[q])), reason: 'quadrant $q: 手前の角は後');
        expect(second, contains(near[q]));
        // 共有辺（対角線）= 両方に含まれる 2 頂点。奥・手前の角ではない
        final shared = first.toSet().intersection(second.toSet());
        expect(shared.length, 2);
        expect(shared, isNot(contains(far[q])));
        expect(shared, isNot(contains(near[q])));
        // 4 頂点すべて使う
        expect({...first, ...second}, {sw, se, nw, ne});
      }
    });
  });

  group('LiftedPolygon', () {
    test('耳切りは凹多角形も面積を保つ', () {
      // L 字
      final ring = [
        const Offset(0, 0), const Offset(4, 0), const Offset(4, 1),
        const Offset(1, 1), const Offset(1, 3), const Offset(0, 3),
      ];
      final tris = LiftedPolygon.earClip(ring);
      expect(tris.length, ring.length - 2);
      double area(List<Offset> t) =>
          ((t[1].dx - t[0].dx) * (t[2].dy - t[0].dy) - (t[1].dy - t[0].dy) * (t[2].dx - t[0].dx)).abs() / 2;
      expect(tris.fold<double>(0, (a, t) => a + area(t)), closeTo(6, 1e-9));
    });

    test('矩形クリップは三角形を凸片に切る', () {
      final tri = [const Offset(0, 0), const Offset(10, 0), const Offset(0, 10)];
      final piece = LiftedPolygon.clipToRect(tri, const Rect.fromLTWH(2, 2, 4, 4));
      expect(piece.length, greaterThanOrEqualTo(3));
      for (final p in piece) {
        expect(p.dx, inInclusiveRange(2, 6));
        expect(p.dy, inInclusiveRange(2, 6));
      }
    });

    test('DEM セルで切った三角形の面積は元の面積に一致する', () {
      final dem = DemGrid.synthetic(cols: 21, rows: 21, cellSize: 10);
      final cam = TerrainCamera(centerX: 100, centerY: 100, scale: 1);
      final mesh = TerrainMesh.build(dem, cam, textureWidth: 16, textureHeight: 16, chunkSize: 5);
      final ring = [const Offset(23, 31), const Offset(87, 28), const Offset(91, 74), const Offset(40, 66)];
      final poly = LiftedPolygon.lift(ring, mesh, color: const Color(0xFF00FF00));
      var sum = 0.0;
      for (var t = 0; t < poly.triangleCount; t++) {
        final o = t * 9;
        sum += ((poly.xyz[o + 3] - poly.xyz[o]) * (poly.xyz[o + 7] - poly.xyz[o + 1]) -
                (poly.xyz[o + 4] - poly.xyz[o + 1]) * (poly.xyz[o + 6] - poly.xyz[o]))
            .abs() /
            2;
      }
      var expected = 0.0;
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i];
        final b = ring[(i + 1) % ring.length];
        expected += a.dx * b.dy - b.dx * a.dy;
      }
      expect(sum, closeTo(expected.abs() / 2, 0.5));
      // 全ての三角形が有効なセルに属する
      for (var t = 0; t < poly.triangleCount; t++) {
        expect(poly.cells[t], inInclusiveRange(0, 20 * 20 - 1));
      }
    });
  });

  group('WebMercator', () {
    test('緯度経度と Mercator の往復', () {
      final x = WebMercator.xFromLon(135.97);
      final y = WebMercator.yFromLat(33.93);
      expect(WebMercator.lonFromX(x), closeTo(135.97, 1e-9));
      expect(WebMercator.latFromY(y), closeTo(33.93, 1e-9));
      expect(WebMercator.zScaleAt(0), closeTo(1, 1e-12));
      expect(WebMercator.zScaleAt(60), closeTo(2, 1e-9));
    });

    test('タイル座標は zoom 14 で北山村を正しく指す', () {
      // (135.97+180)/360*2^14 = 14380.4、y は 6548
      expect(WebMercator.tileXFraction(135.97, 14).floor(), 14380);
      expect(WebMercator.tileYFraction(33.93, 14).floor(), 6548);
      expect(WebMercator.metersPerPixel(14), closeTo(9.5546, 1e-3));
    });
  });

  group('TerrainPainter.pick', () {
    test('ラベル・線・面の順で当たる', () {
      final dem = DemGrid(
        cols: 2, rows: 2, originX: 0, originY: 0, cellSize: 100,
        heights: Float32List.fromList([0, 0, 0, 0]),
      );
      final cam = TerrainCamera(centerX: 50, centerY: 50, scale: 2); // 真上・2px/m
      final mesh = TerrainMesh.build(dem, cam, textureWidth: 4, textureHeight: 4, chunkSize: 1);
      const size = Size(400, 400);
      final painter = TerrainPainter(
        mesh: mesh,
        camera: cam,
        texture: null,
        lines: [
          LiftedPolyline.lift([const Offset(10, 50), const Offset(90, 50)], mesh,
              color: const Color(0xFFFF0000), widthPx: 2),
        ],
        polygons: [
          LiftedPolygon.lift(
            [const Offset(20, 20), const Offset(80, 20), const Offset(80, 80), const Offset(20, 80)],
            mesh, color: const Color(0x8000FF00),
          ),
        ],
        labels: [
          TerrainLabel(
            x: 70, y: 70,
            painter: TextPainter(text: const TextSpan(text: 'a'), textDirection: TextDirection.ltr)..layout(),
          ),
        ],
      );
      // 画面中心 (200,200) = 世界 (50,50)。線 y=50 は画面 y=200 を通る
      expect(painter.pick(const Offset(200, 200), size)?.kind, 'line');
      // 世界 (70,70) → 画面 (240, 160)（北が上）
      expect(painter.pick(const Offset(240, 160), size)?.kind, 'label');
      // 面の内側だが線・ラベルから遠い点: 世界 (30,30) → 画面 (160, 240)
      expect(painter.pick(const Offset(160, 240), size)?.kind, 'polygon');
      // 何もない: 世界 (5,95) → 画面 (110, 110)
      expect(painter.pick(const Offset(110, 110), size), isNull);
    });
  });

  group('ContourExtractor', () {
    test('斜面の等高線は真っ直ぐで、DEM を引き直すと高さが一致する', () {
      // 東に向かって 1m/セル で上がる斜面（10m 格子）
      const n = 11;
      final heights = Float32List(n * n);
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          heights[r * n + c] = c * 1.0;
        }
      }
      final dem = DemGrid(cols: n, rows: n, originX: 0, originY: 0, cellSize: 10, heights: heights);
      final lines = ContourExtractor.extract(dem, interval: 2.5);
      expect(lines.keys, [2.5, 5.0, 7.5, 10.0]);
      for (final entry in lines.entries) {
        expect(entry.value.length, n - 1); // 行ごとに 1 本
        for (final seg in entry.value) {
          for (final p in seg) {
            expect(p.dx, closeTo(entry.key * 10, 1e-6)); // x = 高さ × 10m
            expect(dem.elevationAt(p.dx, p.dy), closeTo(entry.key, 1e-6));
          }
        }
      }
    });

    test('合成地形でも交点は等高線の高さに乗る', () {
      final dem = DemGrid.synthetic(cols: 31, rows: 31, cellSize: 10, relief: 100);
      final lines = ContourExtractor.extract(dem, interval: 20);
      expect(lines, isNotEmpty);
      for (final entry in lines.entries) {
        for (final seg in entry.value) {
          for (final p in seg) {
            expect(dem.elevationAt(p.dx, p.dy), closeTo(entry.key, 1e-3));
          }
        }
      }
    });
  });

  group('TerrainPainter.isOccluded', () {
    test('尾根の裏の点は隠れ、手前の点は見える', () {
      // 南北に走る尾根: x = 50 で高さ 100、他は 0（20 格子・10m）
      const n = 21;
      final heights = Float32List(n * n);
      for (var r = 0; r < n; r++) {
        for (var c = 0; c < n; c++) {
          heights[r * n + c] = (c >= 4 && c <= 6) ? 100 : 0;
        }
      }
      final dem = DemGrid(cols: n, rows: n, originX: 0, originY: 0, cellSize: 10, heights: heights);
      // 東（bearing 90°）を画面上に、45° 傾けて見る = 視点は西側の上空
      final cam = TerrainCamera(centerX: 100, centerY: 100, scale: 1, bearing: math.pi / 2, pitch: math.pi / 4);
      final mesh = TerrainMesh.build(dem, cam, textureWidth: 4, textureHeight: 4, chunkSize: 8);
      final painter = TerrainPainter(mesh: mesh, camera: cam, texture: null, lines: const [], labels: const []);
      // 尾根の東（奥）側の地面: 隠れる
      expect(painter.isOccluded(80, 100, 0), isTrue);
      // 尾根の西（手前）側の地面: 見える
      expect(painter.isOccluded(20, 100, 0), isFalse);
      // 奥でも高ければ見える
      expect(painter.isOccluded(80, 100, 150), isFalse);
      // 真上からは何も隠れない
      cam.pitch = 0;
      expect(painter.isOccluded(80, 100, 0), isFalse);
    });
  });

  group('TerrainCamera zoom / unproject', () {
    test('zoom と scale は MapLibre の定義で往復する', () {
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1);
      cam.zoom = 14;
      // z14 の 1px = 9.55m → scale = 1/9.55
      expect(cam.scale, closeTo(1 / WebMercator.metersPerPixel(14), 1e-12));
      expect(cam.zoom, closeTo(14, 1e-9));
    });

    test('視線と地形の交点は同じ視線上に戻る', () {
      final dem = DemGrid.synthetic(cols: 41, rows: 41, cellSize: 10, relief: 150);
      final cam = TerrainCamera(centerX: 200, centerY: 200, scale: 1, bearing: 0.4, pitch: 0.9, zScale: 1.2);
      for (final p in [const Offset(50, 60), const Offset(200, 200), const Offset(330, 120)]) {
        final z = dem.elevationAt(p.dx, p.dy);
        final projected = cam.project(p.dx, p.dy, z);
        final hit = cam.intersectTerrain(projected, dem);
        expect(hit, isNotNull, reason: '$p');
        // 手前の地形に隠れていなければ元の点、隠れていれば手前の点。どちらも同じ視線上
        final back = cam.project(hit!.dx, hit.dy, dem.elevationAt(hit.dx, hit.dy));
        expect(back.dx, closeTo(projected.dx, 1e-6));
        expect(back.dy, closeTo(projected.dy, 2)); // 線形補間の誤差ぶん
      }
    });

    test('真上なら高さに依らず 1 点', () {
      final dem = DemGrid.synthetic(cols: 11, rows: 11, cellSize: 10);
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1);
      final hit = cam.intersectTerrain(cam.project(35, 45, 999), dem);
      expect(hit!.dx, closeTo(35, 1e-9));
      expect(hit.dy, closeTo(45, 1e-9));
    });
  });

  group('TerrainSceneBuilder', () {
    test('GeoJSON のフィーチャが Mercator の DEM 座標に載り、k-style / k-label が効く', () {
      // 北山村役場付近に 1km 四方の DEM（z14 相当 9.55m 格子）
      const lon0 = 135.965;
      const lat0 = 33.925;
      final originX = WebMercator.xFromLon(lon0);
      final originY = WebMercator.yFromLat(lat0);
      final dem = DemGrid(
        cols: 101,
        rows: 101,
        originX: originX,
        originY: originY,
        cellSize: 10,
        heights: Float32List(101 * 101)..fillRange(0, 101 * 101, 100),
      );
      final cam = TerrainCamera(centerX: originX + 500, centerY: originY + 500, scale: 1);
      final mesh = TerrainMesh.build(dem, cam, textureWidth: 4, textureHeight: 4, chunkSize: 25);
      final builder = TerrainSceneBuilder(
        mesh: mesh,
        stylesByKey: {
          'view-a': const TerrainFeatureStyle(
            lineColor: Color(0xFF00FF00),
            lineWidth: 5,
            fillColor: Color(0x80FF0000),
            outlineColor: Color(0xFFFF0000),
            outlineWidth: 1,
            pointColor: Color(0xFF0000FF),
            pointSize: 8,
          ),
        },
      );
      geo.Geographic ll(double dlon, double dlat) => geo.Geographic(lon: lon0 + dlon, lat: lat0 + dlat);
      final scene = builder.build(
        lines: [
          geo.Feature<geo.Geometry>(
            geometry: geo.LineString.from([ll(0.001, 0.001), ll(0.004, 0.003)]),
            properties: {'k-style': 'view-a', 'k-label': '道'},
          ),
          geo.Feature<geo.Geometry>(geometry: geo.LineString.from([ll(0.002, 0.002), ll(0.003, 0.002)])),
        ],
        polygons: [
          geo.Feature<geo.Geometry>(
            geometry: geo.Polygon.from([
              [ll(0.001, 0.004), ll(0.003, 0.004), ll(0.003, 0.006), ll(0.001, 0.006), ll(0.001, 0.004)],
            ]),
            properties: {'k-label': '区画'},
          ),
        ],
        points: [
          geo.Feature<geo.Point>(
            geometry: geo.Point(ll(0.005, 0.005)),
            properties: {'k-style': 'view-a', 'k-label': 'P'},
          ),
        ],
      );
      expect(scene.lines.length, 2);
      expect(scene.lines[0].color, const Color(0xFF00FF00)); // view-a
      expect(scene.lines[0].widthPx, 5);
      expect(scene.lines[1].color, TerrainFeatureStyle.fallback.lineColor); // キー無し → 既定
      expect(scene.polygons.length, 1);
      expect(scene.outlines.length, 1);
      expect(scene.points.length, 1);
      expect(scene.points[0].sizePx, 8);
      expect(scene.labels.map((l) => l.painter.plainText).toList(), ['道', '区画', 'P']);
      // 座標: 経度 +0.005° ≈ 東へ 557m（Mercator）、緯度 +0.005° ≈ 北へ 671m（1/cos φ 倍）
      final p = scene.points[0];
      expect(p.x, closeTo(WebMercator.xFromLon(lon0 + 0.005) - originX, 1e-6));
      expect(p.y, closeTo(WebMercator.yFromLat(lat0 + 0.005) - originY, 1e-6));
      expect(p.x, closeTo(557, 5));
      expect(p.y, closeTo(671, 5));
      // 線は DEM（100m）で持ち上がっている
      expect(scene.lines[0].xyz[2], closeTo(100, 1e-6));
    });
  });
}
