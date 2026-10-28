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
// Root Maps: 同期Pullハンドラー
// Google Drive→ローカルへのPull（ダウンロード）処理を担当

import '../../core/fs/k_file_system.dart';
import '../../i18n/strings.g.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'drive_transfer_registry.dart';
import 'google_drive_service.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';
import 'sync_progress.dart';
import 'sync_snapshot.dart';

/// Pull（ダウンロード）処理ハンドラー
class SyncPullHandler {
  final GoogleDriveService _driveService;
  final KMetaService _kmetaService;
  final SyncFileOperations _fileOps;

  static const int _downloadConcurrency = 5;

  SyncPullHandler({
    required this._driveService,
    required this._kmetaService,
    required this._fileOps,
  });

  /// DriveからプロジェクトをPull（ダウンロード）
  /// [driveFolderId] DriveフォルダID
  /// [localPath] ローカル保存先パス
  /// [snapshot] 同じ連携先の判定に使った材料（あれば Drive をたどり直さない）
  /// [onProgress] 進捗コールバック（指定がなくても [DriveTransferRegistry] には常時配信される）
  Future<SyncResult> pull(
    String driveFolderId,
    String localPath, {
    SyncSnapshot? snapshot,
    void Function(SyncProgress progress)? onProgress,
    bool showOsNotification = false,
  }) async {
    if (!_driveService.isDriveApiAvailable) {
      return SyncResult.failure(t.drive.driveNotConnected);
    }

    final registry = DriveTransferRegistry.instance;
    final managedExternally = registry.isBusy(localPath);
    final throttler = ProgressThrottler((progress) {
      registry.updateProgress(
        localPath,
        progress,
        showOsNotification: showOsNotification,
      );
      onProgress?.call(progress);
    });

    if (!managedExternally) {
      registry.beginTransfer(
        localPath,
        folderName: localPath.split(RegExp(r'[/\\]')).last,
        showOsNotification: showOsNotification,
      );
    }
    throttler.add(const SyncProgress.scanning());

    try {
      if (!await fs.isDirectory(localPath)) {
        await fs.createDirectory(localPath);
      }

      final reuse = snapshot != null && snapshot.driveId == driveFolderId ? snapshot : null;
      final folderInfo = reuse?.folderInfo ?? await _driveService.getFolderInfo(driveFolderId);
      if (folderInfo == null) {
        if (!managedExternally) {
          registry.endTransfer(
            localPath,
            driveId: driveFolderId,
            success: false,
            errorMessage: t.drive.driveFolderNotFound,
            showOsNotification: false,
          );
        }
        return SyncResult.failure(t.drive.driveFolderNotFound);
      }

      final tree = reuse?.drive ?? await _fileOps.listDriveTree(driveFolderId);
      final filesToDownload = tree.files;

      // Driveに存在する全サブフォルダをローカルに作成（空フォルダ含む）。
      // ファイルの置き場所はどれもこのどれか（か根）なので、並列DL中にフォルダを作り合わない
      final createdFolders = await _fileOps.ensureLocalDirs(localPath, tree.folderPaths);

      if (filesToDownload.isEmpty) {
        throttler.add(const SyncProgress.finalizing());
        await _kmetaService.setDriveSync(
          localPath,
          driveId: driveFolderId,
          driveFolderName: folderInfo.name,
          lastSynced: DateTime.now(),
        );
        await registry.clearClonePending(localPath);
        if (!managedExternally) {
          registry.endTransfer(
            localPath,
            driveId: driveFolderId,
            folderName: folderInfo.name,
            success: true,
            showOsNotification: false,
          );
        }
        return SyncResult.success(downloadedCount: 0, createdFolderCount: createdFolders);
      }

      AppLogger.debug(
        '[SyncEngine] Pull開始: ${filesToDownload.length}ファイル ← ${folderInfo.name}',
      );

      final tracker = SyncByteTracker({
        for (final entry in filesToDownload)
          entry.relativePath: int.tryParse(entry.file.size ?? '') ?? 0,
      });
      throttler.add(tracker.snapshot(SyncPhase.transferring));

      int downloadedCount = 0;
      int skippedCount = 0; // 変わっていないので落とさなかった数
      int failedCount = 0; // 落とそうとして落とせなかった数
      final syncedFiles = <String, KMetaSyncFile>{};
      final previous = reuse?.meta.sync.files ?? (await _kmetaService.getMeta(localPath)).sync.files;

      await SyncFileOperations.runParallel(
        filesToDownload.map((driveEntry) => () async {
          final driveFile = driveEntry.file;
          final relPath = driveEntry.relativePath;
          final fileName = driveFile.name ?? relPath.split('/').last;
          final localFilePath = _fileOps.relativePathToLocalPath(localPath, relPath);

          final unchanged = await _unchangedSince(driveEntry, localFilePath, previous[relPath]);
          if (unchanged != null) {
            skippedCount++;
            syncedFiles[relPath] = unchanged.record;
            tracker.markCompleted(relPath, fileName: fileName);
            throttler.add(tracker.snapshot(SyncPhase.transferring));
            // 帳簿で判定できず中身で同じと分かったもの：この時点を base にする（次から行単位で合わせられる）
            if (unchanged.byContent) await SyncBaseStore.saveBase(localPath, relPath);
            return;
          }

          if (await _fileOps.downloadReplacing(
            driveFile.id!,
            localFilePath,
            onChunk: (chunkBytes) {
              tracker.addChunk(relPath, chunkBytes, fileName: fileName);
              throttler.add(tracker.snapshot(SyncPhase.transferring));
            },
            onRetryReset: () {
              tracker.resetFile(relPath);
              throttler.add(tracker.snapshot(SyncPhase.transferring));
            },
          )) {
            downloadedCount++;
            tracker.markCompleted(relPath, fileName: fileName);
            throttler.add(tracker.snapshot(SyncPhase.transferring));
            syncedFiles[relPath] = KMetaSyncFile(
              driveFileId: driveFile.id!,
              lastSyncedTime: DateTime.now(),
              remoteModifiedTime: driveFile.modifiedTime,
              remoteMd5: driveFile.md5Checksum,
            );
            await SyncBaseStore.saveBase(localPath, relPath);
          } else {
            failedCount++;
            // 落とせなかったものは前の記録を残す。消すと次の判定で「帳簿に無い手元のファイル」になり、
            // push が Drive の新しい版を手元の古い版で上書きしていた
            final before = previous[relPath];
            if (before != null) syncedFiles[relPath] = before;
          }
        }),
        maxConcurrency: _downloadConcurrency,
      );

      throttler.flush();
      throttler.add(tracker.snapshot(SyncPhase.finalizing));

      // Driveにないファイルをローカルから削除（ただし失敗ファイルがある場合は安全のため保持）
      int deletedCount = 0;
      final driveFilePaths = filesToDownload.map((f) => f.relativePath).toSet();
      for (final entry in await _fileOps.listLocalSyncFiles(localPath)) {
        if (driveFilePaths.contains(entry.relativePath)) continue;
        await fs.delete(entry.path);
        deletedCount++;
        AppLogger.debug('[SyncEngine] ローカルから削除: ${entry.relativePath}');
      }

      // Driveに存在しない空フォルダをローカルから削除（深い階層から処理）
      await _fileOps.removeEmptyLocalDirs(localPath, tree.folderPaths.toSet());

      AppLogger.debug(
        '[SyncEngine] Pull完了: $downloadedCount downloaded, $deletedCount deleted, '
        '$skippedCount unchanged, $failedCount failed',
      );

      // 落とそうとして 1 つも落ちなかったときだけ失敗（変わっていないものしか無い pull は成功）
      if (downloadedCount == 0 && failedCount > 0) {
        final msg = t.services.downloadFailed(count: failedCount.toString());
        if (!managedExternally) {
          registry.endTransfer(
            localPath,
            driveId: driveFolderId,
            folderName: folderInfo.name,
            success: false,
            errorMessage: msg,
            showOsNotification: false,
          );
        }
        return SyncResult.failure(msg);
      }

      await _kmetaService.setDriveSync(
        localPath,
        driveId: driveFolderId,
        driveFolderName: folderInfo.name,
        lastSynced: DateTime.now(),
        files: syncedFiles,
      );

      if (failedCount == 0) {
        await registry.clearClonePending(localPath);
      }

      if (!managedExternally) {
        registry.endTransfer(
          localPath,
          driveId: driveFolderId,
          folderName: folderInfo.name,
          success: true,
          showOsNotification: false,
        );
      }

      return SyncResult.success(
        downloadedCount: downloadedCount,
        skippedCount: skippedCount,
        deletedCount: deletedCount,
        createdFolderCount: createdFolders,
      );
    } catch (e, stack) {
      AppLogger.debug('[SyncEngine] Pullエラー: $e\n$stack');
      final msg = t.services.downloadError(error: e.toString());
      if (!managedExternally) {
        registry.endTransfer(
          localPath,
          driveId: driveFolderId,
          success: false,
          errorMessage: msg,
          showOsNotification: false,
        );
      }
      return SyncResult.failure(msg);
    }
  }

