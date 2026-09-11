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

import 'package:vector_math/vector_math.dart' as vm;

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

  // ── 透視（眺め）モード ───────────────────────────
  //
  // 正射影と同じ方位・傾き・倍率のまま、画面中心（高さ centerHeight）で 1 m = [scale] px になる距離に
  // 視点を置いた透視投影。GPU 経路だけ（純 Dart の描画は正射影の線形性に頼っている）。
  // 投影は線形でないので、ラベル・点・ヒットテストは毎フレーム行列で落とす

  /// 透視で描く
  bool perspective = false;

  /// 縦の画角（度）
  double fovDeg = 50;

  /// 画面サイズ（論理 px）。透視の投影に要る。レイヤが毎フレーム入れる
  Size viewport = Size.zero;

  /// far 面 = 視点距離 × これ
  static const farFactor = 8.0;

  /// 靄（遠くを空色に溶かす）の始まりと終わり = 視点距離 × これ。終わりより遠くのタイルは読まない
  static const fogStartFactor = 1.5;
  static const fogEndFactor = 4.0;

  /// 視点から画面中心までの距離（m）
  double get eyeDistance => (viewport.height / 2) / scale / math.tan(fovDeg * math.pi / 360);

  /// 視点の位置（カメラ中心基準。z は zScale 倍した空間）
  vm.Vector3 eyeAt(double centerHeight) {
    final d = eyeDistance;
    return vm.Vector3(-_sinB * d * _sinP, -_cosB * d * _sinP, centerHeight * zScale + d * _cosP);
  }

  /// 画面の「上」に当たる世界の向き（視線と直交。真上のときは方位の向き、横を向くほど鉛直に近づく）
  vm.Vector3 get _screenUp => vm.Vector3(_sinB * _cosP, _cosB * _cosP, _sinP);

  /// view × projection（座標: カメラ中心基準の (dx, dy, z·zScale)。NDC z ∈ [−1, 1]）。同じ状態なら使い回す
  vm.Matrix4 perspectiveViewProjection(double centerHeight) {
    final key = (centerHeight, bearing, pitch, scale, viewport.width, viewport.height, zScale, fovDeg);
    final cached = _vp;
    if (cached != null && _vpKey == key) return cached;
    final d = eyeDistance;
    final eye = eyeAt(centerHeight);
    final target = vm.Vector3(0, 0, centerHeight * zScale);
    final view = vm.makeViewMatrix(eye, target, _screenUp);
    final aspect = viewport.height == 0 ? 1.0 : viewport.width / viewport.height;
    final proj = vm.makePerspectiveMatrix(fovDeg * math.pi / 180, aspect, math.max(1.0, d * 0.02), d * farFactor);
    final vp = proj * view;
    _vp = vp;
    _vpKey = key;
    return vp;
  }

  vm.Matrix4? _vp;
  Object? _vpKey;

  /// 透視で画面座標（論理 px）に落とす。視点の裏側なら null。[dx], [dy] はカメラ中心基準、[z] は標高（生）
  Offset? projectPerspective(double dx, double dy, double z, double centerHeight) {
    final m = perspectiveViewProjection(centerHeight).storage;
    final zz = z * zScale;
    final cx = m[0] * dx + m[4] * dy + m[8] * zz + m[12];
    final cy = m[1] * dx + m[5] * dy + m[9] * zz + m[13];
    final cw = m[3] * dx + m[7] * dy + m[11] * zz + m[15];
    if (cw <= 1e-6) return null;
    return Offset(viewport.width / 2 * (1 + cx / cw), viewport.height / 2 * (1 - cy / cw));
  }

  /// 画面座標 → 視線（原点と単位方向。カメラ中心基準、z は標高の単位）
  (vm.Vector3, vm.Vector3) rayPerspective(Offset screen, double centerHeight) {
    final inv = vm.Matrix4.inverted(perspectiveViewProjection(centerHeight));
    final nx = screen.dx / viewport.width * 2 - 1;
    final ny = 1 - screen.dy / viewport.height * 2;
    vm.Vector3 unproject(double nz) {
      final v = inv.transform(vm.Vector4(nx, ny, nz, 1));
      return vm.Vector3(v.x / v.w, v.y / v.w, v.z / v.w / zScale);
    }

    final a = unproject(-1);
    final b = unproject(1);
    final dir = (b - a)..normalize();
    return (a, dir);
  }

  /// 透視の視線と地形の交点（カメラ中心基準の x, y）。視線に沿って地上距離 [stepMeters] ずつ進み、
  /// 初めて地形の下に潜った区間で線形補間。[maxHeight] より上へ抜けたら null
  Offset? intersectRayPerspective(
    Offset screen,
    double centerHeight,
    double? Function(double x, double y) elevation, {
    required double stepMeters,
    required double maxHeight,
    double? maxDistance,
  }) {
    final (o, dir) = rayPerspective(screen, centerHeight);
    final horizontal = math.sqrt(dir.x * dir.x + dir.y * dir.y);
    final dt = stepMeters / math.max(horizontal, 1e-3);
    final tMax = maxDistance ?? eyeDistance * farFactor;
    double? prevDiff;
    var prevX = o.x;
    var prevY = o.y;
    for (var t = 0.0; t <= tMax; t += dt) {
      final x = o.x + dir.x * t;
      final y = o.y + dir.y * t;
      final zr = o.z + dir.z * t;
      if (dir.z >= 0 && zr > maxHeight) return null;
      final h = elevation(x, y);
      final diff = h == null ? null : zr - h;
      if (diff != null && diff <= 0) {
        if (prevDiff == null || prevDiff <= 0) return Offset(x, y);
        final k = prevDiff / (prevDiff - diff);
        return Offset(prevX + (x - prevX) * k, prevY + (y - prevY) * k);
      }
      prevDiff = diff;
      prevX = x;
      prevY = y;
    }
    return null;
  }

  /// 画面座標の視線が高さ [z] の平面に当たる点（カメラ中心基準）。
  /// 当たらない（地平線の上）か、中心から [maxDistance] より遠ければ、その向きのまま [maxDistance] に打ち切る
  Offset groundPointPerspective(Offset screen, double centerHeight, double z, {required double maxDistance}) {
    final (o, dir) = rayPerspective(screen, centerHeight);
    final Offset p;
    if (dir.z < -1e-6) {
      final t = math.max(0.0, (z - o.z) / dir.z);
      p = Offset(o.x + dir.x * t, o.y + dir.y * t);
    } else {
      p = Offset(o.x + dir.x * 1e9, o.y + dir.y * 1e9);
    }
    final d = p.distance;
    return d > maxDistance ? p * (maxDistance / d) : p;
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
    return intersectHeightField(
      projected,
      (x, y) => (x >= 0 && y >= 0 && x <= dem.width && y <= dem.height)
          ? dem.elevationAt(x + dem.originX, y + dem.originY)
          : null,
      minHeight: minH,
      maxHeight: maxH,
      stepMeters: dem.cellSize,
    );
  }

  /// 任意の標高関数（原点基準の x, y → 標高。範囲外は null）に対する視線との交点
  ///
  /// [maxHeight] の高さから視線に沿って [stepMeters]（地上距離）ずつ下げ、
  /// 初めて地形の下に潜った区間で線形補間する。標高関数が null を返す間は素通り
  Offset? intersectHeightField(
    Offset projected,
    double? Function(double x, double y) elevation, {
    required double minHeight,
    required double maxHeight,
    required double stepMeters,
  }) {
    if (_sinP < 1e-6) {
      final p = unprojectAtHeight(projected, 0);
      return elevation(p.dx, p.dy) == null ? null : p;
    }
    final dz = stepMeters / (zScale * math.tan(pitch));
    var zPrev = maxHeight + dz;
    var pPrev = unprojectAtHeight(projected, zPrev);
    var diffPrev = 1.0;
    for (var z = maxHeight; z >= minHeight - dz; z -= dz) {
      final p = unprojectAtHeight(projected, z);
      final h = elevation(p.dx, p.dy);
      final diff = h == null ? 1.0 : z - h;
      if (diff <= 0 && diffPrev > 0) {
        final t = diffPrev / (diffPrev - diff);
        final hit = Offset(pPrev.dx + (p.dx - pPrev.dx) * t, pPrev.dy + (p.dy - pPrev.dy) * t);
        return elevation(hit.dx, hit.dy) == null ? null : hit;
      }
      zPrev = z;
      pPrev = p;
      diffPrev = diff;
    }
    return null;
  }
}
