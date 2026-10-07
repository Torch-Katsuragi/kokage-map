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
/// 水準器（Spirit Level）画面
///
/// デバイスの加速度計・磁気センサー・GPS情報を統合して
/// 水平度、方位、GPS座標をリアルタイムに表示する全画面専用画面。
///
/// Features:
/// - 大きな円（球体見立て）内で流動点が動き、水平度を直感的に表示
/// - N/E/S/W が円周を回転してリアルタイムで北を指す
/// - 情報パネル: GPS座標、方位角、傾斜角、標高、三角形計算
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../i18n/strings.g.dart';
import '../services/gps_manager_service.dart';

/// 水準器画面
class LevelScreen extends StatefulWidget {
  const LevelScreen({super.key});

  @override
  State<LevelScreen> createState() => _LevelScreenState();
}

class _LevelScreenState extends State<LevelScreen> {
  // センサーデータ（ローパスフィルタ済み）
  double _filteredX = 0.0;
  double _filteredY = 0.0;
  double _filteredZ = 9.8;

  /// フィルタ済み加速度から求めた傾き（加速度が届くたびに 1 回だけ計算する）
  _Tilt _tilt = _Tilt.fromAccel(0.0, 0.0, 9.8);

  // コンパス
  double? _heading;
  double _compassAccuracy = -1; // 15=高精度, 30=中, 45=低, -1=不明

  // GPS
  final GpsManagerService _gpsManager = GpsManagerService();

  // ストリームサブスクリプション
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  StreamSubscription<CompassEvent>? _compassSubscription;

  // ローパスフィルタ係数（加速度計用）
  static const double _alpha = 0.12;

  // 水平判定で触覚フィードバック済みフラグ
  bool _wasLevel = false;

  // 三角形の基準辺（タップで切り替え）
  _TriangleRef _triangleRef = _TriangleRef.base;

  // コンパスEMA平滑化パラメータ
  static const double _compassAlpha = 0.08;
  double? _lastSmoothedHeading;

  @override
  void initState() {
    super.initState();
    _checkLevelHaptic();
    _startSensors();
    // GPS は位置が届いたら組み直す（以前は 2 秒おきのタイマーで読み直していた）
    _gpsManager.addListener(_onGpsUpdate);
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    _compassSubscription?.cancel();
    _gpsManager.removeListener(_onGpsUpdate);
    super.dispose();
  }

  void _startSensors() {
    // 加速度計ストリーム
    _accelSubscription = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 33), // ~30Hz
    ).listen((event) {
      setState(() {
        _filteredX = _alpha * event.x + (1 - _alpha) * _filteredX;
        _filteredY = _alpha * event.y + (1 - _alpha) * _filteredY;
        _filteredZ = _alpha * event.z + (1 - _alpha) * _filteredZ;
        _tilt = _Tilt.fromAccel(_filteredX, _filteredY, _filteredZ);
      });
      _checkLevelHaptic();
    });

    // コンパスストリーム（マップと同じEMA平滑化ロジック alpha=0.08）
    _compassSubscription = FlutterCompass.events?.listen((event) {
      final heading = event.heading;
      if (heading != null) {
        setState(() {
          _heading = _smoothHeading(heading);
          _compassAccuracy = event.accuracy ?? -1;
        });
      }
    });
  }

  /// 水平に入った瞬間だけ触覚フィードバックを返す
  void _checkLevelHaptic() {
    final isLevel = _LevelStatus.of(_tilt.tiltDeg) == _LevelStatus.level;
    if (isLevel && !_wasLevel) {
      HapticFeedback.lightImpact();
    }
    _wasLevel = isLevel;
  }

  void _onGpsUpdate() {
    if (mounted) setState(() {});
  }

  /// 循環角度対応 EMA 平滑化
  double _smoothHeading(double rawHeading) {
    final prev = _lastSmoothedHeading;
    if (prev == null) {
      _lastSmoothedHeading = rawHeading;
      return rawHeading;
    }
    // 最短角度差分を計算（-180° ~ +180°）
    double diff = rawHeading - prev;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    double smoothed = (prev + _compassAlpha * diff) % 360;
    if (smoothed < 0) smoothed += 360;
    _lastSmoothedHeading = smoothed;
    return smoothed;
  }

  void _selectTriangleRef(_TriangleRef ref) {
    if (ref == _triangleRef) return;
    setState(() => _triangleRef = ref);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final status = _LevelStatus.of(_tilt.tiltDeg);
    final levelView = _LevelView(
      tilt: _tilt,
      heading: _heading,
      statusColor: status.color,
    );
    final infoPanel = _LevelInfoPanel(
      tilt: _tilt,
      status: status,
      heading: _heading,
      compassAccuracy: _compassAccuracy,
      gps: _gpsManager.currentInfo,
      triangleRef: _triangleRef,
      onTriangleRefSelected: _selectTriangleRef,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(t.level.title),
        backgroundColor: status.color.withValues(alpha: 0.7),
        foregroundColor: Colors.white,
      ),
      backgroundColor: Colors.grey[900],
      body: OrientationBuilder(
        builder: (context, orientation) {
          if (orientation == Orientation.landscape) {
            return Row(
              children: [
                Expanded(child: levelView),
                SizedBox(width: 280, child: infoPanel),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: levelView),
              infoPanel,
            ],
          );
        },
      ),
    );
  }
}

