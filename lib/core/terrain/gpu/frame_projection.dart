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
// こかげマップ: GPU 描画のフレームの投影行列（flutter_gpu 版・WebGL2 版で共通。NDC z は [0, 1]）
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:vector_math/vector_math.dart' as vm;

import '../terrain_camera.dart';

/// 深度の正規化に使うタイルの箱（カメラ中心基準ではなく世界の Mercator m）
typedef GpuTileBox = ({double originX, double originY, double width, double height, double minZ, double maxZ});

/// カメラ中心基準の投影を [m]（列優先 4×4）に書き、正射影の深度の係数 kz を返す（透視は 0）。
///
/// 正射影は深度をタイルの箱（xy）× 標高の範囲で [0, 1] に正規化、
/// 透視は TerrainCamera の view × projection（NDC z を [0, 1] に畳む）
double writeBaseProjection(
  Float32List m,
  TerrainCamera camera,
  ui.Size size, {
  required double centerHeight,
  required (double, double) heightRange,
  required Iterable<GpuTileBox> tiles,
}) {
  final zs = camera.zScale;
  if (camera.perspective && camera.viewport != ui.Size.zero) {
    final toUnit = vm.Matrix4.identity()
      ..setEntry(2, 2, 0.5)
      ..setEntry(2, 3, 0.5);
    final model = vm.Matrix4.identity()..setEntry(2, 2, zs);
    final mvp = toUnit.multiplied(camera.perspectiveViewProjection(centerHeight)).multiplied(model);
    m.setAll(0, mvp.storage);
    return 0;
  }
  final cosB = math.cos(camera.bearing);
  final sinB = math.sin(camera.bearing);
  final cosP = math.cos(camera.pitch);
  final sinP = math.sin(camera.pitch);
  final pc = camera.project(0, 0, centerHeight);
  final kx = 2 * camera.scale / size.width;
  final ky = 2 * camera.scale / size.height;
  var zLo = heightRange.$1;
  var zHi = heightRange.$2;
  for (final t in tiles) {
    if (t.minZ < zLo) zLo = t.minZ;
    if (t.maxZ > zHi) zHi = t.maxZ;
  }
  final zPad = math.max(10.0, (zHi - zLo) * 0.05);
  zLo -= zPad;
  zHi += zPad;
  var dMin = double.infinity;
  var dMax = -double.infinity;
  for (final t in tiles) {
    final ox = t.originX - camera.centerX;
    final oy = t.originY - camera.centerY;
    for (final x in [ox, ox + t.width]) {
      for (final y in [oy, oy + t.height]) {
        for (final z in [zLo, zHi]) {
          final d = camera.depth(x, y, z);
          if (d < dMin) dMin = d;
          if (d > dMax) dMax = d;
        }
      }
    }
  }
  final span = math.max(1e-3, dMax - dMin);
  final pad = span * 0.02;
  final kz = 1 / (span + 2 * pad);
  final d0 = dMin - pad;
  m.fillRange(0, 16, 0);
  m[0] = kx * cosB;
  m[4] = -kx * sinB;
  m[12] = -kx * pc.dx;
  m[1] = ky * sinB * cosP;
  m[5] = ky * cosB * cosP;
  m[9] = ky * zs * sinP;
  m[13] = ky * pc.dy;
  m[2] = kz * sinB * sinP;
  m[6] = kz * cosB * sinP;
  m[10] = -kz * zs * cosP;
  m[14] = -kz * d0;
  m[15] = 1;
  return kz;
}
