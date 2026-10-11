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
// こかげマップ: WGS84 楕円体の測地線長（Karney の逆解法）
//
// GeographicLib（Python 版 geographiclib 2.0 の geodesic.py / geomath.py）の Inverse から
// 距離を出すのに要る部分だけを移した。QGIS の楕円体の長さも GeographicLib なので同じ値になる。
// Vincenty と違って対蹠点の近くでも必ず収束する。
//
// 原典: Charles F. F. Karney, Algorithms for geodesics, J. Geodesy 87, 43-55 (2013),
//   https://doi.org/10.1007/s00190-012-0578-z
//   Copyright (c) Charles Karney (2011-2022) <karney@alum.mit.edu>, MIT/X11 License
//   https://geographiclib.sourceforge.io/

import 'dart:math' as math;

/// WGS84 の上の 2 点間の測地線長 [m]
double karneyDistance(double lat1, double lon1, double lat2, double lon2) =>
    _KarneyWgs84.instance.distance(lat1, lon1, lat2, lon2);

double _sq(double x) => x * x;

double _copysign(double x, double y) => (y.isNegative ? -x.abs() : x.abs());

double _hypot(double x, double y) => math.sqrt(x * x + y * y);

double _cbrt(double x) => _copysign(math.pow(x.abs(), 1 / 3.0).toDouble(), x);

(double, double) _norm(double x, double y) {
  final r = _hypot(x, y);
  return (x / r, y / r);
}

/// 誤差の出ない和（s + t = u + v）
(double, double) _sum(double u, double v) {
  final s = u + v;
  var up = s - v;
  var vpp = s - up;
  up -= u;
  vpp -= v;
  final t = s == 0 ? 0.0 : 0.0 - (up + vpp);
  return (s, t);
}

double _polyval(int n, List<double> p, int s, double x) {
  var y = n < 0 ? 0.0 : p[s];
  while (n > 0) {
    n--;
    s++;
    y = y * x + p[s];
  }
  return y;
}

double _angRound(double x) {
  const z = 1 / 16.0;
  var y = x.abs();
  if (y < z) y = z - (z - y);
  return _copysign(y, x);
}

/// IEEE の remainder（[-y/2, y/2]）
double _remainder(double x, double y) {
  if (!x.isFinite) return double.nan;
  var r = x % y; // [0, y)
  if (r > y / 2) r -= y;
  return r;
}

(double, double) _angDiff(double x, double y) {
  var (d, t) = _sum(_remainder(-x, 360), _remainder(y, 360));
  (d, t) = _sum(_remainder(d, 360), t);
  if (d == 0 || d.abs() == 180) d = _copysign(d, t == 0 ? y - x : -t);
  return (d, t);
}

(double, double) _sincosd(double x) {
  var r = x.isFinite ? x.remainder(360).toDouble() : double.nan;
  final q0 = r.isNaN ? 0 : (r / 90).round();
  r -= 90 * q0;
  r = r * math.pi / 180;
  var s = math.sin(r), c = math.cos(r);
  switch (q0 % 4) {
    case 1:
      (s, c) = (c, -s);
    case 2:
      (s, c) = (-s, -c);
    case 3:
      (s, c) = (-c, s);
  }
  c = c + 0.0;
  if (s == 0) s = _copysign(s, x);
  return (s, c);
}

(double, double) _sincosde(double x, double t) {
  final q0 = x.isFinite ? (x / 90).round() : 0;
  var r = x - 90 * q0;
  r = _angRound(r + t) * math.pi / 180;
  var s = math.sin(r), c = math.cos(r);
  switch (q0 % 4) {
    case 1:
      (s, c) = (c, -s);
    case 2:
      (s, c) = (-s, -c);
    case 3:
      (s, c) = (-c, s);
  }
  c = c + 0.0;
  if (s == 0) s = _copysign(s, x);
  return (s, c);
}

class _KarneyWgs84 {
  _KarneyWgs84._() {
    _a3coeff();
    _c3coeff();
  }

  static final instance = _KarneyWgs84._();

