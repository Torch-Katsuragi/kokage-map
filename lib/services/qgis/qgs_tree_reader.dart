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
/// `.qgs` のレイヤツリー構造・表示消灯（`checked`）・並び順（`sortOrder`）の読み取り。
library;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:xml/xml.dart';

import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_order.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../kmeta_service.dart';
import 'qgs_project_builder.dart' show QgsProjectBuilder;
import 'qgs_xml.dart';

/// レイヤツリー上の各ノードの先頭出現位置（上から順 = 描く順）を記録する。
class QgsTreePlacement {
  QgsTreePlacement._(this._treePos);

  factory QgsTreePlacement.fromDocument(XmlDocument doc) {
    final treeIds = qgsTreeLayerIds(doc);
    return QgsTreePlacement._({
      for (var i = 0; i < treeIds.length; i++) treeIds[i]: i,
    });
  }

  final Map<String, int> _treePos;
  final Map<LayerTreeNode, int> placed = <LayerTreeNode, int>{};

  void place(LayerTreeNode node, String? id) {
    final pos = id == null ? null : _treePos[id];
    if (pos == null) return;
    final prev = placed[node];
    if (prev == null || pos < prev) placed[node] = pos;
  }
}

/// レイヤツリーの表示状態（checked）。レイヤの id で引く
class QgsTreeVisibility {
  /// 祖先の checked を AND で畳んだもの。QGIS は親グループが Unchecked なら子も描かないので、
  /// QGIS ユーザーがグループごと消灯した場合も読み戻せるように
  final checked = <String, bool>{};

  /// レイヤ自身の checked（こかげマップが書いた形なら、グループの checked は別に読むので畳まない）
  final ownChecked = <String, bool>{};

  /// 近い順の祖先グループ（名前と自身の checked）
  final ancestors = <String, List<(String, bool)>>{};

  static QgsTreeVisibility read(XmlDocument doc) {
    final result = QgsTreeVisibility();
    final treeRoot = doc.rootElement.findElements('layer-tree-group').firstOrNull;
    if (treeRoot != null) result._walk(treeRoot, true, const []);
    return result;
  }

  void _walk(XmlElement node, bool parentChecked, List<(String, bool)> chain) {
    for (final child in node.childElements) {
      final own = child.getAttribute('checked') != 'Qt::Unchecked';
      final folded = parentChecked && own;
      if (child.name.local == 'layer-tree-group') {
        _walk(child, folded, [(child.getAttribute('name') ?? '', own), ...chain]);
      } else if (child.name.local == 'layer-tree-layer') {
        final id = child.getAttribute('id');
        if (id != null) {
          checked[id] = folded;
          ownChecked[id] = own;
          ancestors[id] = chain;
        }
      }
    }
  }

  /// こかげマップが書いた形（dir グループ > gpkg グループ > レイヤグループ > View）なら、
  /// グループの checked をレイヤ・gpkg・dir の可視性として [layerGroup] と [containers] に入れて true
  bool readGroups(
    String id,
    LayerNode layer,
    GeoPackageNode gpkg,
    FolderNode root,
    Map<LayerNode, bool> layerGroup,
    Map<LayerTreeNode, bool> containers,
  ) {
    final chain = ancestors[id];
    // 親がレイヤグループ、その親が gpkg グループ
    if (chain == null || chain.length < 2 || chain[0].$1 != layer.layerName || chain[1].$1 != gpkg.name) {
      return false;
    }
    layerGroup[layer] = chain[0].$2;
    containers[gpkg] = chain[1].$2;
    // その上は dir グループ（プロジェクト root 自身はグループにならない）
    LayerTreeNode? folder = gpkg.parent;
    for (var i = 2; i < chain.length && folder is FolderNode && !identical(folder, root); i++) {
      if (chain[i].$1 != folder.name) break;
      containers[folder] = chain[i].$2;
      folder = folder.parent;
    }
    return true;
  }
}

/// gpkg と dir のグループの可視性を反映する（変わったものだけ書く）。
Future<void> applyQgsContainerVisibility(
  Map<LayerTreeNode, bool> containerChecked,
  bool Function(FolderNode? owner) accepts,
) async {
  for (final MapEntry(key: node, value: checked) in containerChecked.entries) {
    if (node.visible == checked) continue;
    final owner = node.parent;
    if (!accepts(owner is FolderNode ? owner : null)) continue;
    node.visible = checked;
    await node.persistVisibility();
  }
}

