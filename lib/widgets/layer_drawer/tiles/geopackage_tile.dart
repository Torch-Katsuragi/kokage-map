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
/// Root Maps: GeoPackageタイルウィジェット
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../models/nodes/external_layer_node.dart';
import '../../../models/nodes/geopackage_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/layer_tree_node.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../tutorial/tutorial.dart';
import '../../external_layer_actions.dart';
import '../common_dialogs.dart';
import '../drawer_row.dart';
import 'layer_tile.dart';


/// GeoPackage ノード用タイル（展開/折りたたみ）。
/// ファイルのドラッグ＆ドロップは 2026-10-09 にフォルダへ移した（gpkg への取り込みはやめた。layer_drawer.dart）
class GeoPackageTile extends ConsumerWidget {
  final GeoPackageNode node;
  final VoidCallback? onRename;

  /// 左スワイプの「移動」（gpkg はフォルダへ、中のレイヤは別の gpkg へ）
  final ValueChanged<LayerTreeNode>? onSwipeMove;
  final LayerTreeNode? currentDir;
  final int depth;

  const GeoPackageTile({
    super.key,
    required this.node,
    this.onSwipeMove,
    this.onRename,
    this.currentDir,
    this.depth = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final absPath = node.geoPackageFile.getAbsolutePath();
    // 自分の開閉と案内の有無だけ見る（ほかの gpkg を畳んだり案内の段が進んだりしても、中のレイヤの行まで組み直さない）
    final isExpanded = ref.watch(expandedGeoPackagesProvider.select((s) => s.isExpanded(absPath)));
    // チュートリアルの案内先（練習プロジェクトの GeoPackage だけ）
    final guiding = ref.watch(tutorialProvider.select((s) => s != null)) && isPracticeGpkg(absPath);
    final dimmed = !node.isVisibleRecursive();
    final layers = node.children.whereType<LayerNode>().toList();
    // 読み取り専用レイヤ（shp・GeoJSON など）。レイヤの追加・取り込みは出さず、変換・複製を出す
    final self = node;
    final external = self is ExternalLayerNode ? self : null;

    final header = DrawerGroupHeader(
      headerKey: guiding ? TutorialTargets.gpkgTile : null,
      depth: depth,
      title: _stripExt(node.name),
      expanded: isExpanded,
      dimmed: dimmed,
      badge: external != null ? Text(t.externalLayer.badge, style: const TextStyle(fontSize: 12, color: Colors.black45)) : null,
      onToggleExpanded: () {
        if (absPath != null) ref.read(expandedGeoPackagesProvider.notifier).toggle(absPath);
      },
      eye: nodeVisibilityEye(ref, node),
      menu: () => [
        if (external == null) RowMenuItem('add_layer', t.layerDrawer.layer.addLayer, icon: Icons.add),
        if (external != null) ...[
          RowMenuItem('convert', t.externalLayer.convertAction, icon: Icons.transform),
          RowMenuItem('copy', t.externalLayer.copyAction, icon: Icons.copy),
        ],
        RowMenuItem('rename', t.layerDrawer.geopackage.changeName, icon: Icons.edit),
        RowMenuItem('delete', t.layerDrawer.geopackage.deleteGpkg, icon: Icons.delete_outline, danger: true, dividerBefore: true),
      ],
      onMenu: (v) async {
        switch (v) {
          case 'add_layer':
            await showAddLayerDialog(context, ref, node);
          case 'convert' when external != null:
            if (await confirmConvertExternalLayer(context, external) && context.mounted) {
              await convertExternalLayer(
                ref.read(notificationCenterProvider.notifier),
                external,
                context: context,
                onChanged: ref.refreshMap,
              );
            }
          case 'copy' when external != null:
            await copyExternalLayer(ref.read(notificationCenterProvider.notifier), external, context: context, onChanged: ref.refreshMap);
          case 'rename':
            onRename?.call();
          case 'delete':
            await _handleDelete(context, ref);
        }
      },
      onSwipeMove: onSwipeMove == null ? null : () => onSwipeMove!(node),
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        if (isExpanded) ...[
          for (final layerNode in layers)
            LayerTile(
              node: layerNode,
              currentDir: currentDir,
              depth: depth + 1,
              onSwipeMove: onSwipeMove,
            ),
          // 読めなかった読み取り専用レイヤは理由を出す
          if (external?.loadError != null)
            DrawerRow(
              depth: depth + 1,
              height: 40,
              leading: const Icon(Icons.error_outline, size: 18, color: Colors.redAccent),
              title: t.externalLayer.loadFailed(error: external!.loadError!),
              titleStyle: const TextStyle(fontSize: 14, color: Colors.black54),
            ),
          // 空の gpkg にだけ「レイヤ追加」の行を出す（以前は gpkg ごとに出していてうるさかった。ふだんは見出しの長押しから）
          if (layers.isEmpty && external == null)
            DrawerRow(
              depth: depth + 1,
              height: 40,
              leading: const Icon(Icons.add, size: 18, color: Colors.black45),
              title: t.layerDrawer.layer.addLayer,
              titleStyle: const TextStyle(fontSize: 16, color: Colors.black54),
              onTap: () => showAddLayerDialog(context, ref, node),
            ),
        ],
      ],
    );

    return content;
  }

