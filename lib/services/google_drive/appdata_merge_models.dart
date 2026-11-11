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
/// `AppData/kmap` 端末間データ統合のモデル・3-wayマージ純粋関数・リモートJSON送受信ヘルパー
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/track_recording_settings.dart';
import '../../utils/app_logger.dart';
import '../basemap_service.dart';
import '../gps_history_recorder.dart';
import '../shared_map_link.dart';
import 'google_drive_service.dart';

/// 端末間統合の有効/無効設定キー（既定は false: オプトイン）
const String kAppDataSyncEnabledKey = 'appdata_sync_enabled';

/// 最終同期日時（ISO-8601）
const String kAppDataSyncLastSyncedKey = 'appdata_sync_last_synced';

/// 端末間で同期する SharedPreferences キーの Allowlist（端末固有のパスやUIスケール・レイアウトは除外）
const List<String> kAppDataPortableSettingKeys = [
  'track_recording_settings',
  'gnss_quality_gate',
  BaseMapService.customProvidersPrefsKey,
  'basemap_layers',
  'basemap_provider_id',
  'app_locale',
];

/// 1回の統合結果
class AppDataSyncResult {
  final bool success;
  final int importedGpsDays;
  final int exportedGpsDays;
  final int clonedSharedFolders;
  final bool updatedSettings;
  final String? errorMessage;

  const AppDataSyncResult({
    required this.success,
    this.importedGpsDays = 0,
    this.exportedGpsDays = 0,
    this.clonedSharedFolders = 0,
    this.updatedSettings = false,
    this.errorMessage,
  });
}

/// 設定の3-wayマージ（純粋関数）
///
/// - 初回同期（`base` が空）で `remote` が既に存在する場合:
///   既存のリモート設定を優先して取り込み、リモートに未設定でローカルにのみ存在するキーだけを追加アップロードする。
/// - 2回目以降:
///   - `local != base`: この端末で前回同期後に変更された → `local` を採用しリモートへ送る
///   - `remote != base`: 他端末で変更された → `remote` を採用しローカルへ反映する
({
  Map<String, Object?> merged,
  Map<String, Object?> toApplyLocally,
  bool shouldUpload,
}) mergeAppDataSettings3Way({
  required Map<String, Object?> local,
  required Map<String, Object?> base,
  required Map<String, Object?>? remote,
}) {
  if (remote == null) {
    return (
      merged: Map<String, Object?>.of(local),
      toApplyLocally: const {},
      shouldUpload: local.isNotEmpty,
    );
  }

  final merged = <String, Object?>{};
  final toApplyLocally = <String, Object?>{};
  var shouldUpload = false;
  final isInitialJoin = base.isEmpty && remote.isNotEmpty;

  for (final key in kAppDataPortableSettingKeys) {
    final l = local[key];
    final b = base[key];
    final r = remote[key];

    if (isInitialJoin) {
      if (r != null) {
        merged[key] = r;
        if (r != l) {
          toApplyLocally[key] = r;
        }
      } else if (l != null) {
        merged[key] = l;
        shouldUpload = true;
      }
      continue;
    }

    if (l != b) {
      // ローカルで変更あり
      if (l != null) merged[key] = l;
      if (l != r) shouldUpload = true;
    } else if (r != b) {
      // リモートで変更あり
      if (r != null) merged[key] = r;
      toApplyLocally[key] = r;
    } else {
      if (l != null) merged[key] = l;
    }
  }

  return (
    merged: merged,
    toApplyLocally: toApplyLocally,
    shouldUpload: shouldUpload,
  );
}

