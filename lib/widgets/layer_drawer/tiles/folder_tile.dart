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
import '../../../models/nodes/folder_node.dart';
import '../../../presentation/node_presenter.dart';
import '../../../providers/ui_state_providers.dart';
import '../../dialogs/drive_qr_dialog.dart';
import '../common_dialogs.dart';
import '../drawer_row.dart';
import '../sync_merge_dialog.dart';
import 'drag_feedback_card.dart';

/// フォルダの行。DriveFolderNode は同期の状態を添え、長押しメニューに同期の操作を出す（同期できない環境では QR だけ）
class FolderTile extends ConsumerWidget {
  final FolderNode node;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final Future<void> Function(BuildContext, DriveFolderNode, {required SyncMode mode})? onSyncMerge;
  final Future<void> Function(DriveFolderNode)? onRefreshSync;
  final Future<void> Function(BuildContext, DriveFolderNode)? onUnlinkDrive;
  final Future<void> Function(BuildContext, DriveFolderNode)? onDeleteDrive;

  /// 名前変更・削除のメニューを出さない（「この端末」とグローバルフォルダ本体）。
  /// 実体の場所はアプリが決めているので、ツリーから動かしたり消したりさせない
  final bool fixed;

  /// ドラッグで動かせるとき（ローカルのフォルダ）。長押しして動かさずに離せばメニュー
  final Object? dragData;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnded;

  const FolderTile({
    super.key,
    required this.node,
    required this.onTap,
    this.onRename,
    this.onSyncMerge,
    this.onRefreshSync,
    this.onUnlinkDrive,
    this.onDeleteDrive,
    this.fixed = false,
    this.dragData,
    this.onDragStarted,
    this.onDragEnded,
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
    return DrawerRow(
      dimmed: dimmed,
      leading: drive != null && _canSync
          ? NodePresenter.buildIconWithSyncOverlay(drive, size: 22, syncStatus: drive.syncStatus)
          : Icon(NodePresenter.getIcon(node), size: 22, color: dimmed ? Colors.black26 : NodePresenter.getColor(node)),
      title: NodePresenter.getDisplayName(node),
      subtitle: drive == null
          ? null
          : _canSync
              ? _buildSyncSubtitle(context, drive)
              : Text(t.layerDrawer.folder.pcSyncDisabled, style: const TextStyle(fontSize: 13, color: Colors.grey)),
      eye: VisibilityEye(
        visible: node.visible,
        effective: node.parent?.isVisibleRecursive() ?? true,
        onToggle: () {
          node.visible = !node.visible;
          node.persistVisibility();
          ref.read(featureRefreshTriggerProvider.notifier).trigger();
        },
      ),
      onTap: onTap,
      menu: () => _menuItems(drive),
      onMenu: (v) => _onMenu(context, ref, v, drive),
      dragData: dragData,
      dragFeedback: dragData == null ? null : DragFeedbackCard(node: node),
      onDragStarted: onDragStarted,
      onDragEnded: onDragEnded,
    );
  }

  List<RowMenuItem> _menuItems(DriveFolderNode? drive) {
    if (drive == null) {
      if (fixed) return const [];
      return [
        RowMenuItem('rename', t.layerDrawer.folder.rename, icon: Icons.edit),
        RowMenuItem('delete', t.layerDrawer.folder.delete, icon: Icons.delete_outline, danger: true),
      ];
    }
    // 同期できない環境でも、QR で渡すことはできる（事務所の web で整えた dir を現場の Android に渡す出口）
    if (!_canSync) return [RowMenuItem('qr', t.driveQr.menu, icon: Icons.qr_code_2)];
    return [
      if (!drive.isReadOnly) RowMenuItem('upload', t.layerDrawer.folder.upload, icon: Icons.cloud_upload),
      RowMenuItem('download', t.layerDrawer.folder.download, icon: Icons.cloud_download),
      RowMenuItem('refresh', t.layerDrawer.folder.refreshStatus, icon: Icons.refresh),
      // 連携dirは自己完結した共有単位。QRで丸ごと渡せる
      RowMenuItem('qr', t.driveQr.menu, icon: Icons.qr_code_2),
      RowMenuItem('unlink', t.layerDrawer.folder.unlinkDrive, icon: Icons.link_off, danger: true, dividerBefore: true),
      RowMenuItem('delete_drive', t.layerDrawer.folder.deleteFolderAll, icon: Icons.delete_forever, danger: true),
    ];
  }

  Future<void> _onMenu(BuildContext context, WidgetRef ref, String value, DriveFolderNode? drive) async {
    switch (value) {
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
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      },
    );
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
