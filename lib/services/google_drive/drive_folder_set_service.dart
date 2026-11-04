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
/// Drive上のJSONマニフェストによる共有フォルダセット（[DriveFolderSetNode]）の解析・同期サービス
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/fs/safe_path.dart';
import '../../core/shared_link.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import '../qgis/qgs_read_back.dart';
import 'auto_sync_service.dart';
import 'drive_transfer_registry.dart';
import 'google_drive_service.dart';
import 'sync_engine.dart';

/// JSONマニフェスト内の1フォルダ項目
class DriveFolderSetItem {
  final String driveId;
  final String driveUrl;

  /// JSON側で明示的に読み取り専用が指定されているか（省略時は false で Drive 権限に従う）
  final bool readOnly;

  const DriveFolderSetItem({
    required this.driveId,
    required this.driveUrl,
    this.readOnly = false,
  });
}

/// Drive上の共有フォルダセットJSONのパース結果
class DriveFolderSetManifest {
  final String? name;
  final List<DriveFolderSetItem> items;

  /// パースできなかった不正エントリ数（1件でもあれば誤削除防止のため削除フェーズをスキップする）
  final int invalidEntryCount;

  const DriveFolderSetManifest({
    this.name,
    required this.items,
    this.invalidEntryCount = 0,
  });

  /// JSON文字列をパースする。
  ///
  /// 対応形式:
  /// 1. オブジェクト形式:
  /// ```json
  /// {
  ///   "name": "現在の現場地図",
  ///   "presets": [
  ///     "https://drive.google.com/file/d/.../view"
  ///   ],
  ///   "folders": [
  ///     "https://drive.google.com/drive/folders/...",
  ///     { "url": "https://drive.google.com/drive/folders/...", "readOnly": true }
  ///   ]
  /// }
  /// ```
  /// （子セットのキー名は `presets` / `sets` / `children`、フォルダのキー名は `folders` / `dirs` / `urls` / `items` のいずれでも可。
  ///   また `folders` 等の中に子JSONのURLを混在させても動作する）
  ///
  /// 2. 配列直書き形式:
  /// ```json
  /// [
  ///   "https://drive.google.com/file/d/.../view",
  ///   "https://drive.google.com/drive/folders/...",
  ///   { "url": "https://drive.google.com/drive/folders/...", "readOnly": true }
  /// ]
  /// ```
  static DriveFolderSetManifest parse(String jsonText, {String? fallbackName}) {
    final dynamic decoded = jsonDecode(jsonText);
    String? setName;
    final rawList = <dynamic>[];

    if (decoded is List) {
      rawList.addAll(decoded);
    } else if (decoded is Map) {
      final rawName = decoded['name'] ?? decoded['title'];
      if (rawName is String && rawName.trim().isNotEmpty) {
        setName = rawName.trim();
      }
      final presetCandidate =
          decoded['presets'] ?? decoded['sets'] ?? decoded['children'];
      final folderCandidate =
          decoded['folders'] ?? decoded['dirs'] ?? decoded['urls'] ?? decoded['items'];

      if (presetCandidate != null && presetCandidate is! List) {
        throw const FormatException('"presets" (or "sets"/"children") must be an array');
      }
      if (folderCandidate != null && folderCandidate is! List) {
        throw const FormatException('"folders" (or "dirs"/"urls"/"items") must be an array');
      }
      if (presetCandidate == null && folderCandidate == null) {
        throw const FormatException(
          'JSON must contain a "folders" (or "presets"/"dirs"/"urls"/"items") array',
        );
      }
      if (presetCandidate is List) {
        rawList.addAll(presetCandidate);
      }
      if (folderCandidate is List) {
        rawList.addAll(folderCandidate);
      }
    } else {
      throw const FormatException('Invalid JSON root type for folder set');
    }

    final seenIds = <String>{};
    final items = <DriveFolderSetItem>[];
    var invalidCount = 0;
    for (final entry in rawList) {
      if (entry is String && entry.trim().isEmpty) continue;
      final parsed = _parseEntry(entry);
      if (parsed == null) {
        invalidCount++;
        continue;
      }
      if (seenIds.add(parsed.driveId)) {
        items.add(parsed);
      }
    }

    final effectiveName = setName ?? _stripJsonExt(fallbackName);
    return DriveFolderSetManifest(
      name: effectiveName,
      items: items,
      invalidEntryCount: invalidCount,
    );
  }

