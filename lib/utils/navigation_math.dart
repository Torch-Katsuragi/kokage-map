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
/// 地点への誘導の計算（距離・方位・相対角・到着・地物の目標点）。どれも純粋な関数
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// 誘導の計算
abstract final class NavigationMath {
  /// 到着とみなす最小の半径（m）。GPS の精度がこれより悪ければ精度の値を使う
  static const double minArrivalRadius = 5;

  /// 到着のあと、この倍率ぶん離れたら「まだ着いていない」に戻す（境目で通知が連発しないように）
  static const double rearmFactor = 2;

  /// Vincenty（WGS84 楕円体）。既定の丸め（1 m 単位）は外す
  static const _distance = Distance(roundResult: false);

  /// [a] から [b] までの楕円体上の距離（m）
  static double distanceMeters(LatLng a, LatLng b) => _distance.as(LengthUnit.Meter, a, b);

  /// [a] から [b] への初期方位（真北から時計回り、0〜360°）
  static double bearingDeg(LatLng a, LatLng b) {
    final f1 = a.latitudeInRad, f2 = b.latitudeInRad;
    final dl = b.longitudeInRad - a.longitudeInRad;
    final y = math.sin(dl) * math.cos(f2);
    final x = math.cos(f1) * math.sin(f2) - math.sin(f1) * math.cos(f2) * math.cos(dl);
    return normalizeDeg(math.atan2(y, x) * 180 / math.pi);
  }

  /// 0〜360° に収める
  static double normalizeDeg(double deg) {
    final d = deg % 360;
    return d < 0 ? d + 360 : d;
  }

  /// 向いている方位 [facingDeg] から見た目標の方位 [bearingDeg] の角度（-180〜180°、右が正）
  static double relativeDeg(double bearingDeg, double facingDeg) {
    final d = normalizeDeg(bearingDeg - facingDeg);
    return d > 180 ? d - 360 : d;
  }

  /// 到着とみなす半径（m）: max(5 m, GPS の精度)
  static double arrivalRadius(double? accuracy) =>
      accuracy == null || accuracy.isNaN ? minArrivalRadius : math.max(minArrivalRadius, accuracy);

  /// 到着したか
  static bool isArrived(double distance, double? accuracy) => distance <= arrivalRadius(accuracy);

  /// 到着のあと、離れて「着いていない」に戻すか
  static bool shouldRearm(double distance, double? accuracy) => distance > arrivalRadius(accuracy) * rearmFactor;

  /// 方位を 8 方位の番号に（0 = 北、1 = 北東 … 7 = 北西）
  static int octant(double bearingDeg) => (normalizeDeg(bearingDeg + 22.5) ~/ 45) % 8;

  // ── 地物の目標点 ─────────────────────────────

  /// [origin] を原点にした平面（m、東・北）へ。数 km の範囲なら十分
  static math.Point<double> _toLocal(LatLng origin, LatLng p) {
    const r = 6378137.0;
    final x = (p.longitude - origin.longitude) * math.pi / 180 * r * math.cos(origin.latitudeInRad);
    final y = (p.latitude - origin.latitude) * math.pi / 180 * r;
    return math.Point(x, y);
  }

  static LatLng _fromLocal(LatLng origin, math.Point<double> q) {
    const r = 6378137.0;
    return LatLng(
      origin.latitude + q.y / r * 180 / math.pi,
      origin.longitude + q.x / (r * math.cos(origin.latitudeInRad)) * 180 / math.pi,
    );
  }

  /// 線 [line] 上で [here] にいちばん近い点。線が空なら null
  static LatLng? nearestPointOnLine(LatLng here, List<LatLng> line) {
    if (line.isEmpty) return null;
    if (line.length == 1) return line.first;
    math.Point<double>? best;
    var bestD = double.infinity;
    final h = _toLocal(here, here);
    for (var i = 1; i < line.length; i++) {
      final a = _toLocal(here, line[i - 1]);
      final b = _toLocal(here, line[i]);
      final ab = b - a;
      final len2 = ab.x * ab.x + ab.y * ab.y;
      final t = len2 == 0 ? 0.0 : (((h - a).x * ab.x + (h - a).y * ab.y) / len2).clamp(0.0, 1.0);
      final p = math.Point(a.x + ab.x * t, a.y + ab.y * t);
      final d = p.distanceTo(h);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return _fromLocal(here, best!);
  }

  /// [points] のうち [here] にいちばん近い点。空なら null
  static LatLng? nearestVertex(LatLng here, Iterable<LatLng> points) {
    LatLng? best;
    var bestD = double.infinity;
    for (final p in points) {
      final d = distanceMeters(here, p);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }

  /// 面の外環 [ring] の重心（面積で重み付け。プロットの中心など）。面積が 0 なら頂点の平均。空なら null
  static LatLng? polygonCentroid(List<LatLng> ring) {
    if (ring.isEmpty) return null;
    final pts = ring.length > 1 && ring.first == ring.last ? ring.sublist(0, ring.length - 1) : ring;
    final origin = pts.first;
    final q = [for (final p in pts) _toLocal(origin, p)];
    var area2 = 0.0, cx = 0.0, cy = 0.0;
    for (var i = 0; i < q.length; i++) {
      final a = q[i], b = q[(i + 1) % q.length];
      final cross = a.x * b.y - b.x * a.y;
      area2 += cross;
      cx += (a.x + b.x) * cross;
      cy += (a.y + b.y) * cross;
    }
    if (area2.abs() < 1e-9) {
      var sx = 0.0, sy = 0.0;
      for (final p in q) {
        sx += p.x;
        sy += p.y;
      }
      return _fromLocal(origin, math.Point(sx / q.length, sy / q.length));
    }
    return _fromLocal(origin, math.Point(cx / (3 * area2), cy / (3 * area2)));
  }
}
