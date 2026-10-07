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
// Root Maps: 同期Pushハンドラー
// ローカル→Google DriveへのPush（アップロード）処理を担当

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../i18n/strings.g.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import '../qgis/qgs_auto_refresh.dart';
import 'google_drive_service.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';
import 'sync_snapshot.dart';

/// Push（アップロード）処理ハンドラー
class SyncPushHandler {
  final GoogleDriveService _driveService;
  final KMetaService _kmetaService;
  final SyncFileOperations _fileOps;

  static const int _uploadConcurrency = 3;

  SyncPushHandler({
    required this._driveService,
    required this._kmetaService,
    required this._fileOps,
  });

  /// プロジェクトを Drive の [driveFolder] に Push（アップロード）
  /// [projectPath] ローカルプロジェクトフォルダのパス
  /// [snapshot] 同じ連携先の判定に使った材料（あれば Drive をたどり直さない）
  Future<SyncResult> push(
    String projectPath, {
    required String driveFolder,
    SyncSnapshot? snapshot,
  }) async {
    if (!_driveService.isDriveApiAvailable) {
      return SyncResult.failure(t.drive.driveNotConnected);
    }

    try {
      // デバウンス待ちの `.qgs` を書き切ってから上げる（古い版を飛ばさない）
      await QgsAutoRefresh.instance.flushNow();

      final previousMeta = await _kmetaService.getMeta(projectPath);
      final previousSyncedFiles = previousMeta.sync.files;

      if (!await fs.isDirectory(projectPath)) {
        return SyncResult.failure(t.services.projectNotFound);
      }

      final reuse = snapshot != null && snapshot.driveId == driveFolder ? snapshot : null;
      final folderInfo = reuse?.folderInfo ?? await _driveService.getFolderInfo(driveFolder);
      final folderName = folderInfo?.name ?? 'Unknown';

      // リンク情報は `<dir名>.qgs` に入る。集める前に書いておけば、その `.qgs` も
      // この push で一緒に上がる（後から書くと、次の同期でもう一度上がる）
      final link = previousMeta.sync;
      if (link.driveId != driveFolder || link.driveFolderName != folderName) {
        await _kmetaService.setDriveSync(
          projectPath,
          driveId: driveFolder,
          driveFolderName: folderName,
        );
      }

      final filesToSync = await _fileOps.listLocalSyncFiles(projectPath);
      if (filesToSync.isEmpty) {
        return SyncResult.success(skippedCount: 0);
      }

      // Drive上の現在のファイル配置を取得し、ID↔パスの突合で移動を検出。
      // あるフォルダの ID は一覧から引く（フォルダごとに Drive に聞き直さない）
      final tree = reuse?.drive ?? await _fileOps.listDriveTree(driveFolder);
      final folderIdCache = tree.folderIdsByPath();
      final driveIdToEntry = tree.byId();

      final movedFileIds = await _moveRenamedOnDrive(driveFolder, previousSyncedFiles, driveIdToEntry, folderIdCache);
      AppLogger.debug(
        '[SyncEngine] Push開始: ${filesToSync.length}ファイル → $folderName (移動: ${movedFileIds.length})',
      );

      final uploads = await _uploadChanged(
        projectPath,
        driveFolder,
        filesToSync,
        previousSyncedFiles,
        driveIdToEntry,
        folderIdCache,
      );

      final deletedCount = await _deleteMissingOnDrive(
        {for (final f in filesToSync) f.relativePath},
        previousSyncedFiles,
        tree,
        movedFileIds,
      );

      AppLogger.debug(
        '[SyncEngine] Push完了: ${uploads.uploaded} uploaded, $deletedCount deleted, ${uploads.skipped} skipped',
      );

      // 上げようとして 1 つも上がらなかったときだけ失敗（変わっていないものしか無い push は成功。
      // 以前は改名・削除だけの push も失敗扱いで、帳簿を書かずに終わっていた）
      if (uploads.uploaded == 0 && uploads.failed > 0) {
        return SyncResult.failure(
          t.services.uploadFailed(count: uploads.failed.toString()),
        );
      }

      await _kmetaService.setDriveSync(
        projectPath,
        driveId: driveFolder,
        driveFolderName: folderName,
        lastSynced: DateTime.now(),
        files: uploads.syncedFiles,
      );

      return SyncResult.success(
        uploadedCount: uploads.uploaded,
        skippedCount: uploads.skipped,
        deletedCount: deletedCount,
      );
    } catch (e, stack) {
      AppLogger.debug('[SyncEngine] Pushエラー: $e\n$stack');
      return SyncResult.failure(t.services.syncError(error: e.toString()));
    }
  }

