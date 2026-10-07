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
// Root Maps: 同期エンジン
// Google DriveとローカルファイルのPush/Pull同期を担当するオーケストレーター

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;

import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'google_drive_service.dart';
import 'gpkg_merger.dart';
import 'qgs_merger.dart';
import 'sync_conflict_resolver.dart';
import 'sync_file_operations.dart';
import 'sync_pull_handler.dart';
import 'sync_push_handler.dart';
import 'sync_snapshot.dart';

/// 同期結果
class SyncResult {
  /// 成功したか
  final bool success;

  /// エラーメッセージ（失敗時）
  final String? errorMessage;

  /// アップロードしたファイル数
  final int uploadedCount;

  /// ダウンロードしたファイル数
  final int downloadedCount;

  /// スキップしたファイル数
  final int skippedCount;

  /// 削除したファイル数
  final int deletedCount;

  /// 移動したファイル数
  final int movedCount;

  /// 行単位で合わせたファイル数
  final int mergedCount;

  /// 行単位マージで、同じ行・同じ列を両方が変えていた記録（この端末の値が残っている）
  final List<GpkgConflict> conflicts;

  /// 行単位で合わせようとして合わせられなかったファイル（列の増減をまたいだ、Drive が途中で動いた等）。
  /// 手元もリモートも変えずに衝突のまま残してある
  final List<String> failedMerges;

  /// `.qgs` のフォルダ設定を合わせたとき、両方が別の値にしていた項目。この端末の値が残っている
  final List<QgsSettingConflict> settingConflicts;

  const SyncResult({
    required this.success,
    this.errorMessage,
    this.uploadedCount = 0,
    this.downloadedCount = 0,
    this.skippedCount = 0,
    this.deletedCount = 0,
    this.movedCount = 0,
    this.mergedCount = 0,
    this.conflicts = const [],
    this.failedMerges = const [],
    this.settingConflicts = const [],
  });

  factory SyncResult.success({
    int uploadedCount = 0,
    int downloadedCount = 0,
    int skippedCount = 0,
    int deletedCount = 0,
    int movedCount = 0,
    int mergedCount = 0,
    List<GpkgConflict> conflicts = const [],
    List<String> failedMerges = const [],
    List<QgsSettingConflict> settingConflicts = const [],
  }) {
    return SyncResult(
      success: true,
      uploadedCount: uploadedCount,
      downloadedCount: downloadedCount,
      skippedCount: skippedCount,
      deletedCount: deletedCount,
      movedCount: movedCount,
      mergedCount: mergedCount,
      conflicts: conflicts,
      failedMerges: failedMerges,
      settingConflicts: settingConflicts,
    );
  }

  factory SyncResult.failure(String message) {
    return SyncResult(success: false, errorMessage: message);
  }
}

/// 同期進捗情報
class SyncProgress {
  /// 現在のファイル名
  final String currentFile;

  /// 処理済みファイル数
  final int processedCount;

  /// 総ファイル数
  final int totalCount;

  /// 処理済みバイト数（null = 不明）
  final int? processedBytes;

  /// 総バイト数（null = 不明）
  final int? totalBytes;

  /// 進捗率（0.0〜1.0）
  double get progress =>
      totalCount > 0 ? processedCount / totalCount : 0.0;

  const SyncProgress({
    required this.currentFile,
    required this.processedCount,
    required this.totalCount,
    this.processedBytes,
    this.totalBytes,
  });
}

/// ローカル同期対象ファイル
///
/// ⚠ `dart:io` の `File` は持たない。web には無いため
/// （2026-08-27 に載せ替え）。パスとサイズだけあれば足りる。
class LocalSyncFile {
  final String path;
  final String relativePath;

  /// バイト数。列挙時に1回だけ問い合わせて持ち回る
  /// （web はサイズ取得もハンドル操作なので、都度聞くと高い）。
  final int size;

  const LocalSyncFile({
    required this.path,
    required this.relativePath,
    required this.size,
  });

  /// ファイル名（拡張子つき）
  String get name => p.basename(path);
}

/// Drive側ファイルエントリ（相対パス付き）
class DriveFileEntry {
  final drive.File file;
  final String relativePath;

  const DriveFileEntry({
    required this.file,
    required this.relativePath,
  });
}

//// 同期エンジン
///
/// 何が変わったかの判定は [SyncSnapshot]、片方向の同期は [SyncPushHandler] / [SyncPullHandler]、
/// ファイルごとの選択の反映（マージ）は [SyncConflictResolver] が受け持つ。
/// 判定に使った材料（[FolderSyncStatusDetail.snapshot]）を渡せば、push / pull / マージは
/// Drive をもう一度たどらない（自動同期が使う）
class SyncEngine {
  final GoogleDriveService _driveService;
  final KMetaService _kmetaService;
  final SyncFileOperations _fileOps;
  final SyncPushHandler _pushHandler;
  final SyncPullHandler _pullHandler;
  final SyncConflictResolver _conflictResolver;

