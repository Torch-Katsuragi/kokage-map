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
/// GNSS 測位の品質: GPS 測量で測った点ごとの記録（測位の種類・衛星数・DOP・精度・平均化）と、
/// 条件を満たさない測位を弾く条件（[GnssQualityGate]）。
///
/// 記録は測量の記録（`drawing_points` の 1 点）の `quality` に JSON で入る。
/// キーは書き出しの列名にそのまま使えるよう短い英小文字（fix・sats・hacc・avg_n …）。
/// 詳しくは docs/technical/gps-architecture.md「GNSS の品質の記録と足切り」
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../i18n/strings.g.dart';

/// 測位の種類（悪い順）。GGA の品質番号から決める
enum GnssFix {
  none('none', 'No Fix'),
  gps('gps', 'GPS'),
  dgps('dgps', 'DGPS'),
  rtkFloat('rtk_float', 'RTK FLOAT'),
  rtkFixed('rtk_fixed', 'RTK FIX');

  const GnssFix(this.code, this.label);

  /// JSON・書き出しの列に書く値
  final String code;

  /// 画面に出す名前（受信機の表記に合わせ、訳さない）
  final String label;

  /// GGA の品質番号（0 無効・1 単独・2 DGPS・3 PPS・4 RTK 固定解・5 RTK 浮動解・6 推測航法・
  /// 7 手入力・8 シミュレーション・9 SBAS）から。null なら null（端末の GPS など）
  static GnssFix? fromGgaQuality(int? quality) => switch (quality) {
        null => null,
        1 => GnssFix.gps,
        2 || 3 || 9 => GnssFix.dgps,
        5 => GnssFix.rtkFloat,
        4 => GnssFix.rtkFixed,
        _ => GnssFix.none, // 0・推測航法・手入力・シミュレーションは測位とみなさない
      };

  static GnssFix? fromCode(Object? code) =>
      GnssFix.values.where((f) => f.code == code).firstOrNull;

  bool atLeast(GnssFix other) => index >= other.index;
}

/// 精度の数字の出どころ
abstract final class GnssAccuracySource {
  /// 受信機の GST（緯度・経度の標準偏差）
  static const gst = 'gst';

  /// GGA の品質番号と HDOP からの見積もり
  static const hdop = 'hdop';

  /// 端末の位置情報（Android の推定精度）
  static const device = 'device';
}

/// GPS 測量で集めた 1 回分の測位（`usedGpsData` の 1 件・[GpsSurveySample.toMap] の形）
@immutable
class GnssSample {
  const GnssSample({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.accuracySource,
    this.satellites,
    this.hdop,
    this.pdop,
    this.gpsQuality,
    this.isExternal = false,
    this.device,
    this.time,
  });

  /// 測量の記録の 1 件から。緯度経度が無ければ null
  static GnssSample? fromMap(Map<dynamic, dynamic> m) {
    final lat = _num(m['latitude']);
    final lon = _num(m['longitude']);
    if (lat == null || lon == null) return null;
    final isExternal = m['sourceType'] == 'GNSS';
    return GnssSample(
      latitude: lat,
      longitude: lon,
      accuracy: _num(m['accuracy']),
      accuracySource: m['accuracySource'] as String? ??
          (isExternal ? GnssAccuracySource.hdop : GnssAccuracySource.device),
      satellites: (m['satelliteCount'] as num?)?.toInt(),
      hdop: _num(m['hdop']),
      pdop: _num(m['pdop']),
      gpsQuality: (m['gpsQuality'] as num?)?.toInt(),
      isExternal: isExternal,
      device: m['selectedDevice'] as String?,
      time: DateTime.tryParse('${m['collectedAt'] ?? m['timestamp'] ?? ''}'),
    );
  }

  final double latitude;
  final double longitude;
  final double? accuracy;
  final String? accuracySource;
  final int? satellites;
  final double? hdop;
  final double? pdop;
  final int? gpsQuality;
  final bool isExternal;
  final String? device;
  final DateTime? time;