  static String _stripExt(String name) => name.toLowerCase().endsWith('.gpkg') ? name.substring(0, name.length - 5) : name;

  Future<void> _handleDelete(BuildContext context, WidgetRef ref) async {
    // 読み取り専用レイヤは元のファイル一式を消すので、消えるファイルを見せる
    final self = node;
    final message = self is ExternalLayerNode
        ? t.externalLayer.deleteConfirm(name: self.name, files: (await self.sourceFiles()).map(p.basename).join('、'))
        : t.layerDrawer.geopackage.deleteConfirm(name: self.name);
    if (!context.mounted) return;
    await confirmAndExecute(
      context,
      ref: ref,
      title: t.layerDrawer.geopackage.deleteTitle,
      content: Text(message),
      confirmLabel: t.layerDrawer.geopackage.deleteGpkg,
      successMessage: t.layerDrawer.geopackage.deleted(name: node.name),
      execute: () async {
        node.children.whereType<LayerNode>().forEach(ref.deselectLayer);
        await node.dispose();
        ref.refreshMap();
      },
    );
  }
}

/// レイヤを別の gpkg へ移す（行の左スワイプ「移動」から）。確かめてから移植し、移した先を選ぶ
Future<void> migrateLayerTo(
  BuildContext context,
  WidgetRef ref,
  LayerNode sourceLayer,
  GeoPackageNode targetGpkg,
) async {
  final confirm = await showConfirmDialog(
    context,
    title: t.layerDrawer.geopackage.migrateTitle,
    content: Text(t.layerDrawer.geopackage.migrateConfirm(source: sourceLayer.name, target: targetGpkg.name)),
    confirmLabel: t.common.confirm,
  );
  if (!confirm) return;

  final sourceGpkg = sourceLayer.geoPackageNode;
  final migrated = await sourceLayer.migrateToGeoPackage(targetGpkg, moveLayer: true);
  if (migrated != null) {
    ref.refreshMap();
    ref.read(selectedLayerNodeProvider.notifier).select(migrated);
    ref.notify(
      t.layerDrawer.geopackage.migrateSuccess(source: sourceLayer.name, target: targetGpkg.name),
      level: NotificationLevel.success,
    );
    // 移し元が空になってファイルごと消えた（LayerNode.migrateToGeoPackage → GeoPackageNode.deleteIfEmptiedByMove）
    if (sourceGpkg.parent == null) {
      ref.notify(t.layerDrawer.geopackage.removedEmpty(name: sourceGpkg.name));
    }
  } else {
    ref.notify(t.layerDrawer.geopackage.migrateFailed, level: NotificationLevel.error);
  }
}
