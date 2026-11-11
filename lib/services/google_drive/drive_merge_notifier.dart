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
/// Drive同期・行単位マージ・フォルダセット同期の通知整形と転送ライフサイクル共通化ヘルパー
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import 'conflict_restorer.dart';
import 'drive_folder_set_manifest.dart';
import 'drive_transfer_registry.dart';
import 'gpkg_merger.dart';
import 'sync_engine.dart';

/// 進捗トラッキング付き転送ブロックの完了情報
class TrackedTransferOutcome {
  final bool success;
  final String title;
  final String? detail;
  final String? errorMessage;
  final NotificationLevel level;

  const TrackedTransferOutcome({
    required this.success,
    required this.title,
    this.detail,
    this.errorMessage,
    required this.level,
  });
}

/// [DriveTransferRegistry] と [NotificationCenter] の開始・完了ライフサイクルを対で管理して [action] を実行する
Future<void> runTrackedDriveTransfer({
  required String localPath,
  String? driveId,
  required String folderName,
  required NotificationCenter notifier,
  required String startTitle,
  String? startDetail,
  required Future<TrackedTransferOutcome> Function() action,
  required TrackedTransferOutcome Function(Object error) onUnhandledError,
}) async {
  final registry = DriveTransferRegistry.instance;
  final transferKey = DriveTransferRegistry.normalizeKey(localPath);

  registry.beginTransfer(
    localPath,
    folderName: folderName,
    showOsNotification: true,
  );
  notifier.startTransfer(
    transferKey: transferKey,
    title: startTitle,
    detail: startDetail,
  );

  TrackedTransferOutcome outcome;
  try {
    outcome = await action();
  } catch (e) {
    outcome = onUnhandledError(e);
  }

  registry.endTransfer(
    localPath,
    driveId: driveId,
    folderName: folderName,
    success: outcome.success,
    completionTitle: outcome.title,
    completionBody: outcome.detail,
    errorMessage: outcome.errorMessage,
    showOsNotification: true,
  );
  notifier.completeTransfer(
    transferKey: transferKey,
    title: outcome.title,
    detail: outcome.detail,
    level: outcome.level,
  );
}

/// 共有フォルダセット同期結果から通知メッセージを組み立てる
({
  bool success,
  String title,
  NotificationLevel level,
  String? extraKeptWarning,
}) formatFolderSetSyncSummary(FolderSetSyncResult result) {
  final hasFailures = result.failedItems.isNotEmpty;
  final hasChanges = result.addedCount > 0 || result.removedCount > 0;
  final keptOnly =
      !hasChanges && !hasFailures && result.keptWithLocalChanges.isNotEmpty;

  final doneMsg = hasFailures
      ? t.drive.syncError(error: result.failedItems.join('、'))
      : hasChanges
          ? t.drive.folderSetUpdated(
              added: result.addedCount.toString(),
              removed: result.removedCount.toString(),
            )
          : keptOnly
              ? t.drive.folderSetKeptLocalChanges(
                  names: result.keptWithLocalChanges.join('、'),
                )
              : t.drive.noChanges;

  final extraKeptWarning =
      ((hasChanges || hasFailures) && result.keptWithLocalChanges.isNotEmpty)
          ? t.drive.folderSetKeptLocalChanges(
              names: result.keptWithLocalChanges.join('、'),
            )
          : null;

  return (
    success: !hasFailures,
    title: doneMsg,
    level: (hasFailures || keptOnly)
        ? NotificationLevel.warning
        : NotificationLevel.success,
    extraKeptWarning: extraKeptWarning,
  );
}

/// 行単位マージの結果を通知する（手動の同期と自動同期で共通）。
/// [afterRestore] は「クラウドの値に戻す」を押して書き戻したあとに呼ぶ（地図の読み直しなど）。
void notifyMergeResult(
  WidgetRef ref,
  SyncResult result, {
  Future<void> Function()? afterRestore,
}) {
  final notifier = ref.read(notificationCenterProvider.notifier);

  if (result.failedUploads.isNotEmpty) {
    notifier.add(
      title: t.drive.uploadFolderMissing(
        count: result.failedUploads.length.toString(),
      ),
      detail: result.failedUploads.join('\n'),
      level: NotificationLevel.warning,
    );
  }
  if (result.failedMerges.isNotEmpty) {
    notifier.add(
      title: t.drive.mergeFailed(
        count: result.failedMerges.length.toString(),
      ),
      detail: result.failedMerges.join('\n'),
      level: NotificationLevel.warning,
    );
  }
  if (result.mergedCount > 0) {
    notifier.add(
      title: t.drive.mergedFiles(count: result.mergedCount.toString()),
      level: NotificationLevel.success,
    );
  }
  if (result.settingConflicts.isNotEmpty) {
    notifier.add(
      title: t.drive.settingConflicts(
        count: result.settingConflicts.length.toString(),
      ),
      detail: result.settingConflicts
          .map(
            (c) =>
                '${c.dirPath == null ? '' : '${p.basename(c.dirPath!)}: '}${c.path}',
          )
          .join('\n'),
      level: NotificationLevel.warning,
      actionLabel: t.drive.restoreTheirs,
      onAction: () => _runRestoreAction(
        ref,
        () => ConflictRestorer.restoreSettings(result.settingConflicts),
        afterRestore,
      ),
    );
  }
  if (result.conflicts.isNotEmpty) {
    final anyRestorable = result.conflicts.any((c) => c.restorable);
    notifier.add(
      title: t.drive.mergeConflicts(
        count: result.conflicts.length.toString(),
      ),
      detail: result.conflicts.map(_formatRowConflictLine).join('\n'),
      level: NotificationLevel.warning,
      actionLabel: anyRestorable ? t.drive.restoreTheirs : null,
      onAction: anyRestorable
          ? () => _runRestoreAction(
                ref,
                () => ConflictRestorer.restoreTheirs(result.conflicts),
                afterRestore,
              )
          : null,
    );
  }
}

String _formatRowConflictLine(GpkgConflict c) {
  if (c.theirsDeleted) {
    return t.drive.mergeConflictDeletedLine(
      table: c.table,
      fid: c.fid,
      mine: '${c.mine}',
    );
  }
  if (c.mineDeleted) {
    return t.drive.mergeConflictMineDeletedLine(
      table: c.table,
      fid: c.fid,
      theirs: '${c.theirs}',
    );
  }
  return t.drive.mergeConflictLine(
    table: c.table,
    fid: c.fid,
    theirs: '${c.theirs}',
    mine: '${c.mine}',
  );
}

Future<void> _runRestoreAction(
  WidgetRef ref,
  Future<int> Function() restoreFn,
  Future<void> Function()? afterRestore,
) async {
  try {
    final count = await restoreFn();
    await afterRestore?.call();
    ref.read(notificationCenterProvider.notifier).add(
          title: t.drive.restoredTheirs(count: count.toString()),
          level: NotificationLevel.success,
        );
  } catch (e) {
    ref.read(notificationCenterProvider.notifier).add(
          title: t.drive.restoreTheirsFailed(error: '$e'),
          level: NotificationLevel.error,
        );
  }
}
