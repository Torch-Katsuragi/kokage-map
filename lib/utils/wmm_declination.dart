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
/// WMM2025 磁気偏角計算
///
/// World Magnetic Model 2025 (有効期間: 2025-2029) の球面調和関数係数から
/// 磁気偏角を計算する。外部パッケージ依存なし (dart:math のみ)。
///
/// 計算ロジックは geomagJS (public domain) / geomag Dart (MIT) をベースに、
/// WMM2025 係数 (NOAA NCEI, public domain) をハードコードしたもの。
/// ref: https://www.ncei.noaa.gov/products/world-magnetic-model
library;

import 'dart:math';

class WmmDeclination {
  static _WmmCalculator? _instance;

  /// 指定座標・日付の磁気偏角を計算する（度単位、東偏+/西偏-）
  ///
  /// [lat] 緯度 (-90 ~ +90)
  /// [lon] 経度 (-180 ~ +180)
  /// [date] 計算日（省略時は現在日時）
  static double calculate(double lat, double lon, [DateTime? date]) {
    _instance ??= _WmmCalculator(_wmm2025Coefficients);
    return _instance!.calculate(lat, lon, 0, date);
  }
}

// =========================================================
// WMM 係数データ (n, m, gnm, hnm, dgnm, dhnm)
// =========================================================

class _WmmCoeff {
  final int n, m;
  final double gnm, hnm, dgnm, dhnm;
  const _WmmCoeff(this.n, this.m, this.gnm, this.hnm, this.dgnm, this.dhnm);
}

const double _wmm2025Epoch = 2025.0;

