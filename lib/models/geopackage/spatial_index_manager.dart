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
// Root Maps: 空間インデックス管理クラス
// R-Tree操作、エンベロープ更新、SpatiaLiteトリガー処理を担当
import 'dart:typed_data';

import '../../utils/app_logger.dart';
import '../../utils/wkb_utils.dart';
import 'geopackage_connection.dart';
import 'qgis_interop.dart';
import 'sql_identifier.dart';

/// 空間インデックスを管理するクラス
/// 責務: R-Tree空間インデックス、レイヤエンベロープ、SpatiaLiteトリガー対応
class SpatialIndexManager {
  /// DB接続への参照
  final GeoPackageConnection connection;

  /// QGIS相互運用（落としたトリガーを控えて、クローズ時に戻す）
  final QgisInterop qgisInterop = QgisInterop();

  /// コンストラクタ
  SpatialIndexManager(this.connection);

  /// 空間インデックス作成（GeoPackageの空間インデックス機能を利用）
  Future<void> createSpatialIndex(String tableName) async {
    try {
      final db = await connection.getDatabase();

      // SpatiaLiteスタイルの空間インデックス作成
      await db.execute('''
        CREATE INDEX IF NOT EXISTS ${quoteIdent('idx_${tableName}_geom')}
        ON ${quoteIdent(tableName)} (geom)
      ''');
    } catch (e) {
      AppLogger.debug('[ERROR] SpatialIndexManager.createSpatialIndex: $e');
    }
  }

  /// 書いた行の形（GeoPackage のバイナリ）から範囲を取り、R-Tree とレイヤの範囲
  /// （gpkg_contents）に入れる。範囲はレイヤの CRS のまま（WGS84 に直さない）。
  ///
  /// QGIS 製の gpkg は R-Tree を保つトリガーを SpatiaLite 関数ごと落としているので
  /// （[removeSpatiaLiteTriggers]）、追加・更新のたびにここで入れ直す
  Future<void> indexRows(String tableName, Map<int, Uint8List> geoms) async {
    if (geoms.isEmpty) return;
    try {
      final db = await connection.getDatabase();
      final rtreeTable = 'rtree_${tableName}_geom';
      final hasRtree = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [rtreeTable],
      )).isNotEmpty;

