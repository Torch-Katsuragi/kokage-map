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

  /// [contextPath] 周辺のフォルダセット探索ルート一覧（重複除去済み）を返す。
  ///
  /// 子セット（`共有/Parent/ChildSet`）から呼ばれた場合も最上位セットの親（`共有/`）まで遡り、
  /// さらに現在のプロジェクトルートおよび `共有/` ディレクトリも含めることで、
  /// 別ルートセットからの参照漏れや誤削除を防ぐ。
  Future<List<String>> resolveSearchRoots(String contextPath) async {
    final seen = <String>{};
    final roots = <String>[];
    void addCandidate(String? candidate) {
      if (candidate == null || candidate.isEmpty) return;
      final norm = DriveTransferRegistry.normalizeKey(candidate);
      if (seen.add(norm)) {
        roots.add(p.normalize(candidate));
      }
    }

    final projRoot = ProjectPathResolver.instance.rootPath;
    if (projRoot != null && projRoot.isNotEmpty) {
      addCandidate(p.join(projRoot, ProjectsHome.sharedDirName));
      addCandidate(projRoot);
    }

    // 親がフォルダセットである間は最上位セットの親（`共有/` 等）まで遡る。プロジェクトルートより上へは出ない
    var curr = p.dirname(p.normalize(contextPath));
    if (projRoot == null ||
        projRoot.isEmpty ||
        DriveTransferRegistry.isSameOrDescendantPath(curr, projRoot)) {
      addCandidate(curr);
    }
    for (var i = 0; i < 6 && curr != p.dirname(curr); i++) {
      if (projRoot != null &&
          projRoot.isNotEmpty &&
          DriveTransferRegistry.sameNormalizedPath(curr, projRoot)) {
        break;
      }
      try {
        final raw = await KMetaService.instance.getRawMeta(curr);
        if (raw == null || raw.sync.isFolderSet != true) break;
        final next = p.dirname(curr);
        if (projRoot != null &&
            projRoot.isNotEmpty &&
            !DriveTransferRegistry.isSameOrDescendantPath(next, projRoot)) {
          break;
        }
        curr = next;
        addCandidate(curr);
      } on Object catch (_) {
        break;
      }
    }
    return roots;
  }

  /// [excludingSetPath]（およびその子孫セット）以外のフォルダセットのうち、
  /// [driveId] を `setMembers` に持つセットのパス一覧を返す。
  Future<List<String>> findReferencingSets(
    String driveId, {
    String? excludingSetPath,
    List<String> searchRoots = const [],
  }) async {
    if (driveId.isEmpty) return const [];
    final found = <String>[];
    final visitedDirs = <String>{};

    bool isExcluded(String path) =>
        excludingSetPath != null &&
        excludingSetPath.isNotEmpty &&
        DriveTransferRegistry.isSameOrDescendantPath(path, excludingSetPath);

    Future<void> checkSetAndRecurse(String dirPath, int depth) async {
      if (depth > 6) return;
      final norm = DriveTransferRegistry.normalizeKey(dirPath);
      if (!visitedDirs.add(norm)) return;
      if (isExcluded(dirPath)) return;
      if (!await fs.isDirectory(dirPath)) return;

      try {
        final meta = await KMetaService.instance.getRawMeta(dirPath);
        if (meta != null && meta.sync.isFolderSet == true) {
          if (meta.sync.setMembers.any((m) => m.driveId == driveId)) {
            found.add(dirPath);
          }
          for (final entry in await fs.list(dirPath)) {
            if (!entry.isDirectory || entry.name.startsWith('.')) continue;
            await checkSetAndRecurse(entry.path, depth + 1);
          }
          return;
        }
        // 単体の Drive 連携フォルダ内部にはフォルダセットを作らないため走査不要
        if (depth > 0 && meta != null && meta.sync.isLinked) {
          return;
        }
      } on Object catch (_) {}

      // 通常フォルダ（`共有/`・プロジェクトルート・整理用サブフォルダ等）の配下を走査
      if (depth <= 3) {
        for (final entry in await fs.list(dirPath)) {
          if (!entry.isDirectory || entry.name.startsWith('.')) continue;
          if (isExcluded(entry.path)) continue;
          await checkSetAndRecurse(entry.path, depth + 1);
        }
      }
    }

    for (final root in searchRoots) {
      await checkSetAndRecurse(root, 0);
    }
    return found;
  }

  /// [excludingSetPath]（およびその子孫セット）以外のフォルダセットから [driveId] が参照されているか
  Future<bool> isReferencedByOtherSets(
    String driveId, {
    String? excludingSetPath,
    List<String> searchRoots = const [],
  }) async {
    final sets = await findReferencingSets(
      driveId,
      excludingSetPath: excludingSetPath,
      searchRoots: searchRoots,
    );
    return sets.isNotEmpty;
  }

  /// 単体共有フォルダ（例: `共有/X`）が他のフォルダセットから参照マウントされている状態で
  /// 単体フォルダ側を削除する際、実体を `.kokage/drive_store/<driveId>/<name>` へ退避し、
  /// 辞書・帳簿・参照元セットの `targetPath` を新しいストアパスへ張り替える。
  Future<String> relocateFolderToStore({
    required String driveId,
    required String sourcePath,
    required List<String> searchRoots,
  }) async {
    final storePath = await allocateStorePath(
      driveId: driveId,
      folderName: p.basename(sourcePath),
      contextPath: sourcePath,
    );
    if (!DriveTransferRegistry.sameNormalizedPath(sourcePath, storePath)) {
      if (await fs.isDirectory(storePath) &&
          await _isValidFolderForDriveId(storePath, driveId)) {
        await fs.delete(sourcePath, recursive: true);
      } else {
        if (await fs.exists(storePath)) {
          await fs.delete(storePath, recursive: true);
        }
        await _moveDirectoryCrossPlatform(sourcePath, storePath);
      }
      KMetaService.instance.invalidateCache(sourcePath);
      KMetaService.instance.invalidateCache(storePath);
    }

    await register(driveId, storePath);

    // SyncLedger の owner が旧パスを指していれば新パスへ更新
    final ledgerKey = SyncLedger.keyFor(driveId: driveId, folderPath: storePath);
    final ledgerEntry = await SyncLedger.instance.read(ledgerKey);
    if (ledgerEntry != null &&
        (ledgerEntry.owner == null ||
            DriveTransferRegistry.sameNormalizedPath(
              ledgerEntry.owner!,
              sourcePath,
            ))) {
      await SyncLedger.instance.write(
        ledgerKey,
        ledgerEntry.withOwner(storePath),
      );
    }

    // 参照元セットの setMembers.targetPath を新しい storePath に更新
    final referencingSetPaths = await findReferencingSets(
      driveId,
      searchRoots: searchRoots,
    );
    for (final setPath in referencingSetPaths) {
      try {
        final raw = await KMetaService.instance.getRawMeta(setPath);
        if (raw == null) continue;
        var changed = false;
        final nextMembers = [
          for (final m in raw.sync.setMembers)
            if (m.driveId == driveId &&
                (m.targetPath == null ||
                    !DriveTransferRegistry.sameNormalizedPath(
                      m.targetPath!,
                      storePath,
                    )))
              (() {
                changed = true;
                return m.copyWith(targetPath: storePath);
              })()
            else
              m,
        ];
        if (changed) {
          await KMetaService.instance.setDriveSync(
            setPath,
            setMembers: nextMembers,
          );
        }
      } on Object catch (e) {
        AppLogger.debug('[DriveDirStore] setMembers targetPath 更新失敗 ($setPath): $e');
      }
    }

    return storePath;
  }

  Future<void> _moveDirectoryCrossPlatform(String from, String to) async {
    await fs.createDirectory(p.dirname(to));
    if (fs.hasRealPaths) {
      try {
        await fs.rename(from, to);
        return;
      } on Object catch (_) {
        // 別ボリューム間移動や Web 環境では再帰コピー＋削除にフォールバック
      }
    }
    await _copyDirectoryRecursive(from, to);
    await fs.delete(from, recursive: true);
  }

  Future<void> _copyDirectoryRecursive(String fromDir, String toDir) async {
    await fs.createDirectory(toDir);
    for (final entry in await fs.list(fromDir)) {
      final dst = p.join(toDir, entry.name);
      if (entry.isDirectory) {
        await _copyDirectoryRecursive(entry.path, dst);
      } else {
        final bytes = await fs.readAsBytes(entry.path);
        await fs.writeAsBytes(dst, bytes);
      }
    }
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
    KMetaService.instance.invalidateCache(targetPath);
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

  /// `.kokage/drive_store` 内でどのフォルダセットからも参照されていない孤児実体一覧を走査する
  Future<List<OrphanedStoreEntry>> scanOrphanedStoreEntries({
    String? contextPath,
    List<String>? searchRoots,
  }) async {
    final baseContext =
        contextPath ?? ProjectPathResolver.instance.rootPath ?? '';
    if (baseContext.isEmpty &&
        (customStoreRoot == null || customStoreRoot!.isEmpty)) {
      return const [];
    }
    final storeRoot = resolveStoreRoot(baseContext);
    if (!await fs.isDirectory(storeRoot)) return const [];

    final roots = searchRoots ??
        await resolveSearchRoots(
          baseContext.isNotEmpty ? baseContext : p.dirname(storeRoot),
        );
    final registry = DriveTransferRegistry.instance;
    final orphans = <OrphanedStoreEntry>[];

    for (final idEntry in await fs.list(storeRoot)) {
      if (!idEntry.isDirectory || idEntry.name.startsWith('.')) continue;
      final driveId = idEntry.name;
      if (registry.isBusy(idEntry.path)) continue;

      final children = await fs.list(idEntry.path);
      final subDirs = children.where((c) => c.isDirectory).toList();
      if (subDirs.isEmpty) {
        // 空の `<driveId>/` ディレクトリも孤児として扱う
        if (children.isEmpty &&
            !await isReferencedByOtherSets(driveId, searchRoots: roots)) {
          orphans.add(
            OrphanedStoreEntry(
              driveId: driveId,
              folderName: driveId,
              targetPath: idEntry.path,
              sizeBytes: 0,
            ),
          );
        }
        continue;
      }

      final referenced = await isReferencedByOtherSets(
        driveId,
        searchRoots: roots,
      );
      if (referenced) continue;

      for (final sub in subDirs) {
        if (registry.isBusy(sub.path)) continue;
        var totalBytes = 0;
        for (final f in await fs.listRecursive(sub.path)) {
          totalBytes += (await fs.length(f.path)) ?? 0;
        }
        orphans.add(
          OrphanedStoreEntry(
            driveId: driveId,
            folderName: sub.name,
            targetPath: sub.path,
            sizeBytes: totalBytes,
          ),
        );
      }
    }
    return orphans;
  }

  /// どのフォルダセットからも参照されていない `.kokage/drive_store` の孤児実体を一括削除する
  Future<({int deletedCount, int freedBytes})> pruneOrphanedStoreEntries({
    String? contextPath,
    List<String>? searchRoots,
  }) async {
    final orphans = await scanOrphanedStoreEntries(
      contextPath: contextPath,
      searchRoots: searchRoots,
    );
    var deletedCount = 0;
    var freedBytes = 0;

    for (final orphan in orphans) {
      if (DriveTransferRegistry.instance.isBusy(orphan.targetPath)) continue;
      if (await fs.exists(orphan.targetPath)) {
        await fs.delete(orphan.targetPath, recursive: true);
      }
      KMetaService.instance.invalidateCache(orphan.targetPath);
      final parentDir = p.dirname(orphan.targetPath);
      if (isManagedStorePath(orphan.targetPath)) {
        try {
          if (await fs.isDirectory(parentDir) &&
              (await fs.list(parentDir)).isEmpty) {
            await fs.delete(parentDir, recursive: true);
          }
        } on Object catch (_) {}
      }
      await unregister(orphan.driveId, ifPathMatches: orphan.targetPath);
      deletedCount++;
      freedBytes += orphan.sizeBytes;
    }

    // 辞書内に残っている存在しないパスのゴミエントリも掃除
    await _ensureLoaded();
    var dictChanged = false;
    for (final entry in _pathsByDriveId.entries.toList()) {
      if (!await fs.isDirectory(entry.value)) {
        _pathsByDriveId.remove(entry.key);
        dictChanged = true;
      }
    }
    if (dictChanged) await _persist();

    return (deletedCount: deletedCount, freedBytes: freedBytes);
  }

  @visibleForTesting
  void resetForTest() {
    _pathsByDriveId.clear();
    _loaded = false;
    customStoreRoot = null;
  }
}

/// `.kokage/drive_store` 内の未参照（孤児）実体エントリ情報
class OrphanedStoreEntry {
  final String driveId;
  final String folderName;
  final String targetPath;
  final int sizeBytes;

  const OrphanedStoreEntry({
    required this.driveId,
    required this.folderName,
    required this.targetPath,
    required this.sizeBytes,
  });
}
