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
import '../../utils/app_logger.dart';
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

  /// R-Tree空間インデックスを更新（フィーチャ追加/更新時に呼び出す）
  Future<void> updateRTreeIndex(
    String tableName,
    int rowId,
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) async {
    try {
      final db = await connection.getDatabase();
      final rtreeTable = 'rtree_${tableName}_geom';

      // R-Treeテーブルが存在するか確認
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [rtreeTable],
      );

      if (tables.isNotEmpty) {
        // R-Treeインデックスを更新（INSERT OR REPLACEで既存エントリも更新）
        await db.execute(
          '''
          INSERT OR REPLACE INTO ${quoteIdent(rtreeTable)} (id, minx, maxx, miny, maxy)
          VALUES (?, ?, ?, ?, ?)
          ''',
          [rowId, minX, maxX, minY, maxY],
        );
      }
    } catch (e) {
      // R-Tree更新エラーは致命的ではないのでログのみ
      AppLogger.debug('[WARNING] SpatialIndexManager.updateRTreeIndex: $e');
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

  /// gpkg_contentsテーブルのエンベロープを更新
  Future<void> updateLayerEnvelope(
    String tableName,
    double minX,
    double minY,
    double maxX,
    double maxY,
  ) async {
    try {
      final db = await connection.getDatabase();

      // 現在のエンベロープを取得
      final currentEnvelope = await db.query(
        'gpkg_contents',
        columns: ['min_x', 'min_y', 'max_x', 'max_y'],
        where: 'table_name = ?',
        whereArgs: [tableName],
      );

      double? currentMinX, currentMinY, currentMaxX, currentMaxY;
      if (currentEnvelope.isNotEmpty) {
        final row = currentEnvelope.first;
        currentMinX = row['min_x'] as double?;
        currentMinY = row['min_y'] as double?;
        currentMaxX = row['max_x'] as double?;
        currentMaxY = row['max_y'] as double?;
      }

      // エンベロープを拡張
      final newMinX =
          currentMinX != null
              ? (currentMinX < minX ? currentMinX : minX)
              : minX;
      final newMinY =
          currentMinY != null
              ? (currentMinY < minY ? currentMinY : minY)
              : minY;
      final newMaxX =
          currentMaxX != null
              ? (currentMaxX > maxX ? currentMaxX : maxX)
              : maxX;
      final newMaxY =
          currentMaxY != null
              ? (currentMaxY > maxY ? currentMaxY : maxY)
              : maxY;

      // エンベロープを更新
      await db.update(
        'gpkg_contents',
        {
          'min_x': newMinX,
          'min_y': newMinY,
          'max_x': newMaxX,
          'max_y': newMaxY,
        },
        where: 'table_name = ?',
        whereArgs: [tableName],
      );
    } catch (e) {
      AppLogger.debug('[SpatialIndexManager] エンベロープ更新エラー: $e');
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
