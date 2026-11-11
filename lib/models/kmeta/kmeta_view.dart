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
// こかげマップ: View（スタイルグループ・フィルタ）定義モデル

import 'kmeta_layer_style.dart';

/// View: 親レイヤに対する「フィルタ＋スタイル」の集合体。
///
/// > [!IMPORTANT] View は見せ方であって、データではない
/// > フィーチャは Layer に属する。View は同じ Layer を別の条件・別の見た目で
/// > 何枚も見せるための定義。同じ Layer に対して複数の View を作り、
/// > 同時に表示できる。並べ替えは**同一 Layer 内でのみ**許す
/// > （dir構造の拘束を保つため。z順は常に dir 構造から決まる）。
///
/// QGIS の「レイヤ」と 1:1 で対応する唯一の概念。
/// dir / GeoPackage / Layer はすべて QGIS のレイヤグループになる。
/// 設計の全体像は [[docs/technical/project-format-design]]。
class KMetaView {
  const KMetaView({required this.name, this.filter, this.style});

  /// View名。**同一レイヤ内で一意**であること（キーの一部になる）
  final String name;

  /// フィルタ。SQL の WHERE 句（QGIS の subset string と同じ書き方）。
  /// null / 空文字なら絞り込み無し。
  final String? filter;

  /// この View の見た目。null なら親レイヤ／既定のスタイルに従う。
  final KMetaLayerStyle? style;

  factory KMetaView.fromJson(Map<String, dynamic> json) {
    final styleJson = json['style'] as Map<String, dynamic>?;
    return KMetaView(
      name: json['name'] as String? ?? '',
      filter: json['filter'] as String?,
      style: styleJson == null ? null : KMetaLayerStyle.fromJson(styleJson),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'name': name};
    if (filter != null && filter!.isNotEmpty) json['filter'] = filter;
    if (style != null && !style!.isEmpty) json['style'] = style!.toJson();
    return json;
  }

  @override
  String toString() => 'KMetaView($name, filter=$filter)';
}
