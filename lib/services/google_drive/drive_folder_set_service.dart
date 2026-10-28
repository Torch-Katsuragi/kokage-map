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
  ///   "folders": [
  ///     "https://drive.google.com/drive/folders/...",
  ///     { "url": "https://drive.google.com/drive/folders/...", "readOnly": true }
  ///   ]
  /// }
  /// ```
  /// （リストのキー名は `folders` / `dirs` / `urls` / `items` のいずれでも可）
  ///
  /// 2. 配列直書き形式:
  /// ```json
  /// [
  ///   "https://drive.google.com/drive/folders/...",
  ///   { "url": "https://drive.google.com/drive/folders/...", "readOnly": true }
  /// ]
  /// ```
  static DriveFolderSetManifest parse(String jsonText, {String? fallbackName}) {
    final dynamic decoded = jsonDecode(jsonText);
    String? setName;
    List<dynamic>? rawList;

    if (decoded is List) {
      rawList = decoded;
    } else if (decoded is Map) {
      final rawName = decoded['name'] ?? decoded['title'];
      if (rawName is String && rawName.trim().isNotEmpty) {
        setName = rawName.trim();
      }
      final listCandidate =
          decoded['folders'] ?? decoded['dirs'] ?? decoded['urls'] ?? decoded['items'];
      if (listCandidate is List) {
        rawList = listCandidate;
      } else {
        throw const FormatException('JSON must contain a "folders" (or "dirs"/"urls") array');
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
      final rawUrl = (entry['url'] ?? entry['driveUrl'] ?? entry['driveId'] ?? entry['id'])
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
  final String? errorMessage;

  const FolderSetSyncResult({
    required this.success,
    this.addedCount = 0,
    this.removedCount = 0,
    this.keptWithLocalChanges = const [],
    this.failedItems = const [],
    this.errorMessage,
  });

  bool get changedLocal => addedCount > 0 || removedCount > 0;
}

/// Drive共有フォルダセットの取得・差分調整サービス
class DriveFolderSetService {
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
  /// - JSONに新しく入ったDriveフォルダは `localSetPath` 直下へクローン
  /// - JSONから消えたDriveフォルダは、同期済み（`synced` またはローカル変更ゼロの `remoteChanges`）と確認できた場合のみ削除し、
  ///   未送信の変更がある場合やオフライン/権限喪失で確認できない場合は削除せず [FolderSetSyncResult.keptWithLocalChanges] に返す
  Future<FolderSetSyncResult> reconcileSet({
    required String manifestFileId,
    required String localSetPath,
    DriveFolderSetNode? setNode,
    DriveFolderSetManifest? preloadedManifest,
    bool showOsNotification = false,
  }) {
    final key = DriveTransferRegistry.normalizeKey(localSetPath);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _reconcileSetImpl(
      manifestFileId: manifestFileId,
      localSetPath: localSetPath,
      setNode: setNode,
      preloadedManifest: preloadedManifest,
      showOsNotification: showOsNotification,
    );
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  Future<FolderSetSyncResult> _reconcileSetImpl({
    required String manifestFileId,
    required String localSetPath,
    DriveFolderSetNode? setNode,
    DriveFolderSetManifest? preloadedManifest,
    bool showOsNotification = false,
  }) async {
    final registry = DriveTransferRegistry.instance;
    final effectiveSetNode =
        setNode ?? AutoSyncService.instance.findFolderSetByPath(localSetPath);
    try {
      final fileMeta = await _driveService.lookupFolder(manifestFileId);
      final remoteMd5 = fileMeta.folder?.md5Checksum;

      await fs.createDirectory(localSetPath);

      // 現在の直下サブフォルダの Drive 連携状態を集める
      final existingByDriveId = <String, String>{};
      final existingNameByPath = <String, String>{};
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
          }
        } catch (_) {}
      }

      // 自動同期等で preloadedManifest が無く、かつ JSON の MD5 が前回から変わっておらず、
      // 未完了クローンのマーカーも無ければ JSON 本体ダウンロードを省略できる
      if (preloadedManifest == null &&
          remoteMd5 != null &&
          !anySubfolderPending &&
          !await registry.hasClonePending(localSetPath)) {
        final currentSetMeta = await KMetaService.instance.getMeta(localSetPath);
        if (currentSetMeta.sync.driveRevisionId == remoteMd5 &&
            existingByDriveId.isNotEmpty) {
          if (effectiveSetNode != null) {
            effectiveSetNode.syncStatus = SyncStatus.synced;
          }
          return const FolderSetSyncResult(success: true);
        }
      }

      final manifest = preloadedManifest ??
          await fetchManifest(
            manifestFileId,
            fallbackName: fileMeta.folder?.name ?? p.basename(localSetPath),
          );

      final desiredById = {
        for (final item in manifest.items) item.driveId: item,
      };

      var addedCount = 0;
      var removedCount = 0;
      final keptWithLocalChanges = <String>[];
      final failedItems = <String>[];

      // JSONにパース不能な項目が混じっている場合や、既存フォルダがあるのにJSONが空配列になった場合は
      // 記載ミスによる全消去事故を防ぐため削除フェーズをスキップする
      final allowDeletion = manifest.invalidEntryCount == 0 &&
          (manifest.items.isNotEmpty || existingByDriveId.isEmpty);

      // 1. JSONから外れたフォルダを検査・削除
      if (allowDeletion) {
        for (final MapEntry(key: driveId, value: subPath) in existingByDriveId.entries) {
          if (desiredById.containsKey(driveId)) continue;
          if (registry.isBusy(subPath)) continue;

          final folderName = existingNameByPath[subPath] ?? p.basename(subPath);

          // 許可リスト方式: 未完了クローン、または Drive と照合してローカル変更が 0 件と確認できた場合のみ削除可能
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

      // 2. JSONにあるフォルダを追加・設定更新
      for (final item in manifest.items) {
        final existingPath = existingByDriveId[item.driveId];
        if (existingPath != null) {
          if (registry.isBusy(existingPath)) continue;

          // 既にローカルにある場合: 未完了クローンなら再開
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
          if (item.readOnly) {
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

        // 新規フォルダを Drive からクローン
        final lookup = await _driveService.lookupFolder(item.driveId);
        final info = lookup.folder;
        if (info == null || !GoogleDriveService.isFolderMetadata(info)) {
          AppLogger.debug('[DriveFolderSet] 対象フォルダが見つからないかフォルダではありません: ${item.driveId}');
          failedItems.add(info?.name ?? item.driveId);
          continue;
        }

        final baseName = toLocalFolderName(info.name ?? item.driveId, fallback: item.driveId);
        var childPath = p.join(localSetPath, baseName);
        for (var n = 2; await fs.exists(childPath); n++) {
          childPath = p.join(localSetPath, '$baseName $n');
        }
        final isReadOnly = item.readOnly || !(info.capabilities?.canEdit ?? false);

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

  /// [setNode] 配下の子ノードを再帰的に読み込み、各子 [DriveFolderNode] の `.qgs` を読み戻す
  static Future<void> reloadFolderSetNode(DriveFolderSetNode setNode) async {
    await _reloadRecursive(setNode);
    for (final child in setNode.children.whereType<DriveFolderNode>()) {
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

  static Future<void> _reloadRecursive(LayerTreeNode node) async {
    await node.updateChildren();
    for (final child in node.children) {
      if (child is FolderNode || child is GeoPackageNode) {
        await _reloadRecursive(child);
      }
    }
  }
}
