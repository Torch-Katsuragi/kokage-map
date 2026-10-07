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
// こかげマップ: 「地図を開く」で開くいつもの地図（置き場所 `Documents/KokageMap` そのもの）
//
// スマホが苦手な人は何も考えずにここだけを開き、地図にメモをし、たまに事務員から QR で現場の地図を
// 受け取る（2026-10-03 の想定）。中身の形は決めてある:
//
//   KokageMap/
//   ├─ KokageMap.qgs        フォルダの設定（PC の QGIS でもこれで開ける）
//   ├─ マイ地図.gpkg         書き込み先。点・線・面のレイヤを最初から作っておく
//   ├─ 共有/                QR で受け取った地図（Drive と同期）
//   └─ .kokage/             アプリ用（Global・練習用。地図に出さない）
//
// 置き場所の外のフォルダも「ほかの場所を開く」で開ける。

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/fs/k_file_system.dart';
import '../models/geometry_type.dart';
import '../models/geopackage/geopackage_file.dart';
import '../utils/app_logger.dart';
import 'global_folder_locator.dart';

class ProjectsHome {
  ProjectsHome._();

  // 名前は端末の言語に依らず固定（Drive で共有しても、どの端末でも同じ形になるように）
  static const myMapName = 'マイ地図.gpkg';
  static const sharedDirName = '共有';
  static const myMapLayers = {'点': GeometryType.point, '線': GeometryType.linestring, '面': GeometryType.polygon};

  static const _lastKey = 'last_project_dir';

  /// いつもの地図のフォルダ（中身をそろえてから返す）
  static Future<String> myMap() async {
    final root = await GlobalFolderLocator.kokageRoot();
    // 写真は決めた入れ先を作らない（取り込みはレイヤ一覧で開いている場所に入る。ほかのフォルダと同じ決まり）
    // createDirectory は親ごと作り、在れば何もしない（置き場所と 共有/ を 1 回で）
    await fs.createDirectory(p.join(root, sharedDirName));
    final gpkgPath = p.join(root, myMapName);
    if (!await fs.exists(gpkgPath)) {
      final gpkg = GeoPackageFile([myMapName], absolutePath: gpkgPath);
      try {
        if (await gpkg.createEmptyDatabase()) {
          for (final e in myMapLayers.entries) {
            await gpkg.addLayer(e.key, e.value);
            await gpkg.addAttributeColumns(e.key, {'name': 'TEXT', 'メモ': 'TEXT'});
          }
        }
      } catch (e) {
        AppLogger.debug('[ProjectsHome] マイ地図を作れない: $e');
      } finally {
        await gpkg.dispose();
      }
    }
    return root;
  }

  /// いつもの地図か（受け取った地図の入れ先を決めるのに使う）
  static Future<bool> isMyMap(String dir) async =>
      p.equals(p.normalize(dir), p.normalize(await GlobalFolderLocator.kokageRoot()));

  /// 最後に開いたフォルダを覚える（練習用は覚えない）
  static Future<void> remember(String path) async {
    if (p.split(path).contains(GlobalFolderLocator.systemDirName)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastKey, path);
  }

  /// 最後に開いたフォルダ。消えていれば null
  static Future<String?> last() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_lastKey);
    if (path == null || !await fs.exists(path)) return null;
    return path;
  }
}
