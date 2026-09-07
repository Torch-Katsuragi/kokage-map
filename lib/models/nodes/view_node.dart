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
/// View: 親レイヤに対する「フィルタ＋スタイル」の集合体。
///
/// > [!IMPORTANT] View は QGIS のレイヤと 1:1 で対応する唯一の概念
/// > dir / GeoPackage / Layer はすべて QGIS のレイヤ**グループ**になる。
/// > この 1:1 が成り立つおかげで `.qgs` を書いても破綻しない。
/// > 設計の全体像は [[docs/technical/project-format-design]]。
library;

import '../../core/node_types.dart';
import '../../services/kmeta_service.dart';
import '../kmeta.dart';
import 'layer_node.dart';
import 'layer_tree_node.dart';

/// 既定Viewの名前。
///
/// View定義を持たないレイヤは、この名前の View を1枚だけ暗黙に持つ。
/// 「View を導入しても既存プロジェクトの見え方は変わらない」を成立させるための逃げ道。
const String kDefaultViewName = '既定';

/// View ノード。
///
/// > [!WARNING] ViewNode は親 Layer の `children` に**入らない**
/// > `LayerNode.children` はコードベース全体で「FeatureNode の集まり」として
/// > 扱われている（`children.cast<FeatureNode>()` を書いている箇所すらある）。
/// > そこに別種を混ぜると踏み抜く。View は [LayerNode.views] に持たせ、
/// > `parent` だけ Layer を指す形にしてある。
/// >
/// > 「View は見せ方であってデータではない」という設計とも、この置き方は合う。
/// > 可視性の再帰（[LayerTreeNode.isVisibleRecursive]）は `parent` を辿るので
/// > `children` に居なくても正しく効く。
class ViewNode extends LayerTreeNode {
  ViewNode({
    required String name,
    required LayerNode parent,
    this.filter,
    this.style,
    bool visible = true,
  }) : super(name, visible: visible, parent: parent, nodeType: NodeType.view);

  /// フィルタ。SQL の WHERE 句（QGIS の subset string と同じ書き方）。
  /// null / 空文字なら絞り込み無し。
  String? filter;

  /// この View の見た目。null なら親レイヤ／既定のスタイルに従う。
  KMetaLayerStyle? style;

  /// 親レイヤ。`ViewNode` は必ず Layer の下にいる。
  LayerNode get layerNode {
    final p = parent;
    if (p is LayerNode) return p;
    throw StateError('ViewNode must have a LayerNode parent: $name');
  }

  /// この View の一意キー（`gpkgName/layerName/viewName` 形式）
  String get viewKey => '${layerNode.layerKey}/$name';

  /// フィルタが実質的に設定されているか
  bool get hasFilter => filter != null && filter!.trim().isNotEmpty;

  /// 既定Viewか（＝ユーザーが View を作っていないレイヤの、暗黙の1枚）
  bool get isDefaultView => name == kDefaultViewName && !hasFilter;

  /// 永続化する形に落とす
  KMetaView toKMetaView() =>
      KMetaView(name: name, filter: filter, style: style);

  @override
  Future<void> persistVisibility() async {
    final folder = layerNode.folderNode;
    if (folder == null) return;
    final folderPath = folder.getAbsoluteFilePath();
    if (folderPath == null) return;
    await KMetaService.instance.setViewVisibility(
      folderPath,
      viewKey,
      visible,
    );
    folder.invalidateMetaCache();
  }

  /// View は子を持たない
  @override
  Future<void> updateChildren() async {}

  @override
  String toString() => 'ViewNode($name, filter=$filter, visible=$visible)';
}
