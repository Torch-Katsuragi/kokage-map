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
/// Root Maps: フォルダタイルウィジェット
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/fs/k_file_system.dart';
import '../../../core/platform_capabilities.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/nodes/drive_folder_node.dart';
import '../../../models/nodes/drive_folder_set_node.dart';
import '../../../models/nodes/folder_node.dart';
import '../../../presentation/node_presenter.dart';
import '../../../providers/notification_providers.dart';
import '../../../services/google_drive/drive_transfer_registry.dart';
import '../../../services/google_drive/sync_progress.dart';
import '../../dialogs/drive_qr_dialog.dart';
import '../../external_layer_actions.dart';
import '../add_files_action.dart';
import '../common_dialogs.dart';
import '../drawer_row.dart';
import '../sync_merge_dialog.dart';

/// フォルダの行。DriveFolderNode は同期の状態を添え、長押しメニューに同期の操作を出す（同期できない環境では QR だけ）
class FolderTile extends ConsumerWidget {
  final FolderNode node;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final Future<void> Function(BuildContext, DriveFolderNode, {required SyncMode mode})? onSyncMerge;
  final Future<void> Function(DriveFolderNode)? onRefreshSync;
  final Future<void> Function(BuildContext, DriveFolderSetNode)? onSyncFolderSet;
  final Future<void> Function(BuildContext, FolderNode)? onUnlinkDrive;
  final Future<void> Function(BuildContext, FolderNode)? onDeleteDrive;



  /// 名前変更・削除のメニューを出さない（「この端末」とグローバルフォルダ本体）。
  /// 実体の場所はアプリが決めているので、ツリーから動かしたり消したりさせない
  final bool fixed;

  /// 左スワイプの「移動」（ローカルのフォルダだけ）
  final VoidCallback? onSwipeMove;

  /// ファイルをこの行の上に落としている（光らせる）
  final bool isDropTarget;

  const FolderTile({
    super.key,
    required this.node,
    required this.onTap,
    this.onRename,
    this.onSyncMerge,
    this.onRefreshSync,
    this.onSyncFolderSet,
    this.onUnlinkDrive,
    this.onDeleteDrive,
    this.fixed = false,
    this.onSwipeMove,
    this.isDropTarget = false,
  });

  /// このプラットフォームで実際に同期できるか。
  ///
  /// 2026-08-27 に web を含むようになった（Drive連携から `dart:io` を撤去）。
  /// できないときは「QRで渡すだけ」のタイルに落ちる。
  static bool get _canSync => PlatformCapabilities.supportsDriveSync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dimmed = !node.isVisibleRecursive();
    final drive = node is DriveFolderNode ? node as DriveFolderNode : null;
    final folderSet = node is DriveFolderSetNode ? node as DriveFolderSetNode : null;
    final absPath = (drive ?? folderSet)?.getAbsoluteFilePath();

