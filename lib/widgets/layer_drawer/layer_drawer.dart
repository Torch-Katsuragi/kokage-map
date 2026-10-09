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


import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';

import '../../core/fs/k_file_system.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/external_layer_node.dart';
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
import '../../services/external/external_layer_cache.dart';
import '../../services/kmeta_service.dart';
import '../../services/layer_drawer_service.dart';
import '../../tutorial/tutorial.dart';
import '../dialogs/add_folder_type_dialog.dart';
import '../dialogs/drive_url_input_dialog.dart';
import '../external_layer_actions.dart';
import 'add_files_action.dart';
import 'common_dialogs.dart';
import 'layer_drawer_drive_sync.dart';
import 'layer_drawer_title_bar.dart';
import 'move_target_dialog.dart';
import 'sync_merge_dialog.dart';
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
  /// ファイルを落としている最中か（web のドラッグ＆ドロップ）
  bool _dragging = false;

  /// ファイルを落としている先のフォルダの行（光らせる）。null なら開いているフォルダそのもの
  FolderNode? _dropFolder;

  /// フォルダの行の位置を引くための鍵（落とした位置の下の行を探す）
  final _folderKeys = Expando<GlobalKey>();

  @override
  void triggerMapRefresh() => ref.refreshMap();

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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncExpansionState(reset: true);
      });
    }
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

  // --- ファイル移動 ---

  /// 行の左スワイプ「移動」: 行き先を選ばせて動かす（フォルダ・gpkg・写真はフォルダへ、レイヤは別の gpkg へ移植）
  Future<void> _swipeMove(LayerTreeNode source) async {
    // 読み取り専用レイヤの中のレイヤは別の gpkg へ移せない（ファイルごとのフォルダ移動はできる）
    if (source is LayerNode &&
        refuseReadOnlyEdit(ref.read(notificationCenterProvider.notifier), source, onChanged: ref.refreshMap)) {
      return;
    }
    LayerTreeNode root = widget.currentNode!;
    while (root.parent != null) {
      root = root.parent!;
    }
    final target = await MoveTargetDialog.show(context, source: source, root: root);
    if (target == null || !mounted) return;
    if (source is LayerNode && target is GeoPackageNode) {
      await migrateLayerTo(context, ref, source, target);
    } else if (target is FolderNode) {
      await _moveNodeToFolder(source, target);
    }
  }

  Future<void> _moveNodeToFolder(LayerTreeNode source, FolderNode target) async {
    if (source is ExternalLayerNode) return _moveExternalToFolder(source, target);

    final sourcePath = source.getAbsoluteFilePath();
    final targetDir = target.getAbsoluteFilePath();
    if (sourcePath == null || targetDir == null) return;

    final baseName = p.basename(sourcePath);
    final newPath = p.join(targetDir, baseName);
    if (sourcePath == newPath) return;

    if (await fs.exists(newPath)) {
      ref.notify(t.layerDrawer.alreadyExists(name: baseName, target: target.name));
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

      ref.refreshMap();
      ref.notify(t.layerDrawer.movedTo(source: source.name, target: target.name));
    } catch (e) {
      ref.notify(t.layerDrawer.moveFailed(error: '$e'), level: NotificationLevel.error);
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
    final titleBar = LayerDrawerTitleBar(
      title: NodePresenter.getDisplayName(widget.currentNode!),
      currentNode: widget.currentNode!,
      onAdd: canAddHere
          ? (action) => switch (action) {
                AddAction.folder => _addFolder(context),
                AddAction.geoPackage => _addGeoPackage(context),
                AddAction.photo => _addPhoto(context),
                AddAction.files => pickAndAddFiles(ref, widget.currentNode! as FolderNode),
              }
          : null,
      onBack: parent != null ? () => widget.onDirChanged(parent) : null,
      onNavigate: widget.onDirChanged,
      syncStatus: driveRoot?.syncStatus,
      isReadOnly: driveRoot?.isReadOnly ?? false,
      onCloudAction: driveRoot != null
          ? (action) => _handleCloudAction(context, driveRoot, action)
          : null,
    );

    return Column(
      children: [
        titleBar,
        Expanded(
          // ファイルを落とすと、その下のフォルダの行（無ければ開いているフォルダ）にそのまま入れる。
          // 行ごとに DropTarget を置くと入れ子で両方に届くので、ここ 1 つで受けて位置から行を探す
          child: DropTarget(
            onDragEntered: (d) => _onDragOver(d.globalPosition),
            onDragUpdated: (d) => _onDragOver(d.globalPosition),
            onDragExited: (_) => _endDrag(),
            onDragDone: _onDrop,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: _dragging && _dropFolder == null && canAddHere
                    ? Border.all(color: Colors.blue, width: 2)
                    : null,
              ),
              child: ListView.builder(
                itemCount: widget.currentNode!.children.length,
                itemBuilder: (_, i) => _buildNodeTile(widget.currentNode!.children[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNodeTile(LayerTreeNode node) {
    if (node is FolderNode) {
      // 「この端末」とグローバルフォルダ本体は、名前変更・削除・ドラッグの対象にしない
      final fixed = node is SysNode || node is GlobalFolderNode;
      final drive = node is DriveFolderNode;
      final movable = !drive && !fixed;
      return FolderTile(
        key: _folderKeys[node] ??= GlobalKey(),
        node: node,
        fixed: fixed,
        isDropTarget: _dropFolder == node,
        onTap: () => widget.onDirChanged(node),
        onRename: movable ? () => _renameFolder(context, node) : null,
        onSyncMerge: drive ? openSyncMergeDialog : null,
        onRefreshSync: drive ? refreshSyncStatus : null,
        onUnlinkDrive: drive ? unlinkDriveFolder : null,
        onDeleteDrive: drive ? deleteDriveFolder : null,
        onSwipeMove: movable ? () => _swipeMove(node) : null,
      );
    }
    if (node is ImageNode) {
      return PhotoTile(
        node: node,
        onRename: () => _renamePhoto(context, node),
        onJumpTo: widget.onJumpTo,
        onSwipeMove: () => _swipeMove(node),
      );
    }
    if (node is GeoPackageNode) {
      return GeoPackageTile(
        node: node,
        onRename: () => _renameGeoPackage(context, node),
        onSwipeMove: _swipeMove,
        currentDir: widget.currentNode,
      );
    }
    return const SizedBox.shrink();
  }

  // --- ファイルのドラッグ＆ドロップ ---

  /// [global] の下にあるフォルダの行
  FolderNode? _folderAt(Offset global) {
    for (final node in widget.currentNode?.children.whereType<FolderNode>() ?? const <FolderNode>[]) {
      final box = _folderKeys[node]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(global)) return node;
    }
    return null;
  }

  void _onDragOver(Offset global) {
    final folder = _folderAt(global);
    if (_dragging && folder == _dropFolder) return;
    setState(() {
      _dragging = true;
      _dropFolder = folder;
    });
  }

  void _endDrag() {
    if (!_dragging && _dropFolder == null) return;
    setState(() {
      _dragging = false;
      _dropFolder = null;
    });
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    final target = _folderAt(details.globalPosition) ?? widget.currentNode;
    _endDrag();
    if (target is! FolderNode) return;
    await addDroppedFiles(ref, target, details.files);
  }

  // --- UI アクション ---

  /// 名前を聞いて [apply] で変える。やめた・空・同じ名前なら何もしない。失敗は通知する
  Future<void> _rename(
    BuildContext context, {
    required String title,
    required String currentName,
    required String label,
    required Future<void> Function(String name) apply,
  }) async {
    final result = await RenameDialog.show(context, title: title, currentName: currentName, label: label);
    if (result == null || result.isEmpty || result == currentName) return;
    try {
      await apply(result);
    } catch (e) {
      ref.notify(t.layerDrawer.renameFailed(error: '$e'));
    }
  }

  Future<void> _renameFolder(BuildContext context, FolderNode node) => _rename(
        context,
        title: t.layerDrawer.renameFolder,
        currentName: node.name,
        label: t.layerDrawer.newName,
        apply: (name) async {
          final absPath = node.getAbsoluteFilePath();
          if (absPath != null) {
            final newPath = p.join(p.dirname(absPath), name);
            await fs.rename(absPath, newPath);
            await LayerDrawerService.notifySyncedPathChange(node, absPath, newPath);
          }
          node.name = name;
          triggerMapRefresh();
        },
      );

  Future<void> _renamePhoto(BuildContext context, ImageNode node) => _rename(
        context,
        title: t.layerDrawer.renamePhoto,
        currentName: p.basenameWithoutExtension(node.name),
        label: t.layerDrawer.newFileName,
        apply: (name) async {
          await LayerDrawerService.renamePhoto(node, name);
          triggerMapRefresh();
          ref.notify(t.layerDrawer.photoRenamed(name: name));
        },
      );

  /// 読み取り専用レイヤ（shp など）のフォルダ移動。付属ファイルも一緒に動かす（キャッシュは移った先で作り直す）
  Future<void> _moveExternalToFolder(ExternalLayerNode source, FolderNode target) async {
    final targetDir = target.getAbsoluteFilePath();
    if (targetDir == null || p.equals(p.dirname(source.sourcePath), targetDir)) return;
    final files = await source.sourceFiles();
    for (final file in files) {
      if (await fs.exists(p.join(targetDir, p.basename(file)))) {
        ref.notify(t.layerDrawer.alreadyExists(name: p.basename(file), target: target.name));
        return;
      }
    }
    try {
      await ExternalLayerCache.discard(source.geoPackageFile.getAbsolutePath()!);
      for (final file in files) {
        final newPath = p.join(targetDir, p.basename(file));
        await fs.rename(file, newPath);
        await LayerDrawerService.notifySyncedPathChange(source, file, newPath);
      }
      await source.parent?.updateChildren();
      await target.updateChildren();
      final moved = target.children.whereType<ExternalLayerNode>().where((n) => n.name == source.name).firstOrNull;
      await moved?.updateChildren();
      ref.refreshMap();
      ref.notify(t.layerDrawer.movedTo(source: source.name, target: target.name));
    } catch (e) {
      ref.notify(t.layerDrawer.moveFailed(error: '$e'), level: NotificationLevel.error);
    }
  }

  Future<void> _renameGeoPackage(BuildContext context, GeoPackageNode node) => _rename(
        context,
        title: t.layerDrawer.renameGeoPackage,
        currentName: p.basenameWithoutExtension(node.name),
        label: t.layerDrawer.newFileName,
        apply: (name) async {
          final oldPath = node.geoPackageFile.getAbsolutePath();
          final wasExpanded = ref.read(expandedGeoPackagesProvider).isExpanded(oldPath);
          // updateChildren()でnode.parentがnullになるため、先に保持
          final parentNode = node.parent;

          final projectRoot = ref.read(projectRootDirProvider);
          final newFileName = await LayerDrawerService.renameGeoPackage(
            node, name, projectRootDir: projectRoot ?? '',
          );

          if (node is ExternalLayerNode && parentNode != null) {
            // 読み取り専用レイヤ: 開閉はキャッシュのパスで覚えている。元のパスが変わるとキャッシュも変わる
            final newSource = p.join(p.dirname(node.sourcePath), newFileName);
            if (wasExpanded && oldPath != null) {
              ref.read(expandedGeoPackagesProvider.notifier).updatePath(oldPath, ExternalLayerCache.cachePathFor(newSource));
            }
            final renamed = parentNode.children.whereType<ExternalLayerNode>().where((c) => c.sourcePath == newSource).firstOrNull;
            await renamed?.updateChildren();
          } else if (oldPath != null && parentNode != null) {
            final newPath = p.join(p.dirname(oldPath), newFileName);
            if (wasExpanded) {
              ref.read(expandedGeoPackagesProvider.notifier).updatePath(oldPath, newPath);
            }
            // 新しいGeoPackageNodeのレイヤを読み込む
            final renamed = parentNode.children
                .whereType<GeoPackageNode>()
                .where((c) => c.geoPackageFile.getAbsolutePath() == newPath)
                .firstOrNull;
            await renamed?.updateChildren();
          }

          triggerMapRefresh();
          ref.notify(t.layerDrawer.gpkgRenamed(name: newFileName));
        },
      );

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
    final confirm = await showConfirmDialog(
      context,
      title: t.layerDrawer.folder.unlinkDrive,
      content: Text(t.layerDrawer.unlinkDriveConfirm(name: driveRoot.name)),
      confirmLabel: t.layerDrawer.unlink,
      confirmColor: Colors.red,
    );
    if (!confirm || !mounted) return;

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

    ref.notify(t.layerDrawer.driveUnlinked);
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
        ref.notify('$e');
      }
    } else {
      if (!context.mounted) return;
      await _addDriveFolder(context);
    }
  }

  Future<void> _addDriveFolder(BuildContext context) async {
    final urlResult = await DriveUrlInputDialog.show(context);
    if (urlResult == null) return;

    ref.notify(t.layerDrawer.cloningDrive(name: urlResult.folderName));

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
        ref.notify(t.layerDrawer.cloneSuccess(name: urlResult.folderName), level: NotificationLevel.success);
      } else {
        ref.notify(t.layerDrawer.cloneFailed, level: NotificationLevel.error);
      }
    } catch (e) {
      AppLogger.error('[LayerDrawer] Driveフォルダクローンエラー: $e');
      ref.notify(t.common.errorOccurred(error: '$e'), level: NotificationLevel.error);
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
        ref.notify(t.layerDrawer.gpkgCreateFailed);
        return;
      }
      final absPath = newNode.geoPackageFile.getAbsolutePath();
      if (absPath != null) ref.read(expandedGeoPackagesProvider.notifier).addExpanded(absPath);
      triggerMapRefresh();
    } catch (e) {
      ref.notify('$e');
    }
  }

  Future<void> _addPhoto(BuildContext context) async {
    final folder = widget.currentNode as FolderNode;
    final imported = await GalleryImporter.pickAndImport(context, folder, ref: ref);
    if (imported) {
      await folder.updateChildren();
      triggerMapRefresh();
      ref.read(tutorialProvider.notifier).report(const PhotosImported());
    }
  }
}
