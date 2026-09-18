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
// Root Maps: 同期コンフリクト解決
// 同期状態チェック、マージエントリ取得、マージ実行を担当

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import '../geodiff/geodiff.dart';
import '../kmeta_service.dart';
import 'google_drive_service.dart';
import 'gpkg_merger.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';

/// コンフリクト解決ハンドラー
class SyncConflictResolver {
  final GoogleDriveService _driveService;
  final KMetaService _kmetaService;
  final SyncFileOperations _fileOps;

  SyncConflictResolver({
    required this._driveService,
    required this._kmetaService,
    required this._fileOps,
  });

  /// フォルダの同期状態をチェック
  /// ファイルID単位でDriveとローカルを比較
  Future<FolderSyncStatus> checkSyncStatus(String localPath) async {
    final detail = await checkSyncStatusDetail(localPath);
    return detail.status;
  }

  /// 同期状態の詳細を取得
  Future<FolderSyncStatusDetail> checkSyncStatusDetail(String localPath) async {
    if (!_driveService.isDriveApiAvailable) {
      return const FolderSyncStatusDetail(status: FolderSyncStatus.error);
    }

    try {
      final meta = await _kmetaService.getMeta(localPath);
      final driveId = meta.sync.driveId;
      final syncedFiles = meta.sync.files;

      if (driveId == null) {
        return const FolderSyncStatusDetail(status: FolderSyncStatus.notLinked);
      }

      final folderInfo = await _driveService.getFolderInfo(driveId);
      if (folderInfo == null) {
        return const FolderSyncStatusDetail(status: FolderSyncStatus.error);
      }

      final driveData = await _fileOps.listDriveFilesWithFolders(driveId);
      final driveAllEntries = driveData.files;
      final driveFolderMap = driveData.folderMap;

      final driveIdMap = <String, DriveFileEntry>{};
      for (final entry in driveAllEntries) {
        final fileId = entry.file.id;
        if (fileId != null) driveIdMap[fileId] = entry;
      }

      // 中身は SyncFileOperations.scanLocalFiles と同じなので、そちらに任せる
      final localFiles = await _fileOps.scanLocalFiles(localPath);

      int localAdded = 0;
      int localDeleted = 0;
      int localModified = 0;
      int remoteAdded = 0;
      int remoteDeleted = 0;
      int remoteModified = 0;
      int remoteMoved = 0;
      final localAddedFiles = <String>[];
      final localDeletedFiles = <String>[];
      final localModifiedFiles = <String>[];
      final remoteAddedFiles = <String>[];
      final remoteDeletedFiles = <String>[];
      final remoteModifiedFiles = <String>[];
      final remoteMovedFiles = <FileChangeInfo>[];

      // syncedFilesを driveFileId → syncedPath に反転
      final syncedIdToPath = <String, String>{};
      for (final entry in syncedFiles.entries) {
        if (p.basename(entry.key) == kMetaFileName) continue;
        syncedIdToPath[entry.value.driveFileId] = entry.key;
      }

      final movedFileIds = <String>{};
      final movedToPathSet = <String>{};

      for (final entry in syncedFiles.entries) {
        final syncedPath = entry.key;
        if (p.basename(syncedPath) == kMetaFileName) continue;

        final syncInfo = entry.value;
        final lastSyncedTime = syncInfo.lastSyncedTime;
        final driveEntry = driveIdMap[syncInfo.driveFileId];

        if (driveEntry == null) {
          remoteDeleted++;
          remoteDeletedFiles.add(syncedPath);
        } else {
          final drivePath = driveEntry.relativePath;
          final driveFile = driveEntry.file;

          if (syncedPath != drivePath) {
            final alsoModified = lastSyncedTime != null &&
                driveFile.modifiedTime != null &&
                driveFile.modifiedTime!.isAfter(lastSyncedTime);

            remoteMoved++;
            remoteMovedFiles.add(FileChangeInfo(
              fileName: syncedPath,
              type: alsoModified
                  ? FileChangeType.movedAndModified
                  : FileChangeType.moved,
              movedFrom: syncedPath,
              movedTo: drivePath,
            ));
            movedFileIds.add(syncInfo.driveFileId);
            movedToPathSet.add(drivePath);
          } else {
            if (lastSyncedTime == null) {
              remoteModified++;
              remoteModifiedFiles.add(syncedPath);
            } else if (driveFile.modifiedTime != null &&
                driveFile.modifiedTime!.isAfter(lastSyncedTime)) {
              remoteModified++;
              remoteModifiedFiles.add(syncedPath);
            }
          }
        }

        if (movedFileIds.contains(syncInfo.driveFileId)) {
          localFiles.remove(syncedPath);
        } else if (localFiles.containsKey(syncedPath)) {
          final localModifiedTime = localFiles[syncedPath]!;
          if (lastSyncedTime == null) {
            localModified++;
            localModifiedFiles.add(syncedPath);
          } else if (localModifiedTime.isAfter(lastSyncedTime)) {
            localModified++;
            localModifiedFiles.add(syncedPath);
          }
          localFiles.remove(syncedPath);
        } else {
          localDeleted++;
          localDeletedFiles.add(syncedPath);
        }
      }

      localAdded = localFiles.length;
      if (localFiles.isNotEmpty) {
        localAddedFiles.addAll(localFiles.keys);
      }

      for (final entry in driveAllEntries) {
        if (p.basename(entry.relativePath) == kMetaFileName) continue;
        if (movedToPathSet.contains(entry.relativePath)) continue;
        if (movedFileIds.contains(entry.file.id)) continue;
        // syncedIdToPathにIDがあればsyncedFilesに登録済み（パスが違っても移動として処理済み）
        if (syncedIdToPath.containsKey(entry.file.id)) continue;
        if (!syncedFiles.containsKey(entry.relativePath)) {
          remoteAdded++;
          remoteAddedFiles.add(entry.relativePath);
        }
      }

      // Driveにあるがローカルに存在しないフォルダを検出
      for (final relativeFolderPath in driveFolderMap.values) {
        if (relativeFolderPath.isEmpty) continue;
        final localFolder =
            _fileOps.relativePathToLocalPath(localPath, relativeFolderPath);
        if (!await fs.isDirectory(localFolder)) {
          remoteAdded++;
          remoteAddedFiles.add('$relativeFolderPath/');
        }
      }

      final hasLocalChanges =
          localAdded > 0 || localDeleted > 0 || localModified > 0;
      final hasRemoteChanges =
          remoteAdded > 0 || remoteDeleted > 0 || remoteModified > 0 || remoteMoved > 0;

      if (syncedFiles.isEmpty && meta.sync.lastSynced == null) {
        return FolderSyncStatusDetail(
          status: FolderSyncStatus.remoteChanges,
          localAdded: localAdded,
          localDeleted: localDeleted,
          localModified: localModified,
          remoteAdded: remoteAdded,
          remoteDeleted: remoteDeleted,
          remoteModified: remoteModified,
          remoteMoved: remoteMoved,
          localAddedFiles: localAddedFiles,
          localDeletedFiles: localDeletedFiles,
          localModifiedFiles: localModifiedFiles,
          remoteAddedFiles: remoteAddedFiles,
          remoteDeletedFiles: remoteDeletedFiles,
          remoteModifiedFiles: remoteModifiedFiles,
          remoteMovedFiles: remoteMovedFiles,
        );
      }

      final status = hasLocalChanges && hasRemoteChanges
          ? FolderSyncStatus.conflict
          : hasLocalChanges
              ? FolderSyncStatus.localChanges
              : hasRemoteChanges
                  ? FolderSyncStatus.remoteChanges
                  : FolderSyncStatus.synced;

      return FolderSyncStatusDetail(
        status: status,
        localAdded: localAdded,
        localDeleted: localDeleted,
        localModified: localModified,
        remoteAdded: remoteAdded,
        remoteDeleted: remoteDeleted,
        remoteModified: remoteModified,
        remoteMoved: remoteMoved,
        localAddedFiles: localAddedFiles,
        localDeletedFiles: localDeletedFiles,
        localModifiedFiles: localModifiedFiles,
        remoteAddedFiles: remoteAddedFiles,
        remoteDeletedFiles: remoteDeletedFiles,
        remoteModifiedFiles: remoteModifiedFiles,
        remoteMovedFiles: remoteMovedFiles,
      );
    } catch (e) {
      AppLogger.error('[SyncEngine] 同期状態チェックエラー: $e');
      return const FolderSyncStatusDetail(status: FolderSyncStatus.error);
    }
  }