/// 共有フォルダURLリストの3-wayマージ（純粋関数）
///
/// - ローカルで新規追加（`in local && not in base`）→ `merged` に追加してアップロード
/// - ローカルで削除（`not in local && in base`）→ `merged` から外してアップロード（再クローンしない）
/// - リモートで新規追加（`in remote && not in base && not in local`）→ クローン対象（`toClone`）に追加
({
  Map<String, SharedMapEntry> merged,
  List<SharedMapEntry> toClone,
  bool shouldUpload,
}) mergeAppDataSharedFolders3Way({
  required Map<String, SharedMapEntry> local,
  required Set<String> baseIds,
  required Map<String, SharedMapEntry>? remote,
}) {
  if (remote == null) {
    return (
      merged: Map<String, SharedMapEntry>.of(local),
      toClone: const [],
      shouldUpload: local.isNotEmpty,
    );
  }

  final merged = Map<String, SharedMapEntry>.of(remote);
  final toClone = <SharedMapEntry>[];
  var shouldUpload = false;

  // 1. ローカルで新規追加されたフォルダ（または読み取り専用属性の変更）
  // ※ クローン時の同名衝突サフィックス（" 2" 等）によるピンポンを防ぐため folderName 差分では再アップロードしない
  for (final entry in local.values) {
    final id = entry.driveId;
    if (!remote.containsKey(id)) {
      if (!baseIds.contains(id)) {
        // この端末で新しく追加された共有フォルダ
        merged[id] = entry;
        shouldUpload = true;
      }
      // baseIds にあるのに remote に無い場合は、他端末でリストから外されたものなので再アップロードしない
    } else {
      final r = remote[id]!;
      if (r.isReadOnly != entry.isReadOnly) {
        merged[id] = SharedMapEntry(
          driveId: r.driveId,
          folderName: r.folderName,
          driveUrl: r.driveUrl,
          isReadOnly: entry.isReadOnly,
          isFolderSet: entry.isFolderSet,
        );
        shouldUpload = true;
      }
    }
  }

  // 2. この端末で削除されたフォルダ（base にあったが local に無い）
  for (final baseId in baseIds) {
    if (!local.containsKey(baseId) && merged.containsKey(baseId)) {
      merged.remove(baseId);
      shouldUpload = true;
    }
  }

  // 3. 他端末で追加され、この端末にまだ無いフォルダ
  for (final entry in merged.values) {
    if (!local.containsKey(entry.driveId) && !baseIds.contains(entry.driveId)) {
      toClone.add(entry);
    }
  }

  return (
    merged: merged,
    toClone: toClone,
    shouldUpload: shouldUpload,
  );
}

/// Drive 上の JSON ファイル（Map形式）をダウンロードしてデコードする。
///
/// - [remoteFile] が無い場合は `(ok: true, map: null)`
/// - [remoteFile] が存在するのにダウンロードまたは JSON 解析に失敗した場合は誤上書き防止のため `(ok: false, map: null)`
Future<({bool ok, Map<String, Object?>? map})> downloadAppDataJsonMap(
  GoogleDriveService driveService,
  drive.File? remoteFile, {
  required String fileLabel,
  required String logTag,
}) async {
  if (remoteFile?.id == null) {
    return (ok: true, map: null);
  }
  final bytes = await driveService.downloadBytes(remoteFile!.id!);
  if (bytes == null) {
    AppLogger.debug('$logTag $fileLabel のダウンロードに失敗したため同期をスキップ');
    return (ok: false, map: null);
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) {
      return (ok: true, map: Map<String, Object?>.from(decoded));
    }
    AppLogger.debug('$logTag $fileLabel の形式が不正なため同期をスキップ');
    return (ok: false, map: null);
  } catch (e) {
    AppLogger.debug('$logTag $fileLabel の解析失敗のため同期をスキップ: $e');
    return (ok: false, map: null);
  }
}

/// オブジェクトを整形済み JSON として Drive の [folderId] へアップロードする
Future<drive.File?> uploadAppDataPrettyJson(
  GoogleDriveService driveService, {
  required Object payload,
  required String fileName,
  required String folderId,
}) {
  final encoded = utf8.encode(
    const JsonEncoder.withIndent('  ').convert(payload),
  );
  return driveService.uploadBytes(
    Uint8List.fromList(encoded),
    fileName,
    folderId,
  );
}

/// リモート変更分の設定値をローカルの [SharedPreferences] および関連サービスへ適用する
Future<void> applyPortableSettingsLocally(
  SharedPreferences prefs,
  Map<String, Object?> toApplyLocally,
) async {
  for (final entry in toApplyLocally.entries) {
    final k = entry.key;
    final v = entry.value;
    if (v == null) {
      await prefs.remove(k);
    } else if (v is String) {
      await prefs.setString(k, v);
    } else if (v is int) {
      await prefs.setInt(k, v);
    } else if (v is double) {
      await prefs.setDouble(k, v);
    } else if (v is bool) {
      await prefs.setBool(k, v);
    }
  }

  if (toApplyLocally['track_recording_settings']
      case final String rawTrackJson) {
    try {
      GpsHistoryRecorder().filter.settings = TrackRecordingSettings.fromJson(
        jsonDecode(rawTrackJson) as Map,
      );
    } catch (_) {}
  }

  if (toApplyLocally.containsKey(BaseMapService.customProvidersPrefsKey) ||
      toApplyLocally.containsKey('basemap_layers') ||
      toApplyLocally.containsKey('basemap_provider_id')) {
    try {
      await BaseMapService().reloadSettingsFromPrefs();
    } catch (_) {}
  }
}