// =============================================
// 傾き・水平状態・三角形の基準辺
// =============================================

/// 加速度から求めた傾き（度）
class _Tilt {
  /// Pitch（前後の傾き）。Y軸 = デバイス縦方向（前後）
  final double pitchDeg;

  /// Roll（左右の傾き）。X軸 = デバイス横方向（左右）
  final double rollDeg;

  /// 合成傾斜角
  final double tiltDeg;

  const _Tilt(this.pitchDeg, this.rollDeg, this.tiltDeg);

  factory _Tilt.fromAccel(double x, double y, double z) {
    final pitch = math.atan2(y, math.sqrt(x * x + z * z)) * 180 / math.pi;
    final roll = math.atan2(x, math.sqrt(y * y + z * z)) * 180 / math.pi;
    return _Tilt(pitch, roll, math.sqrt(pitch * pitch + roll * roll));
  }
}

/// 水平状態（1° 未満で水平、5° 未満でほぼ水平）
enum _LevelStatus {
  level(Colors.greenAccent, Icons.check_circle),
  almost(Colors.amberAccent, Icons.warning_amber_rounded),
  tilted(Colors.redAccent, Icons.error_outline);

  const _LevelStatus(this.color, this.icon);

  final Color color;
  final IconData icon;

  static _LevelStatus of(double tiltDeg) {
    if (tiltDeg < 1.0) return level;
    if (tiltDeg < 5.0) return almost;
    return tilted;
  }

  String get label => switch (this) {
        level => t.level.level,
        almost => t.level.almostLevel,
        tilted => t.level.tilted,
      };
}

typedef _TriangleSides = ({double base, double hypotenuse, double height});

/// 三角形の基準辺（タップで切り替え）
enum _TriangleRef {
  base,
  hypotenuse,
  height;

  /// 各辺の長さ（選択中の基準辺 = 1 として計算）
  _TriangleSides sides(double tiltDeg) {
    final tiltRad = tiltDeg * math.pi / 180;
    final s = math.sin(tiltRad);
    final c = math.cos(tiltRad);
    return switch (this) {
      _TriangleRef.base => (
          base: 1.0,
          hypotenuse: c != 0 ? 1.0 / c : double.infinity,
          height: math.tan(tiltRad),
        ),
      _TriangleRef.hypotenuse => (base: c, hypotenuse: 1.0, height: s),
      _TriangleRef.height => (
          base: s != 0 ? c / s : double.infinity,
          hypotenuse: s != 0 ? 1.0 / s : double.infinity,
          height: 1.0,
        ),
    };
  }

  /// 三角形セクションタイトル（基準辺に応じて変化）
  String get title => switch (this) {
        _TriangleRef.base => t.level.triangleCalcBase,
        _TriangleRef.hypotenuse => t.level.triangleCalcHypotenuse,
        _TriangleRef.height => t.level.triangleCalcHeight,
      };

  /// 各辺のラベル（基準辺に応じて数式が変わる）
  String get baseLabel => switch (this) {
        _TriangleRef.base => t.level.base,
        _TriangleRef.hypotenuse => '${t.level.base} (cos)',
        _TriangleRef.height => '${t.level.base} (cos/sin)',
      };

