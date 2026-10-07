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
// Root Maps: 同期の判定
// 帳簿・Drive・手元をそろえて見て、何が変わったかを出す（同期状態とマージの一覧）

import 'package:googleapis/drive/v3.dart' as gdrive;
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'google_drive_service.dart';
import 'sync_base_store.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';

/// 同期の判定の材料（帳簿・Drive・手元を同じ時点でそろえて見たもの）。
///
/// 同期状態（[toStatusDetail]）とマージの一覧（[toMergeEntries]）は同じ材料から出す。
/// 自動同期は判定に使った材料をそのまま push / pull / マージに渡し、Drive をもう一度たどらない
class SyncSnapshot {
  SyncSnapshot._({
    required this.localPath,
    required this.meta,
    required this.driveId,
    required this.folderInfo,
    required this.drive,
    required this.localFiles,
  });

  final String localPath;

  /// 集めた時点のフォルダ設定（帳簿を含む）
  final KMeta meta;

  final String driveId;

  /// 連携先の Drive フォルダ
  final gdrive.File folderInfo;

  /// Drive のフォルダ配下
  final DriveTree drive;

  /// 手元の同期対象ファイル（相対パス→更新日時）
  final Map<String, DateTime> localFiles;

  Map<String, KMetaSyncFile> get _ledger => meta.sync.files;

  /// 材料を集める。連携していなければ [FolderSyncStatus.notLinked]、Drive のフォルダを取れなければ
  /// [FolderSyncStatus.error] を failure に返す
  static Future<({SyncSnapshot? snapshot, FolderSyncStatus? failure})> take(
    String localPath, {
    required GoogleDriveService driveService,
    required KMetaService kmetaService,
    required SyncFileOperations fileOps,
  }) async {
    final meta = await kmetaService.getMeta(localPath);
    final driveId = meta.sync.driveId;
    if (driveId == null) {
      AppLogger.debug('[SyncSnapshot] driveId が無い: $localPath');
      return (snapshot: null, failure: FolderSyncStatus.notLinked);
    }
    // フォルダの確認・Drive の一覧・手元の走査は互いに待たない
    final (folderInfo, tree, localFiles) = await (
      driveService.getFolderInfo(driveId),
      fileOps.listDriveTree(driveId),
      fileOps.scanLocalFiles(localPath),
    ).wait;
    if (folderInfo == null) {
      AppLogger.debug('[SyncSnapshot] Driveのフォルダを取れない: $driveId');
      return (snapshot: null, failure: FolderSyncStatus.error);
    }
    return (
      snapshot: SyncSnapshot._(
        localPath: localPath,
        meta: meta,
        driveId: driveId,
        folderInfo: folderInfo,
        drive: tree,
        localFiles: localFiles,
      ),
      failure: null,
    );
  }

  // ========== 突き合わせ ==========

  late final _Diff _diff = _Diff.of(_ledger, drive, localFiles);

