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
/// QGIS / GDAL との相互運用を保つための後始末。
///
/// こかげマップ は「ユーザーの `.gpkg` をそのまま読み書きする」ことを identity に
/// しているので、**編集して返したファイルが QGIS で普通に開けること**が要件になる。
/// ここは編集中には邪魔だがQGIS側では必要、という3点の面倒を見る。
///
/// 1. **SpatiaLiteトリガーの復元**
///    QGIS/GDAL製のGeoPackageは RTree自動更新トリガーを持ち、それらは
///    `ST_IsEmpty` / `ST_MinX` 等の SpatiaLite 関数を使う。sqflite には
///    その拡張が無いので、こかげマップ は書き込み前にトリガーを落とし、rtree は
///    [SpatialIndexManager] が自前で更新している。
///    ⚠ **落としたまま返すと、その後QGISで編集しても空間インデックスが
///    更新されなくなる。** クローズ時に元のSQLで復元する。
///
/// 2. **`gpkg_contents` のバウンディングボックス**
///    こかげマップ は新規レイヤ作成時に min_x/min_y/max_x/max_y を null で入れていた。
///    QGISはここをレイヤ範囲として使うので、「レイヤにズーム」が効かない。
///
/// 3. **`gpkg_ogr_contents` のフィーチャ数**
///    GDALが維持する件数キャッシュ。こかげマップ が直接 INSERT/DELETE すると
///    実態とズレる（GDAL製ファイルにはこれを維持するトリガーもあるが、
///    上記1で一緒に落ちることがある）。
library;

import 'package:sqflite/sqflite.dart';

import '../../utils/app_logger.dart';
import 'sql_identifier.dart';

/// GeoPackage を QGIS/GDAL と行き来させるための整合処理
class QgisInterop {
  /// 落としたトリガーの定義（トリガー名 → CREATE TRIGGER 文）
  ///
  /// 規格から生成し直すのではなく**逐語的に保存して戻す**。
  /// RTreeトリガーの構成は GDAL のバージョンで違い（update1〜update7 等）、
  /// 生成し直すと元と違うものを書き込むことになるため。
  final Map<String, String> _removedTriggers = {};

  /// 削除するトリガーの定義を控えておく。
  ///
  /// 実際の DROP は呼び出し側が行う。ここは「戻せるようにする」だけ。
  void rememberTrigger(String name, String? sql) {
    if (sql == null || sql.isEmpty) return;
    _removedTriggers[name] = sql;
  }

  /// 控えておいたトリガーを復元する。
  ///
  /// クローズ時に呼ぶ。こかげマップ の書き込みが終わったあとでなければならない
  /// （復元後に書くと ST_ 関数が無くて落ちる）。
  Future<void> restoreTriggers(Database db) async {
    if (_removedTriggers.isEmpty) return;

    var restored = 0;
    for (final entry in _removedTriggers.entries) {
      try {
        // 同名が既にある場合に備えて落としてから作る
        await db.execute('DROP TRIGGER IF EXISTS ${quoteIdent(entry.key)}');
        await db.execute(entry.value);
        restored++;
      } catch (e) {
        AppLogger.debug('[QgisInterop] トリガー復元に失敗: ${entry.key} - $e');
      }
    }
    _removedTriggers.clear();
    AppLogger.debug('[QgisInterop] SpatiaLiteトリガーを復元: $restored 個');
  }

  /// `gpkg_contents` のバウンディングボックスを実データから更新する。
  ///
  /// rtree があればそこから、無ければフィーチャを走査せずスキップする
  /// （全件走査は重く、こかげマップ は rtree を自前で維持しているため通常は存在する）。
  static Future<void> updateContentsBounds(
    Database db,
    String tableName,
  ) async {
    try {
      final rtree = 'rtree_${tableName}_geom';
      final exists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name = ?",
        [rtree],
      );
      if (exists.isEmpty) return;

      final rows = await db.rawQuery(
        'SELECT MIN(minx) AS min_x, MIN(miny) AS min_y, '
        'MAX(maxx) AS max_x, MAX(maxy) AS max_y FROM ${quoteIdent(rtree)}',
      );
      if (rows.isEmpty) return;

      final r = rows.first;
      if (r['min_x'] == null) return; // フィーチャ0件

      await db.update(
        'gpkg_contents',
        {
          'min_x': r['min_x'],
          'min_y': r['min_y'],
          'max_x': r['max_x'],
          'max_y': r['max_y'],
        },
        where: 'table_name = ?',
        whereArgs: [tableName],
      );
      AppLogger.debug(
        '[QgisInterop] $tableName の範囲を更新: '
        '(${r['min_x']}, ${r['min_y']}) - (${r['max_x']}, ${r['max_y']})',
      );
    } catch (e) {
      AppLogger.debug('[QgisInterop] updateContentsBounds エラー: $e');
    }
  }

  /// `gpkg_ogr_contents` のフィーチャ数を実データに合わせる。
  ///
  /// このテーブルはGDAL拡張で、存在しないGeoPackageもある。無ければ何もしない
  /// （こかげマップが勝手に作ると、逆にGDALの前提を崩す可能性がある）。
  static Future<void> syncOgrContents(Database db, String tableName) async {
    try {
      final exists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='gpkg_ogr_contents'",
      );
      if (exists.isEmpty) return;

      final registered = await db.rawQuery(
        'SELECT table_name FROM gpkg_ogr_contents WHERE table_name = ?',
        [tableName],
      );
      if (registered.isEmpty) return; // このレイヤは登録されていない

      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${quoteIdent(tableName)}',
      );
      final count = countRows.first['c'];

      await db.update(
        'gpkg_ogr_contents',
        {'feature_count': count},
        where: 'table_name = ?',
        whereArgs: [tableName],
      );
      AppLogger.debug('[QgisInterop] $tableName の件数を同期: $count');
    } catch (e) {
      AppLogger.debug('[QgisInterop] syncOgrContents エラー: $e');
    }
  }

  /// フィーチャを持つ全レイヤについて、範囲と件数を実データに合わせる。
  static Future<void> syncAllLayers(Database db) async {
    try {
      final layers = await db.rawQuery(
        "SELECT table_name FROM gpkg_contents WHERE data_type = 'features'",
      );
      for (final layer in layers) {
        final name = layer['table_name'] as String?;
        if (name == null) continue;
        await updateContentsBounds(db, name);
        await syncOgrContents(db, name);
      }
    } catch (e) {
      AppLogger.debug('[QgisInterop] syncAllLayers エラー: $e');
    }
  }
}