  String get hypotenuseLabel => switch (this) {
        _TriangleRef.base => '${t.level.hypotenuse} (1/cos)',
        _TriangleRef.hypotenuse => t.level.hypotenuse,
        _TriangleRef.height => '${t.level.hypotenuse} (1/sin)',
      };

  String get heightLabel => switch (this) {
        _TriangleRef.base => '${t.level.height} (tan)',
        _TriangleRef.hypotenuse => '${t.level.height} (sin)',
        _TriangleRef.height => t.level.height,
      };
}

/// 方位角を方角文字に変換
String _headingToDirection(double heading) {
  const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  final index = ((heading + 22.5) % 360 / 45).floor();
  return directions[index];
}

// =============================================
// 画面の部品
// =============================================

/// 水準器メインビュー（大きな円と流動点）
class _LevelView extends StatelessWidget {
  final _Tilt tilt;
  final double? heading;
  final Color statusColor;

  const _LevelView({
    required this.tilt,
    required this.heading,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _LevelPainter(
                pitchDeg: tilt.pitchDeg,
                rollDeg: tilt.rollDeg,
                tiltDeg: tilt.tiltDeg,
                heading: heading,
                statusColor: statusColor,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 情報パネル（水平状態・傾斜・方位・GPS・直角三角形）
class _LevelInfoPanel extends StatelessWidget {
  final _Tilt tilt;
  final _LevelStatus status;
  final double? heading;
  final double compassAccuracy;
  final GpsInfo gps;
  final _TriangleRef triangleRef;
  final ValueChanged<_TriangleRef> onTriangleRefSelected;

  const _LevelInfoPanel({
    required this.tilt,
    required this.status,
    required this.heading,
    required this.compassAccuracy,
    required this.gps,
    required this.triangleRef,
    required this.onTriangleRefSelected,
  });

  static const _divider = Divider(color: Colors.white24);

  static String _fixed(double? v, int digits, [String suffix = '']) =>
      v != null ? '${v.toStringAsFixed(digits)}$suffix' : '—';

  @override
  Widget build(BuildContext context) {
    final heading = this.heading;
    final bearing = gps.bearing;
    final sides = triangleRef.sides(tilt.tiltDeg);

    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.all(12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 水平状態インジケータ
            _buildStatusIndicator(),
            const SizedBox(height: 8),
            _divider,
            // 傾斜情報
            _InfoRow(t.level.tilt, '${tilt.tiltDeg.toStringAsFixed(1)}°'),
            _InfoRow('Pitch', '${tilt.pitchDeg.toStringAsFixed(1)}°'),
            _InfoRow('Roll', '${tilt.rollDeg.toStringAsFixed(1)}°'),
            _divider,
            // 方位
            _InfoRow(
              t.level.bearing,
              heading != null
                  ? '${heading.toStringAsFixed(1)}° ${_headingToDirection(heading)}'
                  : '—',
            ),
            _CompassAccuracyRow(compassAccuracy),
            if (bearing != null)
              _InfoRow(t.level.gpsBearing, '${bearing.toStringAsFixed(1)}°'),
            _divider,
            // GPS座標
            _InfoRow(t.level.latitude, _fixed(gps.latitude, 6)),
            _InfoRow(t.level.longitude, _fixed(gps.longitude, 6)),
            _InfoRow(t.level.altitude, _fixed(gps.altitude, 1, ' m')),
            _InfoRow(t.level.accuracy, _fixed(gps.accuracy, 1, ' m')),
            _divider,
            // 直角三角形の計算
            _SectionTitle(triangleRef.title),
            _buildTriangleRow(
                triangleRef.baseLabel, sides.base, _TriangleRef.base),
            _buildTriangleRow(triangleRef.hypotenuseLabel, sides.hypotenuse,
                _TriangleRef.hypotenuse),
            _buildTriangleRow(
                triangleRef.heightLabel, sides.height, _TriangleRef.height),
            const SizedBox(height: 8),
            // 三角形図示
            SizedBox(
              height: 100,
              child: CustomPaint(
                size: const Size(double.infinity, 100),
                painter: _TrianglePainter(
                  tiltDeg: tilt.tiltDeg,
                  base: sides.base,
                  hypotenuse: sides.hypotenuse,
                  height: sides.height,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    final color = status.color;
    return Row(
      children: [
        Icon(status.icon, color: color, size: 28),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${status.label} (${tilt.tiltDeg.toStringAsFixed(1)}°)',
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  /// 三角形の辺の行（タップで基準切り替え）
  Widget _buildTriangleRow(String label, double value, _TriangleRef ref) {
    final isSelected = triangleRef == ref;
    final valueStr = isSelected
        ? '= 1.0000'
        : (value.isFinite ? value.toStringAsFixed(4) : '∞');

    return GestureDetector(
      onTap: () => onTriangleRefSelected(ref),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSelected)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.touch_app,
                        color: Colors.cyanAccent, size: 12),
                  ),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected ? Colors.cyanAccent : Colors.white70,
                    fontSize: 13,
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
            Text(
              valueStr,
              style: TextStyle(
                color: isSelected ? Colors.cyanAccent : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ラベルと値の 1 行
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          decoration: TextDecoration.underline,
          decorationColor: Colors.white38,
        ),
      ),
    );
  }
}

/// コンパス精度インジケータ
class _CompassAccuracyRow extends StatelessWidget {
  /// 15=高精度, 30=中, 45=低, 0 以下=不明
  final double accuracy;

  const _CompassAccuracyRow(this.accuracy);

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon) = switch (accuracy) {
      <= 0 => (Colors.grey, Icons.help_outline),
      <= 15 => (Colors.greenAccent, Icons.check_circle_outline),
      <= 30 => (Colors.amberAccent, Icons.warning_amber_rounded),
      _ => (Colors.redAccent, Icons.error_outline),
    };
    final label = accuracy <= 0 ? '—' : '±${accuracy.toStringAsFixed(0)}°';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 4),
              Text(
                t.level.compassAccuracy,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================
// 水準器 CustomPainter
// =============================================

class _LevelPainter extends CustomPainter {
  final double pitchDeg;
  final double rollDeg;
  final double tiltDeg;
  final double? heading;
  final Color statusColor;

  _LevelPainter({
    required this.pitchDeg,
    required this.rollDeg,
    required this.tiltDeg,
    required this.heading,
    required this.statusColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) * 0.40;

    _drawOuterCircle(canvas, center, maxRadius);
    _drawGridLines(canvas, center, maxRadius);
    _drawNESW(canvas, center, maxRadius);
    _drawBubble(canvas, center, maxRadius);
  }

  /// 外周の大きな円（球体見立て）
  void _drawOuterCircle(Canvas canvas, Offset center, double maxRadius) {
    // 外枠
    final outerPaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, maxRadius, outerPaint);

    // 同心円ガイド（10°, 20°, 30°, ... に相当）
    final guidePaint = Paint()
      ..color = Colors.white10
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    for (int i = 1; i <= 8; i++) {
      canvas.drawCircle(center, maxRadius * i / 9, guidePaint);
    }

    // 1° 範囲のインナーサークル（水平判定ゾーン）
    final levelZoneRadius = maxRadius * (1.0 / 45.0); // 1° / 45°
    final levelZonePaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, levelZoneRadius, levelZonePaint);
    final levelZoneBorder = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, levelZoneRadius, levelZoneBorder);
  }

  /// グリッド線（十字）
  void _drawGridLines(Canvas canvas, Offset center, double maxRadius) {
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;
    canvas.drawLine(
        Offset(center.dx - maxRadius, center.dy),
        Offset(center.dx + maxRadius, center.dy),
        gridPaint);
    canvas.drawLine(
        Offset(center.dx, center.dy - maxRadius),
        Offset(center.dx, center.dy + maxRadius),
        gridPaint);
  }

  /// NESW コンパスラベル
  void _drawNESW(Canvas canvas, Offset center, double maxRadius) {
    if (heading == null) return;

    final headingRad = -heading! * math.pi / 180;
    const labels = ['N', 'E', 'S', 'W'];
    const colors = [Colors.redAccent, Colors.white70, Colors.white70, Colors.white70];
    final labelRadius = maxRadius + 20;

    for (int i = 0; i < 4; i++) {
      final angle = headingRad + (i * math.pi / 2);
      final x = center.dx + labelRadius * math.sin(angle);
      final y = center.dy - labelRadius * math.cos(angle);

      final textSpan = TextSpan(
        text: labels[i],
        style: TextStyle(
          color: colors[i],
          fontSize: labels[i] == 'N' ? 20 : 16,
          fontWeight: labels[i] == 'N' ? FontWeight.bold : FontWeight.w500,
        ),
      );
      final tp = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
    }

    // 刻み付き方位マーク（30°刻み）
    final tickPaint = Paint()
      ..color = Colors.white30
      ..strokeWidth = 1;
    for (int deg = 0; deg < 360; deg += 30) {
      if (deg % 90 == 0) continue; // N/E/S/Wの位置はスキップ
      final angle = headingRad + deg * math.pi / 180;
      final innerR = maxRadius + 8;
      final outerR = maxRadius + 14;
      canvas.drawLine(
        Offset(center.dx + innerR * math.sin(angle), center.dy - innerR * math.cos(angle)),
        Offset(center.dx + outerR * math.sin(angle), center.dy - outerR * math.cos(angle)),
        tickPaint,
      );
    }
  }

  /// 中心点と流動点（バブル）
  void _drawBubble(Canvas canvas, Offset center, double maxRadius) {
    // 中心点（固定）
    final centerDotPaint = Paint()..color = Colors.white60;
    canvas.drawCircle(center, 4, centerDotPaint);

    // 流動点の位置計算（球面正投影）
    // 大きな円を球として見立て、流動点は球の頂点（真上）にある点。
    // 上から見た時、傾斜角θの点は中心から sin(θ) * R の位置に射影される。
    // 90°で円周に到達（sin(90°) = 1）。
    final dirAngle = math.atan2(-pitchDeg, rollDeg); // atan2(Y方向, X方向)
    final tiltRad = math.min(tiltDeg, 90.0) * math.pi / 180; // 合成傾斜（ラジアン、90°でクランプ）
    final projDistance = math.sin(tiltRad) * maxRadius; // 球面射影距離

    final bubbleX = projDistance * math.cos(dirAngle);
    final bubbleY = projDistance * math.sin(dirAngle);

    final bubblePos = Offset(center.dx + bubbleX, center.dy + bubbleY);

    // 線分（中心〜流動点）
    final linePaint = Paint()
      ..color = statusColor.withValues(alpha: 0.6)
      ..strokeWidth = 1.5;
    canvas.drawLine(center, bubblePos, linePaint);

    // 角度ラベル（線分の中点横に表示）
    if (tiltDeg > 0.1) {
      final midPoint = Offset(
        (center.dx + bubblePos.dx) / 2,
        (center.dy + bubblePos.dy) / 2,
      );
      final textSpan = TextSpan(
        text: '${tiltDeg.toStringAsFixed(1)}°',
        style: TextStyle(
          color: statusColor,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      );
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();
      // 線分に対して垂直方向にオフセット
      final perpX = -(bubblePos.dy - center.dy);
      final perpY = bubblePos.dx - center.dx;
      final perpLen = math.sqrt(perpX * perpX + perpY * perpY);
      final offset = perpLen > 0
          ? Offset(perpX / perpLen * 16, perpY / perpLen * 16)
          : const Offset(16, 0);
      tp.paint(canvas, Offset(
        midPoint.dx + offset.dx - tp.width / 2,
        midPoint.dy + offset.dy - tp.height / 2,
      ));
    }

    // 流動点（バブル）
    final bubblePaint = Paint()..color = statusColor;
    canvas.drawCircle(bubblePos, 8, bubblePaint);

    // 流動点の光沢
    final highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.4);
    canvas.drawCircle(
      Offset(bubblePos.dx - 2, bubblePos.dy - 2),
      3,
      highlightPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _LevelPainter oldDelegate) =>
      oldDelegate.pitchDeg != pitchDeg ||
      oldDelegate.rollDeg != rollDeg ||
      oldDelegate.tiltDeg != tiltDeg ||
      oldDelegate.heading != heading ||
      oldDelegate.statusColor != statusColor;
}

// =============================================
// 直角三角形 CustomPainter
// =============================================

class _TrianglePainter extends CustomPainter {
  final double tiltDeg;
  final double base;
  final double hypotenuse;
  final double height;

  _TrianglePainter({
    required this.tiltDeg,
    required this.base,
    required this.hypotenuse,
    required this.height,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (tiltDeg < 0.01) {
      // ほぼ水平時は水平線のみ
      final paint = Paint()
        ..color = Colors.greenAccent
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(20, size.height - 20),
        Offset(size.width - 20, size.height - 20),
        paint,
      );
      final textSpan = TextSpan(
        text: t.level.levelState,
        style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
      );
      final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(size.width / 2 - tp.width / 2, size.height - 40));
      return;
    }

    // 三角形の描画（クランプ: tiltDegが大きすぎると三角形が崩れるので）
    final clampedTilt = math.min(tiltDeg, 60.0);
    final tiltRad = clampedTilt * math.pi / 180;
    final tanVal = math.tan(tiltRad);
    final cosVal = math.cos(tiltRad);

    // 描画領域
    const margin = 30.0;
    final maxWidth = size.width - margin * 2;
    final maxHeight = size.height - margin - 10;

    // 底辺の長さ（ピクセル）。高さが描画範囲に収まるように調整
    double baseLen = maxWidth * 0.6;
    final desiredH = baseLen * tanVal;
    if (desiredH > maxHeight) {
      baseLen = maxHeight / tanVal;
    }
    final h = baseLen * tanVal;
    final hypoLen = cosVal != 0 ? baseLen / cosVal : baseLen;

    // 各頂点
    final bottomLeft = Offset(margin, size.height - 10);
    final bottomRight = Offset(margin + baseLen, size.height - 10);
    final topRight = Offset(margin + baseLen, size.height - 10 - h);

    // 三角形塗りつぶし
    final fillPaint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(bottomLeft.dx, bottomLeft.dy)
      ..lineTo(bottomRight.dx, bottomRight.dy)
      ..lineTo(topRight.dx, topRight.dy)
      ..close();
    canvas.drawPath(path, fillPaint);

    // 三角形の辺
    final linePaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, linePaint);

    // 直角マーク
    const sq = 8.0;
    final sqPaint = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(bottomRight.dx - sq, bottomRight.dy),
      Offset(bottomRight.dx - sq, bottomRight.dy - sq),
      sqPaint,
    );
    canvas.drawLine(
      Offset(bottomRight.dx - sq, bottomRight.dy - sq),
      Offset(bottomRight.dx, bottomRight.dy - sq),
      sqPaint,
    );

    // 角度表示（左下角）
    _drawLabel(canvas, '${clampedTilt.toStringAsFixed(1)}°',
        Offset(bottomLeft.dx + 8, bottomLeft.dy - 16), Colors.amberAccent);

    // 底辺ラベル
    _drawLabel(canvas, base.isFinite ? base.toStringAsFixed(4) : '∞',
        Offset((bottomLeft.dx + bottomRight.dx) / 2 - 16, bottomLeft.dy + 2),
        Colors.white70, fontSize: 10);

    // 高さラベル（右辺）
    if (height.isFinite) {
      _drawLabel(canvas, height.toStringAsFixed(4),
          Offset(bottomRight.dx + 4, (bottomRight.dy + topRight.dy) / 2 - 6),
          Colors.cyanAccent, fontSize: 10);
    }

    // 斜辺ラベル
    if (hypotenuse.isFinite && hypoLen > 20) {
      final mid = Offset(
        (bottomLeft.dx + topRight.dx) / 2 - 24,
        (bottomLeft.dy + topRight.dy) / 2 - 8,
      );
      _drawLabel(canvas, hypotenuse.toStringAsFixed(4), mid,
          Colors.orangeAccent, fontSize: 10);
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset pos, Color color,
      {double fontSize = 11}) {
    final textSpan = TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w600),
    );
    final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _TrianglePainter oldDelegate) =>
      oldDelegate.tiltDeg != tiltDeg ||
      oldDelegate.base != base ||
      oldDelegate.hypotenuse != hypotenuse ||
      oldDelegate.height != height;
}
