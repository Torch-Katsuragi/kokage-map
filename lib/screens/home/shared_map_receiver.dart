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
/// Drive 共有リンク・共有フォルダセット・QR/URL 入力からの地図取り込み
library;

import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive show User;

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import '../../services/google_drive/drive_folder_set_service.dart';
import '../../services/google_drive/folder_lookup.dart';
import '../../services/google_drive/google_drive_service.dart';
import '../../services/shared_map_link.dart';
import '../../widgets/dialogs/drive_url_input_dialog.dart';

/// 起動中と起動後で同じ共有リンクが二度届くのを弾くゲート
class SharedLinkDeduplicator {
  String? _lastSharedLink;
  DateTime _lastSharedLinkAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 受け付けるならフォルダ/ファイル ID を返す（重複や不正 URL なら null）
  String? acceptAndExtractDriveId(String link) {
    final now = DateTime.now();
    if (link == _lastSharedLink && now.difference(_lastSharedLinkAt).inSeconds < 15) {
      return null;
    }
    _lastSharedLink = link;
    _lastSharedLinkAt = now;
    return GoogleDriveService.extractFolderIdFromUrl(link);
  }
}

/// Drive フォルダまたは共有フォルダセット JSON を、いつもの地図の `共有/` に取り込む（QR のリンク）
Future<String?> receiveSharedFromDriveId({
  required String driveId,
  required NotificationCenter notifications,
  required Future<bool> Function(String folderName, drive.User? owner) confirmReceive,
}) async {
  void notify(String title, NotificationLevel level, {String? detail}) {
    notifications.add(title: title, detail: detail, level: level);
  }

  final driveSvc = GoogleDriveService();
  // 起動直後は無音の復元が終わっていないことがある。先に無音で試し、だめなときだけサインインを出す
  if (!driveSvc.authState.isAuthenticated) await driveSvc.restoreSessionSilently();
  if (!driveSvc.authState.isAuthenticated && !await driveSvc.signIn()) {
    notify(
      driveSvc.authState.errorMessage ?? t.home.receiveNeedsSignIn,
      NotificationLevel.warning,
      detail: driveSvc.authState.errorDetail,
    );
    return null;
  }
  // 失敗は「圏外」「権限なし」「無い」で文言を分ける（圏外で共有設定を疑わせない）
  final lookup = await driveSvc.lookupFolder(driveId);
  final info = lookup.folder;
  if (info == null) {
    notify(
      lookup.message,
      lookup.failure == FolderLookupFailure.offline ? NotificationLevel.warning : NotificationLevel.error,
      detail: lookup.code,
    );
    return null;
  }
  if (GoogleDriveService.isJsonFileMetadata(info)) {
    DriveFolderSetManifest? manifest;
    try {
      manifest = await DriveFolderSetService().fetchManifest(
        driveId,
        fallbackName: info.name,
      );
    } catch (_) {
      notify(t.drive.invalidFolderSetJson, NotificationLevel.error);
      return null;
    }
    final setName = manifest.name ??
        (info.name?.replaceAll(
              RegExp(r'\.json$', caseSensitive: false),
              '',
            ) ??
            driveId);
    return receiveSharedFolderSetInBackground(
      jsonDriveId: driveId,
      setName: setName,
      driveUrl: 'https://drive.google.com/file/d/$driveId/view',
      preloadedManifest: manifest,
      confirm: () => confirmReceive(setName, info.owners?.firstOrNull),
      notifications: notifications,
    );
  }
  if (!GoogleDriveService.isFolderMetadata(info)) {
    notify(t.drive.invalidUrl, NotificationLevel.error);
    return null;
  }
  final name = info.name ?? driveId;
  return receiveSharedMapInBackground(
    driveId: driveId,
    folderName: name,
    driveUrl: 'https://drive.google.com/drive/folders/$driveId',
    isReadOnly: !(info.capabilities?.canEdit ?? false),
    // リンクは外から届くので、知らない人のフォルダを黙って取り込まない
    confirm: () => confirmReceive(name, info.owners?.firstOrNull),
    notifications: notifications,
  );
}

/// 共有リンクの地図を取り込むか聞く（フォルダ名と、取れれば持ち主）
Future<bool> showReceiveConfirmDialog(
  BuildContext context, {
  required String folderName,
  required drive.User? owner,
}) async {
  if (!context.mounted) return false;
  final ownerLabel = [owner?.displayName, if (owner?.emailAddress != null) '<${owner!.emailAddress}>']
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .join(' ');
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.home.receiveConfirmTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.home.receiveConfirmBody(name: folderName)),
          if (ownerLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(t.home.receiveConfirmOwner(owner: ownerLabel)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.home.receiveConfirmAction)),
      ],
    ),
  );
  return yes == true;
}

/// ホームの「QR で受け取る」: アプリのカメラで読む（Drive の URL を貼っても読める）
Future<void> promptAndReceiveSharedMap(
  BuildContext context, {
  required NotificationCenter notifications,
  required Future<void> Function(Future<String?> Function() receive) runReceiveAndOpen,
}) async {
  final result = await DriveUrlInputDialog.show(context);
  if (result == null || !context.mounted) return;
  if (result.isFolderSet) {
    await runReceiveAndOpen(() => receiveSharedFolderSetInBackground(
          jsonDriveId: result.folderId,
          setName: result.folderName,
          driveUrl: result.url,
          preloadedManifest: result.folderSetManifest,
          notifications: notifications,
        ));
    return;
  }
  await runReceiveAndOpen(() => receiveSharedMapInBackground(
        driveId: result.folderId,
        folderName: result.folderName,
        driveUrl: result.url,
        isReadOnly: result.isReadOnly,
        notifications: notifications,
      ));
}
