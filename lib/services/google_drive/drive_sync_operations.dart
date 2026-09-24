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
/// Root Maps: Drive同期操作のスタンドアロンサービス
/// LayerDrawerやタイトルバーなど、複数のUIから再利用可能
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/global_folder_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../providers/notification_providers.dart';
import '../../services/kmeta_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/dialogs/drive_sign_in_prompt.dart';
import '../../widgets/layer_drawer/sync_merge_dialog.dart';
import 'index.dart';

/// Drive同期操作を提供するサービスクラス
///
/// UI依存（setState等）はコールバックで受け取ることで、
/// LayerDrawer・タイトルバーどちらからでも利用可能。
class DriveSyncOperations {
  /// Riverpod ref（通知システム用）
  final WidgetRef ref;

  /// UI更新コールバック（setState相当）
  final VoidCallback onStateChanged;

  /// 地図リフレッシュコールバック
  final VoidCallback? onMapRefresh;

  DriveSyncOperations({
    required this.ref,
    required this.onStateChanged,
    this.onMapRefresh,
  });

  /// 同期状態を更新（UIのみ、ダイアログなし）
  Future<void> refreshSyncStatus(DriveFolderNode node) async {
    final localPath = node.getAbsoluteFilePath();
    if (localPath == null) return;

    node.syncStatus = SyncStatus.syncing;
    onStateChanged();

    try {
      final syncEngine = SyncEngine();
      final detail = await syncEngine.checkSyncStatusDetail(localPath);
      updateNodeSyncStatus(node, detail.status);
    } catch (e) {
      node.syncStatus = SyncStatus.error;
    }

    onStateChanged();
  }

