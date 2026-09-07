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
import 'package:desktop_drop/desktop_drop.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/nodes/layer_tree_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/feature_node.dart';
import '../../../models/nodes/geopackage_node.dart';
import '../../../models/app_notification.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../services/import_export/import_export_service.dart';
import '../common_dialogs.dart';
import 'drag_feedback_card.dart';
import 'layer_tile.dart';
import 'node_visibility_icon.dart';

/// GeoPackage ノード用タイル（展開/折りたたみ・ドラッグ&ドロップ対応）
class GeoPackageTile extends ConsumerWidget {
  final GeoPackageNode node;
  final bool isDropTarget;
  final VoidCallback? onRename;
  final void Function(GeoPackageNode?) onDragTargetChanged;
  final ValueChanged<LayerTreeNode?> onDragActiveChanged;
  final LayerTreeNode? currentDir;

  const GeoPackageTile({
    super.key,
    required this.node,
    required this.isDropTarget,
    required this.onDragTargetChanged,
    required this.onDragActiveChanged,
    this.onRename,
    this.currentDir,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(featureRefreshTriggerProvider);
    final expansionState = ref.watch(expandedGeoPackagesProvider);
    final absPath = node.geoPackageFile.getAbsolutePath();
    final isExpanded = expansionState.isExpanded(absPath);

    final headerTile = ListTile(
      leading: NodeVisibilityIcon(node: node),
      title: Row(
        children: [
          Expanded(child: Text(node.name)),
          if (isDropTarget)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(12)),
              child: Text(
                t.layerDrawer.geopackage.dropLayerHere,
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      onTap: () {
        if (absPath != null) ref.read(expandedGeoPackagesProvider.notifier).toggle(absPath);
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'rename') {
                onRename?.call();
              } else if (value == 'delete') {
                await _handleDelete(context, ref);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'rename', child: Text(t.layerDrawer.geopackage.changeName)),
              PopupMenuItem(value: 'delete', child: Text(t.layerDrawer.geopackage.deleteGpkg)),
            ],
          ),
        ],
      ),
    );

    final content = Column(
      children: [
        LongPressDraggable<GeoPackageNode>(
          data: node,
          dragAnchorStrategy: (_, _, _) => const Offset(0, 0),
          feedback: DragFeedbackCard(node: node),
          childWhenDragging: Opacity(opacity: 0.4, child: headerTile),
          onDragStarted: () => onDragActiveChanged(node),
          onDraggableCanceled: (_, _) => onDragActiveChanged(null),
          onDragEnd: (_) => onDragActiveChanged(null),
          child: headerTile,
        ),
        if (isExpanded) ...[
          ...node.children.map(
            (layerNode) => LayerTile(
              node: layerNode as LayerNode,
              currentDir: currentDir,
              onDragActiveChanged: (dragNode) {
                onDragActiveChanged(dragNode);
                if (dragNode == null) onDragTargetChanged(null);
              },
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 32, top: 4, bottom: 4),
              child: AddLayerButton(node: node),
            ),
          ),
        ],
      ],
    );

    // レイヤ D&D ターゲット
    final layerDragTarget = DragTarget<LayerNode>(
      onAcceptWithDetails: (details) async {
        await _handleLayerDrop(context, ref, details.data, node);
        onDragActiveChanged(null);
        onDragTargetChanged(null);
      },
      onWillAcceptWithDetails: (details) => details.data.geoPackageNode != node,
      onMove: (details) {
        onDragActiveChanged(details.data);
        onDragTargetChanged(node);
      },
      onLeave: (_) => onDragTargetChanged(null),
      builder: (context, _, _) {
        return Container(
          decoration: isDropTarget
              ? BoxDecoration(
                  border: Border.all(color: Colors.blue, width: 2),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.blue.withValues(alpha: 0.1),
                )
              : null,
          child: content,
        );
      },
    );

    // ファイル D&D ターゲット（外側・デスクトップからのドロップ用）
    return DropTarget(
      onDragEntered: (_) => onDragTargetChanged(node),
      onDragExited: (_) => onDragTargetChanged(null),
      onDragDone: (details) async {
        for (final file in details.files) {
          await _handleFileDrop(file.path, ref);
        }
        onDragTargetChanged(null);
      },
      child: layerDragTarget,
    );
  }

  Future<void> _handleFileDrop(String filePath, WidgetRef ref) async {
    try {
      final result = await ImportExportService().importFile(filePath, node);
      if (result.success) {
        await node.updateChildren();
        if (result.createdLayers != null) {
          for (final layer in result.createdLayers!) {
            await layer.updateChildren();
          }
        }

        final absPath = node.geoPackageFile.getAbsolutePath();
        if (absPath != null) ref.read(expandedGeoPackagesProvider.notifier).addExpanded(absPath);

        ref.read(featureRefreshTriggerProvider.notifier).trigger();
        Future.delayed(const Duration(milliseconds: 500), () {
          ref.read(featureRefreshTriggerProvider.notifier).trigger();
        });
      }
    } catch (_) {}
  }

  Future<void> _handleLayerDrop(
    BuildContext context,
    WidgetRef ref,
    LayerNode sourceLayer,
    GeoPackageNode targetGpkg,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.layerDrawer.geopackage.migrateTitle),
        content: Text(
          t.layerDrawer.geopackage.migrateConfirm(source: sourceLayer.name, target: targetGpkg.name),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(t.common.confirm)),
        ],
      ),
    );
    if (confirm != true) return;

    final migrated = await sourceLayer.migrateToGeoPackage(targetGpkg, moveLayer: true);
    if (migrated != null) {
      ref.read(featureRefreshTriggerProvider.notifier).trigger();
      ref.read(selectedLayerNodeProvider.notifier).select(migrated);
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.geopackage.migrateSuccess(source: sourceLayer.name, target: targetGpkg.name),
            level: NotificationLevel.success,
          );
    } else {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.geopackage.migrateFailed,
            level: NotificationLevel.error,
          );
    }
  }

  Future<void> _handleDelete(BuildContext context, WidgetRef ref) async {
    await confirmAndExecute(
      context,
      ref: ref,
      title: t.layerDrawer.geopackage.deleteTitle,
      content: Text(t.layerDrawer.geopackage.deleteConfirm(name: node.name)),
      confirmLabel: t.layerDrawer.geopackage.deleteGpkg,
      successMessage: t.layerDrawer.geopackage.deleted(name: node.name),
      execute: () async {
        for (final layer in node.children.whereType<LayerNode>()) {
          if (ref.read(selectedLayerNodeProvider) == layer) {
            ref.read(selectedLayerNodeProvider.notifier).select(null);
          }
          ref.read(selectedFeaturesProvider.notifier).set(
            ref.read(selectedFeaturesProvider).where((f) {
              if (f is FeatureNode) return f.parent != layer;
              return true;
            }).toList(),
          );
        }
        await node.dispose();
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      },
    );
  }
}
