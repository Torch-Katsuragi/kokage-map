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
// Root Maps: レイヤリポジトリクラス
// レイヤの作成・削除・リネーム・一覧取得を担当
import 'package:sqflite/sqflite.dart';
import '../../utils/app_logger.dart';
import '../geometry_type.dart';
import 'geopackage_connection.dart';
import 'geopackage_schema.dart';
import 'spatial_index_manager.dart';
import 'sql_identifier.dart';

/// レイヤ（フィーチャテーブル）を管理するリポジトリクラス
/// 責務: レイヤの作成・削除・リネーム・一覧取得
class LayerRepository {
  /// DB接続への参照
  final GeoPackageConnection connection;

  /// スキーマ管理への参照
  final GeoPackageSchema schema;

  /// 空間インデックス管理への参照
  final SpatialIndexManager spatialIndex;

  /// コンストラクタ
  LayerRepository(this.connection, this.schema, this.spatialIndex);

  /// DBからレイヤ（フィーチャテーブル）名一覧を取得
  Future<List<String>> getLayerNames() async {
    try {
      final db = await connection.getDatabase();
      final contents = await db.query(
        'gpkg_contents',
        where: 'data_type = ?',
        whereArgs: ['features'],
      );
      return contents.map((row) => row['table_name'] as String).toList();
    } catch (e) {
      AppLogger.debug('[LayerRepository] getLayerNames: エラー発生 - $e');
      return [];
    }
  }

  /// 指定レイヤのジオメトリタイプを取得
  Future<GeometryType?> getGeometryType(String tableName) async {
    try {
      final db = await connection.getDatabase();
      final rows = await db.query(
        'gpkg_geometry_columns',
        where: 'table_name = ?',
        whereArgs: [tableName],
      );
      if (rows.isEmpty) return null;
      final typeString = rows.first['geometry_type_name'] as String?;
      return typeString != null ? GeometryType.fromString(typeString) : null;
    } catch (e) {
      AppLogger.debug('[LayerRepository] getGeometryType: エラー発生 - $e');
      return null;
    }
  }

  /// レイヤ追加（DBにテーブル作成）
  /// QGIS互換性のため、PRIMARY KEYは fid を使用
  Future<void> addLayer(String name, GeometryType geomType) async {
    try {
      final db = await connection.getDatabase();

      // フィーチャテーブル作成（必須カラムのみ：fid と geom）
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ${quoteIdent(name)} (
          fid INTEGER PRIMARY KEY AUTOINCREMENT,
          geom BLOB NOT NULL
        );
      ''');

      // gpkg_contentsに登録
      await db.insert('gpkg_contents', {
        'table_name': name,
        'data_type': 'features',
        'identifier': name,
        'description': '',
        'srs_id': 4326,
        'min_x': null,
        'min_y': null,
        'max_x': null,
        'max_y': null,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      // gpkg_geometry_columnsに登録
      await db.insert('gpkg_geometry_columns', {
        'table_name': name,
        'column_name': 'geom',
        'geometry_type_name': geomType.value,
        'srs_id': 4326,
        'z': 0,
        'm': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      // 空間インデックスを作成
      await spatialIndex.createSpatialIndex(name);
    } catch (e) {
      AppLogger.debug('[LayerRepository] addLayer: エラー発生 - $e');
    }
  }

  /// レイヤ削除（DBからテーブル・メタ情報削除）
  Future<void> removeLayer(String name) async {
    try {
      final db = await connection.getDatabase();

      // フィーチャテーブル削除
      await db.execute('DROP TABLE IF EXISTS ${quoteIdent(name)};');

      // メタデータ削除
      await db.delete(
        'gpkg_contents',
        where: 'table_name = ?',
        whereArgs: [name],
      );
      await db.delete(
        'gpkg_geometry_columns',
        where: 'table_name = ?',
        whereArgs: [name],
      );

      // PRIMARY KEYキャッシュをクリア
      schema.clearPrimaryKeyCache();
    } catch (e) {
      AppLogger.debug('[LayerRepository] removeLayer: エラー発生 - $e');
    }
  }

  /// レイヤ名変更（テーブル名変更＋メタデータ更新）
  Future<void> renameLayer(String oldName, String newName) async {
    if (oldName == newName) return;

    try {
      final db = await connection.getDatabase();

      // テーブル名変更
      await db.execute('ALTER TABLE ${quoteIdent(oldName)} RENAME TO ${quoteIdent(newName)};');

      // gpkg_contentsのテーブル名更新
      await db.update(
        'gpkg_contents',
        {'table_name': newName, 'identifier': newName},
        where: 'table_name = ?',
        whereArgs: [oldName],
      );

      // gpkg_geometry_columnsのテーブル名更新
      await db.update(
        'gpkg_geometry_columns',
        {'table_name': newName},
        where: 'table_name = ?',
        whereArgs: [oldName],
      );

      // PRIMARY KEYキャッシュをクリア
      schema.clearPrimaryKeyCache();

      AppLogger.debug('[LayerRepository] renameLayer: $oldName -> $newName');
    } catch (e) {
      AppLogger.debug('[LayerRepository] renameLayer: エラー発生 - $e');
      rethrow;
    }
  }
}
