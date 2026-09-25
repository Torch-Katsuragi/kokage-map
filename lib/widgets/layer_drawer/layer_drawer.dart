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
/// Root Maps: レイヤ構造Drawerウィジェット（メインファイル）
/// プロジェクトフォルダ・サブフォルダ・GeoPackage・レイヤの階層構造をファイルエクスプローラ風に1階層のみリスト表示し、
/// 可視切り替え・リネーム・削除などの操作を提供するUI。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';

import '../../core/fs/k_file_system.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/global_folder_node.dart';
import '../../models/nodes/image_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/sys_node.dart';
import '../../presentation/node_presenter.dart';
import '../../providers/notification_providers.dart';
import '../../providers/project_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../screens/gallery_import_screen.dart';
import '../../services/kmeta_service.dart';
import '../../services/layer_drawer_service.dart';
import '../dialogs/add_folder_type_dialog.dart';
import '../dialogs/drive_url_input_dialog.dart';
import 'common_dialogs.dart';
import 'layer_drawer_drive_sync.dart';
import 'layer_drawer_title_bar.dart';
import 'sync_merge_dialog.dart';
import 'tiles/drag_feedback_card.dart';
import 'tiles/folder_tile.dart';
import 'tiles/geopackage_tile.dart';
import 'tiles/photo_tile.dart';

/// レイヤ構造Drawer
class LayerDrawer extends ConsumerStatefulWidget {
  final LayerTreeNode? currentNode;
  final void Function(LayerTreeNode? newNode) onDirChanged;
  final void Function(LatLng latLng)? onJumpTo;
  final void Function(FeatureNode feature)? onStartAppendMode;

  const LayerDrawer({
    super.key,
    required this.currentNode,
    required this.onDirChanged,
    this.onJumpTo,
    this.onStartAppendMode,
  });

  @override
  ConsumerState<LayerDrawer> createState() => _LayerDrawerState();
}

