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
/// 共有フォルダセットのローカル実体走査・単一実体マウント・安全削除検査ヘルパー
library;

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/fs/safe_path.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'drive_dir_store.dart';
import 'drive_folder_set_manifest.dart';
import 'drive_transfer_registry.dart';
import 'drive_tree_nodes.dart';
import 'google_drive_service.dart';
import 'sync_engine.dart';

/// セットフォルダ直下および `KMetaSync.setMembers` の既存連携状態スナップショット
class FolderSetLocalScan {
  final Map<String, String> existingByDriveId;
  final Map<String, String> existingNameByPath;
  final Map<String, bool> existingIsSetByDriveId;
  final Map<String, KMetaFolderSetMember> existingMemberByDriveId;
  final bool anySubfolderPending;
  final bool anyRecordedMemberMissing;

  const FolderSetLocalScan({
    required this.existingByDriveId,
    required this.existingNameByPath,
    required this.existingIsSetByDriveId,
    required this.existingMemberByDriveId,
    required this.anySubfolderPending,
    this.anyRecordedMemberMissing = false,
  });
}

/// 共有フォルダセットのローカル配置・単一実体共有・削除前検査を担うストレージヘルパー
class FolderSetStorage {
  final GoogleDriveService _driveService;
  final SyncEngine _syncEngine;

  const FolderSetStorage(this._driveService, this._syncEngine);

  /// 現在の直下サブフォルダおよび `KMetaSync.setMembers`（参照マウント）の Drive 連携状態を集める
  Future<FolderSetLocalScan> scanExistingEntries({
    required String localSetPath,
    required KMeta currentSetMeta,
    required List<String> searchRoots,
  }) async {
    final registry = DriveTransferRegistry.instance;
    final existingByDriveId = <String, String>{};
    final existingNameByPath = <String, String>{};
    final existingIsSetByDriveId = <String, bool>{};
    final existingMemberByDriveId = <String, KMetaFolderSetMember>{};
    var anySubfolderPending = false;
    var anyRecordedMemberMissing = false;

    for (final member in currentSetMeta.sync.setMembers) {
      if (member.driveId.isEmpty) continue;
      String? targetPath = member.targetPath;
      if (targetPath == null || !await fs.isDirectory(targetPath)) {
        targetPath = await DriveDirStore.instance.findExistingPath(
          member.driveId,
          searchRoots: searchRoots,
        );
      }
      if (targetPath == null || !await fs.isDirectory(targetPath)) {
        anyRecordedMemberMissing = true;
        continue;
      }
      await DriveDirStore.instance.register(member.driveId, targetPath);
      if (await registry.hasClonePending(targetPath)) {
        anySubfolderPending = true;
      }
      existingByDriveId[member.driveId] = targetPath;
      existingNameByPath[targetPath] =
          member.name.isNotEmpty ? member.name : p.basename(targetPath);
      existingIsSetByDriveId[member.driveId] = false;
      existingMemberByDriveId[member.driveId] =
          member.copyWith(targetPath: targetPath);
    }

    for (final entry in await fs.list(localSetPath)) {
      if (!entry.isDirectory || entry.name.startsWith('.')) continue;
      try {
        if (await registry.hasClonePending(entry.path)) {
          anySubfolderPending = true;
        }
        final meta = await KMetaService.instance.getMeta(entry.path);
        final id = meta.sync.driveId;
        if (id != null && id.isNotEmpty) {
          final isSubSet = meta.sync.isFolderSet == true;
          existingByDriveId[id] = entry.path;
          existingNameByPath[entry.path] = entry.name;
          existingIsSetByDriveId[id] = isSubSet;
          if (!isSubSet) {
            await DriveDirStore.instance.register(id, entry.path);
            existingMemberByDriveId[id] = KMetaFolderSetMember(
              driveId: id,
              name: entry.name,
              driveUrl: meta.sync.driveUrl ??
                  'https://drive.google.com/drive/folders/$id',
              isReadOnly: meta.sync.isReadOnly ?? false,
              targetPath: entry.path,
            );
          }
        }
      } catch (_) {}
    }

    return FolderSetLocalScan(
      existingByDriveId: existingByDriveId,
      existingNameByPath: existingNameByPath,
      existingIsSetByDriveId: existingIsSetByDriveId,
      existingMemberByDriveId: existingMemberByDriveId,
      anySubfolderPending: anySubfolderPending,
      anyRecordedMemberMissing: anyRecordedMemberMissing,
    );
  }