const List<_WmmCoeff> _wmm2025Coefficients = [
  _WmmCoeff(1, 0, -29351.8, 0.0, 12.0, 0.0),
  _WmmCoeff(1, 1, -1410.8, 4545.4, 9.7, -21.5),
  _WmmCoeff(2, 0, -2556.6, 0.0, -11.6, 0.0),
  _WmmCoeff(2, 1, 2951.1, -3133.6, -5.2, -27.7),
  _WmmCoeff(2, 2, 1649.3, -815.1, -8.0, -12.1),
  _WmmCoeff(3, 0, 1361.0, 0.0, -1.3, 0.0),
  _WmmCoeff(3, 1, -2404.1, -56.6, -4.2, 4.0),
  _WmmCoeff(3, 2, 1243.8, 237.5, 0.4, -0.3),
  _WmmCoeff(3, 3, 453.6, -549.5, -15.6, -4.1),
  _WmmCoeff(4, 0, 895.0, 0.0, -1.6, 0.0),
  _WmmCoeff(4, 1, 799.5, 278.6, -2.4, -1.1),
  _WmmCoeff(4, 2, 55.7, -133.9, -6.0, 4.1),
  _WmmCoeff(4, 3, -281.1, 212.0, 5.6, 1.6),
  _WmmCoeff(4, 4, 12.1, -375.6, -7.0, -4.4),
  _WmmCoeff(5, 0, -233.2, 0.0, 0.6, 0.0),
  _WmmCoeff(5, 1, 368.9, 45.4, 1.4, -0.5),
  _WmmCoeff(5, 2, 187.2, 220.2, 0.0, 2.2),
  _WmmCoeff(5, 3, -138.7, -122.9, 0.6, 0.4),
  _WmmCoeff(5, 4, -142.0, 43.0, 2.2, 1.7),
  _WmmCoeff(5, 5, 20.9, 106.1, 0.9, 1.9),
  _WmmCoeff(6, 0, 64.4, 0.0, -0.2, 0.0),
  _WmmCoeff(6, 1, 63.8, -18.4, -0.4, 0.3),
  _WmmCoeff(6, 2, 76.9, 16.8, 0.9, -1.6),
  _WmmCoeff(6, 3, -115.7, 48.8, 1.2, -0.4),
  _WmmCoeff(6, 4, -40.9, -59.8, -0.9, 0.9),
  _WmmCoeff(6, 5, 14.9, 10.9, 0.3, 0.7),
  _WmmCoeff(6, 6, -60.7, 72.7, 0.9, 0.9),
  _WmmCoeff(7, 0, 79.5, 0.0, -0.0, 0.0),
  _WmmCoeff(7, 1, -77.0, -48.9, -0.1, 0.6),
  _WmmCoeff(7, 2, -8.8, -14.4, -0.1, 0.5),
  _WmmCoeff(7, 3, 59.3, -1.0, 0.5, -0.8),
  _WmmCoeff(7, 4, 15.8, 23.4, -0.1, 0.0),
  _WmmCoeff(7, 5, 2.5, -7.4, -0.8, -1.0),
  _WmmCoeff(7, 6, -11.1, -25.1, -0.8, 0.6),
  _WmmCoeff(7, 7, 14.2, -2.3, 0.8, -0.2),
  _WmmCoeff(8, 0, 23.2, 0.0, -0.1, 0.0),
  _WmmCoeff(8, 1, 10.8, 7.1, 0.2, -0.2),
  _WmmCoeff(8, 2, -17.5, -12.6, 0.0, 0.5),
  _WmmCoeff(8, 3, 2.0, 11.4, 0.5, -0.4),
  _WmmCoeff(8, 4, -21.7, -9.7, -0.1, 0.4),
  _WmmCoeff(8, 5, 16.9, 12.7, 0.3, -0.5),
  _WmmCoeff(8, 6, 15.0, 0.7, 0.2, -0.6),
  _WmmCoeff(8, 7, -16.8, -5.2, -0.0, 0.3),
  _WmmCoeff(8, 8, 0.9, 3.9, 0.2, 0.2),
  _WmmCoeff(9, 0, 4.6, 0.0, -0.0, 0.0),
  _WmmCoeff(9, 1, 7.8, -24.8, -0.1, -0.3),
  _WmmCoeff(9, 2, 3.0, 12.2, 0.1, 0.3),
  _WmmCoeff(9, 3, -0.2, 8.3, 0.3, -0.3),
  _WmmCoeff(9, 4, -2.5, -3.3, -0.3, 0.3),
  _WmmCoeff(9, 5, -13.1, -5.2, 0.0, 0.2),
  _WmmCoeff(9, 6, 2.4, 7.2, 0.3, -0.1),
  _WmmCoeff(9, 7, 8.6, -0.6, -0.1, -0.2),
  _WmmCoeff(9, 8, -8.7, 0.8, 0.1, 0.4),
  _WmmCoeff(9, 9, -12.9, 10.0, -0.1, 0.1),
  _WmmCoeff(10, 0, -1.3, 0.0, 0.1, 0.0),
  _WmmCoeff(10, 1, -6.4, 3.3, 0.0, 0.0),
  _WmmCoeff(10, 2, 0.2, 0.0, 0.1, -0.0),
  _WmmCoeff(10, 3, 2.0, 2.4, 0.1, -0.2),
  _WmmCoeff(10, 4, -1.0, 5.3, -0.0, 0.1),
  _WmmCoeff(10, 5, -0.6, -9.1, -0.3, -0.1),
  _WmmCoeff(10, 6, -0.9, 0.4, 0.0, 0.1),
  _WmmCoeff(10, 7, 1.5, -4.2, -0.1, 0.0),
  _WmmCoeff(10, 8, 0.9, -3.8, -0.1, -0.1),
  _WmmCoeff(10, 9, -2.7, 0.9, -0.0, 0.2),
  _WmmCoeff(10, 10, -3.9, -9.1, -0.0, -0.0),
  _WmmCoeff(11, 0, 2.9, 0.0, 0.0, 0.0),
  _WmmCoeff(11, 1, -1.5, 0.0, -0.0, -0.0),
  _WmmCoeff(11, 2, -2.5, 2.9, 0.0, 0.1),
  _WmmCoeff(11, 3, 2.4, -0.6, 0.0, -0.0),
  _WmmCoeff(11, 4, -0.6, 0.2, 0.0, 0.1),
  _WmmCoeff(11, 5, -0.1, 0.5, -0.1, -0.0),
  _WmmCoeff(11, 6, -0.6, -0.3, 0.0, -0.0),
  _WmmCoeff(11, 7, -0.1, -1.2, -0.0, 0.1),
  _WmmCoeff(11, 8, 1.1, -1.7, -0.1, -0.0),
  _WmmCoeff(11, 9, -1.0, -2.9, -0.1, 0.0),
  _WmmCoeff(11, 10, -0.2, -1.8, -0.1, 0.0),
  _WmmCoeff(11, 11, 2.6, -2.3, -0.1, 0.0),
  _WmmCoeff(12, 0, -2.0, 0.0, 0.0, 0.0),
  _WmmCoeff(12, 1, -0.2, -1.3, 0.0, -0.0),
  _WmmCoeff(12, 2, 0.3, 0.7, -0.0, 0.0),
  _WmmCoeff(12, 3, 1.2, 1.0, -0.0, -0.1),
  _WmmCoeff(12, 4, -1.3, -1.4, -0.0, 0.1),
  _WmmCoeff(12, 5, 0.6, -0.0, -0.0, -0.0),
  _WmmCoeff(12, 6, 0.6, 0.6, 0.1, -0.0),
  _WmmCoeff(12, 7, 0.5, -0.1, -0.0, -0.0),
  _WmmCoeff(12, 8, -0.1, 0.8, 0.0, 0.0),
  _WmmCoeff(12, 9, -0.4, 0.1, 0.0, -0.0),
  _WmmCoeff(12, 10, -0.2, -1.0, -0.1, -0.0),
  _WmmCoeff(12, 11, -1.3, 0.1, -0.0, 0.0),
  _WmmCoeff(12, 12, -0.7, 0.2, -0.1, -0.1),
];