  /// 帳簿のパスと Drive 上のパスが違うもの（この端末で改名・移動したもの）を Drive でも動かす。
  /// 動かせたファイルの ID を返す
  Future<Set<String>> _moveRenamedOnDrive(
    String rootId,
    Map<String, KMetaSyncFile> previousSyncedFiles,
    Map<String, DriveFileEntry> driveIdToEntry,
    Map<String, String> folderIdCache,
  ) async {
    final movedFileIds = <String>{};
    for (final entry in previousSyncedFiles.entries) {
      final syncedPath = entry.key;
      if (p.basename(syncedPath) == kMetaFileName) continue;
      final driveFileId = entry.value.driveFileId;
      final driveEntry = driveIdToEntry[driveFileId];
      if (driveEntry == null || driveEntry.relativePath == syncedPath) continue;

      final newParentId = await _fileOps.getDriveFolderIdForRelativeDir(
        rootId,
        p.posix.dirname(syncedPath),
        folderIdCache,
      );
      if (newParentId == null) continue;
      final newName = p.posix.basename(syncedPath);
      final moved = await _driveService.moveFile(
        driveFileId,
        newParentId: newParentId,
        oldParentId: driveEntry.file.parents?.firstOrNull,
        // この端末で改名したなら名前も（写真の改名など）
        newName: p.posix.basename(driveEntry.relativePath) != newName ? newName : null,
      );
      if (moved) {
        movedFileIds.add(driveFileId);
        AppLogger.debug('[SyncEngine] Drive上で移動: ${driveEntry.relativePath} → $syncedPath');
      }
    }
    return movedFileIds;
  }

  /// 前回の同期から変わったものを並列に上げる。新しい帳簿と数を返す
  Future<({Map<String, KMetaSyncFile> syncedFiles, int uploaded, int skipped, int failed})> _uploadChanged(
    String projectPath,
    String rootId,
    List<LocalSyncEntry> files,
    Map<String, KMetaSyncFile> previousSyncedFiles,
    Map<String, DriveFileEntry> driveIdToEntry,
    Map<String, String> folderIdCache,
  ) async {
    final syncedFiles = <String, KMetaSyncFile>{};
    var uploaded = 0;
    var skipped = 0;
    var failed = 0; // 上げようとして上がらなかった数

    // フォルダIDを事前に解決（並列中のキャッシュ競合回避）
    final resolvedFolders = <String?>[
      for (final f in files)
        await _fileOps.getDriveFolderIdForRelativeDir(rootId, p.posix.dirname(f.relativePath), folderIdCache),
    ];

    await SyncFileOperations.runParallel(
      [
        for (var i = 0; i < files.length; i++)
          () async {
            final localFile = files[i];
            final relativePath = localFile.relativePath;
            final targetFolder = resolvedFolders[i];
            if (targetFolder == null) {
              skipped++;
              failed++;
              return;
            }

            final unchanged = await _unchangedSince(localFile, previousSyncedFiles, driveIdToEntry);
            if (unchanged != null) {
              // 移動は済んだ（Drive 側も動かした）ので、元のパスの印は外す
              syncedFiles[relativePath] = unchanged.withoutMove();
              skipped++;
              return;
            }

            final result = await _driveService.uploadFileById(
              localFile.path,
              targetFolder,
              existingFileId: previousSyncedFiles[relativePath]?.driveFileId,
            );
            if (result == null) {
              skipped++;
              failed++;
              return;
            }
            uploaded++;
            syncedFiles[relativePath] = KMetaSyncFile(
              driveFileId: result.id!,
              lastSyncedTime: DateTime.now(),
              remoteModifiedTime: result.modifiedTime,
            );
            await SyncBaseStore.saveBase(projectPath, relativePath);
          },
      ],
      maxConcurrency: _uploadConcurrency,
    );
    return (syncedFiles: syncedFiles, uploaded: uploaded, skipped: skipped, failed: failed);
  }