  /// 測位の種類。端末の GPS は種類が分からないので単独測位（GPS）とみなす（足切りの比較用）
  GnssFix? get fix => GnssFix.fromGgaQuality(gpsQuality) ?? (isExternal ? null : GnssFix.gps);
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

int? _minOrNull(Iterable<int?> values) {
  final v = values.nonNulls;
  return v.isEmpty ? null : v.reduce(math.min);
}

double? _maxOrNull(Iterable<double?> values) {
  final v = values.nonNulls;
  return v.isEmpty ? null : v.reduce(math.max);
}

/// 測量した 1 点の品質の記録（平均化したならその全体）
@immutable
class GnssQuality {
  const GnssQuality({
    required this.source,
    this.device,
    this.fix,
    this.satellites,
    this.hdop,
    this.pdop,
    this.hAccuracy,
    this.hAccuracySource,
    this.averagingCount = 1,
    this.averagingSeconds = 0,
    this.spread,
    this.time,
    this.rejected = 0,
    this.warnings = const [],
  });

  /// `GPS`（端末）か `GNSS`（外部受信機）。source_type 列と同じ値
  final String source;
  final String? device;

  /// 外部受信機の測位の種類（端末の GPS は null）
  final GnssFix? fix;
  final int? satellites;
  final double? hdop;
  final double? pdop;

  /// 水平精度（m）
  final double? hAccuracy;
  final String? hAccuracySource;
  final int averagingCount;
  final double averagingSeconds;

  /// 平均した測位のばらつき（中心からの水平距離の二乗平均平方根、m）。2 回以上のときだけ
  final double? spread;
  final DateTime? time;

  /// 足切りで平均から外した回数
  final int rejected;

  /// 足切りを「警告だけ」にしていて満たさなかった条件（画面の言葉で）
  final List<String> warnings;

  bool get isExternal => source == 'GNSS';

  /// 集めた測位をまとめる。種類・衛星数は最も悪い回、DOP は最も大きい回、精度は平均。
  /// [seconds] を渡さなければ最初と最後の測位の時刻の差
  factory GnssQuality.aggregate(
    List<GnssSample> samples, {
    double? seconds,
    int rejected = 0,
    List<String> warnings = const [],
  }) {
    if (samples.isEmpty) throw ArgumentError('samples is empty');
    final first = samples.first;
    final accuracies = samples.map((s) => s.accuracy).nonNulls.toList();
    final fixes = samples.map((s) => GnssFix.fromGgaQuality(s.gpsQuality)).nonNulls;
    final times = samples.map((s) => s.time).nonNulls.toList()..sort();
    final sources = samples.map((s) => s.accuracySource).nonNulls.toSet();
    return GnssQuality(
      source: first.isExternal ? 'GNSS' : 'GPS',
      device: first.device,
      fix: fixes.isEmpty ? null : fixes.reduce((a, b) => a.index <= b.index ? a : b),
      satellites: _minOrNull(samples.map((s) => s.satellites)),
      hdop: _maxOrNull(samples.map((s) => s.hdop)),
      pdop: _maxOrNull(samples.map((s) => s.pdop)),
      hAccuracy: accuracies.isEmpty ? null : accuracies.reduce((a, b) => a + b) / accuracies.length,
      hAccuracySource: sources.length == 1 ? sources.single : (sources.isEmpty ? null : GnssAccuracySource.hdop),
      averagingCount: samples.length,
      averagingSeconds:
          seconds ?? (times.length >= 2 ? times.last.difference(times.first).inMilliseconds / 1000 : 0),
      spread: samples.length >= 2 ? horizontalSpread(samples) : null,
      time: times.isEmpty ? null : times.last,
      rejected: rejected,
      warnings: warnings,
    );
  }

  /// 測位のばらつき（m）。中心からの水平距離の二乗平均平方根
  static double horizontalSpread(List<GnssSample> samples) {
    final n = samples.length;
    final lat0 = samples.map((s) => s.latitude).reduce((a, b) => a + b) / n;
    final lon0 = samples.map((s) => s.longitude).reduce((a, b) => a + b) / n;
    const mPerDegLat = 110574.0;
    final mPerDegLon = 111320.0 * math.cos(lat0 * math.pi / 180);
    var sum = 0.0;
    for (final s in samples) {
      final dy = (s.latitude - lat0) * mPerDegLat;
      final dx = (s.longitude - lon0) * mPerDegLon;
      sum += dx * dx + dy * dy;
    }
    return math.sqrt(sum / n);
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'device': ?device,
        'fix': ?fix?.code,
        'sats': ?satellites,
        'hdop': ?_round(hdop, 2),
        'pdop': ?_round(pdop, 2),
        'hacc': ?_round(hAccuracy, 3),
        'hacc_src': ?hAccuracySource,
        'avg_n': averagingCount,
        'avg_s': _round(averagingSeconds, 1),
        'spread': ?_round(spread, 3),
        'time': ?time?.toIso8601String(),
        if (rejected > 0) 'rejected': rejected,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };

  static GnssQuality fromJson(Map<dynamic, dynamic> j) => GnssQuality(
        source: j['source'] as String? ?? 'GPS',
        device: j['device'] as String?,
        fix: GnssFix.fromCode(j['fix']),
        satellites: (j['sats'] as num?)?.toInt(),
        hdop: _num(j['hdop']),
        pdop: _num(j['pdop']),
        hAccuracy: _num(j['hacc']),
        hAccuracySource: j['hacc_src'] as String?,
        averagingCount: (j['avg_n'] as num?)?.toInt() ?? 1,
        averagingSeconds: _num(j['avg_s']) ?? 0,
        spread: _num(j['spread']),
        time: DateTime.tryParse('${j['time'] ?? ''}'),
        rejected: (j['rejected'] as num?)?.toInt() ?? 0,
        warnings: [for (final w in (j['warnings'] as List?) ?? const []) '$w'],
      );

  /// 測量の記録の 1 点（`drawing_points` の 1 件）から。
  /// `quality` が無い以前の記録は、残っている測位（`usedGpsData`）から組み立てる。ペンの点は null
  static GnssQuality? ofSurveyRecord(Map<dynamic, dynamic> record) {
    final q = record['quality'];
    if (q is Map) return fromJson(q);
    if (record['data_source'] == 'pen_tool') return null;
    final used = record['usedGpsData'];
    final samples = <GnssSample>[
      if (used is List)
        for (final m in used.whereType<Map<dynamic, dynamic>>()) ?GnssSample.fromMap(m)
      else
        ?GnssSample.fromMap(record),
    ];
    if (samples.isEmpty) return null;
    return GnssQuality.aggregate(samples);
  }

  /// 1 行の要約「RTK FIX・12 衛星・±0.02 m・平均 10 回」
  String summary() {
    final g = t.gnssQuality;
    return [
      fix?.label ?? (isExternal ? null : g.device),
      if (satellites != null) g.satellites(count: satellites!),
      if (hAccuracy != null) '±${formatMeters(hAccuracy!)}',
      if (hdop != null && hAccuracy == null) 'HDOP ${hdop!.toStringAsFixed(1)}',
      averagingCount > 1 ? g.averaged(count: averagingCount) : g.single,
      if (rejected > 0) g.rejected(count: rejected),
    ].nonNulls.join(g.sep);
  }

