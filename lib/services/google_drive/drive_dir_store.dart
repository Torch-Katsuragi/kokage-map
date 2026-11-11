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
/// Google Drive フォルダの実体ディレクトリ辞書（[DriveDirStore]）と
/// 既存同期済みファイルからのローカルシード索引（[LocalSyncSeedIndex]）。
///
/// - **Tier 1 ([DriveDirStore])**:
///   `driveId -> canonicalLocalPath` の辞書を管理する。共有フォルダセット（JSON）間で
///   同一の `driveId` が重複指定された場合や、既に `共有/` 配下に単体クローン済みの
///   フォルダがある場合に、新規ダウンロードを行わず同一の物理ディレクトリを参照渡しでマウントする。
/// - **Tier 2 ([LocalSyncSeedIndex])**:
///   親フォルダ（例: `全体プロジェクト`）の一部として既にローカルへ同期済みのファイルを
///   [SyncLedger] から索引化する。実装は [local_sync_seed_index.dart] に分離し、本ファイルから再エクスポートする。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/fs/safe_path.dart';
import '../../core/path_resolver.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import '../projects_home.dart';
import '../sync_ledger.dart';
import 'drive_transfer_registry.dart';

export 'local_sync_seed_index.dart';

/// `driveId -> canonicalLocalPath` の実体ディレクトリ辞書
class DriveDirStore {
  DriveDirStore._();

  static final DriveDirStore instance = DriveDirStore._();

  static const String _prefsKey = 'drive_dir_store:v1';
  static const String storeDirMarker = '.kokage/drive_store';

  final Map<String, String> _pathsByDriveId = {};
  bool _loaded = false;