  /// 同期マージダイアログを開く
  Future<void> openSyncMergeDialog(
    BuildContext context,
    DriveFolderNode node, {
    required SyncMode mode,
  }) async {
    final localPath = node.getAbsoluteFilePath();
    if (localPath == null) return;

    if (!await ensureDriveAuthenticated(context)) {
      AppLogger.debug('[DriveSync] 認証できないので中断');
      return;
    }

    try {
      node.syncStatus = SyncStatus.syncing;
      onStateChanged();

      if (!context.mounted) return;
      unawaited(showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Text(t.drive.checkingChanges),
            ],
          ),
        ),
      ));

      final syncEngine = SyncEngine();
      final entries = await syncEngine.getMergeEntries(localPath);
      AppLogger.debug('[DriveSync] mode=$mode entries=${entries.length} local=$localPath');

      if (context.mounted) Navigator.of(context).pop();

      if (!context.mounted) {
        AppLogger.debug('[DriveSync] contextが外れたので中断');
        return;
      }

      if (entries.isEmpty) {
        // ファイル変更なしでもDriveの新フォルダをローカルに作成
        final foldersCreated = await syncEngine.ensureDriveFolders(localPath);
        node.syncStatus = SyncStatus.synced;
        onStateChanged();
        if (foldersCreated > 0) {
          await updateChildrenRecursive(node);
          onStateChanged();
        }
        ref.read(notificationCenterProvider.notifier).add(
              title: foldersCreated > 0
                  ? t.drive.foldersCreated(count: foldersCreated.toString())
                  : t.drive.noChanges,
              level: NotificationLevel.success,
            );
        return;
      }

      final decisions = await SyncMergeDialog.show(
        context,
        folderName: node.name,
        entries: entries,
        mode: mode,
      );

      if (decisions == null || decisions.isEmpty) {
        final detail = await syncEngine.checkSyncStatusDetail(localPath);
        updateNodeSyncStatus(node, detail.status);
        onStateChanged();
        return;
      }

      node.syncStatus = SyncStatus.syncing;
      onStateChanged();

      final result = await syncEngine.executeMerge(localPath, decisions);

      if (result.success) {
        node.syncStatus = SyncStatus.synced;

        if (result.downloadedCount > 0 || result.deletedCount > 0 || result.movedCount > 0 || result.mergedCount > 0) {
          await updateChildrenRecursive(node);
          onMapRefresh?.call();
          onStateChanged();
        }

        ref.read(notificationCenterProvider.notifier).add(
              title: t.drive.syncComplete(
                  uploaded: result.uploadedCount.toString(),
                  downloaded: result.downloadedCount.toString(),
                  deleted: result.deletedCount.toString(),
                  moved: result.movedCount.toString(),
                ),
              level: NotificationLevel.success,
            );
        if (result.mergedCount > 0) {
          ref.read(notificationCenterProvider.notifier).add(
                title: t.drive.mergedFiles(count: result.mergedCount.toString()),
                level: NotificationLevel.success,
              );
        }
        if (result.conflicts.isNotEmpty) {
          ref.read(notificationCenterProvider.notifier).add(
                title: t.drive.mergeConflicts(count: result.conflicts.length.toString()),
                detail: result.conflicts
                    .map((c) => t.drive.mergeConflictLine(
                          table: c.table,
                          fid: c.fid,
                          theirs: '${c.theirs}',
                          mine: '${c.mine}',
                        ))
                    .join('\n'),
                level: NotificationLevel.warning,
              );
        }
      } else {
        node.syncStatus = SyncStatus.error;
        ref.read(notificationCenterProvider.notifier).add(
              title: t.drive.syncError(error: result.errorMessage ?? ''),
              level: NotificationLevel.error,
            );
      }
    } catch (e) {
      node.syncStatus = SyncStatus.error;
      ref.read(notificationCenterProvider.notifier).add(
            title: t.drive.syncError(error: e.toString()),
            level: NotificationLevel.error,
          );
    }

    onStateChanged();
  }

  /// Drive連携を解除（子ノード付きフォルダ用、ルート以外）
  Future<void> unlinkDriveFolder(
    BuildContext context,
    DriveFolderNode node,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.drive.unlinkDrive),
        content: Text(
          t.drive.unlinkConfirm(name: node.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(t.drive.unlink),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final folderPath = node.getAbsoluteFilePath();
    if (folderPath == null) return;

    await KMetaService.instance.unlinkDrive(folderPath);

    final parentNode = node.parent;
    if (parentNode != null) {
      final index = parentNode.children.indexOf(node);
      if (index >= 0) {
        LayerTreeNode replacement;
        if (parentNode is GlobalFolderNode) {
          replacement = GlobalSubFolderNode(
            node.name,
            basePath: parentNode.globalPath,
            visible: node.visible,
            parent: parentNode,
            children: [],
          );
        } else if (parentNode is GlobalSubFolderNode) {
          replacement = GlobalSubFolderNode(
            node.name,
            basePath: parentNode.basePath,
            visible: node.visible,
            parent: parentNode,
            children: [],
          );
        } else {
          replacement = FolderNode(
            node.name,
            visible: node.visible,
            parent: parentNode,
            children: [],
          );
        }
        parentNode.children[index] = replacement;
        node.parent = null;
      }
    }

    onStateChanged();

    ref.read(notificationCenterProvider.notifier).add(
          title: t.drive.unlinkSuccess,
          level: NotificationLevel.info,
        );
  }

  /// Drive連携フォルダをローカルから完全削除
  Future<void> deleteDriveFolder(
    BuildContext context,
    DriveFolderNode node,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.drive.deleteFolder),
        content: Text(
          t.drive.deleteFolderConfirm(name: node.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(t.common.delete),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final folderPath = node.getAbsoluteFilePath();
    if (folderPath == null) return;

    try {
      if (await fs.isDirectory(folderPath)) {
        await fs.delete(folderPath, recursive: true);
      }
      node.parent?.removeChild(node);
      onStateChanged();

      ref.read(notificationCenterProvider.notifier).add(
            title: t.drive.deleteFolderSuccess(name: node.name),
            level: NotificationLevel.info,
          );
    } catch (e) {
      AppLogger.error('[DriveSyncOps] フォルダ削除エラー: $e');
      ref.read(notificationCenterProvider.notifier).add(
            title: t.drive.deleteFolderError(error: e.toString()),
            level: NotificationLevel.info,
          );
    }
  }

  /// Drive操作前の認証チェック
  /// Drive を叩ける状態にする。無理ならサインインUIを出す
  ///
  /// ⚠ web は `signIn()` だけでは足りない。アカウントが無ければ
  /// **Googleが描画したボタン**が要るし、認可のポップアップは
  /// クリックの直下でしか開けない。どちらも [DriveSignInDialog] が受け持つ。
  Future<bool> ensureDriveAuthenticated(BuildContext context) async {
    final driveService = GoogleDriveService();

    // ⚠ `isDriveApiAvailable` だけ見て通すと、失効した API を掴んだまま
    // 同期に入って 401 を踏む（webは約1時間で失効）。実呼び出しで確かめる。
    if (driveService.isDriveApiAvailable) {
      if (await driveService.ensureUsableApi()) return true;
      // 失効していて取り直しも失敗 → 下のサインイン経路に落とす
    }

    await driveService.initialize();
    if (driveService.isDriveApiAvailable) {
      return true;
    }

    // ⚠ web は**ここで**復元を試すこと。ダイアログを出してからでは遅い。
    // GISのポップアップはユーザー操作の有効時間（Chromeで約5秒）の中でしか
    // 開けず、ダイアログを組み立てているうちに切れてブロックされる
    // （2026-08-28 に `Failed to open popup window` で踏んだ）。
    //
    // 覚えているアドレスがあれば無音で通り、無ければ即座に false が返る。
    // 待たされないので、ここで呼んでも画面が固まったようには見えない。
    if (PlatformCapabilities.isWeb) {
      if (await driveService.restoreWebAuthorization()) return true;
      if (!context.mounted) return false;
      return DriveSignInDialog.show(context);
    }

    ref.read(notificationCenterProvider.notifier).add(
          title: t.drive.signingIn,
          level: NotificationLevel.info,
        );

    if (await driveService.signIn()) return true;

    if (!context.mounted) return false;
    return DriveSignInDialog.show(context);
  }

  /// ノードの同期状態を更新
  static void updateNodeSyncStatus(
    DriveFolderNode node,
    FolderSyncStatus status,
  ) {
    switch (status) {
      case FolderSyncStatus.synced:
        node.syncStatus = SyncStatus.synced;
      case FolderSyncStatus.localChanges:
        node.syncStatus = SyncStatus.localChanges;
      case FolderSyncStatus.remoteChanges:
        node.syncStatus = SyncStatus.remoteChanges;
      case FolderSyncStatus.conflict:
        node.syncStatus = SyncStatus.conflict;
      case FolderSyncStatus.notLinked:
      case FolderSyncStatus.error:
        node.syncStatus = SyncStatus.error;
    }
  }

  /// 子ノードを再帰的に更新（フォルダ・GeoPackage両方）
  static Future<void> updateChildrenRecursive(LayerTreeNode node) async {
    await node.updateChildren();
    for (final child in node.children) {
      if (child is FolderNode) {
        await updateChildrenRecursive(child);
      } else if (child is GeoPackageNode) {
        await child.updateChildren();
        await child.reloadLoadedLayers();
      }
    }
  }
}
