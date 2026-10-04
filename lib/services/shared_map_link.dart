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

import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../core/launch_request.dart';
import '../models/geopackage/geopackage_file.dart';
import '../utils/app_logger.dart';
import 'google_drive/sync_engine.dart';
import 'kmeta_service.dart';
import 'projects_home.dart';

export '../core/shared_link.dart';

/// 取り込んだ（または取り込み済みの）地図の範囲を見る位置。開いた地図がそこへ寄るように起動要求に置く
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

/// 共有の地図を、いつもの地図の `共有/` に取り込む（取り込み済みならそのまま）。いつもの地図のパスを返す。
/// 開いた地図はその地図のある場所へ寄る
Future<String> receiveSharedMap({
  required String driveId,
  required String folderName,
  required String driveUrl,
  required bool isReadOnly,
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
  final base = folderName.trim().isEmpty ? driveId : folderName.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  var localPath = p.join(sharedDir, base);
  for (var n = 2; await fs.exists(localPath); n++) {
    localPath = p.join(sharedDir, '$base $n');
  }
  final ok = await SyncEngine().cloneFromDrive(
    driveId: driveId,
    localPath: localPath,
    folderName: p.basename(localPath),
    driveUrl: driveUrl,
    isReadOnly: isReadOnly,
  );
  if (!ok) throw StateError('clone failed');
  await _focusOn(localPath);
  return root;
}
