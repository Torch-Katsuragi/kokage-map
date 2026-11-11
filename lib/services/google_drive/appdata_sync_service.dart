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
/// Google Drive `AppData/kmap` を介した端末間データ統合サービス
///
/// 対象:
/// 1. `gps_history.gpkg`: 前日以前（`date < today`）の確定GPS軌跡の双方向統合
/// 2. `shared_folders.json`: `共有/` ディレクトリ内の Drive 連携フォルダ URL リストの均一化
/// 3. `settings.json`: 端末に依存しないユーザー設定（Allowlist）の同期
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform_capabilities.dart';
import '../../utils/app_logger.dart';
import '../gps_history_recorder.dart';
import '../shared_map_link.dart';
import 'appdata_merge_models.dart';
import 'auto_sync_service.dart';
import 'google_drive_service.dart';

export 'appdata_merge_models.dart'
    show kAppDataSyncEnabledKey, kAppDataSyncLastSyncedKey, AppDataSyncResult;

class AppDataSyncService extends ChangeNotifier {
  static final AppDataSyncService instance = AppDataSyncService._();
  AppDataSyncService._();

  static const String _logTag = '[AppDataSync]';

  // Drive 上のフォルダ・ファイル名
  static const String kRootFolderName = 'AppData';
  static const String kSubFolderName = 'kmap';
  static const String kGpsFileName = 'gps_history.gpkg';
  static const String kSharedFoldersFileName = 'shared_folders.json';
  static const String kSettingsFileName = 'settings.json';

  // ローカル帳簿キー（3-way マージの base 状態と前回チェック状態）
  static const String _kBaseSettingsKey = 'appdata_sync_base_settings';
  static const String _kBaseSharedIdsKey = 'appdata_sync_base_shared_ids';
  static const String _kLastSyncedEmailKey = 'appdata_sync_last_email';
  static const String _kRemoteGpsMd5Key = 'appdata_sync_remote_gps_md5';
  static const String _kLastGpsSyncDateKey = 'appdata_sync_last_gps_date';

  /// 端末間で同期する SharedPreferences キーの Allowlist（端末固有のパスやUIスケール・レイアウトは除外）
  static const List<String> portableSettingKeys = kAppDataPortableSettingKeys;

  Future<AppDataSyncResult>? _activeSyncFuture;
  bool get isSyncing => _activeSyncFuture != null;

  /// 設定の3-wayマージ（純粋関数）
  @visibleForTesting
  static ({
    Map<String, Object?> merged,
    Map<String, Object?> toApplyLocally,
    bool shouldUpload,
  }) mergeSettings3Way({
    required Map<String, Object?> local,
    required Map<String, Object?> base,
    required Map<String, Object?>? remote,
  }) =>
      mergeAppDataSettings3Way(local: local, base: base, remote: remote);

  /// 共有フォルダURLリストの3-wayマージ（純粋関数）
  @visibleForTesting
  static ({
    Map<String, SharedMapEntry> merged,
    List<SharedMapEntry> toClone,
    bool shouldUpload,
  }) mergeSharedFolders3Way({
    required Map<String, SharedMapEntry> local,
    required Set<String> baseIds,
    required Map<String, SharedMapEntry>? remote,
  }) =>
      mergeAppDataSharedFolders3Way(
        local: local,
        baseIds: baseIds,
        remote: remote,
      );

