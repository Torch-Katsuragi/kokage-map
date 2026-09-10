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
import 'dart:ui' as ui;

import '../dem_grid.dart';
import '../terrain_camera.dart';
import '../terrain_painter.dart' show PolygonBatch;
import 'terrain_gpu_stats.dart';

/// web 向けの空実装（`package:flutter_gpu` は dart:ffi を使うので web では読み込めない）
///
/// インターフェースは `terrain_gpu_renderer.dart` と同じにしておくこと
class TerrainGpuRenderer {
  TerrainGpuRenderer._();

  static const shaderBundleAsset = 'build/shaderbundles/terrain.shaderbundle';

  static bool get isSupported => false;

  static Future<TerrainGpuRenderer> create() async => throw UnsupportedError('flutter_gpu は web 非対応');

  final stats = TerrainGpuStats();

  int get terrainVertexCount => 0;
  int get polygonVertexCount => 0;

  void setTerrain(DemGrid dem, {int step = 1, int lightAzimuthDeg = 315, int lightAltitudeDeg = 45}) {}

  Future<void> setTexture(ui.Image image) async {}

  void setPolygons(List<PolygonBatch> batches) {}

  ui.Image? render(
    TerrainCamera camera,
    ui.Size size, {
    required ui.Offset origin,
    required double centerHeight,
    double pixelRatio = 1,
    bool perspective = false,
    double fovDeg = 50,
  }) =>
      null;

  ui.Offset? toScreen(double x, double y, double z, ui.Size size) => null;

  void dispose() {}
}
