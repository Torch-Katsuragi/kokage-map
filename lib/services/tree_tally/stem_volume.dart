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
/// 立木の幹材積（林野庁「立木幹材積表 西日本編」1970 の材積式）
///
/// 係数の出典: 細田和男・光田靖・家原敏郎 (2010)
/// 「現行立木幹材積表と材積式による計算値との相違およびその修正方法」森林計画学会誌 44(2): 23-39,
/// 表-2「材積式の係数」No.55 大阪スギ・No.57 大阪ヒノキ。式の形は山本式 log v = a + b·log d + c·log h（常用対数）。
/// 両式とも単一式（胸高直径で式が分かれない）で、同論文 表-1 で「修正不要」（接合部の移動平均なし）。
///
/// 照合: 西日本編「近畿・中国・石川・福井地方」スギ（pp.64-67）・ヒノキ（pp.84-87）の表の値と、
/// 小数第3位で四捨五入して一致することをテストで確かめた（test/stem_volume_test.dart）。
/// 確かめていない地域・樹種は入れない。docs/features/tree-tally.md「材積」
library;

import 'dart:math' as math;

/// 材積式の地域。いまは確かめた1地域だけ
enum VolumeRegion {
  /// 近畿・中国・石川・福井地方（旧 大阪営林局管内。三重・滋賀・京都・大阪・兵庫・奈良・和歌山・
  /// 鳥取・島根・岡山・広島・山口・石川・福井）
  kinkiChugoku,
}

/// 地域 × 樹種の材積式 log10 v = a + b·log10 d + c·log10 h（d: 胸高直径 cm、h: 樹高 m、v: m³）
class _Yamamoto {
  final double a, b, c;
  const _Yamamoto(this.a, this.b, this.c);
  double volume(double d, double h) =>
      math.pow(10, a + b * math.log(d) / math.ln10 + c * math.log(h) / math.ln10).toDouble();
}

const _equations = <VolumeRegion, Map<String, _Yamamoto>>{
  VolumeRegion.kinkiChugoku: {
    // 細田ら (2010) 表-2 No.55 大阪スギ（山陽の人工林・天然林、山陰の人工林。山陰の天然スギは別の式で、入れていない）
    'スギ': _Yamamoto(-4.19207, 1.82696, 0.99227),
    // 同 No.57 大阪ヒノキ
    'ヒノキ': _Yamamoto(-4.31101, 1.83546, 1.10655),
  },
};

/// 樹種名のゆれ（漢字の表記）を材積式の名前にそろえる
const _aliases = {'杉': 'スギ', '檜': 'ヒノキ', '桧': 'ヒノキ'};

String _canonical(String species) {
  final s = species.trim();
  return _aliases[s] ?? s;
}

/// [region] に [species] の材積式があるか
bool hasStemVolumeEquation(VolumeRegion region, String species) =>
    _equations[region]?.containsKey(_canonical(species)) ?? false;

/// 1本の幹材積 [m³]。式が無い樹種、直径・樹高が無い（0 以下）ときは null。
/// 表のように丸めはしない（集計で足してから表示の桁にする）
double? stemVolumeM3(VolumeRegion region, String species, double? dbhCm, double? heightM) {
  final eq = _equations[region]?[_canonical(species)];
  if (eq == null || dbhCm == null || heightM == null || dbhCm <= 0 || heightM <= 0) return null;
  return eq.volume(dbhCm, heightM);
}