  /// マージ用のファイルエントリ一覧を取得
  Future<List<MergeFileEntry>> getMergeEntries(String localPath) async {
    final entries = <MergeFileEntry>[];

    try {
      final meta = await _kmetaService.getMeta(localPath);
      final driveId = meta.sync.driveId;
      final syncedFiles = meta.sync.files;

      if (driveId == null) {
        AppLogger.debug('[getMergeEntries] driveId が無い');
        return entries;
      }

      final localFilesFuture = _fileOps.scanLocalFiles(localPath);
      final folderInfo = await _driveService.getFolderInfo(driveId);
      if (folderInfo == null) {
        AppLogger.debug('[getMergeEntries] Driveのフォルダを取れない: $driveId');
        return entries;
      }

      final driveAllEntries =
          (await _fileOps.listDriveFilesWithFolders(driveId)).files;

      final driveIdMap = <String, DriveFileEntry>{};
      for (final entry in driveAllEntries) {
        final fileId = entry.file.id;
        if (fileId != null) driveIdMap[fileId] = entry;
      }

      final localFiles = await localFilesFuture;
      AppLogger.debug(
        '[getMergeEntries] local=${localFiles.keys.toList()} '
        'drive=${driveAllEntries.map((e) => e.relativePath).toList()} '
        'synced=${syncedFiles.keys.toList()}',
      );

      // syncedFilesを driveFileId → syncedPath に反転
      final syncedIdToPath = <String, String>{};
      for (final entry in syncedFiles.entries) {
        if (p.basename(entry.key) == kMetaFileName) continue;
        syncedIdToPath[entry.value.driveFileId] = entry.key;
      }

      final movedFileIds = <String>{};
      final movedToPathSet = <String>{};

      for (final entry in syncedFiles.entries) {
        final syncedPath = entry.key;
        if (p.basename(syncedPath) == kMetaFileName) continue;

        final syncInfo = entry.value;
        final lastSyncedTime = syncInfo.lastSyncedTime;
        final driveEntry = driveIdMap[syncInfo.driveFileId];

        MergeChangeType localChange = MergeChangeType.none;
        MergeChangeType remoteChange = MergeChangeType.none;
        DateTime? localModTime;
        final DateTime? remoteModTime = driveEntry?.file.modifiedTime;
        FileChangeInfo? moveInfo;

        if (driveEntry == null) {
          remoteChange = MergeChangeType.deleted;
        } else {
          final drivePath = driveEntry.relativePath;

          if (syncedPath != drivePath) {
            remoteChange = MergeChangeType.moved;
            moveInfo = FileChangeInfo(
              fileName: syncedPath,
              type: FileChangeType.moved,
              movedFrom: syncedPath,
              movedTo: drivePath,
            );
            movedFileIds.add(syncInfo.driveFileId);
            movedToPathSet.add(drivePath);
          } else if (lastSyncedTime != null &&
              driveEntry.file.modifiedTime != null &&
              driveEntry.file.modifiedTime!.isAfter(lastSyncedTime)) {
            remoteChange = MergeChangeType.modified;
          }
        }

        if (movedFileIds.contains(syncInfo.driveFileId)) {
          localChange = MergeChangeType.none;
        } else if (localFiles.containsKey(syncedPath)) {
          localModTime = localFiles[syncedPath];
          if (lastSyncedTime != null && localModTime!.isAfter(lastSyncedTime)) {
            localChange = MergeChangeType.modified;
          }
        } else {
          localChange = MergeChangeType.deleted;
        }

        if (localChange != MergeChangeType.none || remoteChange != MergeChangeType.none) {
          // 両方 modified の gpkg で base が残っていれば、行単位で合わせられる
          final mergeable = localChange == MergeChangeType.modified &&
              remoteChange == MergeChangeType.modified &&
              await SyncBaseStore.hasBase(localPath, syncedPath);
          entries.add(MergeFileEntry(
            relativePath: syncedPath,
            localChange: localChange,
            remoteChange: remoteChange,
            localModifiedTime: localModTime,
            remoteModifiedTime: remoteModTime,
            moveInfo: moveInfo,
            driveFileId: syncInfo.driveFileId,
            mergeable: mergeable,
          ));
        }

        localFiles.remove(syncedPath);
      }

      for (final entry in localFiles.entries) {
        entries.add(MergeFileEntry(
          relativePath: entry.key,
          localChange: MergeChangeType.added,
          remoteChange: MergeChangeType.none,
          localModifiedTime: entry.value,
          remoteModifiedTime: null,
        ));
      }

      AppLogger.debug('[SyncEngine] getMergeEntries: Drive新規ファイル確認 (${driveAllEntries.length}件)');
      for (final driveEntry in driveAllEntries) {
        if (p.basename(driveEntry.relativePath) == kMetaFileName) continue;
        if (movedToPathSet.contains(driveEntry.relativePath)) continue;
        if (movedFileIds.contains(driveEntry.file.id)) continue;
        if (syncedIdToPath.containsKey(driveEntry.file.id)) continue;
        if (!syncedFiles.containsKey(driveEntry.relativePath)) {
          AppLogger.debug('  リモート追加検出: ${driveEntry.relativePath} (id: ${driveEntry.file.id})');
          entries.add(MergeFileEntry(
            relativePath: driveEntry.relativePath,
            localChange: MergeChangeType.none,
            remoteChange: MergeChangeType.added,
            localModifiedTime: null,
            remoteModifiedTime: driveEntry.file.modifiedTime,
            driveFileId: driveEntry.file.id,
          ));
        }
      }

      AppLogger.debug('[SyncEngine] getMergeEntries完了: ${entries.length}件のエントリ');
      return entries;
    } catch (e) {
      AppLogger.error('[SyncEngine] getMergeEntries エラー: $e');
      return entries;
    }
  }