// =========================================================
// WMM 球面調和関数計算 (NOAA public domain algorithm)
// =========================================================

class _WmmCalculator {
  static const int _maxord = 12;
  static const double _a = 6378.137;
  static const double _b = 6356.7523142;
  static const double _re = 6371.2;

  final List<List<double>> _c;
  final List<List<double>> _cd;
  final List<List<double>> _snorm;
  final List<List<double>> _k;

  _WmmCalculator(List<_WmmCoeff> coeffs)
      : _c = _make2d(),
        _cd = _make2d(),
        _snorm = _make2d(),
        _k = _make2d() {
    _init(coeffs);
  }

  static List<List<double>> _make2d() =>
      List.generate(_maxord + 1, (_) => List.filled(_maxord + 1, 0.0));

  void _init(List<_WmmCoeff> coeffs) {
    for (final i in coeffs) {
      final m = i.m, n = i.n;
      if (m <= n) {
        _c[m][n] = i.gnm;
        _cd[m][n] = i.dgnm;
        if (m != 0) {
          _c[n][m - 1] = i.hnm;
          _cd[n][m - 1] = i.dhnm;
        }
      }
    }

    _snorm[0][0] = 1;
    for (var n = 1; n <= _maxord; n++) {
      _snorm[0][n] = _snorm[0][n - 1] * (2 * n - 1) / n;
      var j = 2;
      var m = 0;
      for (var d2 = n - m + 1; d2 > 0; d2--, m++) {
        _k[m][n] = (((n - 1) * (n - 1)) - (m * m)) /
            ((2 * n - 1) * (2 * n - 3));
        if (m > 0) {
          final flnmj = ((n - m + 1) * j) / (n + m);
          _snorm[m][n] = _snorm[m - 1][n] * sqrt(flnmj);
          j = 1;
          _c[n][m - 1] = _snorm[m][n] * _c[n][m - 1];
          _cd[n][m - 1] = _snorm[m][n] * _cd[n][m - 1];
        }
        _c[m][n] = _snorm[m][n] * _c[m][n];
        _cd[m][n] = _snorm[m][n] * _cd[m][n];
      }
    }
    _k[1][1] = 0;
  }