  /// 手元がもう Drive と同じなら、帳簿に書く記録を返す（落とさない）。落とすなら null。
  ///
  /// 以前は pull のたびに Drive の全ファイルを落とし直していた（1 つ変わっただけでも全部）。
  /// 1. 帳簿に同じ ID の記録があり、Drive がその後変わっておらず（時刻か md5）、手元もその後触っていない
  /// 2. 帳簿が無い・合わなくても、大きさと md5 が Drive と同じ（帳簿を失くした端末・別経路で置いたもの）
  static Future<({KMetaSyncFile record, bool byContent})?> _unchangedSince(
    DriveFileEntry entry,
    String localFilePath,
    KMetaSyncFile? synced,
  ) async {
    final file = entry.file;
    final local = await fs.lastModified(localFilePath);
    if (local == null) return null; // 手元に無い
    final at = synced?.lastSyncedTime;
    if (synced != null &&
        at != null &&
        synced.driveFileId == file.id &&
        !local.isAfter(at) &&
        (file.modifiedTime == null || !synced.isRemoteNewer(file.modifiedTime!, md5: file.md5Checksum))) {
      return (
        record: synced.withoutMove().copyWith(remoteModifiedTime: file.modifiedTime, remoteMd5: file.md5Checksum),
        byContent: false,
      );
    }
    if (await SyncFileOperations.sameContentAsDrive(localFilePath, file)) {
      return (
        record: KMetaSyncFile(
          driveFileId: file.id!,
          lastSyncedTime: DateTime.now(),
          remoteModifiedTime: file.modifiedTime,
          remoteMd5: file.md5Checksum,
        ),
        byContent: true,
      );
    }
    return null;
  }

