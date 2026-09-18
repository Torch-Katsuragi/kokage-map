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

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../i18n/strings.g.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'google_drive_service.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';

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
  /// [onProgress] 進捗コールバック
  Future<SyncResult> pull(
    String driveFolderId,
    String localPath, {
    void Function(SyncProgress progress)? onProgress,
  }) async {
    if (!_driveService.isDriveApiAvailable) {
      return SyncResult.failure(t.drive.driveNotConnected);
    }

    try {
      final localExists = await fs.isDirectory(localPath);
      if (!localExists) {
        await fs.createDirectory(localPath);
      }

      final folderInfo = await _driveService.getFolderInfo(driveFolderId);
      if (folderInfo == null) {
        return SyncResult.failure(t.drive.driveFolderNotFound);
      }

      final driveResult =
          await _fileOps.listDriveFilesWithFolders(driveFolderId);
      final filesToDownload = driveResult.files;

      // Driveに存在する全サブフォルダをローカルに作成（空フォルダ含む）
      for (final relativeFolderPath in driveResult.folderMap.values) {
        if (relativeFolderPath.isEmpty) continue;
        await fs.createDirectory(
          _fileOps.relativePathToLocalPath(localPath, relativeFolderPath),
        );
      }

      if (filesToDownload.isEmpty) {
        await _kmetaService.setDriveSync(
          localPath,
          driveId: driveFolderId,
          driveFolderName: folderInfo.name,
          lastSynced: DateTime.now(),
        );
        return SyncResult.success(downloadedCount: 0);
      }

      AppLogger.debug(
        '[SyncEngine] Pull開始: ${filesToDownload.length}ファイル ← ${folderInfo.name}',
      );

      int downloadedCount = 0;
      int skippedCount = 0;
      int completedCount = 0;
      final syncedFiles = <String, KMetaSyncFile>{};

      final totalBytes = filesToDownload.fold<int>(
        0, (sum, e) => sum + (int.tryParse(e.file.size ?? '') ?? 0),
      );
      int processedBytes = 0;

      // ファイルのあるディレクトリも念のため作成（並列DL中の競合回避）
      final fileDirs = filesToDownload
          .map((e) => p.dirname(
              _fileOps.relativePathToLocalPath(localPath, e.relativePath)))
          .toSet();
      for (final dir in fileDirs) {
        await fs.createDirectory(dir);
      }

      onProgress?.call(SyncProgress(
        currentFile: t.drive.syncProgressStart,
        processedCount: 0,
        totalCount: filesToDownload.length,
        processedBytes: 0,
        totalBytes: totalBytes,
      ));

      await SyncFileOperations.runParallel(
        filesToDownload.map((driveEntry) => () async {
          final driveFile = driveEntry.file;
          final fileName = p.posix.basename(driveEntry.relativePath);
          final fileSize = int.tryParse(driveFile.size ?? '') ?? 0;
          final localFilePath =
              _fileOps.relativePathToLocalPath(localPath, driveEntry.relativePath);

          final success = await _driveService.downloadFile(
            driveFile.id!,
            localFilePath,
          );

          if (success) {
            downloadedCount++;
            syncedFiles[driveEntry.relativePath] = KMetaSyncFile(
              driveFileId: driveFile.id!,
              lastSyncedTime: DateTime.now(),
            );
            await SyncBaseStore.saveBase(localPath, driveEntry.relativePath);
          } else {
            skippedCount++;
          }
          processedBytes += fileSize;
          completedCount++;
          onProgress?.call(SyncProgress(
            currentFile: fileName,
            processedCount: completedCount,
            totalCount: filesToDownload.length,
            processedBytes: processedBytes,
            totalBytes: totalBytes,
          ));
        }),
        maxConcurrency: _downloadConcurrency,
      );

      // Driveにないファイルをローカルから削除（.kmeta.jsonは保護）
      int deletedCount = 0;
      final driveFilePaths =
          filesToDownload.map((f) => f.relativePath).toSet();

      if (await fs.isDirectory(localPath)) {
        for (final entity in await fs.listRecursive(localPath)) {
          final localName = p.basename(entity.path);
          if (localName == kMetaFileName) continue;
          if (!_fileOps.matchesSyncPattern(localName)) continue;
          final relativePath = _fileOps.normalizeRelativePath(
            p.relative(entity.path, from: localPath),
          );
          if (SyncBaseStore.isInside(relativePath)) continue;
          if (!driveFilePaths.contains(relativePath)) {
            await fs.delete(entity.path);
            deletedCount++;
            AppLogger.debug('[SyncEngine] ローカルから削除: $relativePath');
          }
        }

        // Driveに存在しない空フォルダをローカルから削除（深い階層から処理）
        final driveFolderPaths = driveResult.folderMap.values
            .where((v) => v.isNotEmpty)
            .toSet();
        final localDirs = await fs.listDirectoriesRecursive(localPath);
        localDirs.sort((a, b) => b.path.length.compareTo(a.path.length));

        for (final dir in localDirs) {
          final relativePath = _fileOps.normalizeRelativePath(
            p.relative(dir.path, from: localPath),
          );
          if (driveFolderPaths.contains(relativePath)) continue;
          if ((await fs.list(dir.path)).isEmpty) {
            await fs.delete(dir.path);
            AppLogger.debug('[SyncEngine] 空フォルダ削除: $relativePath');
          }
        }
      }

      onProgress?.call(SyncProgress(
        currentFile: t.drive.syncProgressComplete,
        processedCount: filesToDownload.length,
        totalCount: filesToDownload.length,
        processedBytes: totalBytes,
        totalBytes: totalBytes,
      ));

      AppLogger.debug(
        '[SyncEngine] Pull完了: $downloadedCount downloaded, $deletedCount deleted, $skippedCount skipped',
      );

      if (downloadedCount == 0 && filesToDownload.isNotEmpty) {
        return SyncResult.failure(
          t.services.downloadFailed(count: skippedCount.toString()),
        );
      }

      await _kmetaService.setDriveSync(
        localPath,
        driveId: driveFolderId,
        driveFolderName: folderInfo.name,
        lastSynced: DateTime.now(),
        files: syncedFiles,
      );

      return SyncResult.success(
        downloadedCount: downloadedCount,
        skippedCount: skippedCount,
        deletedCount: deletedCount,
      );
    } catch (e, stack) {
      AppLogger.debug('[SyncEngine] Pullエラー: $e\n$stack');
      return SyncResult.failure(t.services.downloadError(error: e.toString()));
    }
  }

  /// 共有URLからプロジェクトをPull
  /// [shareUrl] Google Drive共有URL
  /// [localPath] ローカル保存先パス
  /// [onProgress] 進捗コールバック
  Future<SyncResult> pullFromUrl(
    String shareUrl,
    String localPath, {
    void Function(SyncProgress progress)? onProgress,
  }) async {
    final folderId = GoogleDriveService.extractFolderIdFromUrl(shareUrl);
    if (folderId == null) {
      return SyncResult.failure(t.drive.invalidShareUrl);
    }

    return pull(folderId, localPath, onProgress: onProgress);
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
  }) async {
    AppLogger.debug('[SyncEngine] クローン開始: $folderName ($driveId)');

    await fs.createDirectory(localPath);

    // クローン固有のメタデータを先にセットアップ
    // pull() 内の setDriveSync はマージ動作なのでこれらを上書きしない
    final saved = await _kmetaService.setDriveSync(
      localPath,
      driveId: driveId,
      driveUrl: driveUrl,
      isReadOnly: isReadOnly,
    );
    if (!saved) {
      AppLogger.error('[SyncEngine] クローン: .kmeta.json 初期化失敗');
      return false;
    }

    // あとは通常のダウンロード同期と同じ
    final result = await pull(driveId, localPath, onProgress: onProgress);

    if (!result.success) {
      AppLogger.error('[SyncEngine] クローン失敗: ${result.errorMessage}');
      return false;
    }

    AppLogger.debug(
      '[SyncEngine] クローン完了: ${result.downloadedCount} ファイルダウンロード',
    );
    return true;
  }

  /// フォルダ単位でPull
  Future<SyncResult> pullFolder(String localPath) async {
    final meta = await _kmetaService.getMeta(localPath);
    final driveId = meta.sync.driveId;

    if (driveId == null) {
      return SyncResult.failure(t.drive.driveNotLinked);
    }

    return pull(driveId, localPath);
  }
}
