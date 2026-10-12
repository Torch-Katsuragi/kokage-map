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
// こかげマップ: rtree 拡張（gpkg_rtree_index）のトリガーが丸ごと消えた表を見つけ、規格のトリガーを組む
//
// 以前の版は Android で書く前に GDAL の rtree トリガーを落とし、戻さないまま Drive へ上げることがあった
// （2026-10-12 に GeoPackageFile.prepareForHandOff で塞いだ）。そうして上がったファイルは
// gpkg_extensions に rtree が登録され rtree の表もあるのに、トリガーが 1 つも無く、
// QGIS/GDAL の空間検索から行が漏れる。控え（逐語の定義）はもう無いので、規格どおりに作り直す。

import 'package:sqflite/sqflite.dart';

import 'sql_identifier.dart';

/// rtree が登録されているのにトリガーが 1 つも無い表
class RtreeTriggerGap {
  const RtreeTriggerGap({required this.table, required this.geomColumn, required this.rtree, required this.pk});

  final String table;
  final String geomColumn;

  /// rtree の表の名前（sqlite_master にある綴り）
  final String rtree;

  /// 整数の主キーの列（GDAL の FID）
  final String pk;

  /// 作り直すトリガー（名前 → CREATE TRIGGER 文）
  Map<String, String> get triggers => GpkgRtreeTriggers.standard(table: table, geomColumn: geomColumn, pk: pk);
}

abstract final class GpkgRtreeTriggers {
  /// GeoPackage 1.4 の rtree 拡張（Annex F.3）のトリガーを、GDAL 3.13（QGIS 4.2）が書くのと同じ文字列で組む。
  ///
  /// 並びも GDAL と同じ（insert, update6, update7, update2, update5, update4, delete）。
  /// GeoPackage 1.3 までの update1・update3 は、1.4 で update6・update7 に置き換わった（古い GDAL の gpkg は前者）。
  /// 文字列は GDAL 3.13.3（QGIS 4.2.2 同梱）の ogr2ogr で作った gpkg の sqlite_master と同じ
  /// （test/gpkg_rtree_triggers_test.dart で突き合わせる）。
  /// 名前の囲みは GDAL の SQLEscapeName と同じく `"` を重ねる
  static Map<String, String> standard({required String table, required String geomColumn, required String pk}) {
    final rtree = 'rtree_${table}_$geomColumn';
    final r = quoteIdent(rtree);
    final t = quoteIdent(table);
    final c = quoteIdent(geomColumn);
    final i = quoteIdent(pk);
    String name(String suffix) => '${rtree}_$suffix';
    String head(String suffix) => 'CREATE TRIGGER ${quoteIdent(name(suffix))}';
    final values = 'VALUES (NEW.$i,ST_MinX(NEW.$c), ST_MaxX(NEW.$c),ST_MinY(NEW.$c), ST_MaxY(NEW.$c))';
    return {
      name('insert'): '${head('insert')} AFTER INSERT ON $t WHEN (new.$c NOT NULL AND NOT ST_IsEmpty(NEW.$c)) '
          'BEGIN INSERT OR REPLACE INTO $r $values; END',
      name('update6'): '${head('update6')} AFTER UPDATE OF $c ON $t WHEN OLD.$i = NEW.$i AND '
          '(NEW.$c NOTNULL AND NOT ST_IsEmpty(NEW.$c)) AND (OLD.$c NOTNULL AND NOT ST_IsEmpty(OLD.$c)) '
          'BEGIN UPDATE $r SET minx = ST_MinX(NEW.$c), maxx = ST_MaxX(NEW.$c),'
          'miny = ST_MinY(NEW.$c), maxy = ST_MaxY(NEW.$c) WHERE id = NEW.$i;END',
      name('update7'): '${head('update7')} AFTER UPDATE OF $c ON $t WHEN OLD.$i = NEW.$i AND '
          '(NEW.$c NOTNULL AND NOT ST_IsEmpty(NEW.$c)) AND (OLD.$c ISNULL OR ST_IsEmpty(OLD.$c)) '
          'BEGIN INSERT INTO $r $values; END',
      name('update2'): '${head('update2')} AFTER UPDATE OF $c ON $t WHEN OLD.$i = NEW.$i AND '
          '(NEW.$c ISNULL OR ST_IsEmpty(NEW.$c)) BEGIN DELETE FROM $r WHERE id = OLD.$i; END',
      name('update5'): '${head('update5')} AFTER UPDATE ON $t WHEN OLD.$i != NEW.$i AND '
          '(NEW.$c NOTNULL AND NOT ST_IsEmpty(NEW.$c)) BEGIN DELETE FROM $r WHERE id = OLD.$i; '
          'INSERT OR REPLACE INTO $r $values; END',
      name('update4'): '${head('update4')} AFTER UPDATE ON $t WHEN OLD.$i != NEW.$i AND '
          '(NEW.$c ISNULL OR ST_IsEmpty(NEW.$c)) BEGIN DELETE FROM $r WHERE id IN (OLD.$i, NEW.$i); END',
      name('delete'): '${head('delete')} AFTER DELETE ON $t WHEN old.$c NOT NULL '
          'BEGIN DELETE FROM $r WHERE id = OLD.$i; END',
    };
  }