  /// 手元に無いものを Drive から消す（動かしたものは除く）。消した数を返す
  ///
  /// 帳簿にあって手元に無いもの → Drive の一覧にあって手元のパスに無いもの、の順。
  /// 一覧は push の最初に取ったものを使う（この push で増えたものは手元のパスにあり、
  /// 動かしたもの・消したものは除くので、たどり直しても結果は同じ）
  Future<int> _deleteMissingOnDrive(
    Set<String> localFilePaths,
    Map<String, KMetaSyncFile> previousSyncedFiles,
    DriveTree tree,
    Set<String> movedFileIds,
  ) async {
    var deletedCount = 0;
    final deletedFileIds = <String>{};

    for (final entry in previousSyncedFiles.entries) {
      if (localFilePaths.contains(entry.key)) continue;
      if (movedFileIds.contains(entry.value.driveFileId)) continue;
      if (await _driveService.deleteFile(entry.value.driveFileId)) {
        deletedCount++;
        deletedFileIds.add(entry.value.driveFileId);
        AppLogger.debug('[SyncEngine] Driveから削除（同期情報）: ${entry.key}');
      }
    }

    for (final entry in tree.files) {
      if (deletedFileIds.contains(entry.file.id) || movedFileIds.contains(entry.file.id)) continue;
      if (localFilePaths.contains(entry.relativePath)) continue;
      if (await _driveService.deleteFile(entry.file.id!)) {
        deletedCount++;
        AppLogger.debug('[SyncEngine] Driveから削除: ${entry.relativePath}');
      }
    }
    return deletedCount;
  }

  /// 前回の同期から変わっていないなら、その同期の記録を返す（上げ直さない）。
  ///
  /// 以前は変わったファイルが 1 つでもあるとフォルダの全ファイルを上げ直していた。
  /// 変わっていない gpkg も Drive の更新時刻が進むので、他の端末が毎回「Drive で変更あり」と見て
  /// ダウンロードや行単位マージを繰り返していた（2026-09-24、本物の Drive で見つけた）。
  /// 変更の判定は同期状態の判定と同じ（更新時刻と最後に同期した時刻）。Drive から消えていれば上げる
  static Future<KMetaSyncFile?> _unchangedSince(
    LocalSyncEntry file,
    Map<String, KMetaSyncFile> previous,
    Map<String, DriveFileEntry> onDrive,
  ) async {
    final synced = previous[file.relativePath];
    final at = synced?.lastSyncedTime;
    if (synced == null || at == null || !onDrive.containsKey(synced.driveFileId)) return null;
    final modified = await fs.lastModified(file.path);
    if (modified == null || modified.isAfter(at)) return null;
    return synced;
  }

  /// フォルダ単位でPush（連携先へ）
  Future<SyncResult> pushFolder(String localPath, {SyncSnapshot? snapshot}) async {
    final meta = await _kmetaService.getMeta(localPath);
    final driveId = meta.sync.driveId;

    if (driveId == null) {
      return SyncResult.failure(t.drive.driveNotLinked);
    }

    return push(localPath, driveFolder: driveId, snapshot: snapshot);
  }
}