  static double? _round(double? v, int digits) {
    if (v == null) return null;
    final f = math.pow(10, digits);
    return (v * f).round() / f;
  }
}

/// メートルを桁を揃えて（1 m 未満は cm まで、10 m 以上は整数）
String formatMeters(double m) {
  final digits = m < 1 ? 2 : (m < 10 ? 1 : 0);
  return '${m.toStringAsFixed(digits)} m';
}

/// 地物のメタデータ（`kmaps_metadata`）から GNSS の品質の要約を作る。GPS 測量の点が無ければ null。
/// 点はその 1 点の要約、線・面は頂点の精度の最悪と中央値
String? summarizeFeatureQuality(Map<String, dynamic>? metadata, {required bool isPoint}) {
  final points = metadata?['drawing_points'];
  if (points is! List || points.isEmpty) return null;
  final qualities = [
    for (final p in points.whereType<Map<dynamic, dynamic>>()) ?GnssQuality.ofSurveyRecord(p),
  ];
  if (qualities.isEmpty) return null;
  if (isPoint) return qualities.first.summary();

  final g = t.gnssQuality;
  final acc = qualities.map((q) => q.hAccuracy).nonNulls.toList()..sort();
  final fixes = qualities.map((q) => q.fix).nonNulls.toList();
  final worstFix = fixes.isEmpty ? null : fixes.reduce((a, b) => a.index <= b.index ? a : b);
  return [
    g.vertices(count: qualities.length, total: points.length),
    if (acc.isNotEmpty) g.worstAccuracy(value: formatMeters(acc.last)),
    if (acc.isNotEmpty) g.medianAccuracy(value: formatMeters(_median(acc))),
    if (worstFix != null) g.worstFix(fix: worstFix.label),
  ].join(g.sep);
}

double _median(List<double> sorted) {
  final n = sorted.length;
  return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

/// 足切りの条件の種類
enum GnssGateKind { accuracy, fix, satellites }

/// 条件を満たさない測位を弾く条件。どれも null なら何もしない（既定）
@immutable
class GnssQualityGate {
  const GnssQualityGate({
    this.maxAccuracy,
    this.minFix,
    this.minSatellites,
    this.strict = true,
  });

  static const off = GnssQualityGate();

  /// 水平精度の上限（m）
  final double? maxAccuracy;

  /// 測位の種類の下限
  final GnssFix? minFix;

  /// 衛星数の下限
  final int? minSatellites;

  /// true: 満たさない測位は記録しない（平均から外す）。false: 記録して警告だけ出す
  final bool strict;

  bool get isActive => maxAccuracy != null || minFix != null || minSatellites != null;

  /// 満たさない条件（画面の言葉で）。満たしていれば空。
  /// 値が分からない（端末の GPS の衛星数など）ときも満たさないとする（検査に出せる値が無いので）
  List<String> check(GnssSample s) => [for (final f in failures(s)) f.message];

  /// 満たさない条件と、どの条件か
  List<({GnssGateKind kind, String message})> failures(GnssSample s) {
    final r = t.gnssQuality.reason;
    final unknown = t.gnssQuality.unknown;
    return [
      if (maxAccuracy case final max?)
        if (s.accuracy == null || s.accuracy! > max)
          (
            kind: GnssGateKind.accuracy,
            message: r.accuracy(
              value: s.accuracy == null ? unknown : '±${formatMeters(s.accuracy!)}',
              limit: formatMeters(max),
            ),
          ),
      if (minFix case final min?)
        if (s.fix == null || !s.fix!.atLeast(min))
          (kind: GnssGateKind.fix, message: r.fix(value: s.fix?.label ?? unknown, limit: min.label)),
      if (minSatellites case final min?)
        if (s.satellites == null || s.satellites! < min)
          (
            kind: GnssGateKind.satellites,
            message: r.satellites(value: s.satellites?.toString() ?? unknown, limit: '$min'),
          ),
    ];
  }

  GnssQualityGate copyWith({
    double? Function()? maxAccuracy,
    GnssFix? Function()? minFix,
    int? Function()? minSatellites,
    bool? strict,
  }) =>
      GnssQualityGate(
        maxAccuracy: maxAccuracy != null ? maxAccuracy() : this.maxAccuracy,
        minFix: minFix != null ? minFix() : this.minFix,
        minSatellites: minSatellites != null ? minSatellites() : this.minSatellites,
        strict: strict ?? this.strict,
      );

  Map<String, dynamic> toJson() => {
        'maxAccuracy': ?maxAccuracy,
        'minFix': ?minFix?.code,
        'minSatellites': ?minSatellites,
        'strict': strict,
      };

  static GnssQualityGate fromJson(Map<dynamic, dynamic> j) => GnssQualityGate(
        maxAccuracy: _num(j['maxAccuracy']),
        minFix: GnssFix.fromCode(j['minFix']),
        minSatellites: (j['minSatellites'] as num?)?.toInt(),
        strict: j['strict'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      other is GnssQualityGate &&
      other.maxAccuracy == maxAccuracy &&
      other.minFix == minFix &&
      other.minSatellites == minSatellites &&
      other.strict == strict;

  @override
  int get hashCode => Object.hash(maxAccuracy, minFix, minSatellites, strict);
}

/// 集めた測位に足切りをかけた結果
@immutable
class GnssGateResult {
  const GnssGateResult({required this.accepted, required this.rejected, required this.reasons});

  /// 平均に使う測位
  final List<GnssSample> accepted;

  /// 外した回数
  final int rejected;

  /// 満たさなかった条件（重複なし。厳しくしていれば外した理由、警告だけなら警告の中身）
  final List<String> reasons;

  /// 使える測位が 1 回も無い（厳しくしていて全部外れた）
  bool get isRejected => accepted.isEmpty;
}

/// 集めた測位 [samples] に足切り [gate] をかける
GnssGateResult applyGate(GnssQualityGate gate, List<GnssSample> samples) {
  if (!gate.isActive) return GnssGateResult(accepted: samples, rejected: 0, reasons: const []);
  final accepted = <GnssSample>[];
  // 条件ごとに最初に満たさなかった回の言葉（回ごとに値が違うので全部は並べない）
  final reasons = <GnssGateKind, String>{};
  for (final s in samples) {
    final failures = gate.failures(s);
    for (final f in failures) {
      reasons.putIfAbsent(f.kind, () => f.message);
    }
    if (failures.isEmpty || !gate.strict) accepted.add(s);
  }
  return GnssGateResult(
    accepted: accepted,
    rejected: samples.length - accepted.length,
    reasons: reasons.values.toList(),
  );
}
