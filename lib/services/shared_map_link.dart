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
// こかげマップ: QR で共有する地図のリンク（2026-10-03）
//
// QR の中身は `https://kokage-map.sleeptree.jp/open?drive=<Drive フォルダ ID>`。
// - アプリが入っていれば App Links でアプリが開き、いつもの地図の `共有/` に取り込んでそのまま開く
// - 入っていなければ同じ URL が web のページになり、テスター募集ページへ移る（製品版では Play へ）
// 前からの QR（Drive の URL そのもの）も読める。

import 'dart:async';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../core/fs/safe_path.dart';
import '../core/launch_request.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/geopackage/geopackage_file.dart';
import '../providers/notification_providers.dart';
import '../utils/app_logger.dart';
import 'google_drive/drive_folder_set_service.dart';
import 'google_drive/drive_transfer_registry.dart';
import 'google_drive/sync_engine.dart';
import 'kmeta_service.dart';
import 'projects_home.dart';

export '../core/shared_link.dart';

/// `共有/` フォルダ内の Drive 連携済みエントリ情報
class SharedMapEntry {
  final String driveId;
  final String folderName;
  final String driveUrl;
  final bool isReadOnly;
  final bool isFolderSet;
  final String? localPath;

  const SharedMapEntry({
    required this.driveId,
    required this.folderName,
    required this.driveUrl,
    required this.isReadOnly,
    this.isFolderSet = false,
    this.localPath,
  });

  Map<String, dynamic> toJson() => {
        'driveId': driveId,
        'folderName': folderName,
        'driveUrl': driveUrl,
        'isReadOnly': isReadOnly,
        if (isFolderSet) 'isFolderSet': true,
      };

  factory SharedMapEntry.fromJson(Map<String, dynamic> json) {
    final driveId = (json['driveId'] as String?) ?? '';
    return SharedMapEntry(
      driveId: driveId,
      folderName: (json['folderName'] as String?) ?? driveId,
      driveUrl: (json['driveUrl'] as String?) ??
          'https://drive.google.com/drive/folders/$driveId',
      isReadOnly: (json['isReadOnly'] as bool?) ?? false,
      isFolderSet: (json['isFolderSet'] as bool?) ?? false,
    );
  }
}

/// ローカルの `共有/` ディレクトリにある Drive 連携済みフォルダ一覧を返す
Future<List<SharedMapEntry>> listLocalSharedMaps() async {
  final root = await ProjectsHome.myMap();
  final sharedDir = p.join(root, ProjectsHome.sharedDirName);
  final out = <SharedMapEntry>[];
  if (!await fs.exists(sharedDir)) return out;
  for (final e in await fs.list(sharedDir)) {
    if (!e.isDirectory) continue;
    try {
      final sync = (await KMetaService.instance.getMeta(e.path)).sync;
      final id = sync.driveId;
      if (id == null || id.isEmpty) continue;
      out.add(SharedMapEntry(
        driveId: id,
        folderName: sync.driveFolderName ?? p.basename(e.path),
        driveUrl: sync.driveUrl ?? 'https://drive.google.com/drive/folders/$id',
        isReadOnly: sync.isReadOnly ?? false,
        isFolderSet: sync.isFolderSet ?? false,
        localPath: e.path,
      ));
    } catch (_) {}
  }
  return out;
}

/// 共有の地図がローカルの `共有/` にまだ無ければクローンする（カメラ移動はしない）。
/// 新規にクローンした場合はローカルパスを返し、既にあれば null を返す。
Future<String?> cloneSharedMapIfNeeded({
  required String driveId,
  required String folderName,
  required String driveUrl,
  required bool isReadOnly,
  bool isFolderSet = false,
}) =>
    DriveTransferRegistry.instance.runDeduplicatedClone(
      driveId,
      () => _cloneSharedMapIfNeededImpl(
        driveId: driveId,
        folderName: folderName,
        driveUrl: driveUrl,
        isReadOnly: isReadOnly,
        isFolderSet: isFolderSet,
      ),
    );