  /// 同期状態の詳細
  Future<FolderSyncStatusDetail> toStatusDetail(SyncFileOperations fileOps) async {
    final localAdded = _diff.localOnly.keys.toList();
    final localDeleted = <String>[];
    final localModified = <String>[];
    final remoteAdded = [for (final e in _diff.driveOnly) e.relativePath];
    final remoteDeleted = <String>[];
    final remoteModified = <String>[];
    final remoteMoved = <FileChangeInfo>[];

    for (final item in _diff.ledger) {
      final lastSyncedTime = item.synced.lastSyncedTime;
      if (item.onDrive == null) {
        remoteDeleted.add(item.path);
      } else if (item.localMove) {
        // この端末で改名・移動したもの（Drive はまだ元の場所）。push が Drive 側も動かす
        localModified.add(item.path);
      } else if (item.remoteMove) {
        remoteMoved.add(FileChangeInfo(
          fileName: item.path,
          type: item.remoteNewer ? FileChangeType.movedAndModified : FileChangeType.moved,
          movedFrom: item.path,
          movedTo: item.onDrive!.relativePath,
        ));
      } else if (lastSyncedTime == null || item.remoteNewer) {
        remoteModified.add(item.path);
      }

      if (item.consumedByMove) continue;
      final localTime = item.localModified;
      if (localTime == null) {
        localDeleted.add(item.path);
      } else if (lastSyncedTime == null || localTime.isAfter(lastSyncedTime)) {
        localModified.add(item.path);
      }
    }

    // Driveにあるがローカルに存在しないフォルダ
    for (final folder in drive.folderPaths) {
      if (!await fs.isDirectory(fileOps.relativePathToLocalPath(localPath, folder))) {
        remoteAdded.add('$folder/');
      }
    }

    final neverSynced = _ledger.isEmpty && meta.sync.lastSynced == null;
    final hasLocal = localAdded.isNotEmpty || localDeleted.isNotEmpty || localModified.isNotEmpty;
    final hasRemote =
        remoteAdded.isNotEmpty || remoteDeleted.isNotEmpty || remoteModified.isNotEmpty || remoteMoved.isNotEmpty;
    final status = neverSynced
        ? FolderSyncStatus.remoteChanges
        : hasLocal && hasRemote
            ? FolderSyncStatus.conflict
            : hasLocal
                ? FolderSyncStatus.localChanges
                : hasRemote
                    ? FolderSyncStatus.remoteChanges
                    : FolderSyncStatus.synced;

    return FolderSyncStatusDetail(
      status: status,
      localAdded: localAdded.length,
      localDeleted: localDeleted.length,
      localModified: localModified.length,
      remoteAdded: remoteAdded.length,
      remoteDeleted: remoteDeleted.length,
      remoteModified: remoteModified.length,
      remoteMoved: remoteMoved.length,
      localAddedFiles: localAdded,
      localDeletedFiles: localDeleted,
      localModifiedFiles: localModified,
      remoteAddedFiles: remoteAdded,
      remoteDeletedFiles: remoteDeleted,
      remoteModifiedFiles: remoteModified,
      remoteMovedFiles: remoteMoved,
      snapshot: this,
    );
  }

  /// マージ用のファイルエントリ一覧。途中で失敗したら、そこまでの分を返す
  Future<List<MergeFileEntry>> toMergeEntries() async {
    final entries = <MergeFileEntry>[];
    AppLogger.debug(
      '[getMergeEntries] local=${localFiles.keys.toList()} '
      'drive=${drive.files.map((e) => e.relativePath).toList()} '
      'synced=${_ledger.keys.toList()}',
    );
    try {
      for (final item in _diff.ledger) {
        final lastSyncedTime = item.synced.lastSyncedTime;
        final drivePath = item.onDrive?.relativePath;
        var localChange = MergeChangeType.none;
        var remoteChange = MergeChangeType.none;
        FileChangeInfo? moveInfo;

        if (drivePath == null) {
          remoteChange = MergeChangeType.deleted;
        } else if (item.localMove) {
          // この端末で改名・移動したもの（Drive はまだ元の場所）→ ローカルの移動
          localChange = MergeChangeType.moved;
          moveInfo = FileChangeInfo(
            fileName: item.path,
            type: FileChangeType.moved,
            movedFrom: drivePath,
            movedTo: item.path,
          );
        } else if (item.remoteMove) {
          remoteChange = MergeChangeType.moved;
          moveInfo = FileChangeInfo(
            fileName: item.path,
            type: FileChangeType.moved,
            movedFrom: item.path,
            movedTo: drivePath,
          );
        } else if (item.remoteNewer) {
          remoteChange = MergeChangeType.modified;
        }

        final localTime = item.consumedByMove ? null : item.localModified;
        if (!item.consumedByMove) {
          if (localTime == null) {
            localChange = MergeChangeType.deleted;
          } else if (lastSyncedTime != null && localTime.isAfter(lastSyncedTime)) {
            localChange = MergeChangeType.modified;
          }
        }

        if (localChange == MergeChangeType.none && remoteChange == MergeChangeType.none) continue;
        // 両方 modified の gpkg で base が残っていれば、行単位で合わせられる
        final mergeable = localChange == MergeChangeType.modified &&
            remoteChange == MergeChangeType.modified &&
            await SyncBaseStore.hasBase(localPath, item.path);
        entries.add(MergeFileEntry(
          relativePath: item.path,
          localChange: localChange,
          remoteChange: remoteChange,
          localModifiedTime: localTime,
          remoteModifiedTime: item.onDrive?.file.modifiedTime,
          moveInfo: moveInfo,
          driveFileId: item.synced.driveFileId,
          mergeable: mergeable,
        ));
      }

      for (final entry in _diff.localOnly.entries) {
        entries.add(MergeFileEntry(
          relativePath: entry.key,
          localChange: MergeChangeType.added,
          remoteChange: MergeChangeType.none,
          localModifiedTime: entry.value,
        ));
      }

      for (final driveEntry in _diff.driveOnly) {
        AppLogger.debug('  リモート追加検出: ${driveEntry.relativePath} (id: ${driveEntry.file.id})');
        entries.add(MergeFileEntry(
          relativePath: driveEntry.relativePath,
          localChange: MergeChangeType.none,
          remoteChange: MergeChangeType.added,
          remoteModifiedTime: driveEntry.file.modifiedTime,
          driveFileId: driveEntry.file.id,
        ));
      }
    } catch (e) {
      AppLogger.error('[SyncEngine] getMergeEntries エラー: $e');
      return entries;
    }
    AppLogger.debug('[SyncEngine] getMergeEntries完了: ${entries.length}件のエントリ');
    return entries;
  }
}

