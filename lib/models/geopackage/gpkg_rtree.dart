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
// こかげマップ: レイヤの空間索引（GeoPackage の rtree 拡張）のテーブル名を引く
//
// rtree の名前は `rtree_<表>_<形の列>`。形の列は QGIS なら geom だが、GDAL の GEOMETRY_NAME や
// GeoPandas（geometry）、PostGIS 由来（the_geom）などで違うので、決め打ちせず gpkg の表から読む。

import 'package:sqflite/sqflite.dart';

/// [table] の rtree テーブル名。rtree が無ければ null
///
/// 形の列の名前は
/// 1. `gpkg_extensions` の `gpkg_rtree_index`（仕様どおりに登録した gpkg はここに列名がある）
/// 2. 無ければ `gpkg_geometry_columns` の列名（拡張の登録を省いた gpkg もある）
///
/// から取り、実際に `rtree_<表>_<列>` のテーブルがあるときだけ返す。
/// 編集のたびに呼ぶので、rtree の無い gpkg（このアプリで作ったもの）は sqlite_master を 1 回見るだけで返す
Future<String?> gpkgRtreeTable(DatabaseExecutor db, String table) async {
  // LIKE の候補（大文字小文字を問わない）。表の名前の `_` `%` はそのままの文字として
  final escaped = table.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');
  final rtrees = {
    for (final r in await db.rawQuery(
      r"SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE ? ESCAPE '\'",
      ['rtree\\_$escaped\\_%'],
    ))
      (r['name'] as String).toLowerCase(): r['name'] as String,
  };
  if (rtrees.isEmpty) return null;

  Future<String?> match(String sql) async {
    try {
      for (final r in await db.rawQuery(sql, [table])) {
        final c = r['column_name'];
        if (c is! String || c.isEmpty) continue;
        final name = rtrees['rtree_${table}_$c'.toLowerCase()];
        if (name != null) return name;
      }
    } catch (_) {
      // 表が無い（gpkg_extensions を持たない gpkg など）
    }
    return null;
  }

  return await match(
        "SELECT column_name FROM gpkg_extensions WHERE extension_name = 'gpkg_rtree_index' AND table_name = ? COLLATE NOCASE",
      ) ??
      await match('SELECT column_name FROM gpkg_geometry_columns WHERE table_name = ? COLLATE NOCASE');
}