  /// マージを実行
  Future<SyncResult> executeMerge(
    String localPath,
    List<MergeDecision> decisions,
  ) async {
    Geodiff? geodiff;
    try {
      final meta = await _kmetaService.getMeta(localPath);
      final driveId = meta.sync.driveId;
      final syncedFiles = Map<String, KMetaSyncFile>.from(meta.sync.files);

      if (driveId == null) {
        return SyncResult.failure('Drive連携されていません');
      }

      await ensureDriveFolders(localPath, driveId: driveId);

      int uploadedCount = 0;
      int downloadedCount = 0;
      int deletedCount = 0;
      int movedCount = 0;
      int mergedCount = 0;
      final conflicts = <GpkgConflict>[];

      final folderIdCache = <String, String>{};

      AppLogger.debug('[SyncEngine] executeMerge開始: ${decisions.length}件の決定');

      for (final decision in decisions) {
        final entry = decision.entry;
        final choice = decision.choice;
        final relativePath = entry.relativePath;
        final localFilePath = _fileOps.relativePathToLocalPath(localPath, relativePath);

        AppLogger.debug('[SyncEngine] 処理: $relativePath');
        AppLogger.debug('  choice: $choice');
        AppLogger.debug('  localChange: ${entry.localChange}');
        AppLogger.debug('  remoteChange: ${entry.remoteChange}');
        AppLogger.debug('  driveFileId: ${entry.driveFileId}');

        if (choice == MergeChoice.merge) {
          geodiff ??= Geodiff();
          final merged = await _mergeGpkg(
            localPath: localPath,
            entry: entry,
            localFilePath: localFilePath,
            driveId: driveId,
            folderIdCache: folderIdCache,
            geodiff: geodiff,
          );
          if (merged == null) {
            AppLogger.debug('  → 行単位で合わせられなかった。衝突のまま残す');
            continue;
          }
          mergedCount++;
          conflicts.addAll(merged.conflicts);
          syncedFiles[relativePath] = KMetaSyncFile(
            driveFileId: merged.driveFileId,
            lastSyncedTime: DateTime.now(),
          );
          continue;
        }
        if (choice == MergeChoice.local) {
          switch (entry.localChange) {
            case MergeChangeType.added:
            case MergeChangeType.modified:
              if (await fs.exists(localFilePath)) {
                final relativeDir = p.dirname(relativePath);
                String targetFolderId = driveId;
                if (relativeDir != '.' && relativeDir.isNotEmpty) {
                  final folderId = await _fileOps.getDriveFolderIdForRelativeDir(
                    driveId, relativeDir, folderIdCache);
                  if (folderId != null) {
                    targetFolderId = folderId;
                  }
                }

                final result =
                    await _driveService.uploadFile(localFilePath, targetFolderId);
                if (result != null) {
                  uploadedCount++;
                  syncedFiles[relativePath] = KMetaSyncFile(
                    driveFileId: result.id!,
                    lastSyncedTime: DateTime.now(),
                  );
                  await SyncBaseStore.saveBase(localPath, relativePath, geodiff: geodiff); // web では saveBase が何もしない
                }
              }
            case MergeChangeType.deleted:
              if (entry.driveFileId != null) {
                await _driveService.deleteFile(entry.driveFileId!);
                syncedFiles.remove(relativePath);
                deletedCount++;
              }
            case MergeChangeType.none:
              AppLogger.debug('  → ローカル変更なし、リモート変更を復元: ${entry.remoteChange}');
              switch (entry.remoteChange) {
                case MergeChangeType.deleted:
                  if (await fs.exists(localFilePath)) {
                    final relativeDir = p.dirname(relativePath);
                    String targetFolderId = driveId;
                    if (relativeDir != '.' && relativeDir.isNotEmpty) {
                      final folderId = await _fileOps.getDriveFolderIdForRelativeDir(
                        driveId, relativeDir, folderIdCache);
                      if (folderId != null) {
                        targetFolderId = folderId;
                      }
                    }

                    final result =
                    await _driveService.uploadFile(localFilePath, targetFolderId);
                    if (result != null) {
                      uploadedCount++;
                      syncedFiles[relativePath] = KMetaSyncFile(
                        driveFileId: result.id!,
                        lastSyncedTime: DateTime.now(),
                      );
                      await SyncBaseStore.saveBase(localPath, relativePath, geodiff: geodiff); // web では saveBase が何もしない
                    }
                  }
                case MergeChangeType.added:
                  AppLogger.debug('  → リモート追加を削除（復元）');
                  if (entry.driveFileId != null) {
                    AppLogger.debug('    削除対象driveFileId: ${entry.driveFileId}');

                    final metadata = await _driveService.getFileMetadata(entry.driveFileId!);
                    if (metadata != null) {
                      AppLogger.debug('    ファイル存在確認OK: ${metadata.name}, trashed=${metadata.trashed}');
                      final deleted = await _driveService.deleteFile(entry.driveFileId!);
                      if (deleted) {
                        syncedFiles.remove(relativePath);
                        deletedCount++;
                        AppLogger.debug('    削除完了');
                      } else {
                        AppLogger.debug('    削除失敗');
                      }
                    } else {
                      AppLogger.debug('    ファイルが見つからない（getFileMetadata=null）');
                      syncedFiles.remove(relativePath);
                    }
                  } else {
                    AppLogger.debug('    driveFileIdがnullのためスキップ');
                  }
                case MergeChangeType.modified:
                  if (await fs.exists(localFilePath)) {
                    final relativeDir = p.dirname(relativePath);
                    String targetFolderId = driveId;
                    if (relativeDir != '.' && relativeDir.isNotEmpty) {
                      final folderId = await _fileOps.getDriveFolderIdForRelativeDir(
                        driveId, relativeDir, folderIdCache);
                      if (folderId != null) {
                        targetFolderId = folderId;
                      }
                    }

                    final result =
                    await _driveService.uploadFile(localFilePath, targetFolderId);
                    if (result != null) {
                      uploadedCount++;
                      syncedFiles[relativePath] = KMetaSyncFile(
                        driveFileId: result.id!,
                        lastSyncedTime: DateTime.now(),
                      );
                      await SyncBaseStore.saveBase(localPath, relativePath, geodiff: geodiff); // web では saveBase が何もしない
                    }
                  }
                case MergeChangeType.moved:
                  // ローカルを採用 → Driveのファイルを元の場所（ローカルのパス）に戻す
                  if (entry.driveFileId != null && entry.moveInfo != null) {
                    final relDir = p.dirname(relativePath);
                    final localParentId = await _fileOps.getDriveFolderIdForRelativeDir(
                      driveId, relDir, folderIdCache);
                    if (localParentId != null) {
                      await _driveService.moveFile(
                        entry.driveFileId!,
                        newParentId: localParentId,
                      );
                      syncedFiles[relativePath] = KMetaSyncFile(
                        driveFileId: entry.driveFileId!,
                        lastSyncedTime: DateTime.now(),
                      );
                    }
                  }
                case MergeChangeType.none:
                  break;
              }
            case MergeChangeType.moved:
              break;
          }
        } else {
          // リモートを採用
          switch (entry.remoteChange) {
            case MergeChangeType.added:
            case MergeChangeType.modified:
              if (entry.driveFileId != null) {
                await fs.createDirectory(p.dirname(localFilePath));

                final success = await _driveService.downloadFile(
                  entry.driveFileId!,
                  localFilePath,
                );
                if (success) {
                  downloadedCount++;
                  syncedFiles[relativePath] = KMetaSyncFile(
                    driveFileId: entry.driveFileId!,
                    lastSyncedTime: DateTime.now(),
                  );
                  await SyncBaseStore.saveBase(localPath, relativePath, geodiff: geodiff); // web では saveBase が何もしない
                }
              }
            case MergeChangeType.deleted:
              if (await fs.exists(localFilePath)) {
                await fs.delete(localFilePath);
                syncedFiles.remove(relativePath);
                deletedCount++;
              }
            case MergeChangeType.moved:
              if (entry.moveInfo != null && entry.driveFileId != null) {
                final oldPath = _fileOps.relativePathToLocalPath(localPath, entry.moveInfo!.movedFrom ?? relativePath);
                final newLocalPath = _fileOps.relativePathToLocalPath(localPath, entry.moveInfo!.movedTo ?? relativePath);
                if (await fs.exists(oldPath)) {
                  await fs.createDirectory(p.dirname(newLocalPath));
                  await fs.rename(oldPath, newLocalPath);
                  syncedFiles.remove(entry.moveInfo!.movedFrom ?? relativePath);

                  syncedFiles[entry.moveInfo!.movedTo ?? relativePath] = KMetaSyncFile(
                    driveFileId: entry.driveFileId!,
                    lastSyncedTime: DateTime.now(),
                  );
                  movedCount++;
                }
              }
            case MergeChangeType.none:
              switch (entry.localChange) {
                case MergeChangeType.deleted:
                  if (entry.driveFileId != null) {
                    await fs.createDirectory(p.dirname(localFilePath));

                    final success = await _driveService.downloadFile(
                      entry.driveFileId!,
                      localFilePath,
                    );
                    if (success) {
                      downloadedCount++;
                      syncedFiles[relativePath] = KMetaSyncFile(
                        driveFileId: entry.driveFileId!,
                        lastSyncedTime: DateTime.now(),
                      );
                      await SyncBaseStore.saveBase(localPath, relativePath, geodiff: geodiff); // web では saveBase が何もしない
                    }
                  }
                case MergeChangeType.added:
                  if (await fs.exists(localFilePath)) {
                    await fs.delete(localFilePath);
                    syncedFiles.remove(relativePath);
                    deletedCount++;
                  }
                case MergeChangeType.modified:
                  if (entry.driveFileId != null) {
                    final success = await _driveService.downloadFile(
                      entry.driveFileId!,
                      localFilePath,
                    );
                    if (success) {
                      downloadedCount++;
                      syncedFiles[relativePath] = KMetaSyncFile(
                        driveFileId: entry.driveFileId!,
                        lastSyncedTime: DateTime.now(),
                      );
                      await SyncBaseStore.saveBase(localPath, relativePath, geodiff: geodiff); // web では saveBase が何もしない
                    }
                  }
                case MergeChangeType.moved:
                  break;
                case MergeChangeType.none:
                  break;
              }
          }
        }
      }

      await _kmetaService.setDriveSync(
        localPath,
        driveId: driveId,
        driveUrl: meta.sync.driveUrl,
        isReadOnly: meta.sync.isReadOnly,
        files: syncedFiles,
      );

      // Driveに存在しない空フォルダをローカルから削除（深い階層から処理）
      await _cleanupEmptyLocalFolders(localPath, driveId);

      AppLogger.debug(
        '[SyncEngine] Merge完了: $uploadedCount uploaded, '
        '$downloadedCount downloaded, $deletedCount deleted, $movedCount moved',
      );

      return SyncResult.success(
        uploadedCount: uploadedCount,
        downloadedCount: downloadedCount,
        deletedCount: deletedCount,
        movedCount: movedCount,
        mergedCount: mergedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      AppLogger.error('[SyncEngine] Merge エラー: $e');
      return SyncResult.failure(e.toString());
    } finally {
      geodiff?.dispose();
    }
  }

  /// 両方が変えた gpkg を行単位で合わせて Drive に上げる（docs/technical/drive-geodiff-sync.md）。
  ///
  /// リモートを一時ファイルに落とし、`rebase(base, remote, local)` でローカルに両方の変更を載せ、
  /// ローカルを上げて base を写し直す。どこかで失敗したら null（呼び手は衝突のまま残す）。
  /// ⚠ rebase 済みなのに上げられなかったときは、ローカルには相手の変更が載ったまま base は古い。
  ///   次の同期でもう一度 merge になる。
  Future<({String driveFileId, List<GpkgConflict> conflicts})?> _mergeGpkg({
    required String localPath,
    required MergeFileEntry entry,
    required String localFilePath,
    required String driveId,
    required Map<String, String> folderIdCache,
    required Geodiff geodiff,
  }) async {
    final relativePath = entry.relativePath;
    final fileId = entry.driveFileId;
    if (fileId == null) return null;
    final base = SyncBaseStore.basePath(localPath, relativePath);
    if (!await fs.exists(base) || !await fs.exists(localFilePath)) {
      AppLogger.debug('  base かローカルが無い: base=$base');
      return null;
    }
    final tmp = SyncBaseStore.tmpPath(localPath, relativePath);
    try {
      await fs.createDirectory(p.dirname(tmp));
      if (!await _driveService.downloadFile(fileId, tmp)) {
        AppLogger.debug('  リモートを落とせなかった');
        return null;
      }
      final r = await GpkgMerger(geodiff).rebase(base: base, theirs: tmp, mine: localFilePath);
      if (!r.success) {
        AppLogger.debug('  rebase 失敗: ${r.error}');
        return null;
      }
      // この間に Drive が動いていたら上げない（次の同期で載せ直す）
      final meta = await _driveService.getFileMetadata(fileId);
      final remoteAt = entry.remoteModifiedTime;
      if (meta?.modifiedTime != null && remoteAt != null && meta!.modifiedTime!.isAfter(remoteAt)) {
        AppLogger.debug('  Drive 側が同期開始後に動いた。上げずに次回へ');
        return null;
      }
      final relativeDir = p.dirname(relativePath);
      String targetFolderId = driveId;
      if (relativeDir != '.' && relativeDir.isNotEmpty) {
        final folderId = await _fileOps.getDriveFolderIdForRelativeDir(driveId, relativeDir, folderIdCache);
        if (folderId != null) targetFolderId = folderId;
      }
      final uploaded = await _driveService.uploadFileById(localFilePath, targetFolderId, existingFileId: fileId);
      if (uploaded == null) {
        AppLogger.debug('  上げられなかった');
        return null;
      }
      await SyncBaseStore.saveBase(localPath, relativePath, geodiff: geodiff);
      AppLogger.debug('  → 行単位で合わせた（衝突 ${r.conflicts.length} 件）');
      return (driveFileId: uploaded.id ?? fileId, conflicts: r.conflicts);
    } finally {
      try {
        if (await fs.exists(tmp)) await fs.delete(tmp);
      } catch (_) {}
    }
  }

  /// Driveのフォルダ構造をローカルに反映（空フォルダ含む）
  ///
  /// [driveId] を省略すると .kmeta.json から取得する。
  /// 作成したフォルダ数を返す。
  Future<int> ensureDriveFolders(
    String localPath, {
    String? driveId,
  }) async {
    try {
      driveId ??= (await _kmetaService.getMeta(localPath)).sync.driveId;
      if (driveId == null) return 0;

      final driveData = await _fileOps.listDriveFilesWithFolders(driveId);
      int created = 0;
      for (final relativeFolderPath in driveData.folderMap.values) {
        if (relativeFolderPath.isEmpty) continue;
        final dirPath =
            _fileOps.relativePathToLocalPath(localPath, relativeFolderPath);
        if (!await fs.isDirectory(dirPath)) {
          await fs.createDirectory(dirPath);
          created++;
          AppLogger.debug('[SyncEngine] フォルダ作成: $relativeFolderPath');
        }
      }
      return created;
    } catch (e) {
      AppLogger.error('[SyncEngine] ensureDriveFolders エラー: $e');
      return 0;
    }
  }

  /// Driveに存在しない空のローカルフォルダを削除
  Future<void> _cleanupEmptyLocalFolders(
    String localPath,
    String driveId,
  ) async {
    try {
      final driveData = await _fileOps.listDriveFilesWithFolders(driveId);
      final driveFolderPaths = driveData.folderMap.values
          .where((v) => v.isNotEmpty)
          .toSet();

      if (!await fs.isDirectory(localPath)) return;

      final localDirs = await fs.listDirectoriesRecursive(localPath);
      // 深い階層から処理して連鎖削除を可能にする
      localDirs.sort((a, b) => b.path.length.compareTo(a.path.length));

      for (final dir in localDirs) {
        final relativePath = _fileOps.normalizeRelativePath(
          p.relative(dir.path, from: localPath),
        );
        if (SyncBaseStore.isInside(relativePath)) continue;
        if (driveFolderPaths.contains(relativePath)) continue;
        if ((await fs.list(dir.path)).isEmpty) {
          await fs.delete(dir.path);
          AppLogger.debug('[SyncEngine] 空フォルダ削除: $relativePath');
        }
      }
    } catch (e) {
      AppLogger.error('[SyncEngine] 空フォルダクリーンアップエラー: $e');
    }
  }
}
