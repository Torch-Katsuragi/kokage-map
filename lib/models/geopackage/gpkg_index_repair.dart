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
import 'gpkg_rtree_triggers.dart';
import 'sql_identifier.dart';

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
    return await _execute(path, plan.statements) ? plan.tables : -1;
  }

  /// rtree が登録され rtree の表もあるのにトリガーが 1 つも無い表（[GpkgRtreeTriggers.findMissing]）に、
  /// 規格（GDAL が今書くもの）のトリガーを作り、その表の rtree・範囲・件数を実データに合わせる。
  /// 直した表の数を返す（失敗は -1、投げない）。直す表が無ければファイルを書かない（読むだけで開く）。
  ///
  /// 以前の版が Android でトリガーを落としたまま Drive へ上げたファイルを、アプリが書いたあと外へ出す前に直す
  /// （`GeoPackageFile.prepareForHandOff`・閉じたあと）。呼ぶ前にアプリの接続を閉じておくこと。
  ///
  /// ⚠ **Android 本体の SQLite（sqflite）ではトリガーを作らない**（ST_ 関数も rtree も無く、作ると次の書き込みが落ちる）。
  /// 組んだ SQL は rtree の DELETE から始まるので、rtree の無い SQLite では最初の文で落ち、geodiff の SQLite で流し直す
  static Future<int> healRtreeTriggers(String path) async {
    final List<RtreeTriggerGap> gaps;
    final _Plan plan;
    try {
      final db = await openDatabase(path, readOnly: true, singleInstance: false);
      try {
        gaps = await GpkgRtreeTriggers.findMissing(db);
        if (gaps.isEmpty) return 0;
        plan = await _plan(db, onlyRtrees: {for (final g in gaps) g.rtree.toLowerCase()});
      } finally {
        await db.close();
      }
    } catch (e) {
      AppLogger.debug('[GpkgIndexRepair] $path を読めない: $e');
      return -1;
    }
    // rtree を焼き直せる表だけ（主キー・形の列が引けたもの）。rtree の文を先に、トリガーをあとに
    final healed = [for (final g in gaps) if (plan.rtrees.contains(g.rtree.toLowerCase())) g];
    if (healed.isEmpty) return 0;
    final statements = [
      ...plan.statements,
      for (final g in healed) ...[
        for (final name in g.triggers.keys) 'DROP TRIGGER IF EXISTS ${quoteIdent(name)}',
        ...g.triggers.values,
      ],
    ];
    if (!await _execute(path, statements)) return -1;
    AppLogger.debug('[GpkgIndexRepair] rtree のトリガーを作り直した: ${[for (final g in healed) g.table].join(', ')}');
    return healed.length;
  }

  /// [statements] を 1 つのトランザクションで流す。まずアプリの SQLite で（rtree があれば）、無ければ geodiff の SQLite で
  static Future<bool> _execute(String path, List<String> statements) async {
    Database? db;
    try {
      db = await openDatabase(path, singleInstance: false);
      await db.transaction((txn) async {
        for (final sql in statements) {
          await txn.execute(sql);
        }
      });
      return true;
    } on DatabaseException catch (e) {
      if (!'$e'.contains('no such module: rtree')) {
        AppLogger.debug('[GpkgIndexRepair] $path の焼き直しに失敗: $e');
        return false;
      }
    } catch (e) {
      AppLogger.debug('[GpkgIndexRepair] $path の焼き直しに失敗: $e');
      return false;
    } finally {
      await db?.close();
    }

    if (!Geodiff.isSupported) return false;
    final g = Geodiff();
    try {
      final err = g.execSql(path, 'BEGIN;\n${statements.join(';\n')};\nCOMMIT;');
      if (err != null) {
        AppLogger.debug('[GpkgIndexRepair] geodiff の SQLite でも失敗: $err');
        return false;
      }
      AppLogger.debug('[GpkgIndexRepair] rtree を geodiff の SQLite で焼き直した');
      return true;
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
  ///
  /// [onlyRtrees] を渡すと、その rtree（小文字の名前）の表だけ
  static Future<_Plan> _plan(Database db, {Set<String>? onlyRtrees}) async {
    final statements = <String>[];
    final rtrees = <String>{};
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
      if (onlyRtrees != null && !onlyRtrees.contains(rtree.toLowerCase())) continue;
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

      final rows = await db.rawQuery('SELECT ${quoteIdent(pk)} AS id, ${quoteIdent(geomCol)} AS geom FROM ${quoteIdent(table)}');
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

      statements.add('DELETE FROM ${quoteIdent(rtree)}');
      for (var i = 0; i < values.length; i += 500) {
        final chunk = values.sublist(i, i + 500 > values.length ? values.length : i + 500);
        statements.add('INSERT INTO ${quoteIdent(rtree)} (id, minx, maxx, miny, maxy) VALUES ${chunk.join(',')}');
      }
      if (minX != null && maxX != null && minY != null && maxY != null) {
        statements.add('UPDATE gpkg_contents SET min_x = ${_num(minX)}, min_y = ${_num(minY)}, '
            'max_x = ${_num(maxX)}, max_y = ${_num(maxY)} WHERE table_name = ${quoteSqlString(table)}');
      }
      if (hasOgr) {
        statements.add('UPDATE gpkg_ogr_contents SET feature_count = ${rows.length} WHERE table_name = ${quoteSqlString(table)}');
      }
      tables++;
      rtrees.add(rtree.toLowerCase());
    }
    return _Plan(statements, tables, rtrees);
  }

  static Future<String?> _primaryKey(Database db, String table) async {
    final info = await db.rawQuery('PRAGMA table_info(${quoteIdent(table)})');
    for (final col in info) {
      if ((col['pk'] as int? ?? 0) > 0) return col['name'] as String?;
    }
    return null;
  }

  static String _num(double v) => v.isFinite ? v.toString() : 'NULL';
}

class _Plan {
  const _Plan(this.statements, this.tables, this.rtrees);
  final List<String> statements;
  final int tables;

  /// 焼き直す rtree（小文字の名前）
  final Set<String> rtrees;
  bool get isEmpty => statements.isEmpty;
}