  static const int _order = 6;
  static const int _nA1 = _order, _nC1 = _order, _nC2 = _order, _nA2 = _order, _nA3 = _order, _nC3 = _order;
  static const int _nC3x = (_nC3 * (_nC3 - 1)) ~/ 2;
  static const int _maxit1 = 20;
  static const int _maxit2 = _maxit1 + 53 + 10;

  static final double _tiny = math.sqrt(2.2250738585072014e-308);
  static const double _tol0 = 2.220446049250313e-16;
  static const double _tol1 = 200 * _tol0;
  static final double _tol2 = math.sqrt(_tol0);
  static const double _tolb = _tol0;
  static final double _xthresh = 1000 * _tol2;

  static const double a = 6378137.0;
  static const double f = 1 / 298.257223563;
  static const double _f1 = 1 - f;
  static const double _e2 = f * (2 - f);
  static const double _ep2 = _e2 / (_f1 * _f1);
  static const double _n = f / (2 - f);
  static const double _b = a * _f1;
  static final double _etol2 = 0.1 * _tol2 / math.sqrt(math.max(0.001, f.abs()) * math.min(1.0, 1 - f / 2) / 2);

  final List<double> _a3x = List.filled(_nA3, 0);
  final List<double> _c3x = List.filled(_nC3x, 0);

  static double _sinCosSeries(bool sinp, double sinx, double cosx, List<double> c) {
    var k = c.length;
    var n = k - (sinp ? 1 : 0);
    final ar = 2 * (cosx - sinx) * (cosx + sinx);
    var y1 = 0.0;
    double y0;
    if (n & 1 != 0) {
      k--;
      y0 = c[k];
    } else {
      y0 = 0;
    }
    n = n ~/ 2;
    while (n > 0) {
      n--;
      k--;
      y1 = ar * y0 - y1 + c[k];
      k--;
      y0 = ar * y1 - y0 + c[k];
    }
    return sinp ? 2 * sinx * cosx * y0 : cosx * (y0 - y1);
  }

  static double _astroid(double x, double y) {
    final p = _sq(x);
    final q = _sq(y);
    final r = (p + q - 1) / 6;
    if (!(q == 0 && r <= 0)) {
      final s = p * q / 4;
      final r2 = _sq(r);
      final r3 = r * r2;
      final disc = s * (s + 2 * r3);
      var u = r;
      if (disc >= 0) {
        var t3 = s + r3;
        t3 += t3 < 0 ? -math.sqrt(disc) : math.sqrt(disc);
        final t = _cbrt(t3);
        u += t + (t != 0 ? r2 / t : 0);
      } else {
        final ang = math.atan2(math.sqrt(-disc), -(s + r3));
        u += 2 * r * math.cos(ang / 3);
      }
      final v = math.sqrt(_sq(u) + q);
      final uv = u < 0 ? q / (v - u) : u + v;
      final w = (uv - q) / (2 * v);
      return uv / (math.sqrt(uv + _sq(w)) + w);
    }
    return 0;
  }

  static double _a1m1f(double eps) {
    const coeff = <double>[1, 4, 64, 0, 256];
    const m = _nA1 ~/ 2;
    final t = _polyval(m, coeff, 0, _sq(eps)) / coeff[m + 1];
    return (t + eps) / (1 - eps);
  }

  static void _c1f(double eps, List<double> c) {
    const coeff = <double>[-1, 6, -16, 32, -9, 64, -128, 2048, 9, -16, 768, 3, -5, 512, -7, 1280, -7, 2048];
    final eps2 = _sq(eps);
    var d = eps;
    var o = 0;
    for (var l = 1; l <= _nC1; l++) {
      final m = (_nC1 - l) ~/ 2;
      c[l] = d * _polyval(m, coeff, o, eps2) / coeff[o + m + 1];
      o += m + 2;
      d *= eps;
    }
  }

  static double _a2m1f(double eps) {
    const coeff = <double>[-11, -28, -192, 0, 256];
    const m = _nA2 ~/ 2;
    final t = _polyval(m, coeff, 0, _sq(eps)) / coeff[m + 1];
    return (t - eps) / (1 + eps);
  }

