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

import 'package:flutter/foundation.dart';

import '../terrain_camera.dart';
import '../terrain_world_painter.dart' show TerrainTileDrawable;

/// web 向けの空実装（`package:flutter_gpu` は dart:ffi を使うので web では読み込めない）
///
/// インターフェースは `terrain_gpu_world.dart` と同じにしておくこと
class TerrainGpuWorldRenderer {
  TerrainGpuWorldRenderer._();

  static const shaderBundleAsset = 'build/shaderbundles/terrain.shaderbundle';

  static bool get isSupported => false;

  static Future<TerrainGpuWorldRenderer> create() async => throw UnsupportedError('flutter_gpu は web 非対応');

  VoidCallback? onTextureReady;
  void Function(Object textureKey)? onTextureUploaded;
  void pruneTextures(Set<Object> liveKeys) {}
  Duration lastEncode = Duration.zero;
  Duration lastUpload = Duration.zero;
  int lastDrawCalls = 0;
  int lastUploads = 0;
  String? lastError;
  int get terrainBufferCount => 0;
  int get textureCount => 0;
  int get mippedTextureCount => 0;
  bool get msaa => false;

  ui.Image? render(
    TerrainCamera camera,
    ui.Size size,
    List<TerrainTileDrawable> tiles, {
    required double pixelRatio,
    required (double, double) heightRange,
    required double centerHeight,
  }) =>
      null;

  void dispose() {}
}