  /// 単一フォルダが削除可能か（未完了クローン、または Drive と照合してローカル変更が 0 件）を判定する
  Future<bool> isFolderSafeToDelete(String folderPath) async {
    if (await DriveTransferRegistry.instance.hasClonePending(folderPath)) {
      return true;
    }
    final detail = await _syncEngine.checkSyncStatusDetail(folderPath);
    return (detail.status == FolderSyncStatus.synced ||
            detail.status == FolderSyncStatus.remoteChanges) &&
        detail.localAdded == 0 &&
        detail.localModified == 0 &&
        detail.localDeleted == 0;
  }

  /// 子セット（[subSetPath]）配下のすべての [DriveFolderNode]（参照マウントを含む）を再帰検査し、
  /// 1つでも転送中または未送信のローカル変更がある（もしくは状態確認できない）フォルダがあれば
  /// [keptWithLocalChanges] に名前を追加して false を返す。すべて安全に削除できる場合のみ true を返す。
  Future<bool> canSafelyDeleteSubSet(
    String subSetPath,
    List<String> keptWithLocalChanges, {
    List<String> searchRoots = const [],
  }) async {
    final registry = DriveTransferRegistry.instance;
    if (registry.isBusy(subSetPath)) return false;

    var allSafe = true;
    final checkedPaths = <String>{};

    Future<void> checkFolder(String folderPath, String displayName) async {
      final norm = DriveTransferRegistry.normalizeKey(folderPath);
      if (!checkedPaths.add(norm)) return;
      if (registry.isBusy(folderPath)) {
        allSafe = false;
        return;
      }
      final folderSafe = await isFolderSafeToDelete(folderPath);
      if (!folderSafe) {
        keptWithLocalChanges.add(displayName);
        allSafe = false;
      }
    }

    try {
      final subSetMeta = await KMetaService.instance.getMeta(subSetPath);
      for (final member in subSetMeta.sync.setMembers) {
        final mPath = member.targetPath ??
            await DriveDirStore.instance.findExistingPath(
              member.driveId,
              searchRoots: searchRoots,
            );
        if (mPath == null || !await fs.isDirectory(mPath)) continue;
        final name = member.name.isNotEmpty ? member.name : p.basename(mPath);
        await checkFolder(mPath, name);
      }
    } catch (_) {}

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
          final childSafe = await canSafelyDeleteSubSet(
            entry.path,
            keptWithLocalChanges,
            searchRoots: searchRoots,
          );
          if (!childSafe) allSafe = false;
          continue;
        }
        await checkFolder(entry.path, entry.name);
      } catch (_) {
        keptWithLocalChanges.add(entry.name);
        allSafe = false;
      }
    }
    return allSafe;
  }

  /// 削除されるセット・フォルダ（[subSetPath]）配下の参照メンバー一覧をディスク上の `KMeta` から再帰収集する
  static Future<List<KMetaFolderSetMember>> collectSubSetMembersFromDisk(
    String subSetPath, {
    List<String> searchRoots = const [],
  }) async {
    final out = <KMetaFolderSetMember>[];
    try {
      final meta = await KMetaService.instance.getRawMeta(subSetPath);
      if (meta != null) {
        for (final member in meta.sync.setMembers) {
          final mPath = member.targetPath ??
              await DriveDirStore.instance.findExistingPath(
                member.driveId,
                searchRoots: searchRoots,
              );
          out.add(member.copyWith(targetPath: mPath));
        }
      }
      if (!await fs.isDirectory(subSetPath)) return out;
      for (final entry in await fs.list(subSetPath)) {
        if (!entry.isDirectory || entry.name.startsWith('.')) continue;
        final childMeta = await KMetaService.instance.getRawMeta(entry.path);
        if (childMeta == null || !childMeta.sync.isLinked) {
          // 通常フォルダの中にセットが入っているケースも再帰走査する
          out.addAll(
            await collectSubSetMembersFromDisk(
              entry.path,
              searchRoots: searchRoots,
            ),
          );
          continue;
        }
        if (childMeta.sync.isFolderSet == true) {
          out.addAll(
            await collectSubSetMembersFromDisk(
              entry.path,
              searchRoots: searchRoots,
            ),
          );
        } else if (childMeta.sync.driveId != null &&
            childMeta.sync.driveId!.isNotEmpty) {
          out.add(
            KMetaFolderSetMember(
              driveId: childMeta.sync.driveId!,
              name: entry.name,
              driveUrl: childMeta.sync.driveUrl ?? '',
              isReadOnly: childMeta.sync.isReadOnly ?? false,
              targetPath: entry.path,
            ),
          );
        }
      }
    } catch (_) {}
    return out;
  }

  /// 削除される子セット（[subSetPath]）配下の参照メンバー一覧を再帰収集する
  Future<List<KMetaFolderSetMember>> collectSubSetMembers(
    String subSetPath, {
    List<String> searchRoots = const [],
  }) =>
      collectSubSetMembersFromDisk(subSetPath, searchRoots: searchRoots);

  /// JSONから外れたフォルダ・子セットを安全に検査・削除する（削除できた場合は true）
  Future<bool> removeUnlistedEntry({
    required String driveId,
    required String subPath,
    required String localSetPath,
    required FolderSetLocalScan scan,
    required DriveFolderSetNode? effectiveSetNode,
    required Map<String, KMetaFolderSetMember> updatedMembers,
    required List<String> keptWithLocalChanges,
    required List<String> searchRoots,
  }) async {
    if (DriveTransferRegistry.instance.isBusy(subPath)) return false;

    final folderName = scan.existingNameByPath[subPath] ?? p.basename(subPath);
    final isSubSet = scan.existingIsSetByDriveId[driveId] == true;

    if (isSubSet) {
      final canDelete = await canSafelyDeleteSubSet(
        subPath,
        keptWithLocalChanges,
        searchRoots: searchRoots,
      );
      if (!canDelete) {
        AppLogger.debug(
          '[DriveFolderSet] 子セット配下に未送信変更または状態未確認フォルダがあるため削除をスキップ: $folderName',
        );
        return false;
      }
      final subMembersToCleanup = await collectSubSetMembers(
        subPath,
        searchRoots: searchRoots,
      );
      if (effectiveSetNode != null) {
        final childSetNode = effectiveSetNode.children
            .whereType<DriveFolderSetNode>()
            .where(
              (c) =>
                  c.manifestFileId == driveId ||
                  c.getAbsoluteFilePath() == subPath,
            )
            .firstOrNull;
        if (childSetNode != null) {
          await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(childSetNode);
        }
      }
      if (await fs.exists(subPath)) {
        await fs.delete(subPath, recursive: true);
      }
      for (final m in subMembersToCleanup) {
        if (m.targetPath != null) {
          await DriveDirStore.instance.deletePhysicalIfUnreferenced(
            driveId: m.driveId,
            targetPath: m.targetPath!,
            excludingSetPath: subPath,
            searchRoots: searchRoots,
          );
        }
      }
      return true;
    }

    // 通常の DriveFolderNode: 未完了クローン、または Drive と照合してローカル変更が 0 件と確認できた場合のみ削除可能
    if (!await isFolderSafeToDelete(subPath)) {
      AppLogger.debug(
        '[DriveFolderSet] 未送信変更または状態未確認のため削除をスキップ: $folderName',
      );
      keptWithLocalChanges.add(folderName);
      return false;
    }

    // ツリー上の子ノードがあれば先に dispose して GeoPackage 接続や地図の地物を解放
    if (effectiveSetNode != null) {
      final childNode = effectiveSetNode.children
          .whereType<DriveFolderNode>()
          .where((c) => c.driveId == driveId || c.getAbsoluteFilePath() == subPath)
          .firstOrNull;
      if (childNode != null) {
        await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(childNode);
      }
    }

    updatedMembers.remove(driveId);
    await DriveDirStore.instance.deletePhysicalIfUnreferenced(
      driveId: driveId,
      targetPath: subPath,
      excludingSetPath: localSetPath,
      searchRoots: searchRoots,
    );
    return true;
  }

  /// 既存の通常 Drive フォルダに対して読み取り専用フラグを更新し、解決後の `isReadOnly` を返す
  Future<bool> resolveExistingFolderReadOnly({
    required String existingPath,
    required String driveId,
    required KMeta meta,
    required bool itemEffectiveReadOnly,
  }) async {
    var resolvedRo = meta.sync.isReadOnly ?? false;
    if (itemEffectiveReadOnly) {
      resolvedRo = true;
      if (meta.sync.isReadOnly != true) {
        await KMetaService.instance.setDriveSync(existingPath, isReadOnly: true);
      }
    } else if (meta.sync.isReadOnly == true) {
      final lookup = await _driveService.lookupFolder(driveId);
      if (lookup.folder?.capabilities?.canEdit == true) {
        resolvedRo = false;
        await KMetaService.instance.setDriveSync(existingPath, isReadOnly: false);
      }
    }
    return resolvedRo;
  }

  /// 新規子セット用のローカルサブフォルダを作成し、初期メタデータを書き込んでパスを返す
  Future<String> allocateChildSetDirectory({
    required String localSetPath,
    required DriveFolderSetItem item,
    required String? manifestName,
    required String? remoteInfoName,
    required bool isReadOnly,
  }) async {
    final rawSetName = manifestName ??
        (remoteInfoName?.replaceAll(RegExp(r'\.json$', caseSensitive: false), '') ??
            item.driveId);
    final baseName = toLocalFolderName(rawSetName, fallback: item.driveId);
    var childSetPath = p.join(localSetPath, baseName);
    for (var n = 2; await fs.exists(childSetPath); n++) {
      childSetPath = p.join(localSetPath, '$baseName $n');
    }

    await fs.createDirectory(childSetPath);
    await DriveTransferRegistry.instance.markClonePending(childSetPath);
    await KMetaService.instance.setDriveSync(
      childSetPath,
      driveId: item.driveId,
      driveFolderName: p.basename(childSetPath),
      driveUrl: item.driveUrl,
      isReadOnly: isReadOnly,
      isFolderSet: true,
    );
    return childSetPath;
  }

  /// 新規の通常 Drive フォルダを参照マウント（Tier 1）または `.kokage/drive_store` へクローンする
  Future<({bool added, String? failedItemName})> mountOrCloneNewFolder({
    required DriveFolderSetItem item,
    required drive.File info,
    required bool itemEffectiveReadOnly,
    required String rootSetPath,
    required List<String> searchRoots,
    required bool showOsNotification,
    required Map<String, KMetaFolderSetMember> updatedMembers,
  }) async {
    final registry = DriveTransferRegistry.instance;
    final baseName =
        toLocalFolderName(info.name ?? item.driveId, fallback: item.driveId);
    final isReadOnly =
        itemEffectiveReadOnly || !(info.capabilities?.canEdit ?? false);

    // Tier 1: DriveDirStore に同一 driveId の完了済み実体があればダウンロードせず参照マウント
    final reusedPath = await DriveDirStore.instance.findExistingPath(
      item.driveId,
      searchRoots: searchRoots,
    );
    if (reusedPath != null && !await registry.hasClonePending(reusedPath)) {
      AppLogger.debug(
        '[DriveFolderSet] 既存の共有フォルダ実体を参照マウント: ${item.driveId} -> $reusedPath',
      );
      await DriveDirStore.instance.register(item.driveId, reusedPath);
      updatedMembers[item.driveId] = KMetaFolderSetMember(
        driveId: item.driveId,
        name: baseName,
        driveUrl: item.driveUrl,
        isReadOnly: isReadOnly,
        targetPath: reusedPath,
      );
      return (added: true, failedItemName: null);
    }

    // 新規クローン: `.kokage/drive_store/<driveId>/<folderName>` に実体を配置し、辞書と setMembers に登録
    final targetPath = reusedPath ??
        await DriveDirStore.instance.allocateStorePath(
          driveId: item.driveId,
          folderName: baseName,
          contextPath: rootSetPath,
        );

    registry.bindParentTransfer(targetPath, rootSetPath);
    bool ok = false;
    try {
      ok = await _syncEngine.cloneFromDrive(
        driveId: item.driveId,
        localPath: targetPath,
        folderName: baseName,
        driveUrl: item.driveUrl,
        isReadOnly: isReadOnly,
        preloadedFolderInfo: info,
        showOsNotification: showOsNotification,
      );
    } finally {
      registry.unbindParentTransfer(targetPath);
    }

    if (ok) {
      await DriveDirStore.instance.register(item.driveId, targetPath);
      updatedMembers[item.driveId] = KMetaFolderSetMember(
        driveId: item.driveId,
        name: baseName,
        driveUrl: item.driveUrl,
        isReadOnly: isReadOnly,
        targetPath: targetPath,
      );
      return (added: true, failedItemName: null);
    }
    return (added: false, failedItemName: info.name ?? item.driveId);
  }
}