/// 帳簿の 1 件を、Drive と手元の今の姿と突き合わせたもの
class _LedgerItem {
  _LedgerItem({
    required this.path,
    required this.synced,
    required this.onDrive,
    required this.localModified,
    required this.localMove,
    required this.remoteMove,
    required this.consumedByMove,
  });

  /// 帳簿のパス
  final String path;
  final KMetaSyncFile synced;

  /// Drive 上の姿（ID で引く）。null なら Drive から消えた
  final DriveFileEntry? onDrive;

  /// 手元の更新日時。null なら手元に無い
  final DateTime? localModified;

  /// この端末で改名・移動して、Drive はまだ元の場所にある
  final bool localMove;

  /// Drive 上で動いた（この端末は動かしていない）
  final bool remoteMove;

  /// 移動として扱うので、手元の変更は見ない
  final bool consumedByMove;

  /// 最後の同期より後に Drive 側が変わったか
  bool get remoteNewer {
    final t = onDrive?.file.modifiedTime;
    return t != null && synced.isRemoteNewer(t);
  }
}

/// 帳簿・Drive・手元の突き合わせ
class _Diff {
  _Diff(this.ledger, this.localOnly, this.driveOnly);

  /// 帳簿にあるもの（旧版の `.kmeta.json` の記録は除く）
  final List<_LedgerItem> ledger;

  /// 手元にだけあるもの（帳簿に無い）
  final Map<String, DateTime> localOnly;

  /// Drive にだけあるもの（帳簿に無い）
  final List<DriveFileEntry> driveOnly;

  factory _Diff.of(Map<String, KMetaSyncFile> ledger, DriveTree tree, Map<String, DateTime> localFiles) {
    final onDriveById = tree.byId();
    final local = Map<String, DateTime>.of(localFiles);
    final ledgerIds = <String>{};
    final movedIds = <String>{};
    final movedDrivePaths = <String>{};
    final items = <_LedgerItem>[];

    for (final MapEntry(key: path, value: synced) in ledger.entries) {
      if (p.basename(path) == kMetaFileName) continue;
      ledgerIds.add(synced.driveFileId);
      final onDrive = onDriveById[synced.driveFileId];
      var localMove = false;
      var remoteMove = false;
      if (onDrive != null && onDrive.relativePath != path) {
        localMove = synced.isPendingLocalMoveFrom(onDrive.relativePath);
        remoteMove = !localMove;
        movedIds.add(synced.driveFileId);
        movedDrivePaths.add(onDrive.relativePath);
      }
      items.add(_LedgerItem(
        path: path,
        synced: synced,
        onDrive: onDrive,
        localModified: local.remove(path),
        localMove: localMove,
        remoteMove: remoteMove,
        consumedByMove: movedIds.contains(synced.driveFileId),
      ));
    }

    final driveOnly = [
      for (final e in tree.files)
        // 移動したものの行き先・帳簿に ID かパスがあるものは除く
        if (!movedDrivePaths.contains(e.relativePath) &&
            !movedIds.contains(e.file.id) &&
            !ledgerIds.contains(e.file.id) &&
            !ledger.containsKey(e.relativePath))
          e,
    ];
    return _Diff(items, local, driveOnly);
  }
}