Future<String?> _cloneSharedMapIfNeededImpl({
  required String driveId,
  required String folderName,
  required String driveUrl,
  required bool isReadOnly,
  bool isFolderSet = false,
}) async {
  final existing = await listLocalSharedMaps();
  for (final item in existing) {
    if (item.driveId == driveId) {
      final path = item.localPath;
      if (path != null &&
          await DriveTransferRegistry.instance.hasClonePending(path)) {
        if (isFolderSet || item.isFolderSet) {
          final r = await DriveFolderSetService().reconcileSet(
            manifestFileId: driveId,
            localSetPath: path,
            showOsNotification: true,
          );
          if (!r.success) throw StateError(r.errorMessage ?? 'folder set sync failed');
          return path;
        }
        final r = await SyncEngine().pull(
          driveId,
          path,
          showOsNotification: true,
        );
        if (!r.success) throw StateError(r.errorMessage ?? 'clone failed');
        return path;
      }
      return null;
    }
  }
  final root = await ProjectsHome.myMap();
  final sharedDir = p.join(root, ProjectsHome.sharedDirName);
  final base = toLocalFolderName(folderName, fallback: driveId);
  var localPath = p.join(sharedDir, base);
  for (var n = 2; await fs.exists(localPath); n++) {
    localPath = p.join(sharedDir, '$base $n');
  }
  if (isFolderSet) {
    await fs.createDirectory(localPath);
    await DriveTransferRegistry.instance.markClonePending(localPath);
    await KMetaService.instance.setDriveSync(
      localPath,
      driveId: driveId,
      driveFolderName: p.basename(localPath),
      driveUrl: driveUrl,
      isReadOnly: true,
      isFolderSet: true,
    );
    final r = await DriveFolderSetService().reconcileSet(
      manifestFileId: driveId,
      localSetPath: localPath,
      showOsNotification: true,
    );
    if (!r.success) throw StateError(r.errorMessage ?? 'folder set sync failed');
    return localPath;
  }
  final ok = await SyncEngine().cloneFromDrive(
    driveId: driveId,
    localPath: localPath,
    folderName: p.basename(localPath),
    driveUrl: driveUrl,
    isReadOnly: isReadOnly,
    showOsNotification: true,
  );
  if (!ok) throw StateError('clone failed');
  return localPath;
}

/// 取り込んだ（または取り込み済みの）地図の範囲を見る位置。開いた地図がそこへ寄るように起動要求に置く
Future<void> focusOnSharedMap(String dir) => _focusOn(dir);

Future<void> _focusOn(String dir) async {
  double? minX, minY, maxX, maxY;
  for (final e in await fs.listRecursive(dir)) {
    if (e.isDirectory || !e.path.toLowerCase().endsWith('.gpkg')) continue;
    final g = GeoPackageFile([p.basename(e.path)], absolutePath: e.path);
    try {
      final db = await g.getDatabase();
      final rows = await db.rawQuery('SELECT min_x, min_y, max_x, max_y FROM gpkg_contents WHERE srs_id = 4326');
      for (final r in rows) {
        final x0 = (r['min_x'] as num?)?.toDouble(), y0 = (r['min_y'] as num?)?.toDouble();
        final x1 = (r['max_x'] as num?)?.toDouble(), y1 = (r['max_y'] as num?)?.toDouble();
        if (x0 == null || y0 == null || x1 == null || y1 == null) continue;
        minX = minX == null ? x0 : math.min(minX, x0);
        minY = minY == null ? y0 : math.min(minY, y0);
        maxX = maxX == null ? x1 : math.max(maxX, x1);
        maxY = maxY == null ? y1 : math.max(maxY, y1);
      }
    } catch (_) {
    } finally {
      await g.dispose();
    }
  }
  if (minX == null || minY == null || maxX == null || maxY == null) return;
  final span = math.max(maxX - minX, maxY - minY);
  final zoom = span <= 0 ? 16.0 : (math.log(360 / span) / math.ln2 + 0.5).clamp(8.0, 17.0);
  LaunchRequest.defer(LaunchRequest(lat: (minY + maxY) / 2, lon: (minX + maxX) / 2, zoom: zoom));
}

