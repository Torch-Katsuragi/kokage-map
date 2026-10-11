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
/// 毎木調査の集計（標準地ごと）
///
/// - 胸高断面積 g = π/4 × (DBH[m])²
/// - ha あたり = 標準地の値 ÷ 標準地の水平面積[ha]
/// - 上層高 = 胸高直径の大きい順に ha あたり 100 本ぶん（標準地では 面積[ha]×100 本、最低1本）の平均樹高。
///   樹高のない木は平均から外す
/// - 材積 = 1本ずつの幹材積（[volume] で渡す。stem_volume.dart）の合計。式の無い木・樹高の無い木は足さず、
///   その本数は count − volumeCount で分かる
library;

import 'dart:math' as math;

import '../table/csv_table.dart' show csvField;

/// 集計に使う1本ぶん
class TallyTree {
  final String species;
  final double? dbhCm;
  final double? heightM;
  const TallyTree({required this.species, this.dbhCm, this.heightM});
}

/// 胸高断面積 [m²]
double basalAreaM2(double dbhCm) {
  final d = dbhCm / 100.0;
  return math.pi / 4 * d * d;
}

/// 円形標準地の面積 [m²]
double circlePlotAreaM2(double radiusM) => math.pi * radiusM * radiusM;

/// 面積 [ha] の円形標準地の半径 [m]（0.05 ha → 12.62 m）
double circlePlotRadiusM(double areaHa) => math.sqrt(areaHa * 10000 / math.pi);

class PlotSummary {
  /// 標準地の水平面積 [m²]
  final double areaM2;
  final int count;
  final int dbhCount;
  final int heightCount;
  /// 胸高断面積の合計 [m²]（標準地の中）
  final double basalAreaSumM2;
  final double? meanDbhCm;
  final double? meanHeightM;
  final double? topHeightM;

  /// 幹材積の合計 [m³]（標準地の中）。材積を出さないときは null
  final double? volumeSumM3;

  /// 材積を出せた本数
  final int volumeCount;

  const PlotSummary({
    required this.areaM2,
    required this.count,
    required this.dbhCount,
    required this.heightCount,
    required this.basalAreaSumM2,
    this.meanDbhCm,
    this.meanHeightM,
    this.topHeightM,
    this.volumeSumM3,
    this.volumeCount = 0,
  });

  double get areaHa => areaM2 / 10000;

  /// ha あたり本数
  double? get stemsPerHa => areaM2 > 0 ? count / areaHa : null;

  /// ha あたり胸高断面積合計 [m²/ha]
  double? get basalAreaPerHa => areaM2 > 0 ? basalAreaSumM2 / areaHa : null;

  /// ha あたり幹材積 [m³/ha]
  double? get volumePerHa => areaM2 > 0 && volumeSumM3 != null ? volumeSumM3! / areaHa : null;

  /// [volume] は1本の幹材積 [m³]（出せない木は null）。省くと材積は出さない
  static PlotSummary of(Iterable<TallyTree> trees, double areaM2, {double? Function(TallyTree)? volume}) {
    final list = trees.toList();
    final volumes = volume == null ? null : [for (final t in list) ?volume(t)];
    final dbhs = [for (final t in list) if (t.dbhCm != null && t.dbhCm! > 0) t.dbhCm!];
    final heights = [for (final t in list) if (t.heightM != null && t.heightM! > 0) t.heightM!];
    return PlotSummary(
      areaM2: areaM2,
      count: list.length,
      dbhCount: dbhs.length,
      heightCount: heights.length,
      basalAreaSumM2: dbhs.fold(0.0, (s, d) => s + basalAreaM2(d)),
      meanDbhCm: _mean(dbhs),
      meanHeightM: _mean(heights),
      topHeightM: _topHeight(list, areaM2),
      volumeSumM3: volumes?.fold<double>(0.0, (s, v) => s + v),
      volumeCount: volumes?.length ?? 0,
    );
  }

  static double? _topHeight(List<TallyTree> trees, double areaM2) {
    if (areaM2 <= 0) return null;
    final n = math.max(1, (areaM2 / 10000 * 100).round());
    final byDbh = [for (final t in trees) if (t.dbhCm != null && t.dbhCm! > 0) t]
      ..sort((a, b) => b.dbhCm!.compareTo(a.dbhCm!));
    final hs = [for (final t in byDbh.take(n)) if (t.heightM != null && t.heightM! > 0) t.heightM!];
    return _mean(hs);
  }

  static double? _mean(List<double> v) => v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
}

/// 標準地全体と樹種別の集計。樹種は本数の多い順
class PlotTally {
  final String plotId;
  final PlotSummary all;
  final Map<String, PlotSummary> bySpecies;
  const PlotTally(this.plotId, this.all, this.bySpecies);

  static PlotTally of(String plotId, Iterable<TallyTree> trees, double areaM2, {double? Function(TallyTree)? volume}) {
    final list = trees.toList();
    final groups = <String, List<TallyTree>>{};
    for (final t in list) {
      groups.putIfAbsent(t.species, () => []).add(t);
    }
    final keys = groups.keys.toList()..sort((a, b) => groups[b]!.length.compareTo(groups[a]!.length));
    return PlotTally(plotId, PlotSummary.of(list, areaM2, volume: volume), {
      for (final k in keys) k: PlotSummary.of(groups[k]!, areaM2, volume: volume),
    });
  }
}

/// 集計の CSV（UTF-8 BOM 付き、Excel でそのまま開ける）。樹種が [allLabel] の行が標準地全体
String plotTallyCsv(Iterable<PlotTally> plots, {required String allLabel}) {
  String f(double? v, int digits) => v == null ? '' : v.toStringAsFixed(digits);
  final b = StringBuffer('﻿')
    ..writeln('plot_id,species,area_m2,count,stems_per_ha,basal_area_m2,basal_area_m2_per_ha,'
        'mean_dbh_cm,mean_height_m,top_height_m,dbh_n,height_n,volume_m3,volume_m3_per_ha,volume_n');
  void row(String plot, String sp, PlotSummary s) => b.writeln([
        csvField(plot), csvField(sp), f(s.areaM2, 1), s.count, f(s.stemsPerHa, 0), f(s.basalAreaSumM2, 4),
        f(s.basalAreaPerHa, 2), f(s.meanDbhCm, 1), f(s.meanHeightM, 1), f(s.topHeightM, 1),
        s.dbhCount, s.heightCount,
        f(s.volumeSumM3, 3), f(s.volumePerHa, 1), s.volumeSumM3 == null ? '' : s.volumeCount,
      ].join(','));
  for (final p in plots) {
    row(p.plotId, allLabel, p.all);
    p.bySpecies.forEach((sp, s) => row(p.plotId, sp, s));
  }
  return b.toString();
}
