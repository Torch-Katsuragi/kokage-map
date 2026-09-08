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
import 'dart:ui';

/// 正射影の地形カメラ
///
/// 座標は Web Mercator（m）。真上（pitch 0）のとき 2D 地図と幾何が一致する。
/// 投影は (dx, dy, z) について線形なので、pan と zoom は Canvas の平行移動と
/// 拡大で済み、頂点を作り直すのは [bearing] / [pitch] が変わったときだけ。
///
/// - 画面右 = 方位 [bearing] の東側、画面上 = 方位 [bearing]
/// - [pitch] は真上からの傾き（rad）。画面下側の手前から北を見下ろす形
/// - [zScale] は Mercator の水平が緯度で伸びる分を標高にも掛ける倍率 `1/cos(φ)`
class TerrainCamera {
  TerrainCamera({
    required this.centerX,
    required this.centerY,
    required this.scale,
    this.bearing = 0,
    this.pitch = 0,
    this.zScale = 1,
  });

  /// 視点中心の Mercator x（m）
  double centerX;

  /// 視点中心の Mercator y（m）
  double centerY;

  /// 画面 px / Mercator m
  double scale;

  /// 方位（rad、北から時計回り）
  double bearing;

  /// 傾き（rad、0 = 真上）。painter's algorithm の都合で上限は 70° 程度
  double pitch;

  /// 標高の倍率（`1/cos(緯度)`）
  double zScale;

  double get _cosB => math.cos(bearing);
  double get _sinB => math.sin(bearing);
  double get _cosP => math.cos(pitch);
  double get _sinP => math.sin(pitch);

  /// 世界座標の差分 (dx, dy, z) を、倍率 1 の投影座標に落とす
  ///
  /// 戻り値は画面 px ではなく m 単位。実際の画面座標は
  /// `viewportCenter + (project(p) - project(center)) * scale`
  Offset project(double dx, double dy, double z) {
    final xr = dx * _cosB - dy * _sinB; // 画面右向き成分
    final yr = dx * _sinB + dy * _cosB; // 画面上向き成分
    return Offset(xr, -(yr * _cosP + z * zScale * _sinP));
  }

  /// 視線方向の奥行き。大きいほど遠い（painter's algorithm の並べ替え用）
  double depth(double dx, double dy, double z) {
    final yr = dx * _sinB + dy * _cosB;
    return yr * _sinP - z * zScale * _cosP;
  }

  /// 画面上の移動量（px）を世界座標の移動量（m）に戻す（地表面 z 一定として）
  Offset unprojectPan(Offset screenDelta) {
    final xr = screenDelta.dx / scale;
    final yr = -screenDelta.dy / scale / _cosP;
    return Offset(xr * _cosB + yr * _sinB, -xr * _sinB + yr * _cosB);
  }
}
