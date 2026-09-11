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
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_painter.dart';

/// 3D 描画系のゴールデンテスト（設計の決定 6）
///
/// 固定の合成 DEM + 線 + 面 + ラベルを 1 枚に描き、`test/goldens/` の画像と比べる。
/// 更新は `flutter test --update-goldens test/terrain_golden_test.dart`。
/// ⚠ ゴールデンは Windows の開発機で作っている。他 OS ではフォントとアンチエイリアスが
/// 違って一致しないので、Windows 以外では skip する。
void main() {
  testWidgets('地形 + 線 + 面 + ラベルの描画', (tester) async {
    // ゴールデンは光源の陰影で作ってある（既定は傾斜の濃淡。描画系の検証なので陰影は固定する）
    TerrainShading.source = TerrainShadeSource.hillshade;
    addTearDown(() => TerrainShading.source = TerrainShadeSource.slope);
    final dem = DemGrid.synthetic(cols: 81, rows: 81, cellSize: 10, relief: 200);
    final camera = TerrainCamera(
      centerX: 400,
      centerY: 400,
      scale: 0.5,
      bearing: 30 * math.pi / 180,
      pitch: 50 * math.pi / 180,
      zScale: 1.2,
    );
    final mesh = TerrainMesh.build(dem, camera, textureWidth: 8, textureHeight: 8, chunkSize: 16);
    final painter = TerrainPainter(
      mesh: mesh,
      camera: camera,
      texture: null,
      lines: [
        LiftedPolyline.lift(
          [for (var i = 0; i <= 20; i++) Offset(i * 40.0, 200 + math.sin(i / 3) * 120)],
          mesh,
          color: Colors.red,
          widthPx: 3,
        ),
      ],
      polygons: [
        LiftedPolygon.lift(
          [const Offset(450, 450), const Offset(700, 470), const Offset(680, 700), const Offset(430, 650)],
          mesh,
          color: Colors.green.withValues(alpha: 0.5),
        ),
      ],
      labels: [
        for (var i = 0; i < 5; i++)
          TerrainLabel(
            x: 150.0 + i * 120,
            y: 600.0 - i * 80,
            painter: TextPainter(
              text: TextSpan(text: 'L$i', style: const TextStyle(fontSize: 12, color: Colors.black)),
              textDirection: TextDirection.ltr,
            )..layout(),
          ),
      ],
    );
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: 400,
            height: 300,
            child: CustomPaint(painter: painter),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(RepaintBoundary),
      matchesGoldenFile('goldens/terrain_scene.png'),
    );
  }, skip: !Platform.isWindows);
}
