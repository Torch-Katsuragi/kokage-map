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
/// TruPulse の計測出力（`$PLTIT` 文）の解釈
///
/// 出典: LTI TruPulse 360 User's Manual 4th Edition (part 0144801),
/// Section 8 "Download Message Formats" p.43–45。
/// - HV: `$PLTIT,HV,HD,units,AZ,D,INC,D,SD,units*csum`
/// - HT: `$PLTIT,HT,HT,units*csum`（高さルーチンの結果）
/// - ML: `$PLTIT,ML,HD,units,AZ,D,INC,D,SD,units*csum`（2点間の連結ベクトル）
///
/// チェックサムは `$` と `*` の間の全文字の XOR（NMEA 0183 と同じ）。付いていて合わない行は捨てる。
/// 単位は F=フィート、Y=ヤード、M=メートル。アプリは接続時に `$DU,0`（メートル）を送るが、念のためメートルに換算する。
/// docs/devices/trupulse-360r.md「計測データフォーマット」
library;

import 'dart:math' as math;

sealed class TruPulseSentence {
  const TruPulseSentence();

  /// 1行を解釈する。`$PLTIT` の HV / HT / ML 以外、値の欠けた文、チェックサムの合わない文は null
  static TruPulseSentence? parse(String line) {
    var s = line.trim();
    if (!s.startsWith(r'$PLTIT,')) return null;
    final star = s.indexOf('*');
    if (star >= 0) {
      final given = int.tryParse(s.substring(star + 1).trim(), radix: 16);
      if (given == null || given != checksum(s.substring(1, star))) return null;
      s = s.substring(0, star);
    }
    final p = s.split(',');
    if (p.length < 2) return null;
    switch (p[1]) {
      case 'HV':
      case 'ML':
        if (p.length < 10) return null;
        final hd = _dist(p[2], p[3]);
        final az = double.tryParse(p[4]);
        final inc = double.tryParse(p[6]);
        final sd = _dist(p[8], p[9]);
        // 低品質ターゲット・方位のみの文は距離が空になる（マニュアル p.43 の例）
        if (hd == null || az == null || inc == null || sd == null) return null;
        return p[1] == 'HV'
            ? TruPulseVector(hd: hd, az: az, inc: inc, sd: sd)
            : TruPulseMissingLine(hd: hd, az: az, inc: inc, sd: sd);
      case 'HT':
        if (p.length < 4) return null;
        final ht = _dist(p[2], p[3]);
        return ht == null ? null : TruPulseHeight(ht);
    }
    return null;
  }

  /// 計測の文（HV / HT / ML）か。読めるかどうかは問わない（距離が空の HV・チェックサム違いも true）
  static bool isMeasurementLine(String line) {
    final s = line.trim();
    return s.startsWith(r'$PLTIT,HV,') || s.startsWith(r'$PLTIT,HT,') || s.startsWith(r'$PLTIT,ML,');
  }

  /// `$` と `*` の間の文字の XOR
  static int checksum(String body) {
    var c = 0;
    for (final u in body.codeUnits) {
      c ^= u;
    }
    return c;
  }

  static double? _dist(String value, String unit) {
    final v = double.tryParse(value);
    if (v == null) return null;
    return switch (unit.trim().toUpperCase()) {
      'F' => v * 0.3048,
      'Y' => v * 0.9144,
      _ => v,
    };
  }
}

/// HV（Horizontal Vector）: 1ショットの計測。距離はメートル、角度は度
class TruPulseVector extends TruPulseSentence {
  final double hd;
  final double az;
  final double inc;
  final double sd;
  const TruPulseVector({required this.hd, required this.az, required this.inc, required this.sd});

  /// 鉛直距離 = HD × tan(INC)
  double get vd => hd * math.tan(inc * math.pi / 180.0);
}

/// HT（Height）: 高さルーチン（HD → 角度1 → 角度2 の3ショット）で本体が算出した高さ（m）
class TruPulseHeight extends TruPulseSentence {
  final double heightM;
  const TruPulseHeight(this.heightM);
}

/// ML（Missing Line）: 2ショットの間の連結ベクトル。器械点からの位置ではないので点の生成には使わない
class TruPulseMissingLine extends TruPulseSentence {
  final double hd;
  final double az;
  final double inc;
  final double sd;
  const TruPulseMissingLine({required this.hd, required this.az, required this.inc, required this.sd});
}
