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
// こかげマップ: WGS84 楕円体の上で測る長さ・面積
//
// turf は半径 6378137 m の球で測るので、北山村あたり（北緯 34°）で面積が 0.3% ほど大きく出る。
// 地物の情報パネルと計測ツールはこちらを使う。
// - 長さ: Karney の逆解法（GeographicLib。QGIS の楕円体の長さと同じ → karney_inverse.dart）
// - 面積: 等積の写像（正積緯度）で楕円体を球に移し、球面多角形の面積を測る。辺は球の大円で結ぶので、
//   林班の大きさ（数 km）なら楕円体の測地線との差は無視できる
// 座標は表示用の WGS84（投影座標系のレイヤも読み込み時に WGS84 へ直してある）

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:turf/turf.dart' as turf;

import 'karney_inverse.dart';

class Geodesic {
  Geodesic._();

  static const double _a = 6378137.0;
  static const double _f = 1 / 298.257223563;
  static const double _e2 = _f * (2 - _f);
  static final double _e = math.sqrt(_e2);

  /// 正積緯度の q(φ)
  static double _q(double sinPhi) =>
      (1 - _e2) * (sinPhi / (1 - _e2 * sinPhi * sinPhi) - (1 / (2 * _e)) * math.log((1 - _e * sinPhi) / (1 + _e * sinPhi)));

  static final double _qp = _q(1);

  /// 等積の球の半径
  static final double _rq = _a * math.sqrt(_qp / 2);

  static double _rad(double deg) => deg * math.pi / 180;

  /// 2 点間の測地線長 [m]（Karney の逆解法。QGIS の楕円体の長さと同じ値で、対蹠点の近くでも収束する）
  static double distance(LatLng p1, LatLng p2) {
    if (p1.latitude == p2.latitude && p1.longitude == p2.longitude) return 0;
    return karneyDistance(p1.latitude, p1.longitude, p2.latitude, p2.longitude);
  }

  /// 緯度 [latDeg] での緯度 1° の長さ [m]（子午線曲率半径から。赤道 110,574 m・北緯 34° で 110,922 m）
  static double metersPerDegreeLat(double latDeg) {
    final s = math.sin(_rad(latDeg));
    final w = 1 - _e2 * s * s;
    return _a * (1 - _e2) / (w * math.sqrt(w)) * math.pi / 180;
  }

  /// 緯度 [latDeg] での経度 1° の長さ [m]（卯酉線曲率半径 × cos φ。赤道 111,320 m）
  static double metersPerDegreeLon(double latDeg) {
    final phi = _rad(latDeg);
    final s = math.sin(phi);
    return _a / math.sqrt(1 - _e2 * s * s) * math.cos(phi) * math.pi / 180;
  }

  /// 折れ線の長さ [m]
  static double lineLength(List<LatLng> line) {
    var s = 0.0;
    for (var i = 1; i < line.length; i++) {
      s += distance(line[i - 1], line[i]);
    }
    return s;
  }

  /// 輪の周の長さ [m]（閉じていなければ始点へ戻る辺も足す）
  static double ringPerimeter(List<LatLng> ring) {
    if (ring.length < 2) return 0;
    var s = lineLength(ring);
    if (!_isClosed(ring)) s += distance(ring.last, ring.first);
    return s;
  }

  /// 輪の面積 [m²]（向きによらず正。閉じていなくてよい）
  static double ringArea(List<LatLng> ring) {
    final n = _isClosed(ring) ? ring.length - 1 : ring.length;
    if (n < 3) return 0;
    double beta(double latDeg) {
      final r = (_q(math.sin(_rad(latDeg))) / _qp).clamp(-1.0, 1.0);
      return math.asin(r);
    }

    var sum = 0.0;
    var b1 = beta(ring[0].latitude);
    for (var i = 0; i < n; i++) {
      final p1 = ring[i];
      final p2 = ring[(i + 1) % n];
      final b2 = beta(p2.latitude);
      var dl = _rad(p2.longitude - p1.longitude);
      if (dl > math.pi) dl -= 2 * math.pi;
      if (dl < -math.pi) dl += 2 * math.pi;
      final t1 = math.tan(b1 / 2), t2 = math.tan(b2 / 2);
      sum += 2 * math.atan2(math.tan(dl / 2) * (t1 + t2), 1 + t1 * t2);
      b1 = b2;
    }
    return (sum * _rq * _rq).abs();
  }