  static DriveFolderSetItem? _parseEntry(dynamic entry) {
    if (entry is String) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) return null;
      final id = GoogleDriveService.extractFolderIdFromUrl(trimmed) ??
          (isDriveId(trimmed) ? trimmed : null);
      if (id == null) return null;
      final url = trimmed.startsWith('http')
          ? trimmed
          : 'https://drive.google.com/drive/folders/$id';
      return DriveFolderSetItem(driveId: id, driveUrl: url);
    }
    if (entry is Map) {
      final rawUrl = (entry['url'] ??
              entry['driveUrl'] ??
              entry['driveId'] ??
              entry['id'] ??
              entry['preset'] ??
              entry['folder'])
          ?.toString()
          .trim();
      if (rawUrl == null || rawUrl.isEmpty) return null;
      final id = GoogleDriveService.extractFolderIdFromUrl(rawUrl) ??
          (isDriveId(rawUrl) ? rawUrl : null);
      if (id == null) return null;
      final url = rawUrl.startsWith('http')
          ? rawUrl
          : 'https://drive.google.com/drive/folders/$id';
      final readOnly = (entry['readOnly'] ?? entry['isReadOnly']) == true;
      return DriveFolderSetItem(
        driveId: id,
        driveUrl: url,
        readOnly: readOnly,
      );
    }
    return null;
  }

  static String? _stripJsonExt(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final trimmed = name.trim();
    if (trimmed.toLowerCase().endsWith('.json') && trimmed.length > 5) {
      return trimmed.substring(0, trimmed.length - 5);
    }
    return trimmed;
  }
}

/// 共有フォルダセットの同期結果
class FolderSetSyncResult {
  final bool success;
  final int addedCount;
  final int removedCount;
  final List<String> keptWithLocalChanges;
  final List<String> failedItems;

  /// 循環参照・同一ツリー内の重複・深さ/件数上限によりスキップされた項目
  final List<String> skippedCycleOrDuplicateItems;
  final String? errorMessage;

  const FolderSetSyncResult({
    required this.success,
    this.addedCount = 0,
    this.removedCount = 0,
    this.keptWithLocalChanges = const [],
    this.failedItems = const [],
    this.skippedCycleOrDuplicateItems = const [],
    this.errorMessage,
  });

  bool get changedLocal => addedCount > 0 || removedCount > 0;
}

/// ツリー展開全体で共有する走査コンテキスト（循環遮断・重複排除・総件数制限）
class _ReconcileContext {
  final Set<String> visitedDriveIds;
  int processedItemCount = 0;

  _ReconcileContext({Set<String>? initialVisitedIds})
      : visitedDriveIds = {...?initialVisitedIds};
}

/// Drive共有フォルダセットの取得・差分調整サービス
class DriveFolderSetService {
  /// 子セットの最大ネスト深さ（ルートセット = 0、最大 5 階層の子セットまで許可）
  static const int kMaxSetDepth = 5;

  /// 1つのルートセットツリー全体で展開するアイテム（子セット＋フォルダ）の最大総数
  static const int kMaxSetTotalItems = 100;

  /// 同一セットパスに対する `reconcileSet` の多重実行を防ぐ排他マップ
  static final Map<String, Future<FolderSetSyncResult>> _inFlight = {};

  final GoogleDriveService _driveService;
  final SyncEngine _syncEngine;

  DriveFolderSetService({
    GoogleDriveService? driveService,
    SyncEngine? syncEngine,
  })  : _driveService = driveService ?? GoogleDriveService(),
        _syncEngine = syncEngine ?? SyncEngine();