  /// テスト等でストア配置先を明示指定する場合のオーバーライドパス
  @visibleForTesting
  String? customStoreRoot;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          final val = entry.value;
          if (val is String && val.isNotEmpty) {
            _pathsByDriveId.putIfAbsent(entry.key, () => val);
          }
        }
      }
    } on Object catch (e) {
      AppLogger.debug('[DriveDirStore] 辞書の読み込み失敗: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_pathsByDriveId.isEmpty) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, jsonEncode(_pathsByDriveId));
      }
    } on Object catch (e) {
      AppLogger.debug('[DriveDirStore] 辞書の保存失敗: $e');
    }
  }

  /// `driveId` に対応する実体ディレクトリパスを辞書へ登録する
  Future<void> register(String driveId, String localPath) async {
    if (driveId.isEmpty || localPath.isEmpty) return;
    await _ensureLoaded();
    final norm = p.normalize(localPath);
    if (_pathsByDriveId[driveId] == norm) return;
    _pathsByDriveId[driveId] = norm;
    await _persist();
  }

  /// `driveId` の辞書登録を解除する
  Future<void> unregister(String driveId, {String? ifPathMatches}) async {
    await _ensureLoaded();
    if (ifPathMatches != null) {
      final existing = _pathsByDriveId[driveId];
      if (existing != null &&
          !DriveTransferRegistry.sameNormalizedPath(existing, ifPathMatches)) {
        return;
      }
    }
    if (_pathsByDriveId.remove(driveId) != null) {
      await _persist();
    }
  }

  /// 既にローカルに実体が存在する `driveId` のディレクトリパスを探して返す。
  /// 見つからない場合は null。
  Future<String?> findExistingPath(
    String driveId, {
    List<String> searchRoots = const [],
  }) async {
    if (driveId.isEmpty) return null;
    await _ensureLoaded();

    // 1. メモリ・SharedPreferences 辞書を確認
    final cached = _pathsByDriveId[driveId];
    if (cached != null) {
      if (await _isValidFolderForDriveId(cached, driveId)) {
        return cached;
      }
      _pathsByDriveId.remove(driveId);
    }

    // 2. SyncLedger の owner を確認
    final ledger = await SyncLedger.instance.read('drive:$driveId');
    final owner = ledger?.owner;
    if (owner != null && await _isValidFolderForDriveId(owner, driveId)) {
      await register(driveId, owner);
      return owner;
    }

    // 3. 指定された検索ルート（`共有/` 等）直下のフォルダを走査
    for (final root in searchRoots) {
      final found = await _scanRootForDriveId(root, driveId, depth: 0);
      if (found != null) {
        await register(driveId, found);
        return found;
      }
    }

    return null;
  }

  Future<bool> _isValidFolderForDriveId(String dirPath, String driveId) async {
    try {
      if (!await fs.isDirectory(dirPath)) return false;
      final meta = await KMetaService.instance.getRawMeta(dirPath);
      if (meta == null) return false;
      return meta.sync.driveId == driveId && meta.sync.isFolderSet != true;
    } on Object catch (_) {
      return false;
    }
  }

  Future<String?> _scanRootForDriveId(
    String dirPath,
    String driveId, {
    required int depth,
  }) async {
    if (depth > 4) return null;
    try {
      if (!await fs.isDirectory(dirPath)) return null;
      for (final entry in await fs.list(dirPath)) {
        if (!entry.isDirectory || entry.name.startsWith('.')) continue;
        final meta = await KMetaService.instance.getRawMeta(entry.path);
        if (meta == null || !meta.sync.isLinked) continue;
        if (meta.sync.driveId == driveId && meta.sync.isFolderSet != true) {
          return entry.path;
        }
        if (meta.sync.isFolderSet == true) {
          for (final member in meta.sync.setMembers) {
            if (member.driveId == driveId && member.targetPath != null) {
              if (await _isValidFolderForDriveId(member.targetPath!, driveId)) {
                return member.targetPath!;
              }
            }
          }
          final sub = await _scanRootForDriveId(
            entry.path,
            driveId,
            depth: depth + 1,
          );
          if (sub != null) return sub;
        }
      }
    } on Object catch (_) {}
    return null;
  }

  /// 新規クローン用のストア実体パス（`<root>/.kokage/drive_store/<driveId>/<folderName>`）を割り当てる
  Future<String> allocateStorePath({
    required String driveId,
    required String folderName,
    required String contextPath,
  }) async {
    final storeRoot = resolveStoreRoot(contextPath);
    final safeName = toLocalFolderName(folderName, fallback: driveId);
    final targetPath = p.join(storeRoot, driveId, safeName);
    await register(driveId, targetPath);
    return targetPath;
  }

  /// [contextPath] から `.kokage/drive_store` のルートディレクトリを決定する
  String resolveStoreRoot(String contextPath) {
    if (customStoreRoot != null && customStoreRoot!.isNotEmpty) {
      return customStoreRoot!;
    }
    final projRoot = ProjectPathResolver.instance.rootPath;
    if (projRoot != null && projRoot.isNotEmpty) {
      return p.join(projRoot, '.kokage', 'drive_store');
    }
    var current = p.normalize(contextPath);
    while (true) {
      final base = p.basename(current);
      if (base == ProjectsHome.sharedDirName) {
        return p.join(p.dirname(current), '.kokage', 'drive_store');
      }
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return p.join(p.dirname(p.normalize(contextPath)), '.kokage', 'drive_store');
  }

  /// 指定パスが `.kokage/drive_store` 管理下のパスかどうか
  bool isManagedStorePath(String localPath) {
    final norm = DriveTransferRegistry.normalizeKey(localPath);
    return norm.contains('/$storeDirMarker/');
  }

  /// [excludingSetPath]（およびその子孫セット）以外のフォルダセットから [driveId] が参照されているか
  Future<bool> isReferencedByOtherSets(
    String driveId, {
    required String excludingSetPath,
    List<String> searchRoots = const [],
  }) async {
    Future<bool> scanSetDir(String dirPath, int depth) async {
      if (depth > 6) return false;
      if (!await fs.isDirectory(dirPath)) return false;
      for (final entry in await fs.list(dirPath)) {
        if (!entry.isDirectory || entry.name.startsWith('.')) continue;
        if (DriveTransferRegistry.isSameOrDescendantPath(
          entry.path,
          excludingSetPath,
        )) {
          continue;
        }
        try {
          final meta = await KMetaService.instance.getRawMeta(entry.path);
          if (meta == null || meta.sync.isFolderSet != true) continue;
          if (meta.sync.setMembers.any((m) => m.driveId == driveId)) {
            return true;
          }
          if (await scanSetDir(entry.path, depth + 1)) {
            return true;
          }
        } on Object catch (_) {}
      }
      return false;
    }

    for (final root in searchRoots) {
      if (await scanSetDir(root, 0)) return true;
    }
    return false;
  }

  /// フォルダセットから外れた [driveId] の実体ディレクトリについて、
  /// 他のどのセットからも参照されておらず、かつ管理下ストア（またはセット内部の旧配置）であれば削除する。
  /// `共有/<フォルダ名>` のような単体共有フォルダの実体は削除しない。
  Future<void> deletePhysicalIfUnreferenced({
    required String driveId,
    required String targetPath,
    required String excludingSetPath,
    List<String> searchRoots = const [],
  }) async {
    final referenced = await isReferencedByOtherSets(
      driveId,
      excludingSetPath: excludingSetPath,
      searchRoots: searchRoots,
    );
    if (referenced) {
      AppLogger.debug(
        '[DriveDirStore] 他セットから参照中のため実体ディレクトリを保持: $targetPath ($driveId)',
      );
      return;
    }

    final isInsideExcludedSet = DriveTransferRegistry.isStrictDescendantPath(
      targetPath,
      excludingSetPath,
    );
    final isManaged = isManagedStorePath(targetPath);

    if (!isManaged && !isInsideExcludedSet) {
      // `共有/` 直下などに単体でクローンされたフォルダはセット解除で消さない
      return;
    }

    if (await fs.exists(targetPath)) {
      await fs.delete(targetPath, recursive: true);
    }
    if (isManaged) {
      final parentDir = p.dirname(targetPath);
      try {
        if (await fs.isDirectory(parentDir) &&
            (await fs.list(parentDir)).isEmpty) {
          await fs.delete(parentDir, recursive: true);
        }
      } on Object catch (_) {}
    }
    await unregister(driveId, ifPathMatches: targetPath);
  }

  @visibleForTesting
  void resetForTest() {
    _pathsByDriveId.clear();
    _loaded = false;
    customStoreRoot = null;
  }
}
