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
// ファイルごとの選択（端末を採用・クラウドを採用・行単位で合わせる）の反映を担当
// （何が変わったかの判定は sync_snapshot.dart）

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/geopackage/geopackage_connection.dart';
import '../../models/geopackage/gpkg_index_repair.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import '../geodiff/geodiff.dart';
import '../kmeta_service.dart';
import '../qgis/qgs_meta_store.dart';
import 'google_drive_service.dart';
import 'gpkg_merger.dart';
import 'gpkg_schema_aligner.dart';
import 'qgs_merger.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';
import 'sync_snapshot.dart';

/// 1 回のマージの途中経過（帳簿・数・衝突）
class _MergeRun {
  _MergeRun(this.localPath, this.driveId, this.syncedFiles, this.folderIdCache);

  final String localPath;
  final String driveId;

  /// 書き換えていく帳簿
  final Map<String, KMetaSyncFile> syncedFiles;

  /// Drive のフォルダ：相対パス→ID（Drive の一覧で種を入れ、作ったフォルダも足していく）
  final Map<String, String> folderIdCache;

  int uploaded = 0;
  int downloaded = 0;
  int deleted = 0;
  int moved = 0;
  int merged = 0;
  final conflicts = <GpkgConflict>[];
  final failedMerges = <String>[];
  final settingConflicts = <QgsSettingConflict>[];

  /// 行単位マージで初めて要るときに作る（base の写しにも使い回す）
  Geodiff? geodiff;

  /// 同期できたと帳簿に書く
  void record(String relativePath, String driveFileId, DateTime? remoteModifiedTime) {
    syncedFiles[relativePath] = KMetaSyncFile(
      driveFileId: driveFileId,
      lastSyncedTime: DateTime.now(),
      remoteModifiedTime: remoteModifiedTime,
    );
  }

