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
/// Root Maps: レイヤタイルウィジェット
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../models/geometry_type.dart';
import '../../../models/nodes/feature_node.dart';
import '../../../models/nodes/geopackage_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/layer_tree_node.dart';
import '../../../models/nodes/view_node.dart';
import '../../../presentation/node_presenter.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../screens/layer_style_settings_screen.dart';
import '../../../services/geometry_conversion_service.dart';
import '../../../services/survey/survey_chain_resolver.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/feature_calc_utils.dart';
import '../../../widgets/geometry_conversion_dialogs.dart';
import '../../../widgets/layer_import_export_dialog.dart';
import '../../../widgets/survey_conversion_dialog.dart';
import '../common_dialogs.dart';
import 'drag_feedback_card.dart';
import 'view_tile.dart';

/// レイヤノード用 ListTile（選択・可視切り替え・ドラッグ対応）
class LayerTile extends ConsumerWidget {
  final LayerNode node;

  /// ジオメトリ変換時にターゲットレイヤーを検索するための親ディレクトリ
  final LayerTreeNode? currentDir;

  final ValueChanged<LayerTreeNode?>? onDragActiveChanged;

  const LayerTile({
    super.key,
    required this.node,
    this.currentDir,
    this.onDragActiveChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSelected = ref.watch(selectedLayerNodeProvider) == node;

    final tileContent = GestureDetector(
      onTap: () => ref.read(selectedLayerNodeProvider.notifier).select(node),
      onDoubleTap: () => _zoomToLayer(ref),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 32, right: 16),
        leading: _buildLeadingIcon(ref, isSelected),
        title: Text(
          node.name,
          style: TextStyle(
            color: isSelected ? Colors.blue : (node.isVisibleRecursive() ? null : Colors.grey),
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        trailing: _buildMenu(context, ref),
      ),
    );

    final draggable = LongPressDraggable<LayerNode>(
      data: node,
      dragAnchorStrategy: (_, _, _) => const Offset(0, 0),
      feedback: DragFeedbackCard(node: node),
      childWhenDragging: Container(
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Opacity(opacity: 0.5, child: tileContent),
      ),
      onDragStarted: () => onDragActiveChanged?.call(node),
      onDraggableCanceled: (_, _) => onDragActiveChanged?.call(null),
      onDragEnd: (_) => onDragActiveChanged?.call(null),
      child: tileContent,
    );

    // View は既定 1 枚だけでも出す（松本 2026-09-12: 隠すとかえって分かりにくい。
    // 「レイヤ＝データ、View＝見え方」の型を最初から見せておく）。
    // 既定 1 枚は引き続きファイルには書かれない（`LayerNode.persistViews`）
    final views = node.views;
    if (views.isEmpty) return draggable;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        draggable,
        for (final view in views) ViewTile(key: ValueKey(view.viewKey), node: view),
      ],
    );
  }

  // ---------- UI 部品 ----------

  Widget _buildLeadingIcon(WidgetRef ref, bool isSelected) {
    return GestureDetector(
      onTap: () {
        node.visible = !node.visible;
        node.persistVisibility();
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected ? Colors.blue.withValues(alpha: 0.15) : Colors.transparent,
            ),
            padding: const EdgeInsets.all(4),
            child: Icon(
              NodePresenter.getIcon(node),
              color: isSelected
                  ? Colors.blue
                  : (node.isVisibleRecursive() ? NodePresenter.getColor(node) : Colors.grey),
            ),
          ),
          if (!node.visible)
            Transform.rotate(
              angle: -0.7,
              child: Container(width: 32, height: 4, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  PopupMenuButton<String> _buildMenu(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      onSelected: (value) async {
        switch (value) {
          case 'rename':
            await _showRenameDialog(context, ref);
          case 'style':
            await _openStyleSettings(context, ref);
          case 'export':
            await LayerImportExportDialog.showExportDialog(
              context,
              exportLayer: node,
            );
          case 'convert_to_line' when node is PointLayerNode:
            await _convertPointsToLine(context, ref, node as PointLayerNode);
          case 'merge' when node is PolygonLayerNode:
            await _mergePolygons(context, ref, node as PolygonLayerNode);
          case 'absorb':
            await _absorbMatchingLayers(context, ref);
          case 'add_view':
            await _addView(ref);
          case 'zoom':
            _zoomToLayer(ref);
          case 'delete':
            await _handleDelete(context, ref);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'zoom',
          child: Row(children: [const Icon(Icons.center_focus_strong, size: 16), const SizedBox(width: 8), Text(t.layerDrawer.layer.zoomTo)]),
        ),
        PopupMenuItem(
          value: 'rename',
          child: Row(children: [const Icon(Icons.edit, size: 16), const SizedBox(width: 8), Text(t.layerDrawer.layer.rename)]),
        ),
        PopupMenuItem(
          value: 'style',
          child: Row(children: [const Icon(Icons.palette, size: 16), const SizedBox(width: 8), Text(t.layerDrawer.layer.style)]),
        ),
        PopupMenuItem(
          value: 'add_view',
          child: Row(children: [const Icon(Icons.filter_alt, size: 16), const SizedBox(width: 8), Text(t.layerDrawer.view.addView)]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'export',
          child: Row(children: [const Icon(Icons.file_download, size: 16), const SizedBox(width: 8), Text(t.layerDrawer.layer.exportLayer)]),
        ),
        if (node is PointLayerNode)
          PopupMenuItem(
            value: 'convert_to_line',
            child: Row(children: [const Icon(Icons.transform, size: 16), const SizedBox(width: 8), Text(t.layerDrawer.layer.convertToLinePolygon)]),
          ),
        if (node is PolygonLayerNode)
          PopupMenuItem(value: 'merge', child: Text(t.layerDrawer.layer.merge)),
        PopupMenuItem(
          value: 'absorb',
          child: Row(children: [const Icon(Icons.merge_type, size: 16), const SizedBox(width: 8), Text(t.layerDrawer.layer.absorbMatchingLayers)]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'delete', child: Text(t.layerDrawer.layer.delete)),
      ],
    );
  }

  /// レイヤの全フィーチャが入る範囲へ寄せる（行のダブルタップと ⋮ の「レイヤへ寄せる」）。
  /// 起動時はフィーチャ全体が入る範囲で開く（2026-09-13〜）が、遠くのレイヤへ寄せる導線としても残す
  void _zoomToLayer(WidgetRef ref) {
    final coords = node.getAllCoordinates();
    if (coords.isEmpty) return;
    ref.read(mapControllerHolderProvider)?.fitCoordinates(
      coords,
      padding: const EdgeInsets.all(50),
    );
  }

  // ---------- View 操作 ----------

  /// View を1枚足す。
  ///
  /// 既定Viewしか無いレイヤに足すと、既定Viewもファイルに書かれるようになる
  /// （「Viewが2枚ある」状態は暗黙のままにしておけないため）。
  Future<void> _addView(WidgetRef ref) async {
    if (node.views.isEmpty) await node.loadViews();

    final base = t.layerDrawer.view.newViewName;
    var name = base;
    var n = 1;
    while (node.views.any((v) => v.name == name)) {
      n++;
      name = '$base $n';
    }
    node.views.add(ViewNode(name: name, parent: node));
    await node.persistViews();
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
  }

  // ---------- レイヤー操作 ----------

  Future<void> _showRenameDialog(BuildContext context, WidgetRef ref) async {
    final newName = await RenameDialog.show(
      context,
      title: t.layerDrawer.layer.renameTitle,
      currentName: node.layerName,
      label: t.layerDrawer.layer.layerName,
      hint: t.layerDrawer.layer.enterNewName,
      submitLabel: t.layerDrawer.rename,
    );
    if (newName == null || newName == node.layerName) return;
    try {
      await node.geoPackageFile.renameLayer(node.layerName, newName);
      await node.geoPackageNode.updateChildren();
      ref.read(featureRefreshTriggerProvider.notifier).trigger();
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.renameFailed(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }

  Future<void> _openStyleSettings(BuildContext context, WidgetRef ref) async {
    final folderPath = node.folderNode?.getAbsoluteFilePath();
    if (folderPath == null) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.couldNotDetermineFolder,
            level: NotificationLevel.info,
          );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LayerStyleSettingsScreen(targetLayer: node, folderPath: folderPath)),
    );
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
  }

  Future<void> _handleDelete(BuildContext context, WidgetRef ref) async {
    await confirmAndExecute(
      context,
      ref: ref,
      title: t.layerDrawer.layer.deleteLayer,
      content: Text(t.layerDrawer.layer.deleteLayerConfirm(name: node.name)),
      confirmLabel: t.layerDrawer.layer.delete,
      execute: () async {
        if (ref.read(selectedLayerNodeProvider) == node) {
          ref.read(selectedLayerNodeProvider.notifier).select(null);
        }
        ref.read(selectedFeaturesProvider.notifier).set(
          ref.read(selectedFeaturesProvider).where((f) {
            if (f is FeatureNode) return f.parent != node;
            return true;
          }).toList(),
        );
        await node.dispose();
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      },
    );
  }

  // ---------- ジオメトリ変換・合成・吸収 ----------

  Future<void> _convertPointsToLine(
    BuildContext context,
    WidgetRef ref,
    PointLayerNode sourceLayer,
  ) async {
    final features = sourceLayer.features;
    if (features.isEmpty) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.noPointsToConvert,
            level: NotificationLevel.info,
          );
      return;
    }

    final targetLayers = GeometryConversionService.findTargetLayersForPoints(currentDir);
    if (targetLayers.isEmpty) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.noTargetLayersFound,
            level: NotificationLevel.info,
          );
      return;
    }

    // survey_stnチェーンがあれば測量変換ダイアログに分岐
    try {
      final chains = SurveyChainResolver.resolveAll(sourceLayer);
      if (chains.isNotEmpty) {
        await _convertSurveyPointsImpl(context, ref, sourceLayer, chains, targetLayers);
        return;
      }
    } catch (e) {
      AppLogger.debug('[LayerTile] Survey chain resolution failed: $e');
    }

    // 通常のポイント→ライン/ポリゴン変換
    final targetLayer = await showDialog<LayerNode>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ConvertPointsToGeometryDialog(sourceLayer: sourceLayer, availableLayers: targetLayers),
    );
    if (targetLayer == null) return;
    if (!context.mounted) return;

    final typeLabel = targetLayer is LineLayerNode ? 'Line' : 'Polygon';
    final String? featureName = await showDialog<String>(
      context: context,
      builder: (context) {
        final ctrl = TextEditingController(text: sourceLayer.name);
        return AlertDialog(
          title: Text(t.layerDrawer.layer.featureNameInput(type: typeLabel)),
          content: TextField(autofocus: true, controller: ctrl, decoration: InputDecoration(labelText: t.layerDrawer.layer.nameOptional)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, null), child: Text(t.common.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, ctrl.text), child: Text(t.common.ok)),
          ],
        );
      },
    );
    if (featureName == null) return;

    try {
      final created = await GeometryConversionService.convertPointsToGeometry(
        sourceLayer: sourceLayer,
        targetLayer: targetLayer,
        name: featureName.isNotEmpty ? featureName : null,
      );
      if (created != null) {
        await targetLayer.updateChildren();
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.convertedToType(type: typeLabel, count: '${features.length}'),
              level: NotificationLevel.info,
            );
      } else {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.featureCreateFailed,
              level: NotificationLevel.info,
            );
      }
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.conversionError(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }

  /// 測量チェーン付きポイントの変換（_convertPointsToLineから分岐）
  Future<void> _convertSurveyPointsImpl(
    BuildContext context,
    WidgetRef ref,
    PointLayerNode sourceLayer,
    List<TraverseChain> chains,
    List<LayerNode> targetLayers,
  ) async {
    final result = await showDialog<SurveyConversionResult>(
      context: context,
      barrierDismissible: true,
      builder: (_) => SurveyConversionDialog(
        sourceLayer: sourceLayer,
        chains: chains,
        availableLayers: targetLayers,
      ),
    );
    if (result == null) return;

    try {
      final created = await GeometryConversionService.convertSurveyPointsToGeometry(
        sourceLayer: sourceLayer,
        targetLayer: result.targetLayer,
        chain: result.chain,
        options: result.options,
        name: result.featureName,
        closePath: result.closePath,
      );
      if (created != null) {
        await result.targetLayer.updateChildren();
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
        final typeLabel = result.targetLayer is LineLayerNode ? 'Line' : 'Polygon';
        final closureInfo = result.closePath
            ? t.layerDrawer.layer.closureRatio(ratio: '${created.turfFeature.properties?['survey_closure_ratio'] ?? '?'}')
            : '';
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.surveyConvertedToType(type: typeLabel, count: '${result.chain.length}', closureInfo: closureInfo),
              level: NotificationLevel.info,
            );
      } else {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.featureCreateFailed,
              level: NotificationLevel.info,
            );
      }
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.surveyConversionError(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }

  Future<void> _mergePolygons(
    BuildContext context,
    WidgetRef ref,
    PolygonLayerNode layerNode,
  ) async {
    final features = layerNode.children.cast<FeatureNode>();
    final mergeableCount = PolygonMerge.countMergeablePolygons(features);
    if (mergeableCount < 2) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.mergeNeedTwo,
            level: NotificationLevel.info,
          );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.layerDrawer.layer.mergeTitle),
        content: Text(
          t.layerDrawer.layer.mergeConfirm(name: layerNode.name, count: '$mergeableCount'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(t.layerDrawer.layer.merge)),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final merged = PolygonMerge.mergePolygonFeatures(features);
      if (merged.isEmpty) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.mergeFailed,
              level: NotificationLevel.info,
            );
        return;
      }

      final parentGpkg = layerNode.parent as GeoPackageNode;
      final newLayerName = '${layerNode.name}_merged';
      final newLayer = await PolygonLayerNode.createIn(parentGpkg, newLayerName);
      if (newLayer == null) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.newLayerFailed,
              level: NotificationLevel.info,
            );
        return;
      }

      final mergedFeature = await PolygonFeatureNode.createIn(
        newLayer,
        merged,
        'merged_polygon',
        t.layerDrawer.layer.mergedDescription(name: layerNode.name, count: '$mergeableCount'),
        metadata: {
          'source_layer': layerNode.name,
          'merged_count': mergeableCount,
          'created_at': DateTime.now().toIso8601String(),
        },
      );
      if (mergedFeature != null) {
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.mergeSuccess(name: newLayerName),
              level: NotificationLevel.info,
            );
      } else {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.saveMergedFailed,
              level: NotificationLevel.info,
            );
      }
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.mergeError(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }

  Future<void> _absorbMatchingLayers(BuildContext context, WidgetRef ref) async {
    final parentGpkg = node.parent;
    if (parentGpkg is! GeoPackageNode) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.notInGeoPackage,
            level: NotificationLevel.info,
          );
      return;
    }

    try {
      final targetColumns = await parentGpkg.geoPackageFile.getTableColumns(node.name);
      if (!context.mounted) return;
      if (targetColumns.isEmpty) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.columnInfoFailed,
              level: NotificationLevel.info,
            );
        return;
      }

      final siblings = parentGpkg.children
          .whereType<LayerNode>()
          .where((l) => l != node && l.runtimeType == node.runtimeType)
          .toList();
      if (siblings.isEmpty) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.noSameTypeLayers,
              level: NotificationLevel.info,
            );
        return;
      }

      final systemCols = {'id', 'fid', 'geom', 'geometry', 'ROWID'};
      bool columnsMatch(List<String> a, List<String> b) {
        final a1 = a.where((c) => !systemCols.contains(c.toLowerCase())).toSet();
        final b1 = b.where((c) => !systemCols.contains(c.toLowerCase())).toSet();
        return a1.length == b1.length && a1.containsAll(b1);
      }

      final matching = <LayerNode>[];
      for (final layer in siblings) {
        final cols = await parentGpkg.geoPackageFile.getTableColumns(layer.name);
        if (columnsMatch(targetColumns, cols)) matching.add(layer);
      }
      if (!context.mounted) return;
      if (matching.isEmpty) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.layer.noMatchingColumns,
              level: NotificationLevel.info,
            );
        return;
      }

      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.layerDrawer.layer.absorbTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.layerDrawer.layer.absorbConfirm(count: '${matching.length}', name: node.name)),
              ...matching.map((l) => Text('  • ${l.name}')),
              const SizedBox(height: 12),
              Text(t.layerDrawer.layer.absorbWarning, style: const TextStyle(color: Colors.red)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(t.common.confirm)),
          ],
        ),
      );
      if (confirm != true) return;

      int count = 0;
      for (final src in matching) {
        final copied = await parentGpkg.geoPackageFile.copyFeaturesBetweenLayers(src.name, node.name);
        if (copied > 0) {
          count += copied;
          await src.dispose();
        }
      }

      await node.updateChildren();
      ref.read(featureRefreshTriggerProvider.notifier).trigger();

      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.absorbedFeatures(count: '$count'),
            level: NotificationLevel.info,
          );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.layer.absorbError(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }
}