/// 共有の地図を、いつもの地図の `共有/` にバックグラウンドで取り込む準備をし、
/// ダウンロード完了を待たずにいつもの地図のルートパスを即座に返す。
///
/// - 既に取り込み済み（かつ未完了マーカーなし）なら即座にカメラ位置をセットして返す。
/// - 新規または未完了なら、`共有/<name>` と `.sync/clone.pending`・`.qgs` 連携情報を作成して即座に返し、
///   裏でダウンロードを進めて `NotificationCenter` と OS 通知に進捗→完了（「地図で見る」ボタン付き）を出す。
Future<String?> receiveSharedMapInBackground({
  required String driveId,
  required String folderName,
  required String driveUrl,
  required bool isReadOnly,
  Future<bool> Function()? confirm,
  NotificationCenter? notifications,
}) async {
  final root = await ProjectsHome.myMap();
  final sharedDir = p.join(root, ProjectsHome.sharedDirName);
  final registry = DriveTransferRegistry.instance;

  String? targetLocalPath;
  if (await fs.exists(sharedDir)) {
    for (final e in await fs.list(sharedDir)) {
      if (!e.isDirectory) continue;
      try {
        if ((await KMetaService.instance.getMeta(e.path)).sync.driveId == driveId) {
          if (registry.isBusy(e.path)) {
            return root;
          }
          if (!await registry.hasClonePending(e.path)) {
            AppLogger.debug('[SharedMap] 取り込み済み: ${e.path}');
            await _focusOn(e.path);
            return root;
          }
          targetLocalPath = e.path;
          break;
        }
      } catch (_) {}
    }
  }

  if (targetLocalPath == null) {
    if (confirm != null && !await confirm()) return null;
    final base = toLocalFolderName(folderName, fallback: driveId);
    var candidate = p.join(sharedDir, base);
    for (var n = 2; await fs.exists(candidate); n++) {
      candidate = p.join(sharedDir, '$base $n');
    }
    targetLocalPath = candidate;
    await fs.createDirectory(targetLocalPath);
    await registry.markClonePending(targetLocalPath);
    await KMetaService.instance.setDriveSync(
      targetLocalPath,
      driveId: driveId,
      driveFolderName: p.basename(targetLocalPath),
      driveUrl: driveUrl,
      isReadOnly: isReadOnly,
    );
  }

  final localPath = targetLocalPath;
  final displayFolderName = p.basename(localPath);
  final transferKey = DriveTransferRegistry.normalizeKey(localPath);

  registry.beginTransfer(
    localPath,
    folderName: displayFolderName,
    showOsNotification: true,
  );
  notifications?.startTransfer(
    transferKey: transferKey,
    title: t.drive.downloadingTitle(name: displayFolderName),
  );

  unawaited(
    registry.runDeduplicatedClone(driveId, () async {
      try {
        final result = await SyncEngine().pull(
          driveId,
          localPath,
          showOsNotification: true,
        );
        if (!result.success) {
          final errMsg = result.errorMessage ?? t.layerDrawer.cloneFailed;
          registry.endTransfer(
            localPath,
            driveId: driveId,
            folderName: displayFolderName,
            success: false,
            completionTitle: t.drive.downloadFailedTitle(name: displayFolderName),
            completionBody: errMsg,
            errorMessage: errMsg,
            showOsNotification: true,
          );
          notifications?.completeTransfer(
            transferKey: transferKey,
            title: t.drive.downloadFailedTitle(name: displayFolderName),
            detail: errMsg,
            level: NotificationLevel.error,
          );
          return null;
        }

        final doneTitle = t.drive.downloadCompleteTitle(name: displayFolderName);
        final doneDetail = t.drive.downloadCompleteDetail(
          count: result.downloadedCount.toString(),
        );
        registry.endTransfer(
          localPath,
          driveId: driveId,
          folderName: displayFolderName,
          success: true,
          completionTitle: doneTitle,
          completionBody: doneDetail,
          showOsNotification: true,
        );
        notifications?.completeTransfer(
          transferKey: transferKey,
          title: doneTitle,
          detail: doneDetail,
          level: NotificationLevel.success,
          actionLabel: t.drive.viewOnMap,
          onAction: () => _focusOn(localPath),
        );
        return localPath;
      } catch (e) {
        registry.endTransfer(
          localPath,
          driveId: driveId,
          folderName: displayFolderName,
          success: false,
          completionTitle: t.drive.downloadFailedTitle(name: displayFolderName),
          completionBody: '$e',
          errorMessage: '$e',
          showOsNotification: true,
        );
        notifications?.completeTransfer(
          transferKey: transferKey,
          title: t.drive.downloadFailedTitle(name: displayFolderName),
          detail: '$e',
          level: NotificationLevel.error,
        );
        return null;
      }
    }),
  );

  return root;
}

