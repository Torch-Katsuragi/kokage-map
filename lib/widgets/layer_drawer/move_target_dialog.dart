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
/// 行の左スワイプ「移動」の行き先を選ぶ（2026-10-06〜。長押しドラッグの代わり）
///
/// フォルダ・gpkg・写真はフォルダへ、レイヤは別の gpkg へ（移植）。プロジェクトのツリーを平らに並べ、字下げで階層を見せる。
/// 「この端末」（sys）とその下（グローバルフォルダ）には移さない（実体の場所はアプリが決めている）。
library;

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/sys_node.dart';
import '../../presentation/node_presenter.dart';
import 'drawer_row.dart';

class MoveTargetDialog {
  /// [source] の行き先を選ぶ。フォルダか（[source] がレイヤなら）gpkg を返す。やめたら null
  static Future<LayerTreeNode?> show(BuildContext context, {required LayerTreeNode source, required LayerTreeNode root}) {
    final layer = source is LayerNode;
    final targets = <(LayerTreeNode, int)>[];
    void walk(LayerTreeNode n, int depth) {
      if (n is SysNode) return;
      if (identical(n, source)) return; // 自分と、その下には移せない
      if (n is FolderNode) {
        targets.add((n, depth));
        for (final c in n.children) {
          walk(c, depth + 1);
        }
      } else if (layer && n is GeoPackageNode) {
        targets.add((n, depth));
      }
    }

    walk(root, 0);
    final here = source is LayerNode ? source.geoPackageNode : source.parent;
    return showDialog<LayerTreeNode>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(layer ? t.layerDrawer.moveLayerTitle(name: source.name) : t.layerDrawer.moveTitle(name: NodePresenter.getDisplayName(source))),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: 360,
          height: 420,
          child: targets.isEmpty
              ? Center(child: Text(t.layerDrawer.noMoveTargets))
              : ListView(
                  children: [
                    for (final (n, depth) in targets)
                      Builder(builder: (context) {
                        final isHere = identical(n, here);
                        // レイヤの移植先にならないフォルダは見出しとして出すだけ
                        final pickable = !isHere && (!layer || n is GeoPackageNode);
                        return DrawerRow(
                          depth: depth,
                          height: 44,
                          dimmed: !pickable,
                          leading: Icon(
                            NodePresenter.getIcon(n),
                            size: 20,
                            color: pickable ? NodePresenter.getColor(n) : Colors.black26,
                          ),
                          title: NodePresenter.getDisplayName(n),
                          trailingInfo: isHere ? t.layerDrawer.moveHere : null,
                          onTap: pickable ? () => Navigator.pop(context, n) : null,
                        );
                      }),
                  ],
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel))],
      ),
    );
  }
}