  static void _c2f(double eps, List<double> c) {
    const coeff = <double>[1, 2, 16, 32, 35, 64, 384, 2048, 15, 80, 768, 7, 35, 512, 63, 1280, 77, 2048];
    final eps2 = _sq(eps);
    var d = eps;
    var o = 0;
    for (var l = 1; l <= _nC2; l++) {
      final m = (_nC2 - l) ~/ 2;
      c[l] = d * _polyval(m, coeff, o, eps2) / coeff[o + m + 1];
      o += m + 2;
      d *= eps;
    }
  }

  void _a3coeff() {
    const coeff = <double>[-3, 128, -2, -3, 64, -1, -3, -1, 16, 3, -1, -2, 8, 1, -1, 2, 1, 1];
    var o = 0, k = 0;
    for (var j = _nA3 - 1; j >= 0; j--) {
      final m = math.min(_nA3 - j - 1, j);
      _a3x[k++] = _polyval(m, coeff, o, _n) / coeff[o + m + 1];
      o += m + 2;
    }
  }

  void _c3coeff() {
    const coeff = <double>[
      3, 128, 2, 5, 128, -1, 3, 3, 64, -1, 0, 1, 8, -1, 1, 4, //
      5, 256, 1, 3, 128, -3, -2, 3, 64, 1, -3, 2, 32, //
      7, 512, -10, 9, 384, 5, -9, 5, 192, //
      7, 512, -14, 7, 512, //
      21, 2560,
    ];
    var o = 0, k = 0;
    for (var l = 1; l < _nC3; l++) {
      for (var j = _nC3 - 1; j >= l; j--) {
        final m = math.min(_nC3 - j - 1, j);
        _c3x[k++] = _polyval(m, coeff, o, _n) / coeff[o + m + 1];
        o += m + 2;
      }
    }
  }

  double _a3f(double eps) => _polyval(_nA3 - 1, _a3x, 0, eps);

  void _c3f(double eps, List<double> c) {
    var mult = 1.0;
    var o = 0;
    for (var l = 1; l < _nC3; l++) {
      final m = _nC3 - l - 1;
      mult *= eps;
      c[l] = mult * _polyval(m, _c3x, o, eps);
      o += m + 1;
    }
  }

  /// (s12b, m12b): 距離と換算長（どちらも b で割った値）
  (double, double) _lengths(
    double eps,
    double sig12,
    double ssig1,
    double csig1,
    double dn1,
    double ssig2,
    double csig2,
    double dn2, {
    required bool distance,
    required bool reduced,
    required List<double> c1a,
    required List<double> c2a,
  }) {
    var s12b = double.nan, m12b = double.nan;
    var a1 = _a1m1f(eps);
    _c1f(eps, c1a);
    var a2 = 0.0, m0x = 0.0;
    if (reduced) {
      a2 = _a2m1f(eps);
      _c2f(eps, c2a);
      m0x = a1 - a2;
      a2 = 1 + a2;
    }
    a1 = 1 + a1;
    double j12 = 0;
    if (distance) {
      final b1 = _sinCosSeries(true, ssig2, csig2, c1a) - _sinCosSeries(true, ssig1, csig1, c1a);
      s12b = a1 * (sig12 + b1);
      if (reduced) {
        final b2 = _sinCosSeries(true, ssig2, csig2, c2a) - _sinCosSeries(true, ssig1, csig1, c2a);
        j12 = m0x * sig12 + (a1 * b1 - a2 * b2);
      }
    } else if (reduced) {
      for (var l = 1; l < _nC2; l++) {
        c2a[l] = a1 * c1a[l] - a2 * c2a[l];
      }
      j12 = m0x * sig12 + (_sinCosSeries(true, ssig2, csig2, c2a) - _sinCosSeries(true, ssig1, csig1, c2a));
    }
    if (reduced) {
      m12b = dn2 * (csig1 * ssig2) - dn1 * (ssig1 * csig2) - csig1 * csig2 * j12;
    }
    return (s12b, m12b);
  }

