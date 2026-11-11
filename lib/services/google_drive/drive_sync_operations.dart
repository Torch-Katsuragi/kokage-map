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

import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../providers/notification_providers.dart';
import '../../utils/app_logger.dart';
import '../../widgets/dialogs/drive_sign_in_prompt.dart';
import '../../widgets/layer_drawer/common_dialogs.dart';
import '../../widgets/layer_drawer/sync_merge_dialog.dart';
import '../qgis/qgs_read_back.dart';
import '../qgis/qgs_read_back_notice.dart';
import 'drive_folder_local_lifecycle.dart';
import 'drive_merge_notifier.dart';
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

  /// 通知センターに出す
  void _notify(String title, NotificationLevel level) => ref
      .read(notificationCenterProvider.notifier)
      .add(title: title, level: level);

  /// 同期状態を更新（UIのみ、ダイアログなし）
  Future<void> refreshSyncStatus(DriveFolderNode node) async {
    final localPath = node.getAbsoluteFilePath();
    if (localPath == null) return;

    if (DriveTransferRegistry.instance.isBusy(localPath)) {
      node.syncStatus = SyncStatus.syncing;
      onStateChanged();
      return;
    }

    node.syncStatus = SyncStatus.syncing;
    onStateChanged();

    try {
      final driveService = GoogleDriveService();
      if (!driveService.isDriveApiAvailable) {
        await driveService.restoreSessionSilently(userGesture: false);
      }
      final detail = await SyncEngine().checkSyncStatusDetail(localPath);
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

    final registry = DriveTransferRegistry.instance;
    if (registry.isBusy(localPath)) {
      _notify(t.drive.syncInProgress, NotificationLevel.info);
      return;
    }

    if (!await ensureDriveAuthenticated(context)) {
      AppLogger.debug('[DriveSync] 認証できないので中断');
      return;
    }

    // 未完了のクローン（.sync/clone.pending）がある場合はマージダイアログを開かず（誤Push防止）、
    // 即座に Pull を再開して未取得のファイルを落とす
    if (await registry.hasClonePending(localPath)) {
      await _resumePendingClone(node, localPath);
      return;
    }

    // 「変更を確かめています」を出している間 true。失敗したときに閉じ忘れない
    var progressShown = false;
    try {
      node.syncStatus = SyncStatus.syncing;
      onStateChanged();

      if (!context.mounted) return;
      progressShown = true;
      unawaited(
        showDialog(
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
        ),
      );

      final syncEngine = SyncEngine();
      final entries = await syncEngine.getMergeEntries(localPath);
      AppLogger.debug(
        '[DriveSync] mode=$mode entries=${entries.length} local=$localPath',
      );

      progressShown = false;
      if (context.mounted) Navigator.of(context).pop();

      if (!context.mounted) {
        AppLogger.debug('[DriveSync] contextが外れたので中断');
        return;
      }

      if (entries.isEmpty) {
        await _handleNoFileChanges(syncEngine, node, localPath);
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

      await _executeInteractiveMerge(syncEngine, node, localPath, decisions);
    } catch (e) {
      if (progressShown && context.mounted) Navigator.of(context).pop();
      node.syncStatus = SyncStatus.error;
      final errMsg = t.drive.syncError(error: e.toString());
      _notify(errMsg, NotificationLevel.error);
    }

    onStateChanged();
  }

  Future<void> _resumePendingClone(
    DriveFolderNode node,
    String localPath,
  ) async {
    final notifier = ref.read(notificationCenterProvider.notifier);
    node.syncStatus = SyncStatus.syncing;
    onStateChanged();

    await runTrackedDriveTransfer(
      localPath: localPath,
      driveId: node.driveId,
      folderName: node.name,
      notifier: notifier,
      startTitle: t.drive.resumingClone,
      startDetail: node.name,
      action: () async {
        final result = await SyncEngine().pullFolder(
          localPath,
          showOsNotification: true,
        );
        if (result.success) {
          DriveTransferRegistry.instance.updateProgress(
            localPath,
            const SyncProgress.finalizing(),
            folderName: node.name,
            showOsNotification: true,
          );
          await _refreshAndNotify(ref, node);
          onMapRefresh?.call();
          node.syncStatus = SyncStatus.synced;
          return TrackedTransferOutcome(
            success: true,
            title: t.drive.downloadCompleteTitle(name: node.name),
            detail: t.drive.downloadCompleteDetail(
              count: result.downloadedCount.toString(),
            ),
            level: NotificationLevel.success,
          );
        }
        node.syncStatus = SyncStatus.error;
        final errMsg = result.errorMessage ?? '';
        return TrackedTransferOutcome(
          success: false,
          title: t.drive.downloadFailedTitle(name: node.name),
          detail: errMsg,
          errorMessage: errMsg,
          level: NotificationLevel.error,
        );
      },
      onUnhandledError: (e) {
        node.syncStatus = SyncStatus.error;
        return TrackedTransferOutcome(
          success: false,
          title: t.drive.downloadFailedTitle(name: node.name),
          detail: '$e',
          errorMessage: '$e',
          level: NotificationLevel.error,
        );
      },
    );
    onStateChanged();
  }

  Future<void> _handleNoFileChanges(
    SyncEngine syncEngine,
    DriveFolderNode node,
    String localPath,
  ) async {
    // ファイル変更なしでもDriveの新フォルダをローカルに作成
    final foldersCreated = await syncEngine.ensureDriveFolders(localPath);
    node.syncStatus = SyncStatus.synced;
    onStateChanged();
    if (foldersCreated > 0) {
      await _refreshAndNotify(ref, node);
      onStateChanged();
    }
    _notify(
      foldersCreated > 0
          ? t.drive.foldersCreated(count: foldersCreated.toString())
          : t.drive.noChanges,
      NotificationLevel.success,
    );
  }

  Future<void> _executeInteractiveMerge(
    SyncEngine syncEngine,
    DriveFolderNode node,
    String localPath,
    List<MergeDecision> decisions,
  ) async {
    final notifier = ref.read(notificationCenterProvider.notifier);
    node.syncStatus = SyncStatus.syncing;
    onStateChanged();

    SyncResult? succeededResult;
    await runTrackedDriveTransfer(
      localPath: localPath,
      driveId: node.driveId,
      folderName: node.name,
      notifier: notifier,
      startTitle: t.drive.downloadingTitle(name: node.name),
      action: () async {
        final result = await syncEngine.executeMerge(
          localPath,
          decisions,
          showOsNotification: true,
        );
        if (result.success) {
          // 行単位で合わせられなかったファイルは衝突のまま（端末かクラウドを選び直してもらう）。
          // 置き場所が見つからず上げられなかったものがあればエラー（通知は notifyMerge）
          node.syncStatus = result.failedUploads.isNotEmpty
              ? SyncStatus.error
              : result.failedMerges.isEmpty
                  ? SyncStatus.synced
                  : SyncStatus.conflict;

          if (result.downloadedCount > 0 ||
              result.deletedCount > 0 ||
              result.movedCount > 0 ||
              result.mergedCount > 0) {
            DriveTransferRegistry.instance.updateProgress(
              localPath,
              const SyncProgress.finalizing(),
              folderName: node.name,
              showOsNotification: true,
            );
            await _refreshAndNotify(ref, node);
            onMapRefresh?.call();
            onStateChanged();
          }
          succeededResult = result;
          return TrackedTransferOutcome(
            success: true,
            title: t.drive.syncComplete(
              uploaded: result.uploadedCount.toString(),
              downloaded: result.downloadedCount.toString(),
              deleted: result.deletedCount.toString(),
              moved: result.movedCount.toString(),
            ),
            level: NotificationLevel.success,
          );
        }

        node.syncStatus = SyncStatus.error;
        final errMsg = t.drive.syncError(error: result.errorMessage ?? '');
        return TrackedTransferOutcome(
          success: false,
          title: errMsg,
          errorMessage: result.errorMessage,
          level: NotificationLevel.error,
        );
      },
      onUnhandledError: (e) {
        node.syncStatus = SyncStatus.error;
        final errMsg = t.drive.syncError(error: e.toString());
        return TrackedTransferOutcome(
          success: false,
          title: errMsg,
          errorMessage: '$e',
          level: NotificationLevel.error,
        );
      },
    );

    if (succeededResult != null) {
      notifyMerge(
        ref,
        succeededResult!,
        afterRestore: () async {
          await _refreshAndNotify(ref, node);
          onMapRefresh?.call();
        },
      );
    }
  }

  /// 行単位マージの結果を通知する（手動の同期と自動同期で共通）
  /// [afterRestore] は「クラウドの値に戻す」を押して書き戻したあとに呼ぶ（地図の読み直しなど）
  static void notifyMerge(
    WidgetRef ref,
    SyncResult result, {
    Future<void> Function()? afterRestore,
  }) =>
      notifyMergeResult(ref, result, afterRestore: afterRestore);

  /// 共有フォルダセット（JSON）のリスト再取得＆差分同期を実行
  Future<void> syncFolderSet(
    BuildContext context,
    DriveFolderSetNode node,
  ) async {
    final localPath = node.getAbsoluteFilePath();
    if (localPath == null) return;

    final registry = DriveTransferRegistry.instance;
    if (registry.isBusy(localPath)) {
      _notify(t.drive.syncInProgress, NotificationLevel.info);
      return;
    }

    if (!await ensureDriveAuthenticated(context)) {
      return;
    }

    final notifier = ref.read(notificationCenterProvider.notifier);
    node.syncStatus = SyncStatus.syncing;
    onStateChanged();

    String? extraKeptWarning;
    await runTrackedDriveTransfer(
      localPath: localPath,
      driveId: node.driveId,
      folderName: node.name,
      notifier: notifier,
      startTitle: t.drive.downloadingTitle(name: node.name),
      action: () async {
        final result = await DriveFolderSetService().reconcileSet(
          localSetPath: localPath,
          manifestFileId: node.manifestFileId,
          setNode: node,
          showOsNotification: true,
        );
        if (result.success) {
          final summary = formatFolderSetSyncSummary(result);
          node.syncStatus = summary.success ? SyncStatus.synced : SyncStatus.error;
          await DriveFolderSetService.reloadFolderSetNode(node);
          onMapRefresh?.call();
          onStateChanged();
          extraKeptWarning = summary.extraKeptWarning;
          return TrackedTransferOutcome(
            success: summary.success,
            title: summary.title,
            level: summary.level,
          );
        }

        node.syncStatus = SyncStatus.error;
        onStateChanged();
        final errMsg = t.drive.syncError(error: result.errorMessage ?? '');
        return TrackedTransferOutcome(
          success: false,
          title: errMsg,
          errorMessage: result.errorMessage,
          level: NotificationLevel.error,
        );
      },
      onUnhandledError: (e) {
        node.syncStatus = SyncStatus.error;
        onStateChanged();
        final errMsg = t.drive.syncError(error: '$e');
        return TrackedTransferOutcome(
          success: false,
          title: errMsg,
          errorMessage: '$e',
          level: NotificationLevel.error,
        );
      },
    );

    if (extraKeptWarning != null) {
      _notify(extraKeptWarning!, NotificationLevel.warning);
    }
  }

  /// Drive連携を解除（子ノード付きフォルダ用、ルート以外）
  Future<void> unlinkDriveFolder(
    BuildContext context,
    FolderNode node,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.drive.unlinkDrive,
      content: Text(t.drive.unlinkConfirm(name: node.name)),
      confirmLabel: t.drive.unlink,
      confirmColor: Colors.red,
    );
    if (!confirmed) return;

    if (!await unlinkDriveFolderNodeInTree(node)) return;

    onMapRefresh?.call();
    onStateChanged();

    _notify(t.drive.unlinkSuccess, NotificationLevel.info);
  }

  /// Drive連携フォルダをローカルから完全削除
  Future<void> deleteDriveFolder(
    BuildContext context,
    FolderNode node,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.drive.deleteFolder,
      content: Text(t.drive.deleteFolderConfirm(name: node.name)),
      confirmLabel: t.common.delete,
      confirmColor: Colors.red,
    );
    if (!confirmed) return;

    if (node.getAbsoluteFilePath() == null) return;

    try {
      await deleteDriveFolderLocally(node);
      onMapRefresh?.call();
      onStateChanged();

      _notify(
        t.drive.deleteFolderSuccess(name: node.name),
        NotificationLevel.info,
      );
    } catch (e) {
      AppLogger.error('[DriveSyncOps] フォルダ削除エラー: $e');
      _notify(
        t.drive.deleteFolderError(error: e.toString()),
        NotificationLevel.error,
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

    _notify(t.drive.signingIn, NotificationLevel.info);

    if (await driveService.signIn()) return true;

    if (!context.mounted) return false;
    return DriveSignInDialog.show(context);
  }

  /// ノードの同期状態を更新
  static void updateNodeSyncStatus(
    FolderNode node,
    FolderSyncStatus status,
  ) {
    final next = switch (status) {
      FolderSyncStatus.synced => SyncStatus.synced,
      FolderSyncStatus.localChanges => SyncStatus.localChanges,
      FolderSyncStatus.remoteChanges => SyncStatus.remoteChanges,
      FolderSyncStatus.conflict => SyncStatus.conflict,
      FolderSyncStatus.notLinked || FolderSyncStatus.error => SyncStatus.error,
    };
    if (node is DriveFolderNode) {
      node.syncStatus = next;
    } else if (node is DriveFolderSetNode) {
      node.syncStatus = next;
    }
  }

  /// 同期で落としたあとの更新: ツリーを読み直し、QGIS で保存された `.qgs` が届いていれば読み戻す。
  ///
  /// 読み戻しは開いたときにしか走らなかったので、QGIS で直した `.qgs` が Drive 越しに届いても、
  /// 次にアプリが設定や `.qgs` を書いた時点で QGIS 側の変更が消えていた（2026-09-29）
  ///
  /// 読み戻したときはその結果を返す（通知は呼び手。[notifyQgsReadBack]）
  static Future<QgsReadBackResult?> refreshAfterSync(LayerTreeNode node) async {
    await updateChildrenRecursive(node);
    if (node is! FolderNode) return null;
    try {
      final r = await const QgsReadBack().run(node);
      if (r != null) {
        AppLogger.debug(
          '[DriveSync] 同期で届いた ${r.fileName} を読み戻した（View ${r.importedViewCount} 個）',
        );
        await updateChildrenRecursive(node);
      }
      return r;
    } on Object catch (e) {
      AppLogger.debug('[DriveSync] 読み戻しに失敗: $e');
      return null;
    }
  }

  /// [refreshAfterSync] して、読み戻したら通知する（手動の同期）
  static Future<void> _refreshAndNotify(
    WidgetRef ref,
    LayerTreeNode node,
  ) async {
    final r = await refreshAfterSync(node);
    if (r != null) notifyQgsReadBack(ref, r);
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
