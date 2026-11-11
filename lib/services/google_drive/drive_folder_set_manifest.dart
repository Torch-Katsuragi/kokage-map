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
/// Drive上の共有フォルダセット JSON マニフェストのモデル・パーサ・同期結果モデル
library;

import 'dart:convert';

import '../../core/shared_link.dart';
import 'drive_url_parser.dart';

/// JSONマニフェスト内の1フォルダ（または子セット）項目
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
      final folderCandidate = decoded['folders'] ??
          decoded['dirs'] ??
          decoded['urls'] ??
          decoded['items'];

      if (presetCandidate != null && presetCandidate is! List) {
        throw const FormatException(
          '"presets" (or "sets"/"children") must be an array',
        );
      }
      if (folderCandidate != null && folderCandidate is! List) {
        throw const FormatException(
          '"folders" (or "dirs"/"urls"/"items") must be an array',
        );
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

    final effectiveName = setName ?? stripJsonExtension(fallbackName);
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
      final id = extractDriveIdFromUrl(trimmed) ??
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
      final id = extractDriveIdFromUrl(rawUrl) ??
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

  /// ファイル名末尾の `.json`（大文字小文字不問）を取り除く
  static String? stripJsonExtension(String? name) {
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
