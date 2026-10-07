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
import 'google_drive_service.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';
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
  Future<SyncResult> pull(
    String driveFolderId,
    String localPath, {
    SyncSnapshot? snapshot,
  }) async {
    if (!_driveService.isDriveApiAvailable) {
      return SyncResult.failure(t.drive.driveNotConnected);
    }

    try {
      if (!await fs.isDirectory(localPath)) {
        await fs.createDirectory(localPath);
      }

      final reuse = snapshot != null && snapshot.driveId == driveFolderId ? snapshot : null;
      final folderInfo = reuse?.folderInfo ?? await _driveService.getFolderInfo(driveFolderId);
      if (folderInfo == null) {
        return SyncResult.failure(t.drive.driveFolderNotFound);
      }

      final tree = reuse?.drive ?? await _fileOps.listDriveTree(driveFolderId);
      final filesToDownload = tree.files;

      // Driveに存在する全サブフォルダをローカルに作成（空フォルダ含む）。
      // ファイルの置き場所はどれもこのどれか（か根）なので、並列DL中にフォルダを作り合わない
      await _fileOps.ensureLocalDirs(localPath, tree.folderPaths);

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
      final syncedFiles = <String, KMetaSyncFile>{};

      await SyncFileOperations.runParallel(
        filesToDownload.map((driveEntry) => () async {
          final driveFile = driveEntry.file;
          final localFilePath = _fileOps.relativePathToLocalPath(localPath, driveEntry.relativePath);

          if (await _fileOps.downloadReplacing(driveFile.id!, localFilePath)) {
            downloadedCount++;
            syncedFiles[driveEntry.relativePath] = KMetaSyncFile(
              driveFileId: driveFile.id!,
              lastSyncedTime: DateTime.now(),
              remoteModifiedTime: driveFile.modifiedTime,
            );
            await SyncBaseStore.saveBase(localPath, driveEntry.relativePath);
          } else {
            skippedCount++;
          }
        }),
        maxConcurrency: _downloadConcurrency,
      );

      // Driveにないファイルをローカルから削除
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
      AppLogger.error('[SyncEngine] クローン: フォルダ設定（.qgs）の初期化失敗');
      return false;
    }

    // あとは通常のダウンロード同期と同じ
    final result = await pull(driveId, localPath);

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
  Future<SyncResult> pullFolder(String localPath, {SyncSnapshot? snapshot}) async {
    final meta = await _kmetaService.getMeta(localPath);
    final driveId = meta.sync.driveId;

    if (driveId == null) {
      return SyncResult.failure(t.drive.driveNotLinked);
    }

    return pull(driveId, localPath, snapshot: snapshot);
  }
}