  /// Newton 法の出発点。短い線なら sig12 >= 0 と dnm も返す
  (double sig12, double salp1, double calp1, double dnm) _inverseStart(
    double sbet1,
    double cbet1,
    double sbet2,
    double cbet2,
    double lam12,
    double slam12,
    double clam12,
  ) {
    var sig12 = -1.0, dnm = double.nan;
    final sbet12 = sbet2 * cbet1 - cbet2 * sbet1;
    final cbet12 = cbet2 * cbet1 + sbet2 * sbet1;
    var sbet12a = sbet2 * cbet1;
    sbet12a += cbet2 * sbet1;

    final shortline = cbet12 >= 0 && sbet12 < 0.5 && cbet2 * lam12 < 0.5;
    double somg12, comg12;
    if (shortline) {
      var sbetm2 = _sq(sbet1 + sbet2);
      sbetm2 /= sbetm2 + _sq(cbet1 + cbet2);
      dnm = math.sqrt(1 + _ep2 * sbetm2);
      final omg12 = lam12 / (_f1 * dnm);
      somg12 = math.sin(omg12);
      comg12 = math.cos(omg12);
    } else {
      somg12 = slam12;
      comg12 = clam12;
    }

    var salp1 = cbet2 * somg12;
    var calp1 = comg12 >= 0
        ? sbet12 + cbet2 * sbet1 * _sq(somg12) / (1 + comg12)
        : sbet12a - cbet2 * sbet1 * _sq(somg12) / (1 - comg12);

    final ssig12 = _hypot(salp1, calp1);
    final csig12 = sbet1 * sbet2 + cbet1 * cbet2 * comg12;

    if (shortline && ssig12 < _etol2) {
      sig12 = math.atan2(ssig12, csig12);
    } else if (_n.abs() >= 0.1 || csig12 >= 0 || ssig12 >= 6 * _n.abs() * math.pi * _sq(cbet1)) {
      // 球の近似で足りる
    } else {
      // 対蹠点の近く: アステロイドの式で出発点を決める（f > 0 の場合）
      final lam12x = math.atan2(-slam12, -clam12);
      final k2 = _sq(sbet1) * _ep2;
      final eps = k2 / (2 * (1 + math.sqrt(1 + k2)) + k2);
      final lamscale = f * cbet1 * _a3f(eps) * math.pi;
      final betscale = lamscale * cbet1;
      final x = lam12x / lamscale;
      final y = sbet12a / betscale;
      if (y > -_tol1 && x > -1 - _xthresh) {
        salp1 = math.min(1.0, -x);
        calp1 = -math.sqrt(1 - _sq(salp1));
      } else {
        final k = _astroid(x, y);
        final omg12a = lamscale * (-x * k / (1 + k));
        somg12 = math.sin(omg12a);
        comg12 = -math.cos(omg12a);
        salp1 = cbet2 * somg12;
        calp1 = sbet12a - cbet2 * sbet1 * _sq(somg12) / (1 - comg12);
      }
    }
    if (!(salp1 <= 0)) {
      (salp1, calp1) = _norm(salp1, calp1);
    } else {
      salp1 = 1;
      calp1 = 0;
    }
    return (sig12, salp1, calp1, dnm);
  }

