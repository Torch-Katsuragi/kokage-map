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

import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../utils/app_logger.dart';
import 'google_drive/sync_engine.dart';
import 'kmeta_service.dart';
import 'projects_home.dart';

export '../core/shared_link.dart';

/// 共有の地図を、いつもの地図の `共有/` に取り込む（取り込み済みならそのまま）。いつもの地図のパスを返す
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
  return root;
}