  SyncEngine({
    GoogleDriveService? driveService,
    KMetaService? kmetaService,
  }) : this._fromServices(
          driveService ?? GoogleDriveService(),
          kmetaService ?? KMetaService.instance,
        );

  SyncEngine._fromServices(GoogleDriveService driveService, KMetaService kmetaService)
      : this._withFileOps(driveService, kmetaService, SyncFileOperations(driveService: driveService));

  SyncEngine._withFileOps(this._driveService, this._kmetaService, this._fileOps)
      : _pushHandler = SyncPushHandler(driveService: _driveService, kmetaService: _kmetaService, fileOps: _fileOps),
        _pullHandler = SyncPullHandler(driveService: _driveService, kmetaService: _kmetaService, fileOps: _fileOps),
        _conflictResolver =
            SyncConflictResolver(driveService: _driveService, kmetaService: _kmetaService, fileOps: _fileOps);

  /// プロジェクトをDriveにPush（アップロード）
  Future<SyncResult> push(
    String projectPath, {
    String? driveFolder,
    void Function(SyncProgress progress)? onProgress,
  }) =>
      _pushHandler.push(projectPath, driveFolder: driveFolder, onProgress: onProgress);

  /// フォルダ単位でPush（[snapshot] は同じフォルダの判定に使った材料）
  Future<SyncResult> pushFolder(String localPath, {SyncSnapshot? snapshot}) =>
      _pushHandler.pushFolder(localPath, snapshot: snapshot);

  /// DriveからプロジェクトをPull（ダウンロード）
  Future<SyncResult> pull(
    String driveFolderId,
    String localPath, {
    void Function(SyncProgress progress)? onProgress,
  }) =>
      _pullHandler.pull(driveFolderId, localPath, onProgress: onProgress);

  /// Driveフォルダをローカルにクローン
  Future<bool> cloneFromDrive({
    required String driveId,
    required String localPath,
    required String folderName,
    required String driveUrl,
    required bool isReadOnly,
    void Function(SyncProgress progress)? onProgress,
  }) =>
      _pullHandler.cloneFromDrive(
        driveId: driveId,
        localPath: localPath,
        folderName: folderName,
        driveUrl: driveUrl,
        isReadOnly: isReadOnly,
        onProgress: onProgress,
      );

  /// フォルダ単位でPull（[snapshot] は同じフォルダの判定に使った材料）
  Future<SyncResult> pullFolder(String localPath, {SyncSnapshot? snapshot}) =>
      _pullHandler.pullFolder(localPath, snapshot: snapshot);

  Future<({SyncSnapshot? snapshot, FolderSyncStatus? failure})> _take(String localPath) =>
      SyncSnapshot.take(localPath, driveService: _driveService, kmetaService: _kmetaService, fileOps: _fileOps);

  /// 同期状態の詳細を取得（ファイルID単位でDriveとローカルを比較）
  Future<FolderSyncStatusDetail> checkSyncStatusDetail(String localPath) async {
    if (!_driveService.isDriveApiAvailable) {
      return const FolderSyncStatusDetail(status: FolderSyncStatus.error);
    }
    try {
      final taken = await _take(localPath);
      final snapshot = taken.snapshot;
      if (snapshot == null) return FolderSyncStatusDetail(status: taken.failure!);
      return await snapshot.toStatusDetail(_fileOps);
    } catch (e) {
      AppLogger.error('[SyncEngine] 同期状態チェックエラー: $e');
      return const FolderSyncStatusDetail(status: FolderSyncStatus.error);
    }
  }

  /// マージ用のファイルエントリ一覧を取得（[snapshot] を渡せばそれで判定する）
  Future<List<MergeFileEntry>> getMergeEntries(String localPath, {SyncSnapshot? snapshot}) async {
    try {
      final s = snapshot ?? (await _take(localPath)).snapshot;
      return s == null ? [] : await s.toMergeEntries();
    } catch (e) {
      AppLogger.error('[SyncEngine] getMergeEntries エラー: $e');
      return [];
    }
  }

  /// マージを実行（[snapshot] を渡せば、Drive のフォルダ構成はそれを使う）
  Future<SyncResult> executeMerge(
    String localPath,
    List<MergeDecision> decisions, {
    SyncSnapshot? snapshot,
  }) =>
      _conflictResolver.executeMerge(localPath, decisions, snapshot: snapshot);

