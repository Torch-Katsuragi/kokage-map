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
/// Drive上のJSONマニフェストによる共有フォルダセット（[DriveFolderSetNode]）の解析・同期サービス。
///
/// 責務ごとに以下のサブモジュールへ分割されている:
/// - [drive_folder_set_manifest.dart]: マニフェストモデル（[DriveFolderSetItem], [DriveFolderSetManifest], [FolderSetSyncResult]）と JSON パース
/// - [drive_folder_set_hierarchy.dart]: 入れ子展開・循環参照遮断・First-Win 重複排除・読み取り専用伝播・件数/深さ上限ガード
/// - [drive_folder_set_storage.dart]: ローカル実体走査・単一実体共有（[DriveDirStore]）・安全削除検査
/// - [drive_tree_nodes.dart]: レイヤーツリー再読込と `.qgs` 読み戻し
library;

import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'auto_sync_service.dart';
import 'drive_dir_store.dart';
import 'drive_folder_set_hierarchy.dart';
import 'drive_folder_set_manifest.dart';
import 'drive_folder_set_storage.dart';
import 'drive_transfer_registry.dart';
import 'drive_tree_nodes.dart';
import 'folder_lookup.dart';
import 'google_drive_service.dart';
import 'sync_engine.dart';
import 'sync_file_operations.dart';

export 'drive_folder_set_manifest.dart';

/// Drive共有フォルダセットの取得・差分調整オーケストレータ
class DriveFolderSetService {
  /// 子セットの最大ネスト深さ（ルートセット = 0、最大 5 階層の子セットまで許可）
  static const int kMaxSetDepth = kFolderSetMaxDepth;

  /// 1つのルートセットツリー全体で展開するアイテム（子セット＋フォルダ）の最大総数
  static const int kMaxSetTotalItems = kFolderSetMaxTotalItems;

  /// 同一セットパスに対する `reconcileSet` の多重実行を防ぐ排他マップ
  static final Map<String, Future<FolderSetSyncResult>> _inFlight = {};