  /// Drive上のJSONファイルをダウンロードしてパースする
  Future<DriveFolderSetManifest> fetchManifest(
    String manifestFileId, {
    String? fallbackName,
  }) async {
    final bytes = await _driveService.downloadBytes(manifestFileId);
    if (bytes == null) {
      throw StateError('Failed to download folder set JSON ($manifestFileId)');
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    return DriveFolderSetManifest.parse(text, fallbackName: fallbackName);
  }

  /// ローカルのセット用フォルダ（[localSetPath]）を Drive 上の JSON（[manifestFileId]）に追従させる。
  ///
  /// - 同一 `localSetPath` に対してすでに実行中ならその Future を共有して二重クローンを防ぐ
  /// - JSON内の項目が Drive フォルダなら `localSetPath` 直下へクローン（[DriveFolderNode]）
  /// - JSON内の項目が別の JSON ファイルなら子セット（[DriveFolderSetNode]）としてサブフォルダを作成し再帰的に展開
  /// - ツリー全体で一度登場した `driveId` は再展開しない（循環参照およびダイヤモンド重複の防止）
  /// - JSONから消えたフォルダ・子セットは、配下の全フォルダが同期済み（未送信変更ゼロ）と確認できた場合のみ削除する
  Future<FolderSetSyncResult> reconcileSet({
    required String manifestFileId,
    required String localSetPath,
    DriveFolderSetNode? setNode,
    DriveFolderSetManifest? preloadedManifest,
    bool showOsNotification = false,
    bool forceReadOnly = false,
  }) {
    final key = DriveTransferRegistry.normalizeKey(localSetPath);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _reconcileRootOrSubtree(
      manifestFileId: manifestFileId,
      localSetPath: localSetPath,
      setNode: setNode,
      preloadedManifest: preloadedManifest,
      showOsNotification: showOsNotification,
      forceReadOnly: forceReadOnly,
    );
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  Future<FolderSetSyncResult> _reconcileRootOrSubtree({
    required String manifestFileId,
    required String localSetPath,
    DriveFolderSetNode? setNode,
    DriveFolderSetManifest? preloadedManifest,
    required bool showOsNotification,
    required bool forceReadOnly,
  }) async {
    final init = await _buildInitialState(
      localSetPath: localSetPath,
      setNode: setNode,
      forceReadOnly: forceReadOnly,
    );
    return _reconcileSetImpl(
      manifestFileId: manifestFileId,
      localSetPath: localSetPath,
      setNode: setNode,
      preloadedManifest: preloadedManifest,
      showOsNotification: showOsNotification,
      forceReadOnly: init.forceReadOnly,
      depth: init.depth,
      context: _ReconcileContext(initialVisitedIds: init.visitedIds),
    );
  }

  /// 途中の子セットから直接 `reconcileSet` が呼ばれた場合でも、
  /// 祖先との循環参照・兄弟枝との重複・親からの `readOnly` 継承・現在の深さを正確に復元する
  Future<({Set<String> visitedIds, bool forceReadOnly, int depth})> _buildInitialState({
    required String localSetPath,
    required DriveFolderSetNode? setNode,
    required bool forceReadOnly,
  }) async {
    final visitedIds = <String>{};
    var effectiveReadOnly = forceReadOnly || (setNode?.isReadOnly ?? false);

    // 1. メモリ上の親ノードチェーンから祖先 DriveFolderSetNode を辿る
    var memDepth = 0;
    for (var pNode = setNode?.parent; pNode != null; pNode = pNode.parent) {
      if (pNode is DriveFolderSetNode) {
        memDepth++;
        visitedIds.add(pNode.manifestFileId);
        if (pNode.isReadOnly) effectiveReadOnly = true;
      }
    }

    // 2. ディスク上の親ディレクトリチェーンから祖先フォルダセットを辿る
    final ancestorPaths = <String>[];
    var curr = p.dirname(localSetPath);
    while (curr != p.dirname(curr)) {
      try {
        final raw = await KMetaService.instance.getRawMeta(curr);
        if (raw == null || raw.sync.isFolderSet != true) break;
        ancestorPaths.add(curr);
        final id = raw.sync.driveId;
        if (id != null && id.isNotEmpty) {
          visitedIds.add(id);
        }
        curr = p.dirname(curr);
      } catch (_) {
        break;
      }
    }

    if (ancestorPaths.isNotEmpty) {
      // 自身が子セットなら自身の KMetaSync.isReadOnly も反映
      try {
        final selfRaw = await KMetaService.instance.getRawMeta(localSetPath);
        if (selfRaw?.sync.isReadOnly == true) {
          effectiveReadOnly = true;
        }
      } catch (_) {}
      // ルート以外の途中祖先セットに isReadOnly == true があれば継承
      for (var i = 0; i < ancestorPaths.length - 1; i++) {
        try {
          final ancRaw = await KMetaService.instance.getRawMeta(ancestorPaths[i]);
          if (ancRaw?.sync.isReadOnly == true) {
            effectiveReadOnly = true;
          }
        } catch (_) {}
      }
      // ルートセット配下のうち、今回の localSetPath サブツリー外の既存 driveId を収集
      final topSetPath = ancestorPaths.last;
      await _collectDriveIdsOutsideSubtree(
        currentDir: topSetPath,
        excludedSubtreePath: localSetPath,
        outIds: visitedIds,
      );
    }

    final depth = ancestorPaths.length > memDepth ? ancestorPaths.length : memDepth;
    return (
      visitedIds: visitedIds,
      forceReadOnly: effectiveReadOnly,
      depth: depth,
    );
  }

  Future<void> _collectDriveIdsOutsideSubtree({
    required String currentDir,
    required String excludedSubtreePath,
    required Set<String> outIds,
  }) async {
    final normCurrent = DriveTransferRegistry.normalizeKey(currentDir);
    final normExcluded = DriveTransferRegistry.normalizeKey(excludedSubtreePath);
    if (normCurrent == normExcluded) return;

    try {
      final raw = await KMetaService.instance.getRawMeta(currentDir);
      final id = raw?.sync.driveId;
      if (id != null && id.isNotEmpty) {
        outIds.add(id);
      }
      if (raw != null && raw.sync.isLinked && raw.sync.isFolderSet != true) {
        // 通常の DriveFolderNode の内部には入らない
        return;
      }
      for (final entry in await fs.list(currentDir)) {
        if (!entry.isDirectory || entry.name.startsWith('.')) continue;
        await _collectDriveIdsOutsideSubtree(
          currentDir: entry.path,
          excludedSubtreePath: excludedSubtreePath,
          outIds: outIds,
        );
      }
    } catch (_) {}
  }

  Future<FolderSetSyncResult> _reconcileSetImpl({
    required String manifestFileId,
    required String localSetPath,
    DriveFolderSetNode? setNode,
    DriveFolderSetManifest? preloadedManifest,
    String? preloadedRemoteMd5,
    String? preloadedRemoteName,
    required bool showOsNotification,
    required bool forceReadOnly,
    required int depth,
    required _ReconcileContext context,
  }) async {
    final registry = DriveTransferRegistry.instance;
    final effectiveSetNode =
        setNode ?? AutoSyncService.instance.findFolderSetByPath(localSetPath);

    // 自分自身の JSON ID を visited に登録（子孫が自分を指していたら循環として弾く）
    context.visitedDriveIds.add(manifestFileId);

    try {
      String? remoteMd5 = preloadedRemoteMd5;
      String? remoteName = preloadedRemoteName;
      if (preloadedManifest == null || (remoteMd5 == null && remoteName == null)) {
        final fileMeta = await _driveService.lookupFolder(manifestFileId);
        remoteMd5 ??= fileMeta.folder?.md5Checksum;
        remoteName ??= fileMeta.folder?.name;
      }

      await fs.createDirectory(localSetPath);

      // 現在の直下サブフォルダの Drive 連携状態を集める
      final existingByDriveId = <String, String>{};
      final existingNameByPath = <String, String>{};
      final existingIsSetByDriveId = <String, bool>{};
      var anySubfolderPending = false;
      for (final entry in await fs.list(localSetPath)) {
        if (!entry.isDirectory || entry.name.startsWith('.')) continue;
        try {
          if (await registry.hasClonePending(entry.path)) {
            anySubfolderPending = true;
          }
          final meta = await KMetaService.instance.getMeta(entry.path);
          final id = meta.sync.driveId;
          if (id != null && id.isNotEmpty) {
            existingByDriveId[id] = entry.path;
            existingNameByPath[entry.path] = entry.name;
            existingIsSetByDriveId[id] = meta.sync.isFolderSet == true;
          }
        } catch (_) {}
      }

      // 自動同期等で preloadedManifest が無く、かつ JSON の MD5 が前回から変わっておらず、
      // 未完了クローンのマーカーも無ければ、この階層の JSON 本体ダウンロードと直下の構成変更は省略できる。
      // ただし、直下に子セット（DriveFolderSetNode）がある場合は子セット側の JSON が更新されている可能性があるため再帰チェックを通す。
      if (preloadedManifest == null &&
          remoteMd5 != null &&
          !anySubfolderPending &&
          !await registry.hasClonePending(localSetPath)) {
        final currentSetMeta = await KMetaService.instance.getMeta(localSetPath);
        if (currentSetMeta.sync.driveRevisionId == remoteMd5 &&
            existingByDriveId.isNotEmpty) {
          // 直下の通常フォルダの ID を先に visited に登録してから子セットを再帰チェック
          for (final MapEntry(key: id, value: isSubSet) in existingIsSetByDriveId.entries) {
            if (!isSubSet) context.visitedDriveIds.add(id);
          }

          var subAdded = 0;
          var subRemoved = 0;
          final subKept = <String>[];
          final subFailed = <String>[];
          final subSkipped = <String>[];

          for (final MapEntry(key: childId, value: childPath) in existingByDriveId.entries) {
            if (existingIsSetByDriveId[childId] != true) continue;
            if (registry.isBusy(childPath)) continue;
            if (depth >= kMaxSetDepth) continue;
            if (!context.visitedDriveIds.add(childId)) {
              subSkipped.add(existingNameByPath[childPath] ?? childId);
              continue;
            }
            final childMeta = await KMetaService.instance.getMeta(childPath);
            final childForceReadOnly = forceReadOnly || (childMeta.sync.isReadOnly == true);
            final childSetNode = effectiveSetNode?.children
                .whereType<DriveFolderSetNode>()
                .where((c) => c.manifestFileId == childId || c.getAbsoluteFilePath() == childPath)
                .firstOrNull;
            final subRes = await _reconcileSetImpl(
              manifestFileId: childId,
              localSetPath: childPath,
              setNode: childSetNode,
              showOsNotification: showOsNotification,
              forceReadOnly: childForceReadOnly,
              depth: depth + 1,
              context: context,
            );
            subAdded += subRes.addedCount;
            subRemoved += subRes.removedCount;
            subKept.addAll(subRes.keptWithLocalChanges);
            subFailed.addAll(subRes.failedItems);
            subSkipped.addAll(subRes.skippedCycleOrDuplicateItems);
            if (!subRes.success) {
              subFailed.add(existingNameByPath[childPath] ?? p.basename(childPath));
            }
          }

          if (effectiveSetNode != null) {
            effectiveSetNode.syncStatus =
                subFailed.isEmpty ? SyncStatus.synced : SyncStatus.error;
          }
          return FolderSetSyncResult(
            success: true,
            addedCount: subAdded,
            removedCount: subRemoved,
            keptWithLocalChanges: subKept,
            failedItems: subFailed,
            skippedCycleOrDuplicateItems: subSkipped,
          );
        }
      }

      final manifest = preloadedManifest ??
          await fetchManifest(
            manifestFileId,
            fallbackName: remoteName ?? p.basename(localSetPath),
          );

      final skippedCycleOrDuplicateItems = <String>[];
      final desiredItems = <DriveFolderSetItem>[];
      final desiredById = <String, DriveFolderSetItem>{};

      for (final item in manifest.items) {
        if (!context.visitedDriveIds.add(item.driveId)) {
          AppLogger.debug(
            '[DriveFolderSet] 循環参照または同一ツリー内の重複のためスキップ: ${item.driveId} (in $localSetPath)',
          );
          skippedCycleOrDuplicateItems.add(item.driveId);
          continue;
        }
        if (context.processedItemCount >= kMaxSetTotalItems) {
          AppLogger.debug(
            '[DriveFolderSet] 最大アイテム総数 ($kMaxSetTotalItems) を超えたためスキップ: ${item.driveId}',
          );
          skippedCycleOrDuplicateItems.add(item.driveId);
          continue;
        }
        context.processedItemCount++;
        desiredItems.add(item);
        desiredById[item.driveId] = item;
      }

      var addedCount = 0;
      var removedCount = 0;
      final keptWithLocalChanges = <String>[];
      final failedItems = <String>[];

      // JSONにパース不能な項目が混じっている場合や、既存フォルダがあるのにJSONが空配列になった場合は
      // 記載ミスによる全消去事故を防ぐため削除フェーズをスキップする
      final allowDeletion = manifest.invalidEntryCount == 0 &&
          (manifest.items.isNotEmpty || existingByDriveId.isEmpty);

      // 1. JSONから外れたフォルダ・子セットを検査・削除
      if (allowDeletion) {
        for (final MapEntry(key: driveId, value: subPath) in existingByDriveId.entries) {
          if (desiredById.containsKey(driveId)) continue;
          if (registry.isBusy(subPath)) continue;

          final folderName = existingNameByPath[subPath] ?? p.basename(subPath);
          final isSubSet = existingIsSetByDriveId[driveId] == true;

          if (isSubSet) {
            final canDeleteSubSet = await _canSafelyDeleteSubSet(
              subPath,
              keptWithLocalChanges,
            );
            if (!canDeleteSubSet) {
              AppLogger.debug(
                '[DriveFolderSet] 子セット配下に未送信変更または状態未確認フォルダがあるため削除をスキップ: $folderName',
              );
              continue;
            }
            if (effectiveSetNode != null) {
              final childSetNode = effectiveSetNode.children
                  .whereType<DriveFolderSetNode>()
                  .where((c) => c.manifestFileId == driveId || c.getAbsoluteFilePath() == subPath)
                  .firstOrNull;
              if (childSetNode != null) {
                await childSetNode.dispose();
              }
            }
            if (await fs.exists(subPath)) {
              await fs.delete(subPath, recursive: true);
            }
            removedCount++;
            continue;
          }

          // 通常の DriveFolderNode: 未完了クローン、または Drive と照合してローカル変更が 0 件と確認できた場合のみ削除可能
          var canSafelyDelete = false;
          if (await registry.hasClonePending(subPath)) {
            canSafelyDelete = true;
          } else {
            final detail = await _syncEngine.checkSyncStatusDetail(subPath);
            canSafelyDelete = (detail.status == FolderSyncStatus.synced ||
                    detail.status == FolderSyncStatus.remoteChanges) &&
                detail.localAdded == 0 &&
                detail.localModified == 0 &&
                detail.localDeleted == 0;
          }

          if (!canSafelyDelete) {
            AppLogger.debug('[DriveFolderSet] 未送信変更または状態未確認のため削除をスキップ: $folderName');
            keptWithLocalChanges.add(folderName);
            continue;
          }

          // ツリー上の子ノードがあれば先に dispose して GeoPackage 接続や地図の地物を解放
          if (effectiveSetNode != null) {
            final childNode = effectiveSetNode.children
                .whereType<DriveFolderNode>()
                .where((c) => c.driveId == driveId || c.getAbsoluteFilePath() == subPath)
                .firstOrNull;
            if (childNode != null) {
              await childNode.dispose();
            }
          }

          if (await fs.exists(subPath)) {
            await fs.delete(subPath, recursive: true);
          }
          removedCount++;
        }
      }

      // 2. JSONにあるフォルダ・子セットを追加・設定更新
      for (final item in desiredItems) {
        final itemEffectiveReadOnly = forceReadOnly || item.readOnly;
        final existingPath = existingByDriveId[item.driveId];
        if (existingPath != null) {
          if (registry.isBusy(existingPath)) continue;

          // 2a. 既存が子セット（DriveFolderSetNode）の場合: 再帰的に reconcile
          if (existingIsSetByDriveId[item.driveId] == true) {
            if (depth >= kMaxSetDepth) {
              AppLogger.debug(
                '[DriveFolderSet] 最大ネスト深さ ($kMaxSetDepth) を超えたため既存子セットをスキップ: $existingPath',
              );
              skippedCycleOrDuplicateItems.add(p.basename(existingPath));
              continue;
            }
            final meta = await KMetaService.instance.getMeta(existingPath);
            if (meta.sync.isReadOnly != itemEffectiveReadOnly) {
              await KMetaService.instance.setDriveSync(
                existingPath,
                isReadOnly: itemEffectiveReadOnly,
              );
            }
            final childSetNode = effectiveSetNode?.children
                .whereType<DriveFolderSetNode>()
                .where((c) =>
                    c.manifestFileId == item.driveId ||
                    c.getAbsoluteFilePath() == existingPath)
                .firstOrNull;
            if (childSetNode != null) {
              childSetNode.isReadOnly = itemEffectiveReadOnly;
            }

            final subRes = await _reconcileSetImpl(
              manifestFileId: item.driveId,
              localSetPath: existingPath,
              setNode: childSetNode,
              showOsNotification: showOsNotification,
              forceReadOnly: itemEffectiveReadOnly,
              depth: depth + 1,
              context: context,
            );
            addedCount += subRes.addedCount;
            removedCount += subRes.removedCount;
            keptWithLocalChanges.addAll(subRes.keptWithLocalChanges);
            failedItems.addAll(subRes.failedItems);
            skippedCycleOrDuplicateItems.addAll(subRes.skippedCycleOrDuplicateItems);
            if (!subRes.success) {
              failedItems.add(p.basename(existingPath));
            }
            continue;
          }

          // 2b. 既存が通常の DriveFolderNode の場合: 未完了クローンなら再開
          if (await registry.hasClonePending(existingPath)) {
            final pullRes = await _syncEngine.pull(
              item.driveId,
              existingPath,
              showOsNotification: showOsNotification,
            );
            if (pullRes.success) {
              addedCount++;
            } else {
              failedItems.add(p.basename(existingPath));
            }
          }
          final meta = await KMetaService.instance.getMeta(existingPath);
          if (itemEffectiveReadOnly) {
            if (meta.sync.isReadOnly != true) {
              await KMetaService.instance.setDriveSync(existingPath, isReadOnly: true);
            }
          } else if (meta.sync.isReadOnly == true) {
            final lookup = await _driveService.lookupFolder(item.driveId);
            if (lookup.folder?.capabilities?.canEdit == true) {
              await KMetaService.instance.setDriveSync(existingPath, isReadOnly: false);
            }
          }
          continue;
        }

        // 新規項目: Drive からメタデータを取得して「子JSONセット」か「Driveフォルダ」かを判別
        final lookup = await _driveService.lookupFolder(item.driveId);
        final info = lookup.folder;
        if (info == null) {
          AppLogger.debug('[DriveFolderSet] 対象が見つかりません: ${item.driveId}');
          failedItems.add(item.driveId);
          continue;
        }

        // 2c. 新規の子JSONセット（入れ子プリセット）
        if (GoogleDriveService.isJsonFileMetadata(info)) {
          if (depth >= kMaxSetDepth) {
            AppLogger.debug(
              '[DriveFolderSet] 最大ネスト深さ ($kMaxSetDepth) を超えたため子セットをスキップ: ${info.name ?? item.driveId}',
            );
            skippedCycleOrDuplicateItems.add(info.name ?? item.driveId);
            continue;
          }
          final DriveFolderSetManifest childManifest;
          try {
            childManifest = await fetchManifest(
              item.driveId,
              fallbackName: info.name,
            );
          } catch (e) {
            AppLogger.debug('[DriveFolderSet] 子セットJSONの取得・解析エラー (${item.driveId}): $e');
            failedItems.add(info.name ?? item.driveId);
            continue;
          }

          final rawSetName = childManifest.name ??
              (info.name?.replaceAll(RegExp(r'\.json$', caseSensitive: false), '') ??
                  item.driveId);
          final baseName = toLocalFolderName(rawSetName, fallback: item.driveId);
          var childSetPath = p.join(localSetPath, baseName);
          for (var n = 2; await fs.exists(childSetPath); n++) {
            childSetPath = p.join(localSetPath, '$baseName $n');
          }

          await fs.createDirectory(childSetPath);
          await registry.markClonePending(childSetPath);
          await KMetaService.instance.setDriveSync(
            childSetPath,
            driveId: item.driveId,
            driveFolderName: p.basename(childSetPath),
            driveUrl: item.driveUrl,
            isReadOnly: itemEffectiveReadOnly,
            isFolderSet: true,
          );

          final subRes = await _reconcileSetImpl(
            manifestFileId: item.driveId,
            localSetPath: childSetPath,
            preloadedManifest: childManifest,
            preloadedRemoteMd5: info.md5Checksum,
            preloadedRemoteName: info.name,
            showOsNotification: showOsNotification,
            forceReadOnly: itemEffectiveReadOnly,
            depth: depth + 1,
            context: context,
          );
          if (subRes.success && subRes.failedItems.isEmpty) {
            addedCount += subRes.addedCount > 0 ? subRes.addedCount : 1;
          } else {
            addedCount += subRes.addedCount;
            if (!subRes.success) {
              failedItems.add(p.basename(childSetPath));
            }
          }
          removedCount += subRes.removedCount;
          keptWithLocalChanges.addAll(subRes.keptWithLocalChanges);
          failedItems.addAll(subRes.failedItems);
          skippedCycleOrDuplicateItems.addAll(subRes.skippedCycleOrDuplicateItems);
          continue;
        }

        // 2d. 新規の通常 Drive フォルダ
        if (!GoogleDriveService.isFolderMetadata(info)) {
          AppLogger.debug('[DriveFolderSet] 対象がフォルダでもJSONでもありません: ${item.driveId}');
          failedItems.add(info.name ?? item.driveId);
          continue;
        }

        final baseName = toLocalFolderName(info.name ?? item.driveId, fallback: item.driveId);
        var childPath = p.join(localSetPath, baseName);
        for (var n = 2; await fs.exists(childPath); n++) {
          childPath = p.join(localSetPath, '$baseName $n');
        }
        final isReadOnly = itemEffectiveReadOnly || !(info.capabilities?.canEdit ?? false);

        final ok = await _syncEngine.cloneFromDrive(
          driveId: item.driveId,
          localPath: childPath,
          folderName: p.basename(childPath),
          driveUrl: item.driveUrl,
          isReadOnly: isReadOnly,
          showOsNotification: showOsNotification,
        );
        if (ok) {
          addedCount++;
        } else {
          failedItems.add(info.name ?? item.driveId);
        }
      }

      // 3. セット自体のメタデータ更新と未完了マーカー解除（全件成功時のみ）
      if (failedItems.isEmpty) {
        await registry.clearClonePending(localSetPath);
      }
      await KMetaService.instance.setDriveSync(
        localSetPath,
        driveId: manifestFileId,
        isFolderSet: true,
        lastSynced: DateTime.now(),
        driveRevisionId: failedItems.isEmpty ? remoteMd5 : null,
      );

      if (effectiveSetNode != null) {
        effectiveSetNode.lastSynced = DateTime.now();
        if (failedItems.isEmpty) {
          effectiveSetNode.driveRevisionId = remoteMd5;
          effectiveSetNode.syncStatus = SyncStatus.synced;
        } else {
          effectiveSetNode.syncStatus = SyncStatus.error;
        }
      }

      return FolderSetSyncResult(
        success: true,
        addedCount: addedCount,
        removedCount: removedCount,
        keptWithLocalChanges: keptWithLocalChanges,
        failedItems: failedItems,
        skippedCycleOrDuplicateItems: skippedCycleOrDuplicateItems,
      );
    } catch (e) {
      AppLogger.error('[DriveFolderSet] セット同期エラー ($localSetPath): $e');
      if (effectiveSetNode != null) {
        effectiveSetNode.syncStatus = SyncStatus.error;
      }
      return FolderSetSyncResult(
        success: false,
        errorMessage: '$e',
      );
    }
  }

  /// 子セット（[subSetPath]）配下のすべての [DriveFolderNode] を再帰検査し、
  /// 1つでも転送中または未送信のローカル変更がある（もしくは状態確認できない）フォルダがあれば
  /// [keptWithLocalChanges] に名前を追加して false を返す。すべて安全に削除できる場合のみ true を返す。
  Future<bool> _canSafelyDeleteSubSet(
    String subSetPath,
    List<String> keptWithLocalChanges,
  ) async {
    final registry = DriveTransferRegistry.instance;
    if (registry.isBusy(subSetPath)) return false;

    var allSafe = true;
    for (final entry in await fs.list(subSetPath)) {
      if (!entry.isDirectory || entry.name.startsWith('.')) continue;
      if (registry.isBusy(entry.path)) {
        allSafe = false;
        continue;
      }
      try {
        final meta = await KMetaService.instance.getMeta(entry.path);
        if (!meta.sync.isLinked) continue;
        if (meta.sync.isFolderSet == true) {
          final childSafe = await _canSafelyDeleteSubSet(
            entry.path,
            keptWithLocalChanges,
          );
          if (!childSafe) allSafe = false;
          continue;
        }
        var folderSafe = false;
        if (await registry.hasClonePending(entry.path)) {
          folderSafe = true;
        } else {
          final detail = await _syncEngine.checkSyncStatusDetail(entry.path);
          folderSafe = (detail.status == FolderSyncStatus.synced ||
                  detail.status == FolderSyncStatus.remoteChanges) &&
              detail.localAdded == 0 &&
              detail.localModified == 0 &&
              detail.localDeleted == 0;
        }
        if (!folderSafe) {
          keptWithLocalChanges.add(entry.name);
          allSafe = false;
        }
      } catch (_) {
        keptWithLocalChanges.add(entry.name);
        allSafe = false;
      }
    }
    return allSafe;
  }

  /// [setNode] 配下の子ノードを再帰的に読み込み、子セット内も含めた全子孫 [DriveFolderNode] の `.qgs` を読み戻す
  static Future<void> reloadFolderSetNode(DriveFolderSetNode setNode) async {
    await _reloadRecursive(setNode);
    for (final child in _collectDescendantDriveFolders(setNode)) {
      try {
        final readBack = await const QgsReadBack().run(child);
        if (readBack != null) {
          await _reloadRecursive(child);
        }
      } catch (e) {
        AppLogger.debug('[DriveFolderSet] 子フォルダ ${child.name} の .qgs 読み戻しエラー: $e');
      }
    }
  }

  static Iterable<DriveFolderNode> _collectDescendantDriveFolders(
    LayerTreeNode node,
  ) sync* {
    for (final child in node.children) {
      if (child is DriveFolderNode) {
        yield child;
      } else if (child is FolderNode) {
        yield* _collectDescendantDriveFolders(child);
      }
    }
  }

  static Future<void> _reloadRecursive(LayerTreeNode node) async {
    await node.updateChildren();
    for (final child in node.children) {
      if (child is DriveFolderSetNode &&
          child.syncStatus == SyncStatus.unknown &&
          node is DriveFolderSetNode &&
          node.syncStatus == SyncStatus.synced) {
        child.syncStatus = SyncStatus.synced;
      }
      if (child is FolderNode || child is GeoPackageNode) {
        await _reloadRecursive(child);
      }
    }
  }
}