  /// Driveのフォルダ構造をローカルに反映（空フォルダ含む）。作ったフォルダ数を返す
  Future<int> ensureDriveFolders(String localPath) async {
    try {
      final driveId = (await _kmetaService.getMeta(localPath)).sync.driveId;
      if (driveId == null) return 0;
      final tree = await _fileOps.listDriveTree(driveId);
      return await _fileOps.ensureLocalDirs(localPath, tree.folderPaths);
    } catch (e) {
      AppLogger.error('[SyncEngine] ensureDriveFolders エラー: $e');
      return 0;
    }
  }
}

/// フォルダの同期状態
enum FolderSyncStatus {
  /// 同期済み
  synced,
  /// ローカルに変更あり
  localChanges,
  /// Driveに変更あり
  remoteChanges,
  /// 競合あり
  conflict,
  /// Drive未連携
  notLinked,
  /// エラー
  error,
}

/// ファイル変更の種類
enum FileChangeType {
  added,
  modified,
  deleted,
  moved,
  movedAndModified,
}

/// ファイル変更情報
class FileChangeInfo {
  final String fileName;
  final FileChangeType type;
  final String? movedFrom;
  final String? movedTo;

  const FileChangeInfo({
    required this.fileName,
    required this.type,
    this.movedFrom,
    this.movedTo,
  });
}

/// 同期状態の詳細
class FolderSyncStatusDetail {
  final FolderSyncStatus status;
  final int localAdded;
  final int localDeleted;
  final int localModified;
  final int remoteAdded;
  final int remoteDeleted;
  final int remoteModified;
  final int remoteMoved;
  final List<String> localAddedFiles;
  final List<String> localDeletedFiles;
  final List<String> localModifiedFiles;
  final List<String> remoteAddedFiles;
  final List<String> remoteDeletedFiles;
  final List<String> remoteModifiedFiles;
  final List<FileChangeInfo> remoteMovedFiles;

  /// 判定に使った材料。push / pull / マージに渡すと Drive をもう一度たどらない（判定できなかったときは null）
  final SyncSnapshot? snapshot;

  const FolderSyncStatusDetail({
    required this.status,
    this.localAdded = 0,
    this.localDeleted = 0,
    this.localModified = 0,
    this.remoteAdded = 0,
    this.remoteDeleted = 0,
    this.remoteModified = 0,
    this.remoteMoved = 0,
    this.localAddedFiles = const [],
    this.localDeletedFiles = const [],
    this.localModifiedFiles = const [],
    this.remoteAddedFiles = const [],
    this.remoteDeletedFiles = const [],
    this.remoteModifiedFiles = const [],
    this.remoteMovedFiles = const [],
    this.snapshot,
  });

  /// 変更があるか
  bool get hasLocalChanges =>
      localAdded > 0 || localDeleted > 0 || localModified > 0;

  bool get hasRemoteChanges =>
      remoteAdded > 0 || remoteDeleted > 0 || remoteModified > 0 || remoteMoved > 0;
}

/// マージ用の変更タイプ
enum MergeChangeType {
  none,
  added,
  modified,
  deleted,
  moved,
}

/// マージの選択結果
enum MergeChoice {
  local,
  remote,

  /// 両方の変更を行単位で合わせる（gpkg で base があるときだけ。geodiff の rebase）
  merge,
}

/// マージ決定情報
class MergeDecision {
  final MergeFileEntry entry;
  final MergeChoice choice;

  const MergeDecision({
    required this.entry,
    required this.choice,
  });
}

/// マージ用のファイルエントリ
class MergeFileEntry {
  /// ファイルの相対パス
  final String relativePath;

  /// ローカル側の変更タイプ
  final MergeChangeType localChange;

  /// リモート側の変更タイプ
  final MergeChangeType remoteChange;

  /// ローカルファイルの更新日時
  final DateTime? localModifiedTime;

  /// リモートファイルの更新日時
  final DateTime? remoteModifiedTime;

  /// 移動情報（移動の場合）
  final FileChangeInfo? moveInfo;

  /// DriveファイルID（既存ファイルの場合）
  final String? driveFileId;

  /// 行単位で合わせられるか（両方 modified の gpkg で、この端末に base があるとき）
  final bool mergeable;

  const MergeFileEntry({
    required this.relativePath,
    required this.localChange,
    required this.remoteChange,
    this.localModifiedTime,
    this.remoteModifiedTime,
    this.moveInfo,
    this.driveFileId,
    this.mergeable = false,
  });

  /// 変更があるか（どちらか一方でも変更あり）
  bool get hasChanges => localChange != MergeChangeType.none || remoteChange != MergeChangeType.none;

  /// コンフリクト状態か（両方で変更あり）
  bool get isConflict =>
      localChange != MergeChangeType.none &&
      remoteChange != MergeChangeType.none;
}
