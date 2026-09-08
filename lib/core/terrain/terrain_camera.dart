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

import 'dem_grid.dart';
import 'web_mercator.dart';

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

  /// MapLibre と同じ zoom の定義: `scale = 256 · 2^zoom / (2πR)`（px / Mercator m）
  double get zoom => math.log(scale * 2 * math.pi * WebMercator.radius / 256) / math.ln2;

  set zoom(double z) => scale = scaleForZoom(z);

  static double scaleForZoom(double zoom) =>
      256 * math.pow(2, zoom) / (2 * math.pi * WebMercator.radius);

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

  /// 投影座標（倍率 1・原点基準）と高さ z から、その視線上の世界座標 (dx, dy) を返す
  ///
  /// 投影は `sy = -(yr·cosP + z·zScale·sinP)` なので、z を決めれば yr が決まる。
  Offset unprojectAtHeight(Offset projected, double z) {
    final xr = projected.dx;
    final yr = (-projected.dy - z * zScale * _sinP) / _cosP;
    return Offset(xr * _cosB + yr * _sinB, -xr * _sinB + yr * _cosB);
  }

  /// 投影座標（倍率 1・DEM 原点基準）から、視線と地形の交点（DEM 原点基準の x, y）を返す
  ///
  /// 正射影なので視線は平行。DEM の最高点の高さから始めて、視線に沿って高さを下げながら
  /// 地形と比べ、初めて地形の下に潜った区間で線形補間する。DEM の外に出たら null。
  /// 真上（pitch 0）なら地形の高さに依らず 1 点に決まる。
  Offset? intersectTerrain(Offset projected, DemGrid dem) {
    var maxH = -double.infinity;
    var minH = double.infinity;
    for (final h in dem.heights) {
      if (h > maxH) maxH = h;
      if (h < minH) minH = h;
    }
    double terrainAt(Offset p) => dem.elevationAt(p.dx + dem.originX, p.dy + dem.originY);
    bool inside(Offset p) => p.dx >= 0 && p.dy >= 0 && p.dx <= dem.width && p.dy <= dem.height;
    if (_sinP < 1e-6) {
      final p = unprojectAtHeight(projected, 0);
      return inside(p) ? p : null;
    }
    // 地上で 1 セルぶん進むごとの高さの刻み
    final dz = dem.cellSize / (zScale * math.tan(pitch));
    var zPrev = maxH + dz;
    var pPrev = unprojectAtHeight(projected, zPrev);
    var diffPrev = zPrev - terrainAt(pPrev); // 正 = 視線が地形の上
    for (var z = maxH; z >= minH - dz; z -= dz) {
      final p = unprojectAtHeight(projected, z);
      // 視線は視点側の遠くから入ってくるので、DEM の外にいる間は進めるだけ
      final diff = inside(p) ? z - terrainAt(p) : 1.0;
      if (diff <= 0 && diffPrev > 0) {
        final t = diffPrev / (diffPrev - diff);
        final hit = Offset(pPrev.dx + (p.dx - pPrev.dx) * t, pPrev.dy + (p.dy - pPrev.dy) * t);
        return inside(hit) ? hit : null;
      }
      zPrev = z;
      pPrev = p;
      diffPrev = diff;
    }
    return null;
  }
}