/// GeoPackage 内レイヤ追加ボタン
class AddLayerButton extends ConsumerWidget {
  final GeoPackageNode node;

  const AddLayerButton({super.key, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<Map<String, String>>(
          context: context,
          builder: (_) => const _NewLayerDialog(),
        );
        if (result == null || result['name'] == null) return;

        final geomType = GeometryType.fromString(result['geomType']!);
        try {
          final created = switch (geomType) {
            GeometryType.point => await PointLayerNode.createIn(node, result['name']!),
            GeometryType.linestring => await LineLayerNode.createIn(node, result['name']!),
            GeometryType.polygon => await PolygonLayerNode.createIn(node, result['name']!),
            null => null,
          };
          if (created != null) {
            ref.read(featureRefreshTriggerProvider.notifier).trigger();
          }
        } catch (_) {}
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.add, size: 24),
          const SizedBox(width: 8),
          Text(t.layerDrawer.layer.addLayer, style: const TextStyle(fontSize: 16, color: Colors.black87)),
        ],
      ),
    );
  }
}

/// レイヤ新規作成ダイアログ
class _NewLayerDialog extends StatefulWidget {
  const _NewLayerDialog();

  @override
  _NewLayerDialogState createState() => _NewLayerDialogState();
}

class _NewLayerDialogState extends State<_NewLayerDialog> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  GeometryType _geomType = GeometryType.point;
  bool _isUserInput = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _geomType.defaultLayerName);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus) _selectAll();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _selectAll());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _selectAll() {
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  void _create() {
    final name = _controller.text.trim();
    Navigator.pop(context, {
      'name': name.isEmpty ? _geomType.defaultLayerName : name,
      'geomType': _geomType.value,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.layerDrawer.layer.newLayer),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            decoration: InputDecoration(labelText: t.layerDrawer.layer.layerNameLabel, hintText: _geomType.defaultLayerName),
            onTap: _selectAll,
            onChanged: (v) => _isUserInput = v.isNotEmpty && v != _geomType.defaultLayerName,
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<GeometryType>(
            initialValue: _geomType,
            decoration: InputDecoration(labelText: t.layerDrawer.layer.geometryType),
            items: [
              DropdownMenuItem(value: GeometryType.point, child: Text(GeometryType.point.displayName)),
              DropdownMenuItem(value: GeometryType.linestring, child: Text(GeometryType.linestring.displayName)),
              DropdownMenuItem(value: GeometryType.polygon, child: Text(GeometryType.polygon.displayName)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() {
                _geomType = v;
                if (!_isUserInput) {
                  _controller.text = _geomType.defaultLayerName;
                  _selectAll();
                }
              });
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: Text(t.common.cancel)),
        TextButton(onPressed: _create, child: Text(t.layerDrawer.layer.create)),
      ],
    );
  }
}
