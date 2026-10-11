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
/// 磁北基準の向き（端末のコンパス・TruPulse の方位角）を真北基準に直す
///
/// 地図・案内の矢印・GPS の進行方向はすべて真北基準。flutter_compass（Android）は磁北基準の値を返すので、
/// 紀伊半島では西偏 約 7.9° ぶん、そのままだと向きがずれる（2026-10 の WMM2025 で北山村 −7.88°）。
library;

import 'wmm_declination.dart';

/// 磁北基準の向き → 真北基準の向き（偏角は東偏 +、西偏 −）
double magneticToTrue(double magneticDeg, double declinationDeg) {
  final t = (magneticDeg + declinationDeg) % 360;
  return t < 0 ? t + 360 : t;
}

/// コンパスの向きの指数移動平均（EMA）。0°/360° の境界をまたいでも最短の向きの差で寄せる
///
/// [alpha] が小さいほど滑らかだが追従が遅い（0.08 = 安定重視）。最初の値はそのまま返す。
class HeadingSmoother {
  HeadingSmoother({this.alpha = 0.08});

  final double alpha;
  double? _last;

  /// [rawHeading]（度）を足して、平滑化した向き（0〜360）を返す
  double add(double rawHeading) {
    final prev = _last;
    if (prev == null) {
      _last = rawHeading;
      return rawHeading;
    }
    // 最短角度差分を計算（-180° ~ +180°）
    double diff = rawHeading - prev;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    double smoothed = (prev + alpha * diff) % 360;
    if (smoothed < 0) smoothed += 360;
    _last = smoothed;
    return smoothed;
  }
}

/// 位置ごとの偏角を覚えておき、コンパスの値を真北に直す
///
/// 偏角は 10 km 動いても 0.1° 前後しか変わらないので、出し直すのは [_recomputeKm] 以上動いたか
/// 日付が変わったときだけ（コンパスは 15〜60Hz で届く）。
/// 位置がまだ一度も分からないときは直さずに返す（扇・案内の矢印は位置が無いと出ない）。
class TrueHeadingConverter {
  TrueHeadingConverter({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const double _recomputeKm = 10;

  double? _lat, _lon, _declination;
  int? _day;

  /// 今使っている偏角（度、東偏 +）。位置が一度も分かっていなければ null
  double? declinationFor(double? lat, double? lon) {
    if (lat == null || lon == null) return _declination;
    final now = _clock();
    final day = now.year * 400 + now.month * 32 + now.day;
    final pLat = _lat, pLon = _lon;
    if (_declination == null || _day != day || pLat == null || pLon == null || _farKm(pLat, pLon, lat, lon)) {
      _declination = WmmDeclination.calculate(lat, lon, now);
      _lat = lat;
      _lon = lon;
      _day = day;
    }
    return _declination;
  }

  /// 磁北基準の [magneticDeg] を、[lat]/[lon] の偏角で真北基準に直す
  double toTrue(double magneticDeg, {double? lat, double? lon}) {
    final d = declinationFor(lat, lon);
    return d == null ? magneticDeg : magneticToTrue(magneticDeg, d);
  }

  /// 緯度経度の差がおおよそ [_recomputeKm] を超えたか（1° ≒ 111 km、経度は日本の緯度なら 0.8 倍程度で十分）
  static bool _farKm(double lat1, double lon1, double lat2, double lon2) {
    final dLat = (lat2 - lat1).abs() * 111;
    final dLon = (lon2 - lon1).abs() * 111;
    return dLat > _recomputeKm || dLon > _recomputeKm;
  }
}
