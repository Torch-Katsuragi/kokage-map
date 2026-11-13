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
/// Drive フォルダツリーのインメモリキャッシュと Changes API による差分無効化。
///
/// 自動同期の周期ごとに `changes.list` を 1 回だけ確認し、変更のないフォルダは前回の
/// `(folderInfo, DriveTree)` を再利用して API 呼び出しを削減する。
/// 他人所有の共有フォルダでは、リンク共有かつ未閲覧の新規ファイルが `changes.list` に
/// 現れない場合があるため、サブフォルダ数が少ない共有フォルダは毎回実走査し、
/// サブフォルダ数が多い大規模共有フォルダは短い有効期限（TTL）付きでキャッシュする。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:googleapis/drive/v3.dart' as gdrive;

import '../../utils/app_logger.dart';
import 'google_drive_service.dart';
import 'sync_file_operations.dart';

class _CachedDriveFolder {
  final gdrive.File folderInfo;
  final DriveTree tree;
  final DateTime cachedAt;
  final Set<String> knownIds;
  final Set<String> knownFolderIds;

  _CachedDriveFolder({
    required String driveId,
    required this.folderInfo,
    required this.tree,
    required this.cachedAt,
  }) : knownFolderIds = {driveId, ...tree.folderMap.keys},
       knownIds = {
         driveId,
         ...tree.folderMap.keys,
         for (final entry in tree.files)
           if (entry.file.id != null) entry.file.id!,
       };

  bool get isOwnedByMe =>
      folderInfo.owners?.any((owner) => owner.me == true) ?? false;
}

/// Drive フォルダ構成キャッシュ（シングルトン）
class DriveTreeCache {
  static final DriveTreeCache instance = DriveTreeCache._();
  DriveTreeCache._();

  /// 自分が所有するフォルダの最大キャッシュ保持時間
  static Duration ownFolderTtl = const Duration(minutes: 30);

  /// 大規模な共有フォルダ（サブフォルダ数 > [smallSharedSubfolderThreshold]）のキャッシュ保持時間
  static Duration largeSharedFolderTtl = const Duration(minutes: 15);

  /// これ以下のフォルダ数（ルート含む）の他人所有共有フォルダは毎回バッチ実走査する（1〜2 API コールで済むため）
  static int smallSharedSubfolderThreshold = 11;

  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  GoogleDriveService? _boundService;
  String? _pageToken;
  bool _changesSupported = false;
  final Map<String, _CachedDriveFolder> _entries = {};

  void _bindService(GoogleDriveService driveService) {
    if (!identical(_boundService, driveService)) {
      clear();
      _boundService = driveService;
    }
  }

  /// 全キャッシュと変更トークンを破棄する（サインアウト・アカウント切替時など）
  void clear() {
    _entries.clear();
    _pageToken = null;
    _changesSupported = false;
  }

  /// 指定した [driveId] のキャッシュを無効化する（Push / Pull / マージ実行時）
  void invalidate(String? driveId) {
    if (driveId == null) return;
    _entries.remove(driveId);
  }

  /// 自動同期サイクルの開始時に呼び出し、`changes.list` で変更のあったフォルダを無効化する
  Future<void> prepareCycle(GoogleDriveService driveService) async {
    _bindService(driveService);

    if (_pageToken == null) {
      _entries.clear();
      final token = await driveService.getChangesStartPageToken();
      _pageToken = (token != null && token.isNotEmpty) ? token : null;
      _changesSupported = _pageToken != null;
      return;
    }

    final batch = await driveService.listChanges(_pageToken!);
    if (batch == null || batch.overflowed) {
      AppLogger.debug(
        '[DriveTreeCache] Changes API 取得不可または上限超過のため全キャッシュを破棄して再取得します',
      );
      _entries.clear();
      final token = await driveService.getChangesStartPageToken();
      _pageToken = (token != null && token.isNotEmpty) ? token : null;
      _changesSupported = _pageToken != null;
      return;
    }

    _pageToken = batch.newStartPageToken;
    _changesSupported = true;
    if (batch.changes.isEmpty || _entries.isEmpty) return;

    final invalidated = <String>{};
    for (final change in batch.changes) {
      final changedId = change.fileId ?? change.file?.id;
      final parents = change.file?.parents ?? const <String>[];
      for (final entry in _entries.entries) {
        if (invalidated.contains(entry.key)) continue;
        final cached = entry.value;
        final hitById = changedId != null && cached.knownIds.contains(changedId);
        final hitByParent = parents.any(cached.knownFolderIds.contains);
        if (hitById || hitByParent) {
          invalidated.add(entry.key);
        }
      }
    }

    for (final id in invalidated) {
      _entries.remove(id);
    }
    if (invalidated.isNotEmpty) {
      AppLogger.debug(
        '[DriveTreeCache] Changes API により ${invalidated.length} フォルダのキャッシュを更新対象にしました',
      );
    }
  }

  /// 有効なキャッシュがあれば返す。無ければ null。
  ({gdrive.File folderInfo, DriveTree tree})? get(
    GoogleDriveService driveService,
    String driveId,
  ) {
    if (!identical(_boundService, driveService) || !_changesSupported) {
      return null;
    }
    final entry = _entries[driveId];
    if (entry == null) return null;

    final age = clock().difference(entry.cachedAt);
    final Duration ttl;
    if (entry.isOwnedByMe) {
      ttl = ownFolderTtl;
    } else if (entry.tree.folderMap.length > smallSharedSubfolderThreshold) {
      ttl = largeSharedFolderTtl;
    } else {
      ttl = Duration.zero;
    }

    if (ttl <= Duration.zero || age >= ttl) {
      _entries.remove(driveId);
      return null;
    }
    return (folderInfo: entry.folderInfo, tree: entry.tree);
  }

  /// 取得した最新の `(folderInfo, tree)` をキャッシュに記録する
  void put(
    GoogleDriveService driveService,
    String driveId,
    gdrive.File folderInfo,
    DriveTree tree,
  ) {
    _bindService(driveService);
    if (!_changesSupported) return;
    _entries[driveId] = _CachedDriveFolder(
      driveId: driveId,
      folderInfo: folderInfo,
      tree: tree,
      cachedAt: clock(),
    );
  }
}
