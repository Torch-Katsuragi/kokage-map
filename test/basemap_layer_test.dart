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
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/basemap_layer.dart';

/// 背景地図レイヤ（並び・可視・不透明度・合成モード）の保存形と、旧設定（重み）からの読み替え
void main() {
  test('JSON の往復', () {
    const l = BaseMapLayer(providerId: 'gsi_std', visible: false, opacity: 40, blend: BaseMapBlend.multiply);
    final back = BaseMapLayer.fromJson(json.decode(json.encode(l.toJson())) as Map<String, Object?>);
    expect(back, l);
  });

  test('知らないプロバイダ・知らない合成モードは落とす／通常にする', () {
    expect(BaseMapLayer.fromJson({'provider': 'nope'}), isNull);
    expect(BaseMapLayer.fromJson({'provider': 'gsi_std', 'blend': 'plasma', 'opacity': 250})!.blend, BaseMapBlend.normal);
    expect(BaseMapLayer.fromJson({'provider': 'gsi_std', 'opacity': 250})!.opacity, 100);
  });

  test('旧設定の重み: 1 枚なら 100%、複数なら累積補正の不透明度で同じ絵になる', () {
    expect(BaseMapLayer.fromLegacyWeights({'gsi_std': 100}), [const BaseMapLayer(providerId: 'gsi_std')]);
    // 標準地図 100 + 写真 100: 旧式は α = 100/100, 100/200 → 上の写真を 50% で重ねる
    final two = BaseMapLayer.fromLegacyWeights({'gsi_std': 100, 'gsi_photo': 100});
    expect(two.map((l) => l.providerId), ['gsi_std', 'gsi_photo']);
    expect(two.map((l) => l.opacity), [100, 50]);
    // 0 は無い扱い、版付きの等高線は contours に
    final c = BaseMapLayer.fromLegacyWeights({'gsi_std': 100, 'osm': 0, 'contours_v3': 100});
    expect(c.map((l) => l.providerId), ['gsi_std', 'contours']);
  });
}
