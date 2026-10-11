import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/services/tree_tally/stem_volume.dart';
import 'package:root_maps/services/tree_tally/tree_tally_stats.dart';
import 'package:root_maps/utils/geodesic.dart';

void main() {
  test('胸高断面積: DBH 20 cm → π/4×0.2² = 0.031416 m²', () {
    expect(basalAreaM2(20), closeTo(0.0314159, 1e-6));
    expect(basalAreaM2(100), closeTo(math.pi / 4, 1e-12));
  });

  test('0.05 ha の円形標準地は半径 12.62 m', () {
    expect(circlePlotRadiusM(0.05), closeTo(12.6157, 1e-4));
    expect(circlePlotAreaM2(circlePlotRadiusM(0.05)), closeTo(500, 1e-9));
  });

  test('円形標準地の ha あたり換算', () {
    final area = circlePlotAreaM2(circlePlotRadiusM(0.05)); // 500 m²
    final s = PlotSummary.of([
      for (var i = 0; i < 10; i++) const TallyTree(species: 'スギ', dbhCm: 20, heightM: 15),
    ], area);
    expect(s.count, 10);
    expect(s.stemsPerHa, closeTo(200, 1e-9));
    expect(s.basalAreaSumM2, closeTo(10 * basalAreaM2(20), 1e-12));
    expect(s.basalAreaPerHa, closeTo(200 * basalAreaM2(20), 1e-9)); // 200 本/ha × g
  });

  test('多角形の標準地（20 m × 20 m ≒ 0.04 ha）の ha あたり換算', () {
    // 北緯 34° で東西 20 m・南北 20 m の正方形
    const lat = 34.0, lng = 136.0;
    const dLat = 20 / 110940.0; // 北緯34°付近の緯度1度 ≒ 110.94 km
    final dLng = 20 / (111320.0 * math.cos(lat * math.pi / 180));
    final ring = [
      const LatLng(lat, lng),
      LatLng(lat, lng + dLng),
      LatLng(lat + dLat, lng + dLng),
      const LatLng(lat + dLat, lng),
    ];
    final area = Geodesic.polygonArea([ring]);
    expect(area, closeTo(400, 2)); // 近似の座標なので ±0.5%
    final s = PlotSummary.of([
      for (var i = 0; i < 8; i++) const TallyTree(species: 'ヒノキ', dbhCm: 16),
    ], area);
    expect(s.stemsPerHa, closeTo(8 / (area / 10000), 1e-9));
    expect(s.stemsPerHa, closeTo(200, 1.5));
  });

  test('平均は値のある木だけ、上層高は DBH 上位 ha あたり100本ぶん', () {
    // 500 m² → 上位 5 本
    const trees = [
      TallyTree(species: 'スギ', dbhCm: 40, heightM: 25),
      TallyTree(species: 'スギ', dbhCm: 38, heightM: 24),
      TallyTree(species: 'スギ', dbhCm: 36), // 樹高なし → 上層高から外す
      TallyTree(species: 'ヒノキ', dbhCm: 30, heightM: 20),
      TallyTree(species: 'ヒノキ', dbhCm: 28, heightM: 19),
      TallyTree(species: 'ヒノキ', dbhCm: 10, heightM: 8), // 上位 5 本の外
      TallyTree(species: 'ヒノキ'), // DBH も樹高もない
    ];
    final s = PlotSummary.of(trees, 500);
    expect(s.count, 7);
    expect(s.dbhCount, 6);
    expect(s.heightCount, 5);
    expect(s.meanDbhCm, closeTo((40 + 38 + 36 + 30 + 28 + 10) / 6, 1e-9));
    expect(s.meanHeightM, closeTo((25 + 24 + 20 + 19 + 8) / 5, 1e-9));
    expect(s.topHeightM, closeTo((25 + 24 + 20 + 19) / 4, 1e-9));
  });

  test('樹種別の集計と CSV', () {
    final t = PlotTally.of('P1', const [
      TallyTree(species: 'ヒノキ', dbhCm: 20),
      TallyTree(species: 'スギ', dbhCm: 30),
      TallyTree(species: 'スギ', dbhCm: 32),
    ], 500);
    expect(t.all.count, 3);
    expect(t.bySpecies.keys.toList(), ['スギ', 'ヒノキ']);
    expect(t.bySpecies['スギ']!.stemsPerHa, closeTo(40, 1e-9));
    final csv = plotTallyCsv([t], allLabel: '全体');
    expect(csv, startsWith('﻿plot_id,species,'));
    final lines = csv.trim().split('\n');
    expect(lines, hasLength(4));
    expect(lines[1], startsWith('P1,全体,500.0,3,60,'));
  });

  test('材積: 出せた木だけ足し、ha あたりと CSV の列に出す', () {
    double? vol(TallyTree t) =>
        stemVolumeM3(VolumeRegion.kinkiChugoku, t.species, t.dbhCm, t.heightM);
    const trees = [
      TallyTree(species: 'スギ', dbhCm: 30, heightM: 20),
      TallyTree(species: 'ヒノキ', dbhCm: 24, heightM: 18),
      TallyTree(species: 'スギ', dbhCm: 28), // 樹高なし → 入らない
      TallyTree(species: 'コナラ', dbhCm: 20, heightM: 15), // 式が無い → 入らない
    ];
    final p = PlotTally.of('P1', trees, 500, volume: vol);
    final v1 = vol(trees[0])!, v2 = vol(trees[1])!;
    expect(p.all.volumeCount, 2);
    expect(p.all.volumeSumM3, closeTo(v1 + v2, 1e-12));
    expect(p.all.volumePerHa, closeTo((v1 + v2) * 20, 1e-9));
    expect(p.bySpecies['スギ']!.volumeCount, 1);
    expect(p.bySpecies['コナラ']!.volumeSumM3, 0);
    expect(p.bySpecies['コナラ']!.volumeCount, 0);

    final csv = plotTallyCsv([p], allLabel: '全体').trim().split('\n');
    expect(csv[0], endsWith(',volume_m3,volume_m3_per_ha,volume_n'));
    expect(csv[1], endsWith(',${(v1 + v2).toStringAsFixed(3)},${((v1 + v2) * 20).toStringAsFixed(1)},2'));

    // 材積を出さないときは空欄
    final none = plotTallyCsv([PlotTally.of('P1', trees, 500)], allLabel: '全体').trim().split('\n');
    expect(none[1], endsWith(',,,'));
    expect(PlotSummary.of(trees, 500).volumePerHa, isNull);
  });

  test('面積 0 なら ha あたりは出さない', () {
    final s = PlotSummary.of(const [TallyTree(species: 'スギ', dbhCm: 20)], 0);
    expect(s.stemsPerHa, isNull);
    expect(s.basalAreaPerHa, isNull);
    expect(s.topHeightM, isNull);
  });
}
