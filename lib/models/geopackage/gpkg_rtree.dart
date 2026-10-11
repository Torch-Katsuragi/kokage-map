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
/// 1. `gpkg_extensions` の `gpkg_rtree_index`（仕様どおりに登録した gpkg はここに列名がある）
/// 2. 無ければ `gpkg_geometry_columns` の列名（拡張の登録を省いた gpkg もある）
///
/// どちらも、実際に `rtree_<表>_<列>` のテーブルがあるときだけ返す
Future<String?> gpkgRtreeTable(DatabaseExecutor db, String table) async {
  final candidates = <String>[];
  Future<void> addColumns(String sql) async {
    try {
      for (final r in await db.rawQuery(sql, [table])) {
        final c = r['column_name'];
        if (c is String && c.isNotEmpty && !candidates.contains(c)) candidates.add(c);
      }
    } catch (_) {
      // 表が無い（gpkg_extensions を持たない gpkg など）
    }
  }

  await addColumns(
    "SELECT column_name FROM gpkg_extensions WHERE extension_name = 'gpkg_rtree_index' AND table_name = ? COLLATE NOCASE",
  );
  await addColumns('SELECT column_name FROM gpkg_geometry_columns WHERE table_name = ? COLLATE NOCASE');

  for (final c in candidates) {
    final name = 'rtree_${table}_$c';
    final found = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? COLLATE NOCASE",
      [name],
    );
    if (found.isNotEmpty) return found.first['name'] as String? ?? name;
  }
  return null;
}