  /// Driveフォルダをローカルにクローン
  ///
  /// 実質的には「メタデータ設定 → 空フォルダへのpull」と同じ。
  /// pull() がファイルのダウンロードとメタデータの更新を全て行う。
  Future<bool> cloneFromDrive({
    required String driveId,
    required String localPath,
    required String folderName,
    required String driveUrl,
    required bool isReadOnly,
    void Function(SyncProgress progress)? onProgress,
    bool showOsNotification = true,
  }) async {
    AppLogger.debug('[SyncEngine] クローン開始: $folderName ($driveId)');

    final registry = DriveTransferRegistry.instance;
    final managedExternally = registry.isBusy(localPath);
    if (!managedExternally) {
      registry.beginTransfer(
        localPath,
        folderName: folderName,
        showOsNotification: showOsNotification,
      );
    }

    try {
      await fs.createDirectory(localPath);
      await registry.markClonePending(localPath);

      // クローン固有のメタデータを先にセットアップ
      // pull() 内の setDriveSync はマージ動作なのでこれらを上書きしない
      final saved = await _kmetaService.setDriveSync(
        localPath,
        driveId: driveId,
        driveFolderName: folderName,
        driveUrl: driveUrl,
        isReadOnly: isReadOnly,
      );
      if (!saved) {
        AppLogger.error('[SyncEngine] クローン: フォルダ設定（.qgs）の初期化失敗');
        if (!managedExternally) {
          registry.endTransfer(
            localPath,
            driveId: driveId,
            folderName: folderName,
            success: false,
            showOsNotification: false,
          );
        }
        return false;
      }

      // あとは通常のダウンロード同期と同じ
      final result = await pull(
        driveId,
        localPath,
        onProgress: onProgress,
        showOsNotification: showOsNotification,
      );

      if (!result.success) {
        AppLogger.error('[SyncEngine] クローン失敗: ${result.errorMessage}');
        if (!managedExternally) {
          registry.endTransfer(
            localPath,
            driveId: driveId,
            folderName: folderName,
            success: false,
            errorMessage: result.errorMessage,
            showOsNotification: false,
          );
        }
        return false;
      }

      await registry.clearClonePending(localPath);
      if (!managedExternally) {
        registry.endTransfer(
          localPath,
          driveId: driveId,
          folderName: folderName,
          success: true,
          showOsNotification: false,
        );
      }

      AppLogger.debug(
        '[SyncEngine] クローン完了: ${result.downloadedCount} ファイルダウンロード',
      );
      return true;
    } catch (e) {
      if (!managedExternally) {
        registry.endTransfer(
          localPath,
          driveId: driveId,
          folderName: folderName,
          success: false,
          errorMessage: e.toString(),
          showOsNotification: false,
        );
      }
      rethrow;
    }
  }

  /// フォルダ単位でPull
  Future<SyncResult> pullFolder(
    String localPath, {
    SyncSnapshot? snapshot,
    void Function(SyncProgress progress)? onProgress,
    bool showOsNotification = false,
  }) async {
    final meta = await _kmetaService.getMeta(localPath);
    final driveId = meta.sync.driveId;

    if (driveId == null) {
      return SyncResult.failure(t.drive.driveNotLinked);
    }

    return pull(
      driveId,
      localPath,
      snapshot: snapshot,
      onProgress: onProgress,
      showOsNotification: showOsNotification,
    );
  }
}
