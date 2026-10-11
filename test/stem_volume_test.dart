import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/services/tree_tally/stem_volume.dart';

/// 材積表の載せ方: 小数第3位で四捨五入して第2位まで。0.01 m³ に満たないものは第3位まで
double roundLikeTable(double v) {
  final r3 = (v * 1000 + 0.5).floorToDouble() / 1000;
  if (r3 < 0.01) return r3;
  return (v * 100 + 0.5).floorToDouble() / 100;
}

/// 樹高 h の行の、胸高直径 [d0, d0+2, ...] の値
typedef _Row = (double h, int d0, List<double> values);

void _checkRows(String species, List<_Row> rows) {
  var n = 0;
  for (final (h, d0, values) in rows) {
    for (var i = 0; i < values.length; i++) {
      final d = d0 + 2.0 * i;
      final v = stemVolumeM3(VolumeRegion.kinkiChugoku, species, d, h)!;
      expect(roundLikeTable(v), values[i], reason: '$species d=$d h=$h raw=$v');
      n++;
    }
  }
  expect(n, greaterThanOrEqualTo(60));
}

void main() {
  // 林野庁計画課編「立木幹材積表 西日本編」(1970) 近畿・中国・石川・福井地方 スギ pp.64-67 の表の値。
  // 島根県が掲載している写し（docs/features/tree-tally.md「材積」）から読んだ
  test('近畿・中国 スギ: 材積表の値と一致する', () {
    _checkRows('スギ', [
      (20, 8, [0.06, 0.08, 0.12, 0.16, 0.20, 0.25, 0.30]),
      (10, 22, [0.18, 0.21, 0.24, 0.28, 0.32, 0.35, 0.40, 0.44, 0.49, 0.53]),
      (20, 22, [0.36, 0.42, 0.48, 0.55, 0.63, 0.71, 0.79, 0.88, 0.97, 1.06]),
      (20, 42, [1.16, 1.26, 1.37, 1.48, 1.60, 1.71, 1.84, 1.96, 2.09, 2.23]),
      (30, 42, [1.73, 1.89, 2.05, 2.21, 2.39, 2.56, 2.75, 2.93, 3.13, 3.33]),
      (20, 62, [2.36, 2.50, 2.65, 2.80, 2.95, 3.11, 3.27, 3.43, 3.59, 3.77]),
      (40, 62, [4.70, 4.98, 5.27, 5.57, 5.87, 6.18, 6.50, 6.82, 7.15, 7.49]),
      // 小径木（小数第3位まで載っている）
      (3, 2, [0.001]),
      (10, 4, [0.008]),
      (11, 4, [0.009]),
      (12, 4, [0.01]),
      (3, 6, [0.005]),
    ]);
  });

  // 同 ヒノキ pp.84-87
  test('近畿・中国 ヒノキ: 材積表の値と一致する', () {
    _checkRows('ヒノキ', [
      (20, 8, [0.06, 0.09, 0.13, 0.17, 0.22, 0.27, 0.33]),
      (10, 22, [0.18, 0.21, 0.25, 0.28, 0.32, 0.36, 0.40, 0.45, 0.50, 0.54]),
      (20, 22, [0.39, 0.46, 0.53, 0.61, 0.69, 0.78, 0.87, 0.97, 1.07, 1.17]),
      (20, 42, [1.28, 1.40, 1.52, 1.64, 1.77, 1.90, 2.03, 2.17, 2.32, 2.47]),
      (30, 42, [2.01, 2.19, 2.37, 2.57, 2.77, 2.97, 3.19, 3.41, 3.63, 3.87]),
      (20, 62, [2.62, 2.78, 2.94, 3.11, 3.28, 3.45, 3.63, 3.81, 3.99, 4.18]),
      (40, 62, [5.64, 5.98, 6.33, 6.69, 7.05, 7.43, 7.81, 8.20, 8.60, 9.01]),
      (3, 2, [0.001]),
      (10, 4, [0.008]),
      (11, 4, [0.009]),
      (3, 6, [0.004]),
      (5, 6, [0.008]),
    ]);
  });

  test('漢字の樹種名も同じ式', () {
    final v = stemVolumeM3(VolumeRegion.kinkiChugoku, 'スギ', 30, 20);
    expect(stemVolumeM3(VolumeRegion.kinkiChugoku, '杉', 30, 20), v);
    expect(stemVolumeM3(VolumeRegion.kinkiChugoku, '檜', 30, 20), stemVolumeM3(VolumeRegion.kinkiChugoku, 'ヒノキ', 30, 20));
    expect(stemVolumeM3(VolumeRegion.kinkiChugoku, '桧', 30, 20), stemVolumeM3(VolumeRegion.kinkiChugoku, 'ヒノキ', 30, 20));
  });

  test('式の無い樹種・樹高の無い木は null', () {
    expect(stemVolumeM3(VolumeRegion.kinkiChugoku, 'アカマツ', 30, 20), isNull);
    expect(hasStemVolumeEquation(VolumeRegion.kinkiChugoku, 'アカマツ'), isFalse);
    expect(hasStemVolumeEquation(VolumeRegion.kinkiChugoku, ' スギ '), isTrue);
    expect(stemVolumeM3(VolumeRegion.kinkiChugoku, 'スギ', 30, null), isNull);
    expect(stemVolumeM3(VolumeRegion.kinkiChugoku, 'スギ', 0, 20), isNull);
  });
}