  /// オプトイン設定が有効かどうか
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kAppDataSyncEnabledKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAppDataSyncEnabledKey, value);
    notifyListeners();
  }

  Future<DateTime?> lastSyncedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kAppDataSyncLastSyncedKey);
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  /// 自動同期から呼ばれるエントリ（設定がONのときのみ実行）
  Future<AppDataSyncResult?> syncIfEnabled({
    Future<void> Function()? onSharedFoldersChanged,
  }) async {
    if (!await isEnabled()) return null;
    return syncNow(
      forceGpsCheck: false,
      onSharedFoldersChanged: onSharedFoldersChanged,
    );
  }

  /// 手動または自動での統合実行（実行中の場合は進行中の Future を共有して待つ）
  Future<AppDataSyncResult> syncNow({
    bool forceGpsCheck = true,
    Future<void> Function()? onSharedFoldersChanged,
  }) {
    if (_activeSyncFuture != null) {
      return _activeSyncFuture!;
    }
    final future = _performSync(
      forceGpsCheck: forceGpsCheck,
      onSharedFoldersChanged: onSharedFoldersChanged,
    );
    _activeSyncFuture = future;
    notifyListeners();
    future.whenComplete(() {
      _activeSyncFuture = null;
      notifyListeners();
    });
    return future;
  }

  Future<AppDataSyncResult> _performSync({
    required bool forceGpsCheck,
    Future<void> Function()? onSharedFoldersChanged,
  }) async {
    try {
      final driveService = GoogleDriveService();
      if (!driveService.isDriveApiAvailable) {
        await driveService.initialize();
        if (!driveService.isDriveApiAvailable) {
          await driveService.refreshToken();
        }
      }
      if (!driveService.isDriveApiAvailable) {
        return const AppDataSyncResult(
          success: false,
          errorMessage: 'Google Drive is not signed in',
        );
      }

      final prefs = await SharedPreferences.getInstance();
      await _resetBaseLedgerIfAccountSwitched(prefs, driveService);

      // 1. マイドライブ直下の AppData/kmap フォルダを取得または作成
      final kmapFolderId = await _resolveKmapFolderId(driveService);
      if (kmapFolderId == null) {
        return const AppDataSyncResult(
          success: false,
          errorMessage: 'Failed to resolve AppData/kmap folder on Drive',
        );
      }

      final files = await driveService.listFiles(kmapFolderId);
      final remoteByName = <String, drive.File>{
        for (final f in files) ?f.name: f,
      };

      // 2. 設定（settings.json）の同期
      final updatedSettings = await _syncSettings(
        driveService,
        prefs,
        kmapFolderId,
        remoteByName[kSettingsFileName],
      );

      // 3. 共有フォルダリスト（shared_folders.json）の同期
      var clonedFolders = 0;
      if (PlatformCapabilities.hasLocalFileSystem) {
        clonedFolders = await _syncSharedFolders(
          driveService,
          prefs,
          kmapFolderId,
          remoteByName[kSharedFoldersFileName],
        );
        if (clonedFolders > 0) {
          await (onSharedFoldersChanged ??
              AutoSyncService.instance.refreshSharedFolderTree)();
        }
      }

      // 4. 前日以前の GPS 履歴（gps_history.gpkg）の統合
      var importedDays = 0;
      var exportedDays = 0;
      if (PlatformCapabilities.hasLocalFileSystem &&
          GpsHistoryRecorder().isInitialized) {
        final gpsRes = await _syncGpsHistory(
          driveService,
          prefs,
          kmapFolderId,
          remoteByName[kGpsFileName],
          force: forceGpsCheck,
        );
        importedDays = gpsRes.importedDays;
        exportedDays = gpsRes.exportedDays;
      }

      await prefs.setString(
        kAppDataSyncLastSyncedKey,
        DateTime.now().toIso8601String(),
      );

      AppLogger.debug(
        '$_logTag 完了: GPS(import=$importedDays, export=$exportedDays), '
        '共有クローン=$clonedFolders, 設定更新=$updatedSettings',
      );

      return AppDataSyncResult(
        success: true,
        importedGpsDays: importedDays,
        exportedGpsDays: exportedDays,
        clonedSharedFolders: clonedFolders,
        updatedSettings: updatedSettings,
      );
    } catch (e) {
      AppLogger.debug('$_logTag エラー: $e');
      return AppDataSyncResult(
        success: false,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> _resetBaseLedgerIfAccountSwitched(
    SharedPreferences prefs,
    GoogleDriveService driveService,
  ) async {
    final currentEmail = driveService.authState.user?.email ?? '';
    final lastEmail = prefs.getString(_kLastSyncedEmailKey);
    if (currentEmail.isNotEmpty &&
        lastEmail != null &&
        lastEmail != currentEmail) {
      // アカウントが切り替わった場合は base 帳簿をリセット
      await prefs.remove(_kBaseSettingsKey);
      await prefs.remove(_kBaseSharedIdsKey);
      await prefs.remove(_kRemoteGpsMd5Key);
      await prefs.remove(_kLastGpsSyncDateKey);
    }
    if (currentEmail.isNotEmpty) {
      await prefs.setString(_kLastSyncedEmailKey, currentEmail);
    }
  }

  Future<String?> _resolveKmapFolderId(GoogleDriveService driveService) async {
    final appData =
        await driveService.getOrCreateSubFolder('root', kRootFolderName);
    final appDataId = appData?.id;
    if (appDataId == null || appDataId.isEmpty) return null;
    final kmap =
        await driveService.getOrCreateSubFolder(appDataId, kSubFolderName);
    return kmap?.id;
  }

  Future<bool> _syncSettings(
    GoogleDriveService driveService,
    SharedPreferences prefs,
    String folderId,
    drive.File? remoteFile,
  ) async {
    final localMap = <String, Object?>{
      for (final k in portableSettingKeys) k: ?prefs.get(k),
    };

    final baseRaw = prefs.getString(_kBaseSettingsKey);
    final baseMap = baseRaw != null
        ? Map<String, Object?>.from(jsonDecode(baseRaw) as Map)
        : <String, Object?>{};

    final downloaded = await downloadAppDataJsonMap(
      driveService,
      remoteFile,
      fileLabel: kSettingsFileName,
      logTag: _logTag,
    );
    if (!downloaded.ok) return false;

    final res = mergeSettings3Way(
      local: localMap,
      base: baseMap,
      remote: downloaded.map,
    );

    await applyPortableSettingsLocally(prefs, res.toApplyLocally);

    if (res.shouldUpload) {
      final uploaded = await uploadAppDataPrettyJson(
        driveService,
        payload: res.merged,
        fileName: kSettingsFileName,
        folderId: folderId,
      );
      if (uploaded == null) {
        AppLogger.debug('$_logTag settings.json のアップロードに失敗したため base 更新を保留');
        return res.toApplyLocally.isNotEmpty;
      }
    }

    await prefs.setString(_kBaseSettingsKey, jsonEncode(res.merged));
    return res.toApplyLocally.isNotEmpty;
  }

  Future<int> _syncSharedFolders(
    GoogleDriveService driveService,
    SharedPreferences prefs,
    String folderId,
    drive.File? remoteFile,
  ) async {
    final localList = await listLocalSharedMaps();
    final localMap = {for (final e in localList) e.driveId: e};
    final baseIds =
        (prefs.getStringList(_kBaseSharedIdsKey) ?? const <String>[]).toSet();

    final downloaded = await downloadAppDataJsonMap(
      driveService,
      remoteFile,
      fileLabel: kSharedFoldersFileName,
      logTag: _logTag,
    );
    if (!downloaded.ok) return 0;

    Map<String, SharedMapEntry>? remoteMap;
    if (downloaded.map != null) {
      final rawFolders = downloaded.map!['folders'];
      if (rawFolders is! List) {
        AppLogger.debug(
          '$_logTag shared_folders.json の形式が不正なため共有リスト同期をスキップ',
        );
        return 0;
      }
      try {
        remoteMap = {
          for (final item in rawFolders.whereType<Map<String, dynamic>>())
            if ((item['driveId'] as String?)?.isNotEmpty ?? false)
              item['driveId'] as String: SharedMapEntry.fromJson(item),
        };
      } catch (e) {
        AppLogger.debug(
          '$_logTag shared_folders.json の解析失敗のため共有リスト同期をスキップ: $e',
        );
        return 0;
      }
    }

    final res = mergeSharedFolders3Way(
      local: localMap,
      baseIds: baseIds,
      remote: remoteMap,
    );

    var cloned = 0;
    for (final entry in res.toClone) {
      try {
        final path = await cloneSharedMapIfNeeded(
          driveId: entry.driveId,
          folderName: entry.folderName,
          driveUrl: entry.driveUrl,
          isReadOnly: entry.isReadOnly,
          isFolderSet: entry.isFolderSet,
        );
        if (path != null) cloned++;
      } catch (e) {
        AppLogger.debug('$_logTag 共有フォルダのクローン失敗 (${entry.folderName}): $e');
      }
    }

    if (res.shouldUpload) {
      final uploaded = await uploadAppDataPrettyJson(
        driveService,
        payload: {
          'v': 1,
          'folders': [for (final e in res.merged.values) e.toJson()],
        },
        fileName: kSharedFoldersFileName,
        folderId: folderId,
      );
      if (uploaded == null) {
        AppLogger.debug('$_logTag shared_folders.json のアップロード失敗');
      }
    }

    // 実際にローカルに存在する共有フォルダの ID のみを base として保存する。
    // （クローンに失敗した ID を base に入れないことで、次回同期で「削除された」と誤判定されるのを防ぐ）
    final updatedLocal = await listLocalSharedMaps();
    await prefs.setStringList(
      _kBaseSharedIdsKey,
      updatedLocal.map((e) => e.driveId).toSet().toList(),
    );

    return cloned;
  }

  Future<({int importedDays, int exportedDays})> _syncGpsHistory(
    GoogleDriveService driveService,
    SharedPreferences prefs,
    String folderId,
    drive.File? remoteFile, {
    required bool force,
  }) async {
    final todayKey = GpsHistoryRecorder.dateKey(DateTime.now());
    final lastDate = prefs.getString(_kLastGpsSyncDateKey);
    final lastMd5 = prefs.getString(_kRemoteGpsMd5Key);

    // 自動同期時: リモートの md5 が前回と同じ、かつ今日も既に過去日チェック済みなら転送ゼロでスキップ
    if (!force &&
        remoteFile != null &&
        remoteFile.md5Checksum != null &&
        remoteFile.md5Checksum == lastMd5 &&
        lastDate == todayKey) {
      return (importedDays: 0, exportedDays: 0);
    }

    final tempDir =
        await Directory.systemTemp.createTemp('kokage_appdata_gps_');
    final tempPath = p.join(tempDir.path, kGpsFileName);
    try {
      if (remoteFile?.id != null) {
        final ok = await driveService.downloadFile(remoteFile!.id!, tempPath);
        if (!ok) {
          AppLogger.debug('$_logTag リモート gps_history.gpkg のダウンロード失敗');
          return (importedDays: 0, exportedDays: 0);
        }
      }

      final mergeRes = await GpsHistoryRecorder().mergePastDaysWith(tempPath);

      if (mergeRes.changedRemote && await File(tempPath).exists()) {
        final uploaded = await driveService.uploadFileById(
          tempPath,
          folderId,
          existingFileId: remoteFile?.id,
        );
        if (uploaded?.md5Checksum != null) {
          await prefs.setString(_kRemoteGpsMd5Key, uploaded!.md5Checksum!);
        }
      } else if (remoteFile?.md5Checksum != null) {
        await prefs.setString(_kRemoteGpsMd5Key, remoteFile!.md5Checksum!);
      }

      await prefs.setString(_kLastGpsSyncDateKey, todayKey);
      return (
        importedDays: mergeRes.importedDays,
        exportedDays: mergeRes.exportedDays,
      );
    } finally {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
}