  SyncResult toResult() => SyncResult.success(
        uploadedCount: uploaded,
        downloadedCount: downloaded,
        deletedCount: deleted,
        movedCount: moved,
        mergedCount: merged,
        conflicts: conflicts,
        failedMerges: failedMerges,
        settingConflicts: settingConflicts,
      );
}

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

  /// マージを実行
  ///
  /// [snapshot] が同じ連携先のものなら、Drive のフォルダ構成はそれを使う（たどり直さない）
  Future<SyncResult> executeMerge(
    String localPath,
    List<MergeDecision> decisions, {
    SyncSnapshot? snapshot,
  }) async {
    _MergeRun? run;
    try {
      final meta = await _kmetaService.getMeta(localPath);
      final driveId = meta.sync.driveId;
      if (driveId == null) {
        return SyncResult.failure('Drive連携されていません');
      }

      final tree = snapshot != null && snapshot.driveId == driveId
          ? snapshot.drive
          : await _fileOps.listDriveTree(driveId);
      run = _MergeRun(localPath, driveId, Map.of(meta.sync.files), tree.folderIdsByPath());

      // Driveのフォルダ構造をローカルに反映（空フォルダ含む）
      try {
        await _fileOps.ensureLocalDirs(localPath, tree.folderPaths);
      } catch (e) {
        AppLogger.error('[SyncEngine] ensureDriveFolders エラー: $e');
      }

      AppLogger.debug('[SyncEngine] executeMerge開始: ${decisions.length}件の決定');
      for (final decision in decisions) {
        await _apply(run, decision);
      }

      await _kmetaService.setDriveSync(
        localPath,
        driveId: driveId,
        driveUrl: meta.sync.driveUrl,
        isReadOnly: meta.sync.isReadOnly,
        files: run.syncedFiles,
      );

      // Driveに存在しない空フォルダをローカルから削除。Drive のフォルダは、最初の一覧と
      // このマージで作ったもの（どちらも folderIdCache に入っている）
      try {
        await _fileOps.removeEmptyLocalDirs(localPath, run.folderIdCache.keys.toSet());
      } catch (e) {
        AppLogger.error('[SyncEngine] 空フォルダクリーンアップエラー: $e');
      }

      AppLogger.debug(
        '[SyncEngine] Merge完了: ${run.uploaded} uploaded, '
        '${run.downloaded} downloaded, ${run.deleted} deleted, ${run.moved} moved',
      );
      return run.toResult();
    } catch (e) {
      AppLogger.error('[SyncEngine] Merge エラー: $e');
      return SyncResult.failure(e.toString());
    } finally {
      run?.geodiff?.dispose();
    }
  }

  /// 1 件の選択を反映する
  Future<void> _apply(_MergeRun run, MergeDecision decision) async {
    final entry = decision.entry;
    final relativePath = entry.relativePath;
    final localFilePath = _fileOps.relativePathToLocalPath(run.localPath, relativePath);

    AppLogger.debug('[SyncEngine] 処理: $relativePath');
    AppLogger.debug('  choice: ${decision.choice}');
    AppLogger.debug('  localChange: ${entry.localChange}');
    AppLogger.debug('  remoteChange: ${entry.remoteChange}');
    AppLogger.debug('  driveFileId: ${entry.driveFileId}');

    switch (decision.choice) {
      case MergeChoice.merge:
        await _merge(run, entry, localFilePath);
      case MergeChoice.local:
        await _keepLocal(run, entry, localFilePath);
      case MergeChoice.remote:
        await _takeRemote(run, entry, localFilePath);
    }
  }

  // ========== 端末を採用 ==========

  Future<void> _keepLocal(_MergeRun run, MergeFileEntry entry, String localFilePath) async {
    final relativePath = entry.relativePath;
    final fileId = entry.driveFileId;
    switch (entry.localChange) {
      case MergeChangeType.added:
      case MergeChangeType.modified:
        await _uploadLocal(run, relativePath, localFilePath);
      case MergeChangeType.deleted:
        if (fileId != null) {
          await _driveService.deleteFile(fileId);
          run.syncedFiles.remove(relativePath);
          run.deleted++;
        }
      case MergeChangeType.none:
        AppLogger.debug('  → ローカル変更なし、リモート変更を復元: ${entry.remoteChange}');
        switch (entry.remoteChange) {
          case MergeChangeType.deleted:
          case MergeChangeType.modified:
            await _uploadLocal(run, relativePath, localFilePath);
          case MergeChangeType.added:
            await _trashRemoteAddition(run, entry);
          case MergeChangeType.moved:
            // ローカルを採用 → Driveのファイルを元の場所（ローカルのパス）に戻す
            if (fileId != null && entry.moveInfo != null) {
              final localParentId = await _folderId(run, p.dirname(relativePath));
              if (localParentId != null) {
                await _driveService.moveFile(fileId, newParentId: localParentId);
                run.syncedFiles[relativePath] = KMetaSyncFile(driveFileId: fileId, lastSyncedTime: DateTime.now());
              }
            }
          case MergeChangeType.none:
            break;
        }
      case MergeChangeType.moved:
        await _moveOnDrive(run, entry, localFilePath);
    }
  }

  /// 手元のファイルを Drive の同じ場所に上げる（同名があればその版を更新）
  Future<void> _uploadLocal(_MergeRun run, String relativePath, String localFilePath) async {
    if (!await fs.exists(localFilePath)) return;
    // フォルダを解決できなければ根に上げる（以前から）
    final targetFolderId = await _folderId(run, p.dirname(relativePath)) ?? run.driveId;
    final result = await _driveService.uploadFile(localFilePath, targetFolderId);
    if (result == null) return;
    run.uploaded++;
    run.record(relativePath, result.id!, result.modifiedTime);
    await SyncBaseStore.saveBase(run.localPath, relativePath, geodiff: run.geodiff); // web では saveBase が何もしない
  }

  /// Drive にだけ足されたものを消す（端末を採用＝無かったことにする）
  Future<void> _trashRemoteAddition(_MergeRun run, MergeFileEntry entry) async {
    AppLogger.debug('  → リモート追加を削除（復元）');
    final fileId = entry.driveFileId;
    if (fileId == null) {
      AppLogger.debug('    driveFileIdがnullのためスキップ');
      return;
    }
    AppLogger.debug('    削除対象driveFileId: $fileId');
    final metadata = await _driveService.getFileMetadata(fileId);
    if (metadata == null) {
      AppLogger.debug('    ファイルが見つからない（getFileMetadata=null）');
      run.syncedFiles.remove(entry.relativePath);
      return;
    }
    AppLogger.debug('    ファイル存在確認OK: ${metadata.name}, trashed=${metadata.trashed}');
    if (await _driveService.deleteFile(fileId)) {
      run.syncedFiles.remove(entry.relativePath);
      run.deleted++;
      AppLogger.debug('    削除完了');
    } else {
      AppLogger.debug('    削除失敗');
    }
  }

  /// この端末で改名・移動した → Drive 側も同じ場所・名前へ（中身は同じファイル、履歴も残る）。
  ///
  /// `.qgs` は名前が設定から決まるので、dir の改名のあと新しい名前に付け替わっていて手元に無いことがある。
  /// そのときは Drive の古い名前のものを消す（新しい名前のものは追加として上がる）
  Future<void> _moveOnDrive(_MergeRun run, MergeFileEntry entry, String localFilePath) async {
    final relativePath = entry.relativePath;
    final fileId = entry.driveFileId;
    if (fileId == null) return;
    if (SyncBaseStore.isQgs(relativePath) && !await fs.exists(localFilePath)) {
      if (await _driveService.deleteFile(fileId)) {
        run.syncedFiles.remove(relativePath);
        run.deleted++;
      }
      return;
    }
    final parentId = await _folderId(run, p.dirname(relativePath));
    final from = entry.moveInfo?.movedFrom;
    final newName = p.posix.basename(relativePath);
    if (parentId != null &&
        await _driveService.moveFile(
          fileId,
          newParentId: parentId,
          newName: from != null && p.posix.basename(from) != newName ? newName : null,
        )) {
      run.record(relativePath, fileId, entry.remoteModifiedTime);
      run.moved++;
    }
  }

  // ========== クラウドを採用 ==========

  Future<void> _takeRemote(_MergeRun run, MergeFileEntry entry, String localFilePath) async {
    final relativePath = entry.relativePath;
    switch (entry.remoteChange) {
      case MergeChangeType.added:
      case MergeChangeType.modified:
        await _downloadRemote(run, entry, localFilePath, createDir: true);
      case MergeChangeType.deleted:
        await _deleteLocal(run, relativePath, localFilePath);
      case MergeChangeType.moved:
        final move = entry.moveInfo;
        final fileId = entry.driveFileId;
        if (move == null || fileId == null) return;
        final from = move.movedFrom ?? relativePath;
        final to = move.movedTo ?? relativePath;
        final oldPath = _fileOps.relativePathToLocalPath(run.localPath, from);
        final newLocalPath = _fileOps.relativePathToLocalPath(run.localPath, to);
        if (await fs.exists(oldPath)) {
          await fs.createDirectory(p.dirname(newLocalPath));
          await fs.rename(oldPath, newLocalPath);
          run.syncedFiles.remove(from);
          run.record(to, fileId, entry.remoteModifiedTime);
          run.moved++;
        }
      case MergeChangeType.none:
        switch (entry.localChange) {
          case MergeChangeType.deleted:
            await _downloadRemote(run, entry, localFilePath, createDir: true);
          case MergeChangeType.added:
            await _deleteLocal(run, relativePath, localFilePath);
          case MergeChangeType.modified:
            await _downloadRemote(run, entry, localFilePath, createDir: false);
          case MergeChangeType.moved:
          case MergeChangeType.none:
            break;
        }
    }
  }

  /// Drive の版で手元を置き換える
  Future<void> _downloadRemote(
    _MergeRun run,
    MergeFileEntry entry,
    String localFilePath, {
    required bool createDir,
  }) async {
    final fileId = entry.driveFileId;
    if (fileId == null) return;
    if (createDir) await fs.createDirectory(p.dirname(localFilePath));
    if (!await _fileOps.downloadReplacing(fileId, localFilePath)) return;
    run.downloaded++;
    run.record(entry.relativePath, fileId, entry.remoteModifiedTime);
    await SyncBaseStore.saveBase(run.localPath, entry.relativePath, geodiff: run.geodiff); // web では saveBase が何もしない
  }

  Future<void> _deleteLocal(_MergeRun run, String relativePath, String localFilePath) async {
    if (!await fs.exists(localFilePath)) return;
    await fs.delete(localFilePath);
    run.syncedFiles.remove(relativePath);
    run.deleted++;
  }

  // ========== 両方の変更を合わせる ==========

  Future<void> _merge(_MergeRun run, MergeFileEntry entry, String localFilePath) async {
    final relativePath = entry.relativePath;
    if (SyncBaseStore.isQgs(relativePath)) {
      final merged = await _mergeWithRemote(run, entry, localFilePath, (base, theirs) async {
        // この端末の設定の書き込み・自動更新と、読んで直して書く間を取り合わない
        final r = await QgsFileLock.run(localFilePath, () async {
          final r = await QgsMerger.merge(
            base: await fs.readAsString(base),
            mine: await fs.readAsString(localFilePath),
            theirs: await fs.readAsString(theirs),
          );
          if (r != null) await QgsFileWriter.write(localFilePath, r.xml);
          return r;
        });
        if (r == null) return null;
        if (r.conflicts.isNotEmpty) AppLogger.debug('  設定の衝突（この端末の値を残した）: ${r.conflicts}');
        _kmetaService.invalidateCache(p.dirname(localFilePath));
        return [for (final c in r.conflicts) c.withDir(p.dirname(localFilePath))];
      });
      if (merged == null) {
        AppLogger.debug('  → 設定を合わせられなかった。衝突のまま残す');
        run.failedMerges.add(relativePath);
        return;
      }
      AppLogger.debug('  → 設定を合わせた（衝突 ${merged.length} 件）');
      run.merged++;
      run.settingConflicts.addAll(merged);
      return;
    }

    final geodiff = run.geodiff ??= Geodiff();
    final merged = await _mergeWithRemote(run, entry, localFilePath, (base, theirs) async {
      // geodiff の SQLite が書く前に、アプリの接続を閉じる（次の getDatabase() で開き直る）
      await GeoPackageConnection.closeAllFor(localFilePath);
      // 片側だけが列を足していれば、3 つのスキーマをそろえてから（geodiff はスキーマの変更をまたげない）
      final aligned = await GpkgSchemaAligner.align(base: base, theirs: theirs, mine: localFilePath);
      if (aligned.added.isNotEmpty) AppLogger.debug('  列をそろえた: ${aligned.added}');
      final r = await GpkgMerger(geodiff).rebase(base: base, theirs: theirs, mine: localFilePath);
      if (!r.success) {
        AppLogger.debug('  rebase 失敗: ${r.error}');
        return null;
      }
      // geodiff は rtree_* / gpkg_* を触らない。QGIS が読む索引と範囲を実データに合わせる
      final repaired = await GpkgIndexRepair.rebuildFile(localFilePath);
      AppLogger.debug('  索引の焼き直し: $repaired テーブル');
      return [for (final c in r.conflicts) c.withFile(localFilePath)];
    });
    if (merged == null) {
      AppLogger.debug('  → 行単位で合わせられなかった。衝突のまま残す');
      run.failedMerges.add(relativePath);
      return;
    }
    AppLogger.debug('  → 行単位で合わせた（衝突 ${merged.length} 件）');
    run.merged++;
    run.conflicts.addAll(merged);
  }

  /// 両方が変えたファイルを合わせて Drive に上げる（docs/technical/drive-geodiff-sync.md）。
  ///
  /// リモートを一時ファイルに落とし、[combine]（base・リモート → 手元に両方の変更を載せる）で合わせ、
  /// その間に Drive が動いていなければ手元を上げて base を写し直し、帳簿に書く。
  /// どこかで失敗したら null（呼び手は衝突のまま残す）。
  /// ⚠ 合わせたのに上げられなかったときは、ローカルには相手の変更が載ったまま base は古い。
  ///   次の同期でもう一度 merge になる。
  Future<List<T>?> _mergeWithRemote<T>(
    _MergeRun run,
    MergeFileEntry entry,
    String localFilePath,
    Future<List<T>?> Function(String base, String theirs) combine,
  ) async {
    final relativePath = entry.relativePath;
    final fileId = entry.driveFileId;
    if (fileId == null) return null;
    final base = SyncBaseStore.basePath(run.localPath, relativePath);
    if (!await fs.exists(base) || !await fs.exists(localFilePath)) {
      AppLogger.debug('  base かローカルが無い: base=$base');
      return null;
    }
    final tmp = SyncBaseStore.tmpPath(run.localPath, relativePath);
    try {
      await fs.createDirectory(p.dirname(tmp));
      if (!await _driveService.downloadFile(fileId, tmp)) {
        AppLogger.debug('  リモートを落とせなかった');
        return null;
      }
      final conflicts = await combine(base, tmp);
      if (conflicts == null) return null;

      // この間に Drive が動いていたら上げない（次の同期で載せ直す）
      final meta = await _driveService.getFileMetadata(fileId);
      final remoteAt = entry.remoteModifiedTime;
      if (meta?.modifiedTime != null && remoteAt != null && meta!.modifiedTime!.isAfter(remoteAt)) {
        AppLogger.debug('  Drive 側が同期開始後に動いた。上げずに次回へ');
        return null;
      }
      final targetFolderId = await _folderId(run, p.dirname(relativePath)) ?? run.driveId;
      final uploaded = await _driveService.uploadFileById(localFilePath, targetFolderId, existingFileId: fileId);
      if (uploaded == null) {
        AppLogger.debug('  上げられなかった');
        return null;
      }
      await SyncBaseStore.saveBase(run.localPath, relativePath, geodiff: run.geodiff);
      run.record(relativePath, uploaded.id ?? fileId, uploaded.modifiedTime);
      return conflicts;
    } finally {
      try {
        if (await fs.exists(tmp)) await fs.delete(tmp);
      } catch (_) {}
    }
  }

  /// Drive の相対フォルダの ID（無ければ作る）
  Future<String?> _folderId(_MergeRun run, String relativeDir) =>
      _fileOps.getDriveFolderIdForRelativeDir(run.driveId, relativeDir, run.folderIdCache);
}