  /// rtree が `gpkg_extensions` に `gpkg_rtree_index` で登録され、rtree の表もあるのに、
  /// その rtree のトリガー（`rtree_<表>_<列>_*`）が 1 つも無い表。読むだけ。
  ///
  /// 一部だけ残っている表は対象にしない（どの版の GDAL の組か分からない）。登録の無い表・
  /// rtree の表が無い表・整数の主キーが無い表も対象にしない
  static Future<List<RtreeTriggerGap>> findMissing(DatabaseExecutor db) async {
    final master = await db.rawQuery("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE type IN ('table', 'trigger')");
    final tables = <String, String>{}; // 小文字 → 綴り
    final rtrees = <String, String>{}; // 小文字 → 綴り（rtree の仮想表だけ）
    final triggers = <String>[]; // 小文字
    for (final m in master) {
      final name = m['name'] as String?;
      if (name == null) continue;
      if (m['type'] == 'trigger') {
        triggers.add(name.toLowerCase());
      } else {
        tables[name.toLowerCase()] = name;
        final sql = (m['sql'] as String? ?? '').toLowerCase();
        if (sql.startsWith('create virtual table') && RegExp(r'using\s+rtree\s*\(').hasMatch(sql)) {
          rtrees[name.toLowerCase()] = name;
        }
      }
    }
    if (!tables.containsKey('gpkg_extensions')) return const [];

    final gaps = <RtreeTriggerGap>[];
    final registered = await db.rawQuery(
      "SELECT table_name, column_name FROM gpkg_extensions WHERE lower(extension_name) = 'gpkg_rtree_index'",
    );
    for (final e in registered) {
      final t = e['table_name'], c = e['column_name'];
      if (t is! String || c is! String || t.isEmpty || c.isEmpty) continue;
      final table = tables[t.toLowerCase()];
      if (table == null) continue;
      final rtree = rtrees['rtree_${t}_$c'.toLowerCase()];
      if (rtree == null) continue;
      final prefix = '${rtree}_'.toLowerCase();
      if (triggers.any((n) => n.startsWith(prefix))) continue;
      final pk = await _integerPrimaryKey(db, table);
      if (pk == null) continue;
      // GDAL は rtree の名前を表と列の綴りから組む。登録の綴りが違っても実在の綴りに合わせる
      final geomColumn = rtree.substring('rtree_'.length + table.length + 1);
      gaps.add(RtreeTriggerGap(table: table, geomColumn: geomColumn, rtree: rtree, pk: pk));
    }
    return gaps;
  }

  /// 単独の INTEGER PRIMARY KEY（rowid の別名）の列。無ければ null
  static Future<String?> _integerPrimaryKey(DatabaseExecutor db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info(${quoteIdent(table)})');
    final pks = [for (final c in info) if ((c['pk'] as int? ?? 0) > 0) c];
    if (pks.length != 1) return null;
    if ((pks.single['type'] as String? ?? '').toUpperCase() != 'INTEGER') return null;
    return pks.single['name'] as String?;
  }
}
