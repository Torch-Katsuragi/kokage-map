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

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../utils/app_logger.dart';
import '../../utils/wkb_utils.dart';
import 'qgis_interop.dart';

/// 外から行を書き換えられた GeoPackage の索引を実データに合わせ直す。
///
/// geodiff の rebase は `rtree_*` と `gpkg_*` を触らない（docs/technical/drive-geodiff-sync.md）。
/// しかもこのアプリは書き込みのために rtree の ST_ トリガーを落としているので、rebase で入った行は
/// rtree に載らない。アプリの描画は rtree を使わないが、QGIS は使う（＝QGIS で行が消えて見える）。
/// `gpkg_contents` の範囲も rtree から出しているので、先に rtree を焼き直す。
abstract final class GpkgIndexRepair {
  /// rtree を持つ地物テーブルを全部焼き直し、範囲と件数を合わせる。焼き直したテーブル数を返す。
  static Future<int> rebuild(Database db) async {
    var rebuilt = 0;
    final columns = await db.rawQuery(
      'SELECT table_name, column_name FROM gpkg_geometry_columns',
    );
    for (final c in columns) {
      final table = c['table_name'] as String?;
      final geomCol = c['column_name'] as String?;
      if (table == null || geomCol == null) continue;
      final rtree = 'rtree_${table}_$geomCol';
      final exists = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [rtree],
      );
      if (exists.isEmpty) continue;

      final pk = await _primaryKey(db, table);
      if (pk == null) {
        AppLogger.debug('[GpkgIndexRepair] 主キーが分からないので飛ばす: $table');
        continue;
      }
      final rows = await db.rawQuery('SELECT "$pk" AS id, "$geomCol" AS geom FROM "$table"');
      await db.transaction((txn) async {
        await txn.execute('DELETE FROM "$rtree"');
        final batch = txn.batch();
        for (final r in rows) {
          final id = r['id'];
          final blob = r['geom'];
          if (id is! int || blob is! Uint8List) continue;
          final env = gpkgEnvelope(blob);
          if (env == null) continue;
          batch.rawInsert(
            'INSERT INTO "$rtree" (id, minx, maxx, miny, maxy) VALUES (?, ?, ?, ?, ?)',
            [id, env.minX, env.maxX, env.minY, env.maxY],
          );
        }
        await batch.commit(noResult: true);
      });
      rebuilt++;
    }
    // 範囲（rtree から出す）と gpkg_ogr_contents の件数
    await QgisInterop.syncAllLayers(db);
    return rebuilt;
  }

  /// [path] を開いて [rebuild] して閉じる。失敗しても投げない（-1 を返す）。
  static Future<int> rebuildFile(String path) async {
    Database? db;
    try {
      db = await openDatabase(path, singleInstance: false);
      return await rebuild(db);
    } catch (e) {
      AppLogger.debug('[GpkgIndexRepair] $path の焼き直しに失敗: $e');
      return -1;
    } finally {
      await db?.close();
    }
  }

  static Future<String?> _primaryKey(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info("$table")');
    for (final col in info) {
      if ((col['pk'] as int? ?? 0) > 0) return col['name'] as String?;
    }
    return null;
  }
}
