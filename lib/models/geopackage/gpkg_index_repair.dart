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

import '../../services/geodiff/geodiff.dart';
import '../../utils/app_logger.dart';
import '../../utils/wkb_utils.dart';

/// 外から行を書き換えられた GeoPackage の索引を実データに合わせ直す。
///
/// geodiff の rebase は `rtree_*` と `gpkg_*` を触らない（docs/technical/drive-geodiff-sync.md）。
/// しかもこのアプリは書き込みのために rtree の ST_ トリガーを落としているので、rebase で入った行は
/// rtree に載らない。アプリの描画は rtree を使わないが、QGIS は使う（＝QGIS で行が消えて見える）。
///
/// ⚠ **Android 本体の SQLite（sqflite が使う）には rtree モジュールが無い**（2026-09-24 Pixel 9 で確認:
/// `no such module: rtree`）。行と範囲は sqflite で読み、rtree への書き込みは、rtree を持っている
/// geodiff の SQLite（libgeodiff.so に静的リンク）で行う。範囲も rtree からは読まず、ここで出した値を書く。
abstract final class GpkgIndexRepair {
  /// [path] の rtree を焼き直し、範囲と件数を合わせる。焼き直したテーブル数を返す（失敗は -1、投げない）。
  ///
  /// 呼ぶ前にアプリの接続を閉じておくこと（`GeoPackageConnection.closeAllFor`）。
  /// Android では別の SQLite で書くので、同じファイルを開いたままにしない。
  static Future<int> rebuildFile(String path) async {
    final _Plan plan;
    try {
      final db = await openDatabase(path, singleInstance: false);
      try {
        plan = await _plan(db);
      } finally {
        await db.close();
      }
    } catch (e) {
      AppLogger.debug('[GpkgIndexRepair] $path を読めない: $e');
      return -1;
    }
    if (plan.isEmpty) return 0;

    // まずアプリの SQLite で（rtree があれば）。無ければ geodiff の SQLite で
    Database? db;
    try {
      db = await openDatabase(path, singleInstance: false);
      await db.transaction((txn) async {
        for (final sql in plan.statements) {
          await txn.execute(sql);
        }
      });
      return plan.tables;
    } on DatabaseException catch (e) {
      if (!'$e'.contains('no such module: rtree')) {
        AppLogger.debug('[GpkgIndexRepair] $path の焼き直しに失敗: $e');
        return -1;
      }
    } catch (e) {
      AppLogger.debug('[GpkgIndexRepair] $path の焼き直しに失敗: $e');
      return -1;
    } finally {
      await db?.close();
    }

    if (!Geodiff.isSupported) return -1;
    final g = Geodiff();
    try {
      final err = g.execSql(path, 'BEGIN;\n${plan.statements.join(';\n')};\nCOMMIT;');
      if (err != null) {
        AppLogger.debug('[GpkgIndexRepair] geodiff の SQLite でも失敗: $err');
        return -1;
      }
      AppLogger.debug('[GpkgIndexRepair] rtree を geodiff の SQLite で焼き直した: ${plan.tables} テーブル');
      return plan.tables;
    } finally {
      g.dispose();
    }
  }

  /// テスト用: 開いている [db]（rtree が使える SQLite）で焼き直す
  static Future<int> rebuild(Database db) async {
    final plan = await _plan(db);
    await db.transaction((txn) async {
      for (final sql in plan.statements) {
        await txn.execute(sql);
      }
    });
    return plan.tables;
  }

  /// 実データから、rtree・gpkg_contents・gpkg_ogr_contents を書き直す SQL を組む（読むだけ）
  static Future<_Plan> _plan(Database db) async {
    final statements = <String>[];
    var tables = 0;
    final hasOgr = (await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'gpkg_ogr_contents'",
    )).isNotEmpty;
    final columns = await db.rawQuery('SELECT table_name, column_name FROM gpkg_geometry_columns');
    for (final c in columns) {
      final table = c['table_name'] as String?;
      final geomCol = c['column_name'] as String?;
      if (table == null || geomCol == null) continue;
      final rtree = 'rtree_${table}_$geomCol';
      final hasRtree = (await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        [rtree],
      )).isNotEmpty;
      if (!hasRtree) continue;
      final pk = await _primaryKey(db, table);
      if (pk == null) {
        AppLogger.debug('[GpkgIndexRepair] 主キーが分からないので飛ばす: $table');
        continue;
      }

      final rows = await db.rawQuery('SELECT "$pk" AS id, "$geomCol" AS geom FROM "$table"');
      final values = <String>[];
      double? minX, maxX, minY, maxY;
      for (final r in rows) {
        final id = r['id'];
        final blob = r['geom'];
        if (id is! int || blob is! Uint8List) continue;
        final env = gpkgEnvelope(blob);
        if (env == null) continue;
        values.add('($id,${_num(env.minX)},${_num(env.maxX)},${_num(env.minY)},${_num(env.maxY)})');
        minX = minX == null || env.minX < minX ? env.minX : minX;
        maxX = maxX == null || env.maxX > maxX ? env.maxX : maxX;
        minY = minY == null || env.minY < minY ? env.minY : minY;
        maxY = maxY == null || env.maxY > maxY ? env.maxY : maxY;
      }

      statements.add('DELETE FROM ${_q(rtree)}');
      for (var i = 0; i < values.length; i += 500) {
        final chunk = values.sublist(i, i + 500 > values.length ? values.length : i + 500);
        statements.add('INSERT INTO ${_q(rtree)} (id, minx, maxx, miny, maxy) VALUES ${chunk.join(',')}');
      }
      if (minX != null && maxX != null && minY != null && maxY != null) {
        statements.add('UPDATE gpkg_contents SET min_x = ${_num(minX)}, min_y = ${_num(minY)}, '
            'max_x = ${_num(maxX)}, max_y = ${_num(maxY)} WHERE table_name = ${_s(table)}');
      }
      if (hasOgr) {
        statements.add('UPDATE gpkg_ogr_contents SET feature_count = ${rows.length} WHERE table_name = ${_s(table)}');
      }
      tables++;
    }
    return _Plan(statements, tables);
  }

  static Future<String?> _primaryKey(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info("$table")');
    for (final col in info) {
      if ((col['pk'] as int? ?? 0) > 0) return col['name'] as String?;
    }
    return null;
  }

  static String _q(String ident) => '"${ident.replaceAll('"', '""')}"';
  static String _s(String text) => "'${text.replaceAll("'", "''")}'";
  static String _num(double v) => v.isFinite ? v.toString() : 'NULL';
}

class _Plan {
  const _Plan(this.statements, this.tables);
  final List<String> statements;
  final int tables;
  bool get isEmpty => statements.isEmpty;
}
