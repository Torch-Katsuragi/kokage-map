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
/// Google Drive 共有URL解析と Drive ファイル種別（フォルダ・JSONマニフェスト）の判定ヘルパー
library;

import 'package:googleapis/drive/v3.dart' as drive;

import '../../core/shared_link.dart';
import '../../utils/app_logger.dart';
import 'drive_api_client.dart';

/// 共有URLからフォルダID（またはマニフェスト等のファイルID）を抽出
///
/// 対応形式:
/// - `https://kokage-map.sleeptree.jp/open?drive={id}`（こかげマップ共有リンク）
/// - `https://drive.google.com/drive/folders/{folderId}`
/// - `https://drive.google.com/drive/folders/{folderId}?usp=sharing`
/// - `https://drive.google.com/drive/u/0/folders/{folderId}`
/// - `https://drive.google.com/file/d/{fileId}/view`（JSONマニフェスト等のファイル共有URL）
/// - `https://drive.google.com/open?id={folderId}`
/// - `https://drive.google.com/folderview?id={folderId}`
String? extractDriveIdFromUrl(String url) {
  try {
    url = url.trim();
    AppLogger.debug('[GoogleDriveService] URL解析: $url');

    final uri = Uri.parse(url);

    // こかげマップの共有リンク（`https://kokage-map.sleeptree.jp/open?drive=<ID>`。2026-10-03 からの QR）
    final shared = driveIdFromSharedLink(url);
    if (shared != null) return shared;

    // drive.google.comドメインか確認
    if (uri.host != 'google.com' && !uri.host.endsWith('.google.com')) {
      AppLogger.debug('[GoogleDriveService] Google Driveドメインではない: ${uri.host}');
      return null;
    }

    final pathSegments = uri.pathSegments;
    AppLogger.debug('[GoogleDriveService] pathSegments: $pathSegments');

    // パターン1: /drive/folders/{folderId} または /drive/u/0/folders/{folderId}
    final foldersIndex = pathSegments.indexOf('folders');
    if (foldersIndex != -1 && foldersIndex + 1 < pathSegments.length) {
      final folderId = pathSegments[foldersIndex + 1];
      AppLogger.debug('[GoogleDriveService] フォルダID検出 (folders): $folderId');
      return isDriveId(folderId) ? folderId : null;
    }

    // パターン1b: /file/d/{fileId} または /file/u/0/d/{fileId}（JSONマニフェスト等のファイル共有URL）
    if (pathSegments.contains('file')) {
      final dIndex = pathSegments.indexOf('d');
      if (dIndex != -1 && dIndex + 1 < pathSegments.length) {
        final fileId = pathSegments[dIndex + 1];
        AppLogger.debug('[GoogleDriveService] ファイルID検出 (file/d): $fileId');
        return isDriveId(fileId) ? fileId : null;
      }
    }

    // パターン2: /open?id={folderId} または /folderview?id={folderId}
    final idParam = uri.queryParameters['id'];
    if (idParam != null && idParam.isNotEmpty) {
      AppLogger.debug('[GoogleDriveService] フォルダID検出 (id param): $idParam');
      return isDriveId(idParam) ? idParam : null;
    }

    AppLogger.debug('[GoogleDriveService] フォルダIDが見つからない');
    return null;
  } catch (e) {
    AppLogger.debug('[GoogleDriveService] URL解析エラー: $e');
    return null;
  }
}

/// Driveのメタデータがフォルダかどうか判定
bool isDriveFolderMetadata(drive.File file) =>
    (file.mimeType ?? '') == DriveApiClient.folderMime;

/// Driveのメタデータが共有フォルダセット用のJSONファイルかどうか判定
bool isDriveJsonFileMetadata(drive.File file) {
  final mime = (file.mimeType ?? '').toLowerCase();
  if (mime == DriveApiClient.folderMime) return false;
  if (mime == 'application/json') return true;
  final name = (file.name ?? '').toLowerCase();
  return name.endsWith('.json');
}