/// オーバーレイ画像（GeoTIFF）の可視性を反映し、対象となった枚数を返す。
/// ファイルは dir にあるものが正で、`.qgs` からは表示だけ取る。
Future<int> applyQgsOverlayVisibility(
  List<({OverlayImageNode node, String id})> overlays,
  QgsTreeVisibility tree,
  String qgsDir,
  bool Function(FolderNode? owner) accepts,
) async {
  var overlayCount = 0;
  for (final (:node, :id) in overlays) {
    final owner = node.parent;
    if (owner is! FolderNode || !accepts(owner)) continue;
    // こかげマップが書いた形（決定的な id）なら dir グループの消灯は dir の可視性なので、自身の checked。
    // QGIS で足したものは祖先で畳む（グループごと消灯した場合も読み戻す）
    final qgsRel = qgsRelativePath(qgsDir, node.getAbsoluteFilePath());
    final ownForm = qgsRel != null && id == QgsProjectBuilder.rasterLayerIdForPath(qgsRel);
    final visible = (ownForm ? tree.ownChecked[id] : tree.checked[id]) ?? true;
    overlayCount++;
    if (node.visible == visible) continue;
    node.visible = visible;
    await node.persistVisibility();
  }
  return overlayCount;
}

/// レイヤツリーの並びを、こかげマップのフォルダの子とレイヤの並び（フォルダ設定の `layout.sortOrder`）に写す。
///
/// [placed] はツリーで位置の分かった葉（レイヤ・オーバーレイ）とその位置（上から）。
/// 祖先（gpkg・dir）の位置は子孫のいちばん上の位置。QGIS でレイヤをグループの外へ動かしていても、
/// こかげマップの構造（dir > gpkg > レイヤ）の中で近い並びになる。
/// 並びの持ち主はその dir（[accepts] で持ち主のほうが新しければ飛ばす）。今の並びと変わらず、
/// 並びの設定も持っていなければ書かない（開くたびに子 dir の `.qgs` を増やさない）
Future<void> applyQgsTreeOrder(
  FolderNode root,
  Map<LayerTreeNode, int> placed,
  bool Function(FolderNode? owner) accepts,
) async {
  if (placed.isEmpty) return;
  final pos = <LayerTreeNode, int>{};
  for (final MapEntry(key: leaf, value: at) in placed.entries) {
    for (LayerTreeNode? n = leaf; n != null; n = n.parent) {
      final prev = pos[n];
      if (prev == null || at < prev) pos[n] = at;
      if (identical(n, root)) break;
    }
  }
  if (!pos.containsKey(root)) return;

  Iterable<FolderNode> folders(FolderNode f) sync* {
    yield f;
    for (final c in f.children.whereType<FolderNode>()) {
      if (pos.containsKey(c)) yield* folders(c);
    }
  }

  for (final folder in folders(root).toList()) {
    if (!accepts(folder)) continue;
    final folderPath = folder.getAbsoluteFilePath();
    if (folderPath == null) continue;
    final gpkgs = folder.children.whereType<GeoPackageNode>().toList();
    final order = [
      for (final c in sortByPosition(folder.children, (c) => pos[c])) c.name,
      for (final g in gpkgs)
        for (final l in sortByPosition(g.children.whereType<LayerNode>(), (l) => pos[l])) l.layerKey,
    ];
    // 写しで受ける（並びが変わらなければ applyLayerOrder は渡したリストそのものを返す）
    final children = List.of(applyLayerOrder(folder.children, order, layerOrderKey));
    final layers = {for (final g in gpkgs) g: List.of(applyLayerOrder(g.children, order, layerOrderKey))};
    final moved =
        !listEquals(children, folder.children) || layers.entries.any((e) => !listEquals(e.value, e.key.children));
    final stored = (await folder.getMeta()).layout.sortOrder;
    if (!moved && stored == null) continue;
    // 並べ替えるだけ（顔ぶれは変わらない）。`.qgs` の書き直しは設定の保存が合図になる
    folder.children
      ..clear()
      ..addAll(children);
    for (final MapEntry(key: g, value: list) in layers.entries) {
      g.children
        ..clear()
        ..addAll(list);
    }
    await KMetaService.instance.setSortOrder(folderPath, order);
    folder.invalidateMetaCache();
  }
}