  final GoogleDriveService _driveService;
  final SyncEngine _syncEngine;
  late final FolderSetStorage _storage = FolderSetStorage(
    _driveService,
    _syncEngine,
  );

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
  /// - JSON内の項目が Drive フォルダなら `localSetPath` 直下へマウント/クローン（[DriveFolderNode]）
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
    await LocalSyncSeedIndex.instance.refreshFromLedgers();
    final init = await FolderSetHierarchy.buildInitialState(
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
      context: FolderSetReconcileContext(
        initialVisitedIds: init.visitedIds,
        rootSetPath: init.rootSetPath,
        searchRoots: [p.dirname(init.rootSetPath)],
      ),
    );
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
    required FolderSetReconcileContext context,
  }) async {
    final registry = DriveTransferRegistry.instance;
    final effectiveSetNode =
        setNode ?? AutoSyncService.instance.findFolderSetByPath(localSetPath);

    // 自分自身の JSON ID を visited に登録（子孫が自分を指していたら循環として弾く）
    context.visitedDriveIds.add(manifestFileId);

    try {
      String? remoteMd5 = preloadedRemoteMd5;
      String? remoteName = preloadedRemoteName;
      if (preloadedManifest == null ||
          (remoteMd5 == null && remoteName == null)) {
        final fileMeta = await _driveService.lookupFolder(manifestFileId);
        remoteMd5 ??= fileMeta.folder?.md5Checksum;
        remoteName ??= fileMeta.folder?.name;
      }

      await fs.createDirectory(localSetPath);
      final currentSetMeta = await KMetaService.instance.getMeta(localSetPath);
      final scan = await _storage.scanExistingEntries(
        localSetPath: localSetPath,
        currentSetMeta: currentSetMeta,
        searchRoots: context.searchRoots,
      );

      // 自動同期等で preloadedManifest が無く、かつ JSON の MD5 が前回から変わっておらず、
      // 未完了クローンのマーカーも無ければ、この階層の JSON 本体ダウンロードと直下の構成変更は省略できる。
      // ただし、直下に子セット（DriveFolderSetNode）がある場合は子セット側の JSON が更新されている可能性があるため再帰チェックを通す。
      final fastPathResult = await _tryUnchangedManifestFastPath(
        preloadedManifest: preloadedManifest,
        remoteMd5: remoteMd5,
        localSetPath: localSetPath,
        currentSetMeta: currentSetMeta,
        scan: scan,
        effectiveSetNode: effectiveSetNode,
        showOsNotification: showOsNotification,
        forceReadOnly: forceReadOnly,
        depth: depth,
        context: context,
      );
      if (fastPathResult != null) {
        return fastPathResult;
      }

      final manifest = preloadedManifest ??
          await fetchManifest(
            manifestFileId,
            fallbackName: remoteName ?? p.basename(localSetPath),
          );

      final filtered = FolderSetHierarchy.filterManifestItems(
        manifest,
        context,
        logSetPath: localSetPath,
        maxTotalItems: kMaxSetTotalItems,
      );
      final skippedCycleOrDuplicateItems = [
        ...filtered.skippedCycleOrDuplicateItems,
      ];

      var addedCount = 0;
      var removedCount = 0;
      final keptWithLocalChanges = <String>[];
      final failedItems = <String>[];
      final updatedMembers = <String, KMetaFolderSetMember>{
        ...scan.existingMemberByDriveId,
      };

      // 1. JSONから外れたフォルダ・子セットを検査・削除
      if (FolderSetHierarchy.shouldAllowDeletion(
        manifest: manifest,
        hasExistingEntries: scan.existingByDriveId.isNotEmpty,
      )) {
        for (final MapEntry(key: driveId, value: subPath)
            in scan.existingByDriveId.entries) {
          if (filtered.desiredById.containsKey(driveId)) continue;
          final removed = await _storage.removeUnlistedEntry(
            driveId: driveId,
            subPath: subPath,
            localSetPath: localSetPath,
            scan: scan,
            effectiveSetNode: effectiveSetNode,
            updatedMembers: updatedMembers,
            keptWithLocalChanges: keptWithLocalChanges,
            searchRoots: context.searchRoots,
          );
          if (removed) removedCount++;
        }
      }

      // 2. 新規項目のメタデータ（lookupFolder）を事前に並列取得（最大4並列）
      final itemsNeedingLookup = filtered.desiredItems
          .where((item) => !scan.existingByDriveId.containsKey(item.driveId))
          .toList();
      final lookupByDriveId = <String, FolderLookup>{};
      if (itemsNeedingLookup.isNotEmpty) {
        await SyncFileOperations.runParallel(
          itemsNeedingLookup.map(
            (item) => () async {
              lookupByDriveId[item.driveId] =
                  await _driveService.lookupFolder(item.driveId);
            },
          ),
          maxConcurrency: 4,
        );
      }

      // 3. JSONにあるフォルダ・子セットを追加・設定更新
      for (final item in filtered.desiredItems) {
        final itemEffectiveReadOnly = forceReadOnly || item.readOnly;
        final existingPath = scan.existingByDriveId[item.driveId];
        if (existingPath != null) {
          if (registry.isBusy(existingPath)) continue;

          if (scan.existingIsSetByDriveId[item.driveId] == true) {
            final subRes = await _reconcileExistingChildSet(
              item: item,
              existingPath: existingPath,
              effectiveSetNode: effectiveSetNode,
              itemEffectiveReadOnly: itemEffectiveReadOnly,
              showOsNotification: showOsNotification,
              depth: depth,
              context: context,
              skippedOut: skippedCycleOrDuplicateItems,
            );
            if (subRes != null) {
              addedCount += subRes.addedCount;
              removedCount += subRes.removedCount;
              keptWithLocalChanges.addAll(subRes.keptWithLocalChanges);
              failedItems.addAll(subRes.failedItems);
              skippedCycleOrDuplicateItems
                  .addAll(subRes.skippedCycleOrDuplicateItems);
              if (!subRes.success) {
                failedItems.add(p.basename(existingPath));
              }
            }
            continue;
          }

          final outcome = await _reconcileExistingFolder(
            item: item,
            existingPath: existingPath,
            scan: scan,
            itemEffectiveReadOnly: itemEffectiveReadOnly,
            showOsNotification: showOsNotification,
            context: context,
            updatedMembers: updatedMembers,
          );
          if (outcome.resumedAdded) addedCount++;
          if (outcome.failedName != null) failedItems.add(outcome.failedName!);
          continue;
        }

        // 新規項目: 事前取得したメタデータから「子JSONセット」か「Driveフォルダ」かを判別
        final lookup = lookupByDriveId[item.driveId] ??
            await _driveService.lookupFolder(item.driveId);
        final info = lookup.folder;
        if (info == null) {
          AppLogger.debug('[DriveFolderSet] 対象が見つかりません: ${item.driveId}');
          failedItems.add(item.driveId);
          continue;
        }

        if (GoogleDriveService.isJsonFileMetadata(info)) {
          final subOutcome = await _createAndReconcileNewChildSet(
            localSetPath: localSetPath,
            item: item,
            info: info,
            itemEffectiveReadOnly: itemEffectiveReadOnly,
            showOsNotification: showOsNotification,
            depth: depth,
            context: context,
            skippedOut: skippedCycleOrDuplicateItems,
            failedOut: failedItems,
          );
          if (subOutcome != null) {
            addedCount += subOutcome.addedCount;
            removedCount += subOutcome.removedCount;
            keptWithLocalChanges.addAll(subOutcome.keptWithLocalChanges);
            failedItems.addAll(subOutcome.failedItems);
            skippedCycleOrDuplicateItems
                .addAll(subOutcome.skippedItems);
          }
          continue;
        }

        if (!GoogleDriveService.isFolderMetadata(info)) {
          AppLogger.debug(
            '[DriveFolderSet] 対象がフォルダでもJSONでもありません: ${item.driveId}',
          );
          failedItems.add(info.name ?? item.driveId);
          continue;
        }

        final folderOutcome = await _storage.mountOrCloneNewFolder(
          item: item,
          info: info,
          itemEffectiveReadOnly: itemEffectiveReadOnly,
          rootSetPath: context.rootSetPath,
          searchRoots: context.searchRoots,
          showOsNotification: showOsNotification,
          updatedMembers: updatedMembers,
        );
        if (folderOutcome.added) {
          addedCount++;
        } else if (folderOutcome.failedItemName != null) {
          failedItems.add(folderOutcome.failedItemName!);
        }
      }

      // 4. セット自体のメタデータ更新と未完了マーカー解除（全件成功時のみ）
      if (failedItems.isEmpty) {
        await registry.clearClonePending(localSetPath);
      }
      await KMetaService.instance.setDriveSync(
        localSetPath,
        driveId: manifestFileId,
        isFolderSet: true,
        setMembers: updatedMembers.values.toList(),
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

  Future<FolderSetSyncResult?> _tryUnchangedManifestFastPath({
    required DriveFolderSetManifest? preloadedManifest,
    required String? remoteMd5,
    required String localSetPath,
    required KMeta currentSetMeta,
    required FolderSetLocalScan scan,
    required DriveFolderSetNode? effectiveSetNode,
    required bool showOsNotification,
    required bool forceReadOnly,
    required int depth,
    required FolderSetReconcileContext context,
  }) async {
    final registry = DriveTransferRegistry.instance;
    if (preloadedManifest != null ||
        remoteMd5 == null ||
        scan.anySubfolderPending ||
        await registry.hasClonePending(localSetPath)) {
      return null;
    }
    if (currentSetMeta.sync.driveRevisionId != remoteMd5 ||
        scan.existingByDriveId.isEmpty) {
      return null;
    }

    // 直下の通常フォルダの ID を先に visited に登録してから子セットを再帰チェック
    for (final MapEntry(key: id, value: isSubSet)
        in scan.existingIsSetByDriveId.entries) {
      if (!isSubSet) context.visitedDriveIds.add(id);
    }

    var subAdded = 0;
    var subRemoved = 0;
    final subKept = <String>[];
    final subFailed = <String>[];
    final subSkipped = <String>[];

    for (final MapEntry(key: childId, value: childPath)
        in scan.existingByDriveId.entries) {
      if (scan.existingIsSetByDriveId[childId] != true) continue;
      if (registry.isBusy(childPath)) continue;
      if (depth >= kMaxSetDepth) continue;
      if (!context.visitedDriveIds.add(childId)) {
        subSkipped.add(scan.existingNameByPath[childPath] ?? childId);
        continue;
      }
      final childMeta = await KMetaService.instance.getMeta(childPath);
      final childForceReadOnly =
          forceReadOnly || (childMeta.sync.isReadOnly == true);
      final childSetNode = effectiveSetNode?.children
          .whereType<DriveFolderSetNode>()
          .where(
            (c) =>
                c.manifestFileId == childId ||
                c.getAbsoluteFilePath() == childPath,
          )
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
        subFailed.add(
          scan.existingNameByPath[childPath] ?? p.basename(childPath),
        );
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

  Future<FolderSetSyncResult?> _reconcileExistingChildSet({
    required DriveFolderSetItem item,
    required String existingPath,
    required DriveFolderSetNode? effectiveSetNode,
    required bool itemEffectiveReadOnly,
    required bool showOsNotification,
    required int depth,
    required FolderSetReconcileContext context,
    required List<String> skippedOut,
  }) async {
    if (depth >= kMaxSetDepth) {
      AppLogger.debug(
        '[DriveFolderSet] 最大ネスト深さ ($kMaxSetDepth) を超えたため既存子セットをスキップ: $existingPath',
      );
      skippedOut.add(p.basename(existingPath));
      return null;
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
        .where(
          (c) =>
              c.manifestFileId == item.driveId ||
              c.getAbsoluteFilePath() == existingPath,
        )
        .firstOrNull;
    if (childSetNode != null) {
      childSetNode.isReadOnly = itemEffectiveReadOnly;
    }

    return _reconcileSetImpl(
      manifestFileId: item.driveId,
      localSetPath: existingPath,
      setNode: childSetNode,
      showOsNotification: showOsNotification,
      forceReadOnly: itemEffectiveReadOnly,
      depth: depth + 1,
      context: context,
    );
  }

  Future<({bool resumedAdded, String? failedName})> _reconcileExistingFolder({
    required DriveFolderSetItem item,
    required String existingPath,
    required FolderSetLocalScan scan,
    required bool itemEffectiveReadOnly,
    required bool showOsNotification,
    required FolderSetReconcileContext context,
    required Map<String, KMetaFolderSetMember> updatedMembers,
  }) async {
    final registry = DriveTransferRegistry.instance;
    var resumedAdded = false;
    String? failedName;

    if (await registry.hasClonePending(existingPath)) {
      registry.bindParentTransfer(existingPath, context.rootSetPath);
      try {
        final pullRes = await _syncEngine.pull(
          item.driveId,
          existingPath,
          showOsNotification: showOsNotification,
        );
        if (pullRes.success) {
          resumedAdded = true;
        } else {
          failedName =
              scan.existingNameByPath[existingPath] ?? p.basename(existingPath);
        }
      } finally {
        registry.unbindParentTransfer(existingPath);
      }
    }

    final meta = await KMetaService.instance.getMeta(existingPath);
    final resolvedRo = await _storage.resolveExistingFolderReadOnly(
      existingPath: existingPath,
      driveId: item.driveId,
      meta: meta,
      itemEffectiveReadOnly: itemEffectiveReadOnly,
    );
    final prevMember = updatedMembers[item.driveId];
    updatedMembers[item.driveId] = KMetaFolderSetMember(
      driveId: item.driveId,
      name: prevMember?.name ??
          scan.existingNameByPath[existingPath] ??
          p.basename(existingPath),
      driveUrl: item.driveUrl,
      isReadOnly: resolvedRo,
      targetPath: existingPath,
    );
    return (resumedAdded: resumedAdded, failedName: failedName);
  }

  Future<({
    int addedCount,
    int removedCount,
    List<String> keptWithLocalChanges,
    List<String> failedItems,
    List<String> skippedItems,
  })?> _createAndReconcileNewChildSet({
    required String localSetPath,
    required DriveFolderSetItem item,
    required drive.File info,
    required bool itemEffectiveReadOnly,
    required bool showOsNotification,
    required int depth,
    required FolderSetReconcileContext context,
    required List<String> skippedOut,
    required List<String> failedOut,
  }) async {
    if (depth >= kMaxSetDepth) {
      AppLogger.debug(
        '[DriveFolderSet] 最大ネスト深さ ($kMaxSetDepth) を超えたため子セットをスキップ: ${info.name ?? item.driveId}',
      );
      skippedOut.add(info.name ?? item.driveId);
      return null;
    }

    final DriveFolderSetManifest childManifest;
    try {
      childManifest = await fetchManifest(
        item.driveId,
        fallbackName: info.name,
      );
    } catch (e) {
      AppLogger.debug(
        '[DriveFolderSet] 子セットJSONの取得・解析エラー (${item.driveId}): $e',
      );
      failedOut.add(info.name ?? item.driveId);
      return null;
    }

    final childSetPath = await _storage.allocateChildSetDirectory(
      localSetPath: localSetPath,
      item: item,
      manifestName: childManifest.name,
      remoteInfoName: info.name,
      isReadOnly: itemEffectiveReadOnly,
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

    final localFailed = <String>[
      if (!subRes.success) p.basename(childSetPath),
      ...subRes.failedItems,
    ];
    final added = (subRes.success && subRes.failedItems.isEmpty)
        ? (subRes.addedCount > 0 ? subRes.addedCount : 1)
        : subRes.addedCount;

    return (
      addedCount: added,
      removedCount: subRes.removedCount,
      keptWithLocalChanges: subRes.keptWithLocalChanges,
      failedItems: localFailed,
      skippedItems: subRes.skippedCycleOrDuplicateItems,
    );
  }

  /// [setNode] 配下の子ノードを再帰的に読み込み、子セット内も含めた全子孫 [DriveFolderNode] の `.qgs` を読み戻す
  static Future<void> reloadFolderSetNode(DriveFolderSetNode setNode) =>
      DriveTreeNodes.reloadFolderSetNode(setNode);
}