  double distance(double lat1, double lon1, double lat2, double lon2) {
    var (lon12, lon12s) = _angDiff(lon1, lon2);
    final lonsign = _copysign(1, lon12);
    lon12 = lonsign * lon12;
    lon12s = lonsign * lon12s;
    final lam12 = lon12 * math.pi / 180;
    final (slam12, clam12) = _sincosde(lon12, lon12s);
    lon12s = (180 - lon12) - lon12s;

    lat1 = _angRound(lat1.abs() > 90 ? double.nan : lat1);
    lat2 = _angRound(lat2.abs() > 90 ? double.nan : lat2);
    if (lat1.abs() < lat2.abs() || lat2.isNaN) {
      (lat1, lat2) = (lat2, lat1);
    }
    final latsign = _copysign(1, -lat1);
    lat1 *= latsign;
    lat2 *= latsign;

    var (sbet1, cbet1) = _sincosd(lat1);
    sbet1 *= _f1;
    (sbet1, cbet1) = _norm(sbet1, cbet1);
    cbet1 = math.max(_tiny, cbet1);

    var (sbet2, cbet2) = _sincosd(lat2);
    sbet2 *= _f1;
    (sbet2, cbet2) = _norm(sbet2, cbet2);
    cbet2 = math.max(_tiny, cbet2);

    if (cbet1 < -sbet1) {
      if (cbet2 == cbet1) sbet2 = _copysign(sbet1, sbet2);
    } else {
      if (sbet2.abs() == -sbet1) cbet2 = cbet1;
    }

    final dn1 = math.sqrt(1 + _ep2 * _sq(sbet1));
    final dn2 = math.sqrt(1 + _ep2 * _sq(sbet2));

    final c1a = List<double>.filled(_nC1 + 1, 0);
    final c2a = List<double>.filled(_nC2 + 1, 0);
    final c3a = List<double>.filled(_nC3, 0);

    var s12x = double.nan;
    var meridian = lat1 == -90 || slam12 == 0;

    if (meridian) {
      // 両端が同じ子午線の上にある。行き先の経度へ向かう
      final calp1 = clam12;
      const calp2 = 1.0;
      final ssig1 = sbet1, csig1 = calp1 * cbet1;
      final ssig2 = sbet2, csig2 = calp2 * cbet2;
      var sig12 = math.atan2(math.max(0.0, csig1 * ssig2 - ssig1 * csig2) + 0.0, csig1 * csig2 + ssig1 * ssig2);
      final (s, m) = _lengths(_n, sig12, ssig1, csig1, dn1, ssig2, csig2, dn2,
          distance: true, reduced: true, c1a: c1a, c2a: c2a);
      var sx = s, mx = m;
      // 換算長が負なら子午線は最短でない（対蹠点の近く）。一般の場合へ
      if (sig12 < _tol2 || mx >= 0) {
        if (sig12 < 3 * _tiny || (sig12 < _tol0 && (sx < 0 || mx < 0))) {
          sig12 = mx = sx = 0.0;
        }
        s12x = sx * _b;
      } else {
        meridian = false;
      }
    }

    if (!meridian && sbet1 == 0 && (f <= 0 || lon12s >= f * 180)) {
      // 赤道に沿う
      s12x = a * lam12;
    } else if (!meridian) {
      var (sig12, salp1, calp1, dnm) = _inverseStart(sbet1, cbet1, sbet2, cbet2, lam12, slam12, clam12);
      if (sig12 >= 0) {
        s12x = sig12 * _b * dnm;
      } else {
        var numit = 0;
        var tripn = false, tripb = false;
        var salp1a = _tiny, calp1a = 1.0;
        var salp1b = _tiny, calp1b = -1.0;
        late _Lambda12 r;
        while (true) {
          r = _lambda12(sbet1, cbet1, dn1, sbet2, cbet2, dn2, salp1, calp1, slam12, clam12, numit < _maxit1, c1a, c2a, c3a);
          final v = r.lam12;
          final dv = r.dlam12;
          if (tripb || !(v.abs() >= (tripn ? 8 : 1) * _tol0) || numit == _maxit2) break;
          if (v > 0 && (numit > _maxit1 || calp1 / salp1 > calp1b / salp1b)) {
            salp1b = salp1;
            calp1b = calp1;
          } else if (v < 0 && (numit > _maxit1 || calp1 / salp1 < calp1a / salp1a)) {
            salp1a = salp1;
            calp1a = calp1;
          }
          numit++;
          if (numit < _maxit1 && dv > 0) {
            final dalp1 = -v / dv;
            if (dalp1.abs() < math.pi) {
              final sdalp1 = math.sin(dalp1), cdalp1 = math.cos(dalp1);
              final nsalp1 = salp1 * cdalp1 + calp1 * sdalp1;
              if (nsalp1 > 0) {
                calp1 = calp1 * cdalp1 - salp1 * sdalp1;
                salp1 = nsalp1;
                (salp1, calp1) = _norm(salp1, calp1);
                tripn = v.abs() <= 16 * _tol0;
                continue;
              }
            }
          }
          salp1 = (salp1a + salp1b) / 2;
          calp1 = (calp1a + calp1b) / 2;
          (salp1, calp1) = _norm(salp1, calp1);
          tripn = false;
          tripb = (salp1a - salp1).abs() + (calp1a - calp1) < _tolb || (salp1 - salp1b).abs() + (calp1 - calp1b) < _tolb;
        }
        final (s, _) = _lengths(r.eps, r.sig12, r.ssig1, r.csig1, dn1, r.ssig2, r.csig2, dn2,
            distance: true, reduced: false, c1a: c1a, c2a: c2a);
        s12x = s * _b;
      }
    }
    return 0.0 + s12x;
  }