  /// 面（外周＋穴）の面積 [m²]
  static double polygonArea(List<List<LatLng>> rings) {
    if (rings.isEmpty) return 0;
    final a = ringArea(rings.first) - rings.skip(1).fold<double>(0, (s, r) => s + ringArea(r));
    return math.max(0, a);
  }

  /// 面の周の長さ [m]（穴の周も足す。QGIS の $perimeter と同じ）
  static double polygonPerimeter(List<List<LatLng>> rings) =>
      rings.fold<double>(0, (s, r) => s + ringPerimeter(r));

  static bool _isClosed(List<LatLng> r) =>
      r.length > 1 && r.first.latitude == r.last.latitude && r.first.longitude == r.last.longitude;

  // ── turf の形から ──────────────────────────

  static List<LatLng> _line(List<turf.Position> ps) => [for (final p in ps) LatLng(p.lat.toDouble(), p.lng.toDouble())];

  static List<List<LatLng>> _rings(List<List<turf.Position>> rs) => [for (final r in rs) _line(r)];

  /// 線（Multi は合計）の長さ [m]。線でなければ null
  static double? lengthOf(turf.GeometryObject? g) => switch (g) {
    turf.LineString() => lineLength(_line(g.coordinates)),
    turf.MultiLineString() => g.coordinates.fold<double>(0, (s, l) => s + lineLength(_line(l))),
    _ => null,
  };

  /// 面（Multi は合計）の面積 [m²]。面でなければ null
  static double? areaOf(turf.GeometryObject? g) => switch (g) {
    turf.Polygon() => polygonArea(_rings(g.coordinates)),
    turf.MultiPolygon() => g.coordinates.fold<double>(0, (s, p) => s + polygonArea(_rings(p))),
    _ => null,
  };

  /// 面（Multi は合計）の周の長さ [m]。面でなければ null
  static double? perimeterOf(turf.GeometryObject? g) => switch (g) {
    turf.Polygon() => polygonPerimeter(_rings(g.coordinates)),
    turf.MultiPolygon() => g.coordinates.fold<double>(0, (s, p) => s + polygonPerimeter(_rings(p))),
    _ => null,
  };

  // ── 表示 ──────────────────────────

  /// 長さ: 1 km 未満は m、それ以上は km を添える（例 `1,234.5 m（1.235 km）`）
  static String formatLength(double m) {
    final meters = '${_grouped(m, 1)} m';
    return m >= 1000 ? '$meters（${(m / 1000).toStringAsFixed(3)} km）' : meters;
  }

  /// 長さの短い形（地図の上の札）: 1 km 未満は m、それ以上は km だけ
  static String formatLengthShort(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(2)} km' : '${m.toStringAsFixed(1)} m';

  /// 面積: m² と ha を並べる（例 `12,345.6 m²（1.2346 ha）`）
  static String formatArea(double m2) => '${_grouped(m2, 1)} m²（${(m2 / 10000).toStringAsFixed(4)} ha）';

  /// 桁区切り付きの小数
  static String _grouped(double v, int digits) {
    final s = v.toStringAsFixed(digits);
    final dot = s.indexOf('.');
    final intPart = dot < 0 ? s : s.substring(0, dot);
    final frac = dot < 0 ? '' : s.substring(dot);
    final neg = intPart.startsWith('-');
    final digitsOnly = neg ? intPart.substring(1) : intPart;
    final buf = StringBuffer();
    for (var i = 0; i < digitsOnly.length; i++) {
      if (i > 0 && (digitsOnly.length - i) % 3 == 0) buf.write(',');
      buf.write(digitsOnly[i]);
    }
    return '${neg ? '-' : ''}$buf$frac';
  }
}