/// 共有フォルダセット（JSON）をいつもの地図の `共有/` にバックグラウンドで取り込む準備をし、
/// いつもの地図のルートパスを即座に返す。
/// 既に取り込み済みの場合も、最新のリストを再取得・差分同期する。
Future<String?> receiveSharedFolderSetInBackground({
  required String jsonDriveId,
  required String setName,
  required String driveUrl,
  DriveFolderSetManifest? preloadedManifest,
  Future<bool> Function()? confirm,
  NotificationCenter? notifications,
}) async {
  final root = await ProjectsHome.myMap();
  final sharedDir = p.join(root, ProjectsHome.sharedDirName);
  final registry = DriveTransferRegistry.instance;

  String? targetLocalPath;
  if (await fs.exists(sharedDir)) {
    for (final e in await fs.list(sharedDir)) {
      if (!e.isDirectory) continue;
      try {
        if ((await KMetaService.instance.getMeta(e.path)).sync.driveId == jsonDriveId) {
          if (registry.isBusy(e.path)) {
            return root;
          }
          targetLocalPath = e.path;
          break;
        }
      } catch (_) {}
    }
  }

  if (targetLocalPath == null) {
    if (confirm != null && !await confirm()) return null;
    final cleanName = setName.replaceAll(RegExp(r'\.json$', caseSensitive: false), '');
    final base = toLocalFolderName(cleanName, fallback: jsonDriveId);
    var candidate = p.join(sharedDir, base);
    for (var n = 2; await fs.exists(candidate); n++) {
      candidate = p.join(sharedDir, '$base $n');
    }
    targetLocalPath = candidate;
    await fs.createDirectory(targetLocalPath);
    await registry.markClonePending(targetLocalPath);
    await KMetaService.instance.setDriveSync(
      targetLocalPath,
      driveId: jsonDriveId,
      driveFolderName: p.basename(targetLocalPath),
      driveUrl: driveUrl,
      isReadOnly: true,
      isFolderSet: true,
    );
  }

  final localPath = targetLocalPath;
  final displayFolderName = p.basename(localPath);
  final transferKey = DriveTransferRegistry.normalizeKey(localPath);

  registry.beginTransfer(
    localPath,
    folderName: displayFolderName,
    showOsNotification: true,
  );
  notifications?.startTransfer(
    transferKey: transferKey,
    title: t.drive.downloadingTitle(name: displayFolderName),
  );

  unawaited(
    registry.runDeduplicatedClone(jsonDriveId, () async {
      try {
        final result = await DriveFolderSetService().reconcileSet(
          localSetPath: localPath,
          manifestFileId: jsonDriveId,
          preloadedManifest: preloadedManifest,
          showOsNotification: true,
        );
        if (!result.success) {
          final errMsg = result.errorMessage ?? t.layerDrawer.cloneFailed;
          registry.endTransfer(
            localPath,
            driveId: jsonDriveId,
            folderName: displayFolderName,
            success: false,
            completionTitle: t.drive.downloadFailedTitle(name: displayFolderName),
            completionBody: errMsg,
            errorMessage: errMsg,
            showOsNotification: true,
          );
          notifications?.completeTransfer(
            transferKey: transferKey,
            title: t.drive.downloadFailedTitle(name: displayFolderName),
            detail: errMsg,
            level: NotificationLevel.error,
          );
          return null;
        }

        final doneTitle = t.drive.downloadCompleteTitle(name: displayFolderName);
        final doneDetail = t.drive.folderSetUpdated(
          added: result.addedCount.toString(),
          removed: result.removedCount.toString(),
        );
        registry.endTransfer(
          localPath,
          driveId: jsonDriveId,
          folderName: displayFolderName,
          success: true,
          completionTitle: doneTitle,
          completionBody: doneDetail,
          showOsNotification: true,
        );
        notifications?.completeTransfer(
          transferKey: transferKey,
          title: doneTitle,
          detail: doneDetail,
          level: NotificationLevel.success,
          actionLabel: t.drive.viewOnMap,
          onAction: () => _focusOn(localPath),
        );
        if (result.keptWithLocalChanges.isNotEmpty) {
          notifications?.add(
            title: t.drive.folderSetKeptLocalChanges(
              names: result.keptWithLocalChanges.join('、'),
            ),
            level: NotificationLevel.warning,
          );
        }
        return localPath;
      } catch (e) {
        registry.endTransfer(
          localPath,
          driveId: jsonDriveId,
          folderName: displayFolderName,
          success: false,
          completionTitle: t.drive.downloadFailedTitle(name: displayFolderName),
          completionBody: '$e',
          errorMessage: '$e',
          showOsNotification: true,
        );
        notifications?.completeTransfer(
          transferKey: transferKey,
          title: t.drive.downloadFailedTitle(name: displayFolderName),
          detail: '$e',
          level: NotificationLevel.error,
        );
        return null;
      }
    }),
  );

  return root;
}

/// 共有の地図を、いつもの地図の `共有/` に取り込む（取り込み済みならそのまま）。いつもの地図のパスを返す。
/// 開いた地図はその地図のある場所へ寄る。
///
/// [confirm] は新しく取り込む前だけ聞く（取り込み済みなら聞かない）。false ならやめて null
Future<String?> receiveSharedMap({
  required String driveId,
  required String folderName,
  required String driveUrl,
  required bool isReadOnly,
  Future<bool> Function()? confirm,
}) async {
  final root = await ProjectsHome.myMap();
  final sharedDir = p.join(root, ProjectsHome.sharedDirName);
  // 取り込み済みか（同じ Drive フォルダと同期している子がいれば、それを使う）
  for (final e in await fs.list(sharedDir)) {
    if (!e.isDirectory) continue;
    try {
      if ((await KMetaService.instance.getMeta(e.path)).sync.driveId == driveId) {
        AppLogger.debug('[SharedMap] 取り込み済み: ${e.path}');
        await _focusOn(e.path);
        return root;
      }
    } catch (_) {}
  }
  if (confirm != null && !await confirm()) return null;
  final localPath = await cloneSharedMapIfNeeded(
    driveId: driveId,
    folderName: folderName,
    driveUrl: driveUrl,
    isReadOnly: isReadOnly,
  );
  if (localPath != null) {
    await _focusOn(localPath);
  }
  return root;
}