class _LayerDrawerState extends ConsumerState<LayerDrawer>
    with LayerDrawerDriveSync {
  LayerTreeNode? _draggingNode;
  GeoPackageNode? _dragTarget;

  bool get _isDragging => _draggingNode != null;
  bool get _isLayerDrag => _draggingNode is LayerNode;
  Timer? _dragNavTimer;

  void _endDrag() {
    if (!_isDragging) return;
    setState(() { _draggingNode = null; _dragTarget = null; });
  }

  @override
  void triggerMapRefresh() =>
      ref.read(featureRefreshTriggerProvider.notifier).trigger();

  // --- ライフサイクル ---

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncExpansionState(reset: false);
    });
  }

  @override
  void didUpdateWidget(LayerDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentNode != widget.currentNode) {
      _cancelDragNavTimer();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncExpansionState(reset: true);
      });
    }
  }

  @override
  void dispose() {
    _dragNavTimer?.cancel();
    super.dispose();
  }

  void _syncExpansionState({required bool reset}) {
    final paths = _collectGpkgPaths(widget.currentNode);
    final notifier = ref.read(expandedGeoPackagesProvider.notifier);
    if (reset) {
      notifier.resetAndExpandAll(paths);
    } else {
      notifier.expandAll(paths);
    }
  }

  static List<String> _collectGpkgPaths(LayerTreeNode? node) {
    if (node == null) return [];
    return [
      for (final child in node.children)
        if (child is GeoPackageNode)
          if (child.geoPackageFile.getAbsolutePath() case final String p) p,
    ];
  }

  // --- ドラッグ中フォルダナビゲーション ---

  void _startDragNavTimer(VoidCallback navigate) {
    if (_dragNavTimer != null) return;
    _dragNavTimer = Timer(const Duration(milliseconds: 500), () {
      _dragNavTimer = null;
      if (mounted) navigate();
    });
  }

  void _cancelDragNavTimer() {
    _dragNavTimer?.cancel();
    _dragNavTimer = null;
  }

  /// ドラッグ中に0.5秒ホバーでディレクトリ遷移 + ファイル移動ドロップを受け付ける DragTarget ラッパー。
  /// [dropTarget] が指定された場合、非LayerNode のドロップでファイル移動を実行する。
  Widget _wrapDragNav(Widget child, VoidCallback onNavigate, {FolderNode? dropTarget}) {
    return DragTarget<LayerTreeNode>(
      onWillAcceptWithDetails: (details) {
        if (dropTarget != null && identical(details.data, dropTarget)) return false;
        return true;
      },
      onMove: (_) => _startDragNavTimer(onNavigate),
      onLeave: (_) => _cancelDragNavTimer(),
      onAcceptWithDetails: (details) {
        _cancelDragNavTimer();
        if (dropTarget != null && details.data is! LayerNode) {
          _moveNodeToFolder(details.data, dropTarget);
        }
      },
      builder: (context, candidateData, _) => Container(
        decoration: candidateData.isNotEmpty
            ? BoxDecoration(
                border: Border.all(color: Colors.orange, width: 2),
                borderRadius: BorderRadius.circular(4),
                color: Colors.orange.withValues(alpha: 0.1),
              )
            : null,
        child: child,
      ),
    );
  }

  // --- ファイル移動 ---

  Future<void> _moveNodeToFolder(LayerTreeNode source, FolderNode target) async {
    _endDrag();

    final sourcePath = source.getAbsoluteFilePath();
    final targetDir = target.getAbsoluteFilePath();
    if (sourcePath == null || targetDir == null) return;

    final baseName = p.basename(sourcePath);
    final newPath = p.join(targetDir, baseName);
    if (sourcePath == newPath) return;

    if (await fs.exists(newPath)) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.alreadyExists(name: baseName, target: target.name),
            level: NotificationLevel.info,
          );
      return;
    }

    try {
      // Windows: GeoPackageのDB接続を閉じないとファイルロックで移動失敗する
      await _closeGeoPackageConnections(source);
      await _moveFileOrDir(sourcePath, newPath, isDir: source is FolderNode);
      await LayerDrawerService.notifySyncedPathChange(source, sourcePath, newPath);

      final sourceParent = source.parent;
      if (sourceParent != null) await sourceParent.updateChildren();
      await target.updateChildren();

      if (source is GeoPackageNode) {
        final moved = target.children.whereType<GeoPackageNode>()
            .where((n) => n.name == baseName).firstOrNull;
        if (moved != null) await moved.updateChildren();
      }

      ref.read(featureRefreshTriggerProvider.notifier).trigger();
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.movedTo(source: source.name, target: target.name),
            level: NotificationLevel.info,
          );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.moveFailed(error: '$e'),
            level: NotificationLevel.error,
          );
    }
  }

  Future<void> _closeGeoPackageConnections(LayerTreeNode node) async {
    if (node is GeoPackageNode) {
      await node.geoPackageFile.dispose();
    }
    if (node is FolderNode) {
      for (final child in node.children) {
        await _closeGeoPackageConnections(child);
      }
    }
  }

  /// ⚠ `dart:io` を直に使わないこと。web では `Directory` / `File` に
  /// 触れた時点で `Unsupported operation: _Namespace` が飛ぶ（コンパイルは通る）。
  Future<void> _moveFileOrDir(String src, String dst, {required bool isDir}) async {
    // web の `rename` はフォルダに未対応。ドライブをまたぐ移動も rename では
    // 通らないので、どちらも「作り直して消す」に落とす
    if (!isDir) {
      try {
        await fs.rename(src, dst);
        return;
      } catch (_) {
        await fs.writeAsBytes(dst, await fs.readAsBytes(src));
        await fs.delete(src);
        return;
      }
    }
    try {
      await fs.rename(src, dst);
    } catch (_) {
      await _copyDirectory(src, dst);
      await fs.delete(src, recursive: true);
    }
  }

  Future<void> _copyDirectory(String src, String dst) async {
    await fs.createDirectory(dst);
    for (final entry in await fs.list(src)) {
      final to = p.join(dst, entry.name);
      if (entry.isDirectory) {
        await _copyDirectory(entry.path, to);
      } else {
        await fs.writeAsBytes(to, await fs.readAsBytes(entry.path));
      }
    }
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    ref.watch(featureRefreshTriggerProvider);

    if (widget.currentNode == null) {
      return Center(child: Text(t.layerDrawer.directoryNotFound));
    }

    final parent = widget.currentNode!.parent;
    final driveRoot = LayerDrawerService.findDriveRoot(widget.currentNode);
    // ⚠ パスを解決できないフォルダ（プロジェクト未設定の仮ルート `Home`。web の地図プレビューや
    //   `#/map` 直開き）には何も作らせない。作れてしまうと web では IndexedDB にだけ残る幽霊 gpkg になる
    final canAddHere = widget.currentNode is FolderNode && widget.currentNode!.getAbsoluteFilePath() != null;
    Widget titleBar = LayerDrawerTitleBar(
      title: NodePresenter.getDisplayName(widget.currentNode!),
      currentNode: widget.currentNode!,
      onAdd: canAddHere
          ? (action) => switch (action) {
                AddAction.folder => _addFolder(context),
                AddAction.geoPackage => _addGeoPackage(context),
                AddAction.photo => _addPhoto(context),
              }
          : null,
      onBack: parent != null ? () => widget.onDirChanged(parent) : null,
      syncStatus: driveRoot?.syncStatus,
      isReadOnly: driveRoot?.isReadOnly ?? false,
      onCloudAction: driveRoot != null
          ? (action) => _handleCloudAction(context, driveRoot, action)
          : null,
    );
    if (parent != null) {
      titleBar = _wrapDragNav(
        titleBar,
        () => widget.onDirChanged(parent),
        dropTarget: parent is FolderNode && parent is! SysNode ? parent : null,
      );
    }

    return Container(
      decoration: _isDragging
          ? BoxDecoration(
              border: Border.all(color: Colors.blue, width: 2),
              borderRadius: BorderRadius.circular(8),
              color: Colors.blue.withValues(alpha: 0.1),
            )
          : null,
      child: Column(
        children: [
          titleBar,
          if (_isDragging)
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: (_isLayerDrag ? Colors.blue : Colors.orange).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(
                    _isLayerDrag ? Icons.cloud_upload : Icons.drive_file_move,
                    color: _isLayerDrag ? Colors.blue : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _isLayerDrag
                          ? t.layerDrawer.dropOnGeoPackage
                          : t.layerDrawer.dropToMove,
                      style: TextStyle(
                        color: _isLayerDrag ? Colors.blue : Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            const SizedBox.shrink(),
          Expanded(
            child: DragTarget<LayerTreeNode>(
              onWillAcceptWithDetails: (details) =>
                  details.data is! LayerNode &&
                  canAddHere &&
                  details.data.parent != widget.currentNode,
              onAcceptWithDetails: (details) {
                if (widget.currentNode case final FolderNode folder) {
                  _moveNodeToFolder(details.data, folder);
                }
              },
              builder: (context, candidateData, _) => Container(
                decoration: candidateData.isNotEmpty
                    ? BoxDecoration(
                        border: Border.all(color: Colors.orange, width: 2),
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.orange.withValues(alpha: 0.05),
                      )
                    : null,
                child: ListView(
                  children: widget.currentNode!.children.map(_buildNodeTile).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodeTile(LayerTreeNode node) {
    if (node is FolderNode) {
      // 「この端末」とグローバルフォルダ本体は、名前変更・削除・ドラッグの対象にしない
      final fixed = node is SysNode || node is GlobalFolderNode;
      final tile = FolderTile(
        node: node,
        fixed: fixed,
        onTap: () => widget.onDirChanged(node),
        onRename: node is! DriveFolderNode && !fixed ? () => _renameFolder(context, node) : null,
        onSyncMerge: node is DriveFolderNode ? openSyncMergeDialog : null,
        onRefreshSync: node is DriveFolderNode ? refreshSyncStatus : null,
        onUnlinkDrive: node is DriveFolderNode ? unlinkDriveFolder : null,
        onDeleteDrive: node is DriveFolderNode ? deleteDriveFolder : null,
      );
      // sys はパスが無いので落とし先にしない（遷移のためのホバーは受ける）
      Widget result = _wrapDragNav(
        tile,
        () => widget.onDirChanged(node),
        dropTarget: node is SysNode ? null : node,
      );
      if (node is! DriveFolderNode && !fixed) {
        result = _wrapDraggable(result, node);
      }
      return result;
    }
    if (node is ImageNode) {
      return _wrapDraggable(
        PhotoTile(node: node, onRename: () => _renamePhoto(context, node), onJumpTo: widget.onJumpTo),
        node,
      );
    }
    if (node is GeoPackageNode) {
      return GeoPackageTile(
        node: node,
        isDropTarget: (_isLayerDrag || !_isDragging) && _dragTarget == node,
        onRename: () => _renameGeoPackage(context, node),
        onDragTargetChanged: (t) => setState(() => _dragTarget = t),
        onDragActiveChanged: (dragNode) => setState(() {
          _draggingNode = dragNode;
          if (dragNode == null) _dragTarget = null;
        }),
        currentDir: widget.currentNode,
      );
    }
    return const SizedBox.shrink();
  }

  /// ファイル移動用の LongPressDraggable ラッパー
  Widget _wrapDraggable(Widget child, LayerTreeNode node) {
    return LongPressDraggable<LayerTreeNode>(
      data: node,
      dragAnchorStrategy: (_, _, _) => const Offset(0, 0),
      feedback: DragFeedbackCard(node: node),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      onDragStarted: () => setState(() => _draggingNode = node),
      onDraggableCanceled: (_, _) => _endDrag(),
      onDragEnd: (_) => _endDrag(),
      child: child,
    );
  }

  // --- UI アクション ---

  Future<void> _renameFolder(BuildContext context, FolderNode node) async {
    final result = await RenameDialog.show(
      context,
      title: t.layerDrawer.renameFolder,
      currentName: node.name,
      label: t.layerDrawer.newName,
    );
    if (result == null || result.isEmpty || result == node.name) return;
    try {
      final absPath = node.getAbsoluteFilePath();
      if (absPath != null) {
        final newPath = p.join(p.dirname(absPath), result);
        await fs.rename(absPath, newPath);
        await LayerDrawerService.notifySyncedPathChange(node, absPath, newPath);
      }
      node.name = result;
      triggerMapRefresh();
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.renameFailed(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }

  Future<void> _renamePhoto(BuildContext context, ImageNode node) async {
    final currentName = p.basenameWithoutExtension(node.name);
    final result = await RenameDialog.show(
      context,
      title: t.layerDrawer.renamePhoto,
      currentName: currentName,
      label: t.layerDrawer.newFileName,
    );
    if (result == null || result.isEmpty || result == currentName) return;
    try {
      await LayerDrawerService.renamePhoto(node, result);
      triggerMapRefresh();
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.photoRenamed(name: result),
            level: NotificationLevel.info,
          );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.renameFailed(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }

  Future<void> _renameGeoPackage(BuildContext context, GeoPackageNode node) async {
    final currentName = p.basenameWithoutExtension(node.name);
    final result = await RenameDialog.show(
      context,
      title: t.layerDrawer.renameGeoPackage,
      currentName: currentName,
      label: t.layerDrawer.newFileName,
    );
    if (result == null || result.isEmpty || result == currentName) return;
    try {
      final oldPath = node.geoPackageFile.getAbsolutePath();
      final wasExpanded = ref.read(expandedGeoPackagesProvider).isExpanded(oldPath);
      // updateChildren()でnode.parentがnullになるため、先に保持
      final parentNode = node.parent;

      final projectRoot = ref.read(projectRootDirProvider);
      final newFileName = await LayerDrawerService.renameGeoPackage(
        node, result, projectRootDir: projectRoot ?? '',
      );

      if (oldPath != null && parentNode != null) {
        final newPath = p.join(p.dirname(oldPath), newFileName);
        if (wasExpanded) {
          ref.read(expandedGeoPackagesProvider.notifier).updatePath(oldPath, newPath);
        }
        // 新しいGeoPackageNodeのレイヤを読み込む
        for (final child in parentNode.children) {
          if (child is GeoPackageNode && child.geoPackageFile.getAbsolutePath() == newPath) {
            await child.updateChildren();
            break;
          }
        }
      }

      triggerMapRefresh();
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.gpkgRenamed(name: newFileName),
            level: NotificationLevel.info,
          );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.layerDrawer.renameFailed(error: '$e'),
            level: NotificationLevel.info,
          );
    }
  }

  Future<void> _handleCloudAction(
    BuildContext context,
    DriveFolderNode driveRoot,
    String action,
  ) async {
    switch (action) {
      case 'upload':
        await openSyncMergeDialog(context, driveRoot, mode: SyncMode.upload);
      case 'download':
        await openSyncMergeDialog(context, driveRoot, mode: SyncMode.download);
      case 'refresh':
        await refreshSyncStatus(driveRoot);
      case 'unlink':
        if (driveRoot.parent != null) {
          await unlinkDriveFolder(context, driveRoot);
        } else {
          await _unlinkRootDrive(context, driveRoot);
        }
    }
  }

  Future<void> _unlinkRootDrive(
    BuildContext context,
    DriveFolderNode driveRoot,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.layerDrawer.folder.unlinkDrive),
        content: Text(t.layerDrawer.unlinkDriveConfirm(name: driveRoot.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(t.layerDrawer.unlink),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final folderPath = driveRoot.getAbsoluteFilePath();
    if (folderPath == null) return;

    await KMetaService.instance.unlinkDrive(folderPath);

    final replacement = FolderNode(
      driveRoot.name,
      visible: driveRoot.visible,
      children: [],
    );
    for (final child in driveRoot.children) {
      child.parent = replacement;
      replacement.children.add(child);
    }
    driveRoot.children.clear();

    ref.read(folderTreeProvider.notifier).set(replacement);
    widget.onDirChanged(replacement);

    ref.read(notificationCenterProvider.notifier).add(
          title: t.layerDrawer.driveUnlinked,
          level: NotificationLevel.info,
        );
  }

  Future<void> _addFolder(BuildContext context) async {
    final isUnderDrive = LayerDrawerService.findDriveRoot(widget.currentNode) != null;
    final typeResult = await AddFolderTypeDialog.show(context, allowDrive: !isUnderDrive);
    if (typeResult == null) return;
    if (typeResult.type == AddFolderType.local) {
      try {
        await LayerDrawerService.createLocalFolder(widget.currentNode as FolderNode, typeResult.folderName!);
        triggerMapRefresh();
      } catch (e) {
        ref.read(notificationCenterProvider.notifier).add(title: '$e', level: NotificationLevel.info);
      }
    } else {
      if (!context.mounted) return;
      await _addDriveFolder(context);
    }
  }

  Future<void> _addDriveFolder(BuildContext context) async {
    final urlResult = await DriveUrlInputDialog.show(context);
    if (urlResult == null) return;

    ref.read(notificationCenterProvider.notifier).add(
          title: t.layerDrawer.cloningDrive(name: urlResult.folderName),
          level: NotificationLevel.info,
        );

    try {
      final node = await LayerDrawerService.cloneDriveFolder(
        parent: widget.currentNode as FolderNode,
        folderId: urlResult.folderId,
        folderName: urlResult.folderName,
        url: urlResult.url,
        isReadOnly: urlResult.isReadOnly,
      );

      if (node != null) {
        triggerMapRefresh();
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.cloneSuccess(name: urlResult.folderName),
              level: NotificationLevel.success,
            );
      } else {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.cloneFailed,
              level: NotificationLevel.error,
            );
      }
    } catch (e) {
      AppLogger.error('[LayerDrawer] Driveフォルダクローンエラー: $e');
      ref.read(notificationCenterProvider.notifier).add(
            title: t.common.errorOccurred(error: '$e'),
            level: NotificationLevel.error,
          );
    }
  }

  Future<void> _addGeoPackage(BuildContext context) async {
    final result = await RenameDialog.show(
      context,
      title: t.layerDrawer.newGeoPackage,
      currentName: '',
      label: t.layerDrawer.gpkgFileName,
      submitLabel: t.layerDrawer.layer.create,
    );
    if (result == null || result.isEmpty) return;

    try {
      final newNode = await LayerDrawerService.createGeoPackage(widget.currentNode as FolderNode, result);
      if (newNode == null) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.layerDrawer.gpkgCreateFailed,
              level: NotificationLevel.info,
            );
        return;
      }
      final absPath = newNode.geoPackageFile.getAbsolutePath();
      if (absPath != null) ref.read(expandedGeoPackagesProvider.notifier).addExpanded(absPath);
      triggerMapRefresh();
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(title: '$e', level: NotificationLevel.info);
    }
  }

  Future<void> _addPhoto(BuildContext context) async {
    final folder = widget.currentNode as FolderNode;
    final imported = await GalleryImporter.pickAndImport(context, folder, ref: ref);
    if (imported) {
      await folder.updateChildren();
      triggerMapRefresh();
    }
  }
}