  _Lambda12 _lambda12(
    double sbet1,
    double cbet1,
    double dn1,
    double sbet2,
    double cbet2,
    double dn2,
    double salp1,
    double calp1,
    double slam120,
    double clam120,
    bool diffp,
    List<double> c1a,
    List<double> c2a,
    List<double> c3a,
  ) {
    if (sbet1 == 0 && calp1 == 0) calp1 = -_tiny;
    final salp0 = salp1 * cbet1;
    final calp0 = _hypot(calp1, salp1 * sbet1);

    var ssig1 = sbet1;
    final somg1 = salp0 * sbet1;
    var csig1 = calp1 * cbet1;
    final comg1 = csig1;
    (ssig1, csig1) = _norm(ssig1, csig1);

    final calp2 = (cbet2 != cbet1 || sbet2.abs() != -sbet1)
        ? math.sqrt(_sq(calp1 * cbet1) + (cbet1 < -sbet1 ? (cbet2 - cbet1) * (cbet1 + cbet2) : (sbet1 - sbet2) * (sbet1 + sbet2))) / cbet2
        : calp1.abs();
    var ssig2 = sbet2;
    final somg2 = salp0 * sbet2;
    var csig2 = calp2 * cbet2;
    final comg2 = csig2;
    (ssig2, csig2) = _norm(ssig2, csig2);

    final sig12 = math.atan2(math.max(0.0, csig1 * ssig2 - ssig1 * csig2) + 0.0, csig1 * csig2 + ssig1 * ssig2);
    final somg12 = math.max(0.0, comg1 * somg2 - somg1 * comg2) + 0.0;
    final comg12 = comg1 * comg2 + somg1 * somg2;
    final eta = math.atan2(somg12 * clam120 - comg12 * slam120, comg12 * clam120 + somg12 * slam120);

    final k2 = _sq(calp0) * _ep2;
    final eps = k2 / (2 * (1 + math.sqrt(1 + k2)) + k2);
    _c3f(eps, c3a);
    final b312 = _sinCosSeries(true, ssig2, csig2, c3a) - _sinCosSeries(true, ssig1, csig1, c3a);
    final domg12 = -f * _a3f(eps) * salp0 * (sig12 + b312);
    final lam12 = eta + domg12;

    double dlam12;
    if (diffp) {
      if (calp2 == 0) {
        dlam12 = -2 * _f1 * dn1 / sbet1;
      } else {
        final (_, m) = _lengths(eps, sig12, ssig1, csig1, dn1, ssig2, csig2, dn2,
            distance: false, reduced: true, c1a: c1a, c2a: c2a);
        dlam12 = m * _f1 / (calp2 * cbet2);
      }
    } else {
      dlam12 = double.nan;
    }
    return _Lambda12(lam12, dlam12, sig12, ssig1, csig1, ssig2, csig2, eps);
  }
}

class _Lambda12 {
  const _Lambda12(this.lam12, this.dlam12, this.sig12, this.ssig1, this.csig1, this.ssig2, this.csig2, this.eps);
  final double lam12, dlam12, sig12, ssig1, csig1, ssig2, csig2, eps;
}