    if ((drive != null || folderSet != null) && absPath != null && _canSync) {
      return ValueListenableBuilder<SyncProgress?>(
        valueListenable: DriveTransferRegistry.instance.progressOf(absPath),
        builder: (context, progress, _) {
          final rawStatus = drive?.syncStatus ?? folderSet!.syncStatus;
          final effectiveStatus =
              progress != null ? SyncStatus.syncing : rawStatus;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DrawerRow(
                dimmed: dimmed,
                leading: NodePresenter.buildIconWithSyncOverlay(
                  node,
                  size: 22,
                  syncStatus: effectiveStatus,
                ),
                title: NodePresenter.getDisplayName(node),
                selected: isDropTarget,
                subtitle: isDropTarget
                    ? Text(
                        t.layerDrawer.folder.dropFilesHere,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.blue,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : progress != null
                    ? _buildProgressSubtitle(progress)
                    : drive != null
                    ? _buildSyncSubtitle(context, drive)
                    : _buildFolderSetSubtitle(folderSet!),
                eye: nodeVisibilityEye(ref, node),
                onTap: onTap,
                menu: () => _menuItems(drive, folderSet: folderSet, isBusy: progress != null),
                onMenu: (v) => _onMenu(context, ref, v, drive, folderSet: folderSet),
                onSwipeMove: onSwipeMove,
              ),
              if (progress != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: LinearProgressIndicator(
                    value: progress.fraction,
                    minHeight: 2,
                  ),
                ),
            ],
          );
        },
      );
    }

    return DrawerRow(
      dimmed: dimmed,
      leading: drive != null && _canSync
          ? NodePresenter.buildIconWithSyncOverlay(drive, size: 22, syncStatus: drive.syncStatus)
          : Icon(NodePresenter.getIcon(node), size: 22, color: dimmed ? Colors.black26 : NodePresenter.getColor(node)),
      title: NodePresenter.getDisplayName(node),
      selected: isDropTarget,
      subtitle: isDropTarget
          ? Text(t.layerDrawer.folder.dropFilesHere,
              style: const TextStyle(fontSize: 13, color: Colors.blue, fontWeight: FontWeight.bold))
          : drive == null
          ? null
          : _canSync
              ? _buildSyncSubtitle(context, drive)
              : Text(t.layerDrawer.folder.pcSyncDisabled, style: const TextStyle(fontSize: 13, color: Colors.grey)),
      eye: nodeVisibilityEye(ref, node),
      onTap: onTap,
      menu: () => _menuItems(drive, folderSet: folderSet),
      onMenu: (v) => _onMenu(context, ref, v, drive, folderSet: folderSet),
      onSwipeMove: onSwipeMove,
    );
  }

  List<RowMenuItem> _menuItems(
    DriveFolderNode? drive, {
    DriveFolderSetNode? folderSet,
    bool isBusy = false,
  }) {
    if (folderSet != null) {
      return [
        if (!isBusy && _canSync)
          RowMenuItem('refresh_set', t.layerDrawer.folder.refreshStatus, icon: Icons.refresh),
        RowMenuItem('qr_set', t.driveQr.menu, icon: Icons.qr_code_2),
        if (!isBusy && _canSync) ...[
          RowMenuItem('unlink_set', t.layerDrawer.folder.unlinkDrive, icon: Icons.link_off, danger: true, dividerBefore: true),
          RowMenuItem('delete_drive_set', t.layerDrawer.folder.deleteFolderAll, icon: Icons.delete_forever, danger: true),
        ],
      ];
    }
    if (drive == null) {
      if (fixed) return const [];
      return [
        if (canAddFilesTo(node)) RowMenuItem('add_files', t.layerDrawer.folder.addFiles, icon: Icons.note_add_outlined),
        _convertAllItem(null),
        RowMenuItem('rename', t.layerDrawer.folder.rename, icon: Icons.edit),
        RowMenuItem('delete', t.layerDrawer.folder.delete, icon: Icons.delete_outline, danger: true),
      ];
    }
    // 同期できない環境でも、QR で渡すことはできる（事務所の web で整えた dir を現場の Android に渡す出口）
    if (!_canSync) {
      return [
        if (!drive.isReadOnly) RowMenuItem('add_files', t.layerDrawer.folder.addFiles, icon: Icons.note_add_outlined),
        _convertAllItem(drive),
        RowMenuItem('qr', t.driveQr.menu, icon: Icons.qr_code_2),
      ];
    }
    if (isBusy) {
      return [
        RowMenuItem('qr', t.driveQr.menu, icon: Icons.qr_code_2),
      ];
    }
    return [
      if (!drive.isReadOnly) RowMenuItem('add_files', t.layerDrawer.folder.addFiles, icon: Icons.note_add_outlined),
      _convertAllItem(drive),
      if (!drive.isReadOnly) RowMenuItem('upload', t.layerDrawer.folder.upload, icon: Icons.cloud_upload),
      RowMenuItem('download', t.layerDrawer.folder.download, icon: Icons.cloud_download),
      RowMenuItem('refresh', t.layerDrawer.folder.refreshStatus, icon: Icons.refresh),
      // 連携dirは自己完結した共有単位。QRで丸ごと渡せる
      RowMenuItem('qr', t.driveQr.menu, icon: Icons.qr_code_2),
      RowMenuItem('unlink', t.layerDrawer.folder.unlinkDrive, icon: Icons.link_off, danger: true, dividerBefore: true),
      RowMenuItem('delete_drive', t.layerDrawer.folder.deleteFolderAll, icon: Icons.delete_forever, danger: true),
    ];
  }

  /// 「中のファイルをgpkgに変換」（読み取り専用の Drive フォルダでは複製）。直下の shp・GeoJSON などをまとめて変換する
  RowMenuItem _convertAllItem(DriveFolderNode? drive) => (drive?.isReadOnly ?? false)
      ? RowMenuItem('convert_all', t.layerDrawer.folder.copyAll, icon: Icons.copy_all)
      : RowMenuItem('convert_all', t.layerDrawer.folder.convertAll, icon: Icons.transform);

  Future<void> _onMenu(
    BuildContext context,
    WidgetRef ref,
    String value,
    DriveFolderNode? drive, {
    DriveFolderSetNode? folderSet,
  }) async {
    switch (value) {
      case 'add_files':
        await pickAndAddFiles(ref, node);
      case 'convert_all':
        await convertFolderExternalLayers(
          context,
          ref.read(notificationCenterProvider.notifier),
          node,
          onChanged: ref.refreshMap,
        );
      case 'rename':
        onRename?.call();
      case 'delete':
        await _handleDelete(context, ref);
      case 'upload':
        await onSyncMerge?.call(context, drive!, mode: SyncMode.upload);
      case 'download':
        await onSyncMerge?.call(context, drive!, mode: SyncMode.download);
      case 'refresh':
        await onRefreshSync?.call(drive!);
      case 'qr':
        await DriveQrDialog.show(context, folderName: drive!.name, driveUrl: drive.driveUrl);
      case 'unlink':
        await onUnlinkDrive?.call(context, drive!);
      case 'delete_drive':
        await onDeleteDrive?.call(context, drive!);
      case 'refresh_set':
        await onSyncFolderSet?.call(context, folderSet!);
      case 'qr_set':
        await DriveQrDialog.show(context, folderName: folderSet!.name, driveUrl: folderSet.driveUrl);
      case 'unlink_set':
        await onUnlinkDrive?.call(context, folderSet!);
      case 'delete_drive_set':
        await onDeleteDrive?.call(context, folderSet!);
    }
  }

  Future<void> _handleDelete(BuildContext context, WidgetRef ref) async {
    final absPath = node.getAbsoluteFilePath();
    await confirmAndExecute(
      context,
      ref: ref,
      title: t.layerDrawer.folder.deleteTitle,
      content: Text(t.layerDrawer.folder.deleteConfirm(name: node.name)),
      confirmLabel: t.common.delete,
      successMessage: t.layerDrawer.folder.deleted(name: node.name),
      execute: () async {
        if (absPath != null && await fs.exists(absPath)) {
          await fs.delete(absPath, recursive: true);
        }
        await node.dispose();
        ref.refreshMap();
      },
    );
  }

  Widget _buildProgressSubtitle(SyncProgress progress) {
    final String label;
    switch (progress.phase) {
      case SyncPhase.scanning:
        label = t.drive.scanningFolder;
      case SyncPhase.transferring:
        final pct = progress.percent;
        final bytes = progress.formattedBytes;
        final file = progress.currentFileName;
        label = [
          if (pct != null) '$pct%',
          if (bytes != null) '($bytes)',
          if (file != null && file.isNotEmpty) '· $file',
          if (pct == null && bytes == null) t.layerDrawer.folder.syncing,
        ].join(' ');
      case SyncPhase.finalizing:
        label = t.drive.finalizingData;
    }
    return Text(
      label,
      style: const TextStyle(fontSize: 12, color: Colors.blue),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildFolderSetSubtitle(DriveFolderSetNode setNode) {
    final (text, color) = switch (setNode.syncStatus) {
      SyncStatus.synced => (t.layerDrawer.folder.synced, Colors.green),
      SyncStatus.syncing => (t.layerDrawer.folder.syncing, Colors.blue),
      SyncStatus.error => (t.layerDrawer.folder.syncError, Colors.red),
      _ => (t.layerDrawer.folder.driveLinked, Colors.grey),
    };
    return Text(text, style: TextStyle(fontSize: 13, color: color));
  }

  Widget _buildSyncSubtitle(BuildContext context, DriveFolderNode driveNode) {
    final (text, color, icon) = switch (driveNode.syncStatus) {
      SyncStatus.synced => (t.layerDrawer.folder.synced, Colors.green, null),
      SyncStatus.localChanges => (t.layerDrawer.folder.localChanges, Colors.orange, null),
      SyncStatus.remoteChanges => (t.layerDrawer.folder.remoteChanges, Colors.blue, null),
      SyncStatus.conflict => (t.layerDrawer.folder.conflict, Colors.red, Icons.warning_amber_rounded),
      SyncStatus.syncing => (t.layerDrawer.folder.syncing, Colors.blue, null),
      SyncStatus.error => (t.layerDrawer.folder.syncError, Colors.red, null),
      SyncStatus.unknown => (driveNode.isReadOnly ? t.layerDrawer.folder.readOnly : t.layerDrawer.folder.driveLinked, Colors.grey, null),
    };
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
        Text(text, style: TextStyle(fontSize: 13, color: color)),
      ],
    );
    if (driveNode.syncStatus == SyncStatus.conflict) {
      return GestureDetector(
        onTap: () => onSyncMerge?.call(context, driveNode, mode: SyncMode.download),
        child: child,
      );
    }
    return child;
  }
}