      double? minX, minY, maxX, maxY;
      final batch = db.batch();
      for (final MapEntry(key: id, value: blob) in geoms.entries) {
        final env = gpkgEnvelope(blob);
        if (env == null) continue;
        if (hasRtree) {
          batch.execute(
            'INSERT OR REPLACE INTO ${quoteIdent(rtreeTable)} (id, minx, maxx, miny, maxy) VALUES (?, ?, ?, ?, ?)',
            [id, env.minX, env.maxX, env.minY, env.maxY],
          );
        }
        minX = minX == null || env.minX < minX ? env.minX : minX;
        minY = minY == null || env.minY < minY ? env.minY : minY;
        maxX = maxX == null || env.maxX > maxX ? env.maxX : maxX;
        maxY = maxY == null || env.maxY > maxY ? env.maxY : maxY;
      }
      if (minX == null) return;
      // レイヤの範囲は広げるだけ（縮めるのは GpkgIndexRepair）
      batch.execute(
        'UPDATE gpkg_contents SET '
        'min_x = min(coalesce(min_x, ?1), ?1), min_y = min(coalesce(min_y, ?2), ?2), '
        'max_x = max(coalesce(max_x, ?3), ?3), max_y = max(coalesce(max_y, ?4), ?4) '
        'WHERE table_name = ?5',
        [minX, minY, maxX, maxY, tableName],
      );
      await batch.commit(noResult: true);
    } catch (e) {
      // 索引の更新に失敗しても書き込みは成り立つ（GpkgIndexRepair で直せる）
      AppLogger.debug('[WARNING] SpatialIndexManager.indexRows: $e');
    }
  }

  /// R-Tree空間インデックスからエントリを削除（フィーチャ削除時に呼び出す）
  Future<void> removeFromRTreeIndex(String tableName, int rowId) async {
    try {
      final db = await connection.getDatabase();
      final rtreeTable = 'rtree_${tableName}_geom';

      // R-Treeテーブルが存在するか確認
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [rtreeTable],
      );

      if (tables.isNotEmpty) {
        await db.execute('DELETE FROM ${quoteIdent(rtreeTable)} WHERE id = ?', [rowId]);
      }
    } catch (e) {
      AppLogger.debug('[WARNING] SpatialIndexManager.removeFromRTreeIndex: $e');
    }
  }

  /// SpatiaLite固有のトリガーを検出して削除
  /// QGISで作成されたGeoPackageにはST_IsEmpty等のSpatiaLite関数を使用する
  /// トリガーが含まれており、sqfliteではこれらの関数がサポートされていないため
  /// INSERT/UPDATE時にエラーが発生する。このメソッドで問題のトリガーを削除する。
  Future<void> removeSpatiaLiteTriggers() async {
    final db = await connection.getDatabase();

    try {
      // sqlite_masterからトリガー一覧を取得
      final triggers = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'",
      );

      int removedCount = 0;
      for (final trigger in triggers) {
        final triggerName = trigger['name'] as String?;
        final sql = trigger['sql'] as String?;

        // SpatiaLite関数を使用しているトリガーを検出して削除
        if (triggerName != null &&
            sql != null &&
            _containsSpatiaLiteFunctions(sql)) {
          // ⚠ 落とす前に定義を控える。落としたまま返すとQGIS側で
          //    空間インデックスが更新されなくなる（クローズ時に復元する）。
          qgisInterop.rememberTrigger(triggerName, sql);
          await db.execute('DROP TRIGGER IF EXISTS ${quoteIdent(triggerName)}');
          removedCount++;
          AppLogger.debug(
            '[SpatialIndexManager] SpatiaLiteトリガー削除: $triggerName',
          );
        }
      }

      if (removedCount > 0) {
        AppLogger.debug(
          '[SpatialIndexManager] 合計 $removedCount 個のSpatiaLiteトリガーを削除',
        );
      }
    } catch (e) {
      AppLogger.debug(
        '[ERROR] SpatialIndexManager.removeSpatiaLiteTriggers: $e',
      );
    }
  }

  /// [tableName] の SpatiaLite 依存トリガーと rtree_ トリガーを検出・除去（書き込み前に 1 回）
  ///
  /// QGIS/GeoPandasが生成するRTree自動更新トリガーは
  /// ST_IsEmpty, ST_MinX等のSpatiaLite関数を使用するが、
  /// sqfliteにはSpatiaLite拡張がないためINSERT/UPDATE時にエラーとなる。
  /// こかげマップはここ（[indexRows]）でrtreeを管理するため、
  /// これらのトリガーは不要。
  Future<void> removeTableTriggers(String tableName) async {
    try {
      final db = await connection.getDatabase();
      // テーブルに関連するトリガーを全取得
      final triggers = await db.rawQuery(
        'SELECT name, sql FROM sqlite_master '
        "WHERE type = 'trigger' AND tbl_name = ?",
        [tableName],
      );

      if (triggers.isEmpty) return;

      // SpatiaLite関数を使っているトリガーを検出
      const spatialiteFunctions = [
        'ST_IsEmpty',
        'ST_MinX',
        'ST_MaxX',
        'ST_MinY',
        'ST_MaxY',
        'ST_MinZ',
        'ST_MaxZ',
        'ST_MinM',
        'ST_MaxM',
      ];

      final triggersToRemove = <String>[];
      for (final trigger in triggers) {
        final sql = trigger['sql'] as String? ?? '';
        final name = trigger['name'] as String;

        // SpatiaLite関数を使っているトリガーを検出
        final usesSpatialiteFunction = spatialiteFunctions.any(
          sql.contains,
        );

        // rtree仮想テーブルを参照するトリガーを検出
        // (DELETE時のrtreeクリーンアップ等、ST_関数を使わないものも含む)
        final referencesRtree = name.startsWith('rtree_');

        if (usesSpatialiteFunction || referencesRtree) {
          // ⚠ 落とす前に定義を控える（クローズ時に復元してQGISへ返す）
          qgisInterop.rememberTrigger(name, sql);
          triggersToRemove.add(name);
        }
      }

      if (triggersToRemove.isEmpty) return;

      // トリガーを除去
      for (final name in triggersToRemove) {
        await db.execute('DROP TRIGGER IF EXISTS ${quoteIdent(name)}');
      }

      AppLogger.debug(
        '[SpatialIndexManager] 🧹 SpatiaLiteトリガーを除去: '
        '$tableName (${triggersToRemove.length}個: '
        '${triggersToRemove.join(", ")})',
      );
    } catch (e) {
      AppLogger.debug('[SpatialIndexManager] ⚠️ トリガー除去エラー: $tableName - $e');
    }
  }

  /// SQLにSpatiaLite固有の関数が含まれているかチェック
  bool _containsSpatiaLiteFunctions(String sql) {
    const spatialiteFunctions = [
      'ST_IsEmpty',
      'ST_MinX',
      'ST_MaxX',
      'ST_MinY',
      'ST_MaxY',
      'ST_GeometryType',
      'ST_SRID',
      'IsValidGPB',
      'gpkgMakePoint',
      'gpkgMakePointZ',
      'gpkgMakePointM',
      'gpkgMakePointZM',
    ];

    final upperSql = sql.toUpperCase();
    return spatialiteFunctions.any((f) => upperSql.contains(f.toUpperCase()));
  }
}