  double calculate(double glat, double glon, double altKm, DateTime? date) {
    final fn = [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
    final fm = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];

    final time = _decimalDate(date ?? DateTime.now());
    final dt = time - _wmm2025Epoch;

    const a2 = _a * _a, b2 = _b * _b;
    final c2 = a2 - b2, a4 = a2 * a2, b4 = b2 * b2, c4 = a4 - b4;

    final rlat = _deg2rad(glat), rlon = _deg2rad(glon);
    final srlon = sin(rlon), crlon = cos(rlon);
    final srlat = sin(rlat), crlat = cos(rlat);
    final srlat2 = srlat * srlat, crlat2 = crlat * crlat;

    final sp = List<double>.filled(_maxord + 1, 0);
    final cp = List<double>.filled(_maxord + 1, 0);
    sp[0] = 0;
    cp[0] = 1;
    sp[1] = srlon;
    cp[1] = crlon;

    for (var m = 2; m <= _maxord; m++) {
      sp[m] = sp[1] * cp[m - 1] + cp[1] * sp[m - 1];
      cp[m] = cp[1] * cp[m - 1] - sp[1] * sp[m - 1];
    }

    final q = sqrt(a2 - c2 * srlat2);
    final q1 = altKm * q;
    final ct = srlat / sqrt(((q1 + a2) / (q1 + b2)) * ((q1 + a2) / (q1 + b2)) * crlat2 + srlat2);
    final st = sqrt(1.0 - ct * ct);
    final r2 = altKm * altKm + 2.0 * q1 + (a4 - c4 * srlat2) / (q * q);
    final r = sqrt(r2);
    final d = sqrt(a2 * crlat2 + b2 * srlat2);
    final ca = (altKm + d) / r;
    final sa = c2 * crlat * srlat / (r * d);

    final p = _make2d();
    final dp = _make2d();
    final tc = _make2d();
    final pp = List<double>.filled(_maxord + 1, 0);
    p[0][0] = 1;
    pp[0] = 1;

    var br = 0.0, bt = 0.0, bp = 0.0, bpp = 0.0;
    var ar = _re / r;

    for (var n = 1; n <= _maxord; n++) {
      ar *= _re / r;
      var m = 0;
      for (var d4 = n + m + 1; d4 > 0; d4--, m++) {
        if (n == m) {
          p[m][n] = st * p[m - 1][n - 1];
          dp[m][n] = st * dp[m - 1][n - 1] + ct * p[m - 1][n - 1];
        } else if (n == 1 && m == 0) {
          p[m][n] = ct * p[m][n - 1];
          dp[m][n] = ct * dp[m][n - 1] - st * p[m][n - 1];
        } else if (n > 1 && n != m) {
          if (m > n - 2) {
            p[m][n - 2] = 0;
            dp[m][n - 2] = 0;
          }
          p[m][n] = ct * p[m][n - 1] - _k[m][n] * p[m][n - 2];
          dp[m][n] = ct * dp[m][n - 1] - st * p[m][n - 1] - _k[m][n] * dp[m][n - 2];
        }

        tc[m][n] = _c[m][n] + dt * _cd[m][n];
        if (m != 0) {
          tc[n][m - 1] = _c[n][m - 1] + dt * _cd[n][m - 1];
        }

        final par = ar * p[m][n];
        double temp1, temp2;
        if (m == 0) {
          temp1 = tc[m][n] * cp[m];
          temp2 = tc[m][n] * sp[m];
        } else {
          temp1 = tc[m][n] * cp[m] + tc[n][m - 1] * sp[m];
          temp2 = tc[m][n] * sp[m] - tc[n][m - 1] * cp[m];
        }
        bt -= ar * temp1 * dp[m][n];
        bp += fm[m] * temp2 * par;
        br += fn[n] * temp1 * par;

        if (st == 0.0 && m == 1) {
          if (n == 1) {
            pp[n] = pp[n - 1];
          } else {
            pp[n] = ct * pp[n - 1] - _k[m][n] * pp[n - 2];
          }
          bpp += fm[m] * temp2 * ar * pp[n];
        }
      }
    }

    bp = (st == 0.0) ? bpp : bp / st;

    final bx = -bt * ca - br * sa;
    final by = bp;

    final bh = sqrt(bx * bx + by * by);
    if (bh < 1e-10) return 0;

    return _rad2deg(atan2(by, bx));
  }

  static double _decimalDate(DateTime d) {
    final year = d.year;
    final daysInYear = (year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)) ? 366 : 365;
    final dayOfYear = d.difference(DateTime(year, 1, 1)).inMilliseconds /
        (daysInYear * 24 * 60 * 60 * 1000);
    return year + dayOfYear;
  }

  static double _deg2rad(double deg) => deg * (pi / 180);
  static double _rad2deg(double rad) => rad * (180 / pi);
}
