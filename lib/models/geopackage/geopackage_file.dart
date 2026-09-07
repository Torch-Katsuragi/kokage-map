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
// Root Maps: GeoPackageファイル管理クラス（ファサード）
// 既存APIを維持しつつ、内部で各サービスクラスに委譲
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../../utils/background_save_manager.dart';
import '../geometry_type.dart';
import 'feature_repository.dart';
import 'geopackage_connection.dart';
import 'geopackage_schema.dart';
import 'layer_repository.dart';
import 'qgis_interop.dart';
import 'spatial_index_manager.dart';

/// GeoPackageファイルを管理するファサードクラス
///
/// 責務: 既存APIの維持、内部サービスへの委譲
///
/// PRIMARY KEY戦略:
/// - 新規作成: fid INTEGER PRIMARY KEY AUTOINCREMENT（QGIS互換）
/// - 読み込み: 動的検出（fid, id, rowid等）して内部的に'id'として正規化
/// - FeatureNode互換性: row['id']で常にPRIMARY KEYにアクセス可能
class GeoPackageFile {
  /// ルートからのパスリスト
  final List<String> pathList;

  /// 絶対パス（指定時はpathListを無視）
  /// グローバルフォルダ内のGeoPackageで使用
  final String? absolutePath;

  /// プロジェクトルートディレクトリ（相対パスモード時に使用）
  final String? projectRootDir;

  // ============================================================
  // 内部サービス（遅延初期化）
  // ============================================================

  late final GeoPackageConnection _connection;
  late final GeoPackageSchema _schema;
  late final SpatialIndexManager _spatial;
  late final FeatureRepository _features;
  late final LayerRepository _layers;

  bool _servicesInitialized = false;

  /// サポートする属性カラム名リスト（属性テーブルで表示するカラム）
  List<String> get supportedAttributes => _schema.supportedAttributes;

  /// コンストラクタ
  GeoPackageFile(this.pathList, {this.absolutePath, this.projectRootDir}) {
    _initializeServices();
  }

  /// 内部サービスの初期化
  void _initializeServices() {
    if (_servicesInitialized) return;

    _connection = GeoPackageConnection(
      pathList,
      absolutePath: absolutePath,
      projectRootDir: projectRootDir,
    );
    _schema = GeoPackageSchema(_connection);
    _spatial = SpatialIndexManager(_connection);
    _features = FeatureRepository(_connection, _schema, _spatial);
    _layers = LayerRepository(_connection, _schema, _spatial);

    _servicesInitialized = true;
  }

  /// 絶対パスを取得（グローバルフォルダ対応）
  String? getAbsolutePath() {
    if (absolutePath != null) return absolutePath;
    if (projectRootDir == null) return null;
    return p.joinAll([projectRootDir!, ...pathList]);
  }

  // ============================================================
  // DB接続管理（GeoPackageConnectionに委譲）
  // ============================================================

  /// データベース接続を直接取得（非空間テーブル操作等の高度な用途向け）
  Future<Database> getDatabase() => _connection.getDatabase();

  /// 変更を元ファイルへ書き戻す（web のみ実体がある）。
  ///
  /// native は sqflite が実ファイルを直接更新しているので何もしない。
  /// ⚠ web ではこれを呼ばないと編集がタブを閉じた時点で消える。
  Future<void> checkIn() => _connection.checkIn();

  /// 空のGeoPackageファイルを明示的に作成（即座に初期化）
  Future<bool> createEmptyDatabase() async {
    final result = await _connection.createEmptyDatabase();
    if (result) {
      // SpatiaLiteトリガーを削除
      await _spatial.removeSpatiaLiteTriggers();
    }
    return result;
  }

  /// データベースのクローズ処理
  Future<void> dispose() async {
    // 保留中の変更を全て保存
    await flushChanges();

    // BackgroundSaveManagerから変更キューをクリア
    BackgroundSaveManager.instance.clearPendingChanges(this);

    // QGIS/GDALへ返す前の整合処理（書き込みが全部終わったこの位置で行う）
    await _finalizeForQgis();

    // ⚠ 閉じる前に書き戻す。web はここを飛ばすと _finalizeForQgis() の
    // 成果（空間インデックス復元・範囲更新）が元ファイルに残らない
    await checkIn();

    // データベースを閉じる
    await _connection.dispose();
  }

  /// QGIS/GDAL と行き来しても壊れない状態にしてから閉じる
  ///
  /// - `gpkg_contents` の範囲と `gpkg_ogr_contents` の件数を実データに合わせる
  /// - 書き込みのために落としていた SpatiaLiteトリガーを復元する
  ///
  /// ⚠ トリガー復元は**必ず最後**。復元後に書き込むと sqflite に ST_ 関数が無く落ちる。
  /// 失敗してもクローズ自体は続行する（ファイルを開けたままにしない）。
  Future<void> _finalizeForQgis() async {
    try {
      final db = await _connection.getDatabase();
      await QgisInterop.syncAllLayers(db);
      await _spatial.qgisInterop.restoreTriggers(db);
    } catch (e) {
      AppLogger.debug('[GeoPackageFile] QGIS向けの整合処理に失敗: $e');
    }
  }

  /// ファイル自体を削除（物理削除）
  Future<bool> deleteFile() async {
    // 保留中の変更を全て保存
    await flushChanges();

    // BackgroundSaveManagerから変更キューをクリア
    BackgroundSaveManager.instance.clearPendingChanges(this);

    return _connection.deleteFile();
  }

  // ============================================================
  // バックグラウンド保存（BackgroundSaveManagerに委譲）
  // ============================================================

  /// 属性値の遅延更新をキューに追加
  void queueAttributeUpdate(
    String tableName,
    int rowId,
    String attributeName,
    dynamic value,
  ) {
    BackgroundSaveManager.instance.queueAttributeUpdate(
      this,
      tableName,
      rowId,
      attributeName,
      value,
    );
  }

  /// 複数の属性値を一括で遅延更新キューに追加
  void queueAttributeUpdates(
    String tableName,
    int rowId,
    Map<String, dynamic> attributes,
  ) {
    BackgroundSaveManager.instance.queueAttributeUpdates(
      this,
      tableName,
      rowId,
      attributes,
    );
  }

  /// 即座に全ての変更をDBに保存
  Future<void> flushChanges() async {
    await BackgroundSaveManager.instance.flushChanges(this);
  }

  // ============================================================
  // スキーマ操作（GeoPackageSchemaに委譲）
  // ============================================================

  /// PRIMARY KEYカラム名を動的に取得
  Future<String> getPrimaryKeyColumn(String tableName) =>
      _schema.getPrimaryKeyColumn(tableName);

  /// 指定テーブルのカラム名一覧を返す
  /// [skipPrimaryKey] trueの場合、PRIMARY KEYカラムを除外（属性テーブル表示用）
  Future<List<String>> getColumnNames(
    String tableName, {
    bool getAll = false,
    bool skipPrimaryKey = false,
  }) => _schema.getColumnNames(
    tableName,
    getAll: getAll,
    skipPrimaryKey: skipPrimaryKey,
  );

  /// テーブルのカラム名リストを取得
  Future<List<String>> getTableColumns(String tableName) =>
      _schema.getTableColumns(tableName);

  /// 属性カラムを動的に追加
  Future<void> addAttributeColumn(
    String tableName,
    String columnName,
    String columnType,
  ) => _schema.addAttributeColumn(tableName, columnName, columnType);

  /// 複数の属性カラムを一括追加
  Future<void> addAttributeColumns(
    String tableName,
    Map<String, String> attributeSchema,
  ) => _schema.addAttributeColumns(tableName, attributeSchema);

  /// レイヤの全属性カラム情報を取得
  Future<List<Map<String, dynamic>>> getAttributeColumnInfo(
    String tableName, {
    bool includeBuiltIn = false,
  }) =>
      _schema.getAttributeColumnInfo(tableName, includeBuiltIn: includeBuiltIn);

  // ============================================================
  // レイヤ管理（LayerRepositoryに委譲）
  // ============================================================

  /// DBからレイヤ名一覧を取得
  Future<List<String>> getLayerNames() => _layers.getLayerNames();

  /// 指定レイヤのジオメトリタイプを取得
  Future<GeometryType?> getGeometryType(String tableName) =>
      _layers.getGeometryType(tableName);

  /// レイヤ追加
  Future<void> addLayer(String name, GeometryType geomType) =>
      _layers.addLayer(name, geomType);

  /// レイヤ削除
  Future<void> removeLayer(String name) => _layers.removeLayer(name);

  /// レイヤ名変更
  Future<void> renameLayer(String oldName, String newName) =>
      _layers.renameLayer(oldName, newName);

  // ============================================================
  // Point Feature操作（FeatureRepositoryに委譲）
  // ============================================================

  /// 辞書ベースの点フィーチャ追加
  Future<int?> addPointWithAttributes(
    String tableName,
    LatLng point,
    Map<String, dynamic> attributes,
  ) => _features.addPointWithAttributes(tableName, point, attributes);

  /// 点フィーチャを追加
  Future<int?> addPoint(
    String tableName,
    LatLng pt, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _features.addPoint(
    tableName,
    pt,
    name: name,
    description: description,
    metadata: metadata,
  );

  /// 点フィーチャを更新
  Future<bool> updatePoint(
    String tableName,
    int id,
    LatLng pt, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _features.updatePoint(
    tableName,
    id,
    pt,
    name: name,
    description: description,
    metadata: metadata,
  );

  // ============================================================
  // Line Feature操作（FeatureRepositoryに委譲）
  // ============================================================

  /// 辞書ベースの線フィーチャ追加
  Future<int?> addLineWithAttributes(
    String tableName,
    List<LatLng> line,
    Map<String, dynamic> attributes,
  ) => _features.addLineWithAttributes(tableName, line, attributes);

  /// 線フィーチャを追加
  Future<int?> addLine(
    String tableName,
    List<LatLng> line, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _features.addLine(
    tableName,
    line,
    name: name,
    description: description,
    metadata: metadata,
  );

  /// 線フィーチャを更新
  Future<bool> updateLine(
    String tableName,
    int id,
    List<LatLng> line, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _features.updateLine(
    tableName,
    id,
    line,
    name: name,
    description: description,
    metadata: metadata,
  );

  // ============================================================
  // Polygon Feature操作（FeatureRepositoryに委譲）
  // ============================================================

  /// 辞書ベースの面フィーチャ追加
  Future<int?> addPolygonWithAttributes(
    String tableName,
    List<List<LatLng>> polygon,
    Map<String, dynamic> attributes,
  ) => _features.addPolygonWithAttributes(tableName, polygon, attributes);

  /// ポリゴンフィーチャを追加
  Future<int?> addPolygon(
    String tableName,
    List<List<LatLng>> rings, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _features.addPolygon(
    tableName,
    rings,
    name: name,
    description: description,
    metadata: metadata,
  );

  /// ポリゴンフィーチャを更新
  Future<bool> updatePolygon(
    String tableName,
    int id,
    List<List<LatLng>> rings, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _features.updatePolygon(
    tableName,
    id,
    rings,
    name: name,
    description: description,
    metadata: metadata,
  );

  // ============================================================
  // 共通Feature操作（FeatureRepositoryに委譲）
  // ============================================================

  /// 指定IDのフィーチャを削除
  Future<void> removeFeature(String tableName, int id) =>
      _features.removeFeature(tableName, id);

  /// 単一フィーチャを取得
  Future<Map<String, dynamic>?> getFeature(String tableName, int rowId) async {
    final geomType = await _layers.getGeometryType(tableName);
    return _features.getFeature(tableName, rowId, geomType);
  }

  /// 指定レイヤの全フィーチャを取得
  Future<List<Map<String, dynamic>>> getFeatures(String tableName) =>
      _features.getFeatures(tableName);

  /// 全フィーチャをジオメトリパース済みで一括取得（高速版）
  /// [where] は SQL の WHERE 句（View のフィルタ）。null なら絞り込み無し。
  Future<List<Map<String, dynamic>>> getFeaturesWithGeometry(
    String tableName, {
    String? where,
  }) async {
    final geomType = await _layers.getGeometryType(tableName);
    return _features.getFeaturesWithGeometry(tableName, geomType, where: where);
  }

  /// [where] に当てはまるフィーチャの主キーだけを返す（View の所属判定用）
  Future<Set<int>> getFeatureIds(String tableName, {String? where}) =>
      _features.getFeatureIds(tableName, where: where);

  /// 指定レイヤーの全フィーチャの属性データを一括取得
  Future<List<Map<String, dynamic>>> getAllFeatureAttributes(
    String tableName, {
    List<String>? columns,
  }) => _features.getAllFeatureAttributes(tableName, columns: columns);

  // ============================================================
  // 属性操作（FeatureRepositoryに委譲）
  // ============================================================

  /// 指定テーブル・rowId・カラム名から値を取得
  Future<dynamic> getFeatureAttribute(
    String tableName,
    int rowId,
    String attributeName,
  ) => _features.getFeatureAttribute(tableName, rowId, attributeName);

  /// 指定テーブル・rowIdの全属性値を取得
  Future<Map<String, dynamic>?> getFeatureAttributes(
    String tableName,
    int rowId,
  ) => _features.getFeatureAttributes(tableName, rowId);

  /// 指定テーブル・rowId・カラム名の属性値を更新
  Future<bool> updateFeatureAttribute(
    String tableName,
    int rowId,
    String attributeName,
    dynamic newValue,
  ) => _features.updateFeatureAttribute(
    tableName,
    rowId,
    attributeName,
    newValue,
  );

  /// 複数の属性値を一括更新
  Future<bool> updateFeatureAttributes(
    String tableName,
    int rowId,
    Map<String, dynamic> attributes,
  ) => _features.updateFeatureAttributes(tableName, rowId, attributes);

  // ============================================================
  // バッチ操作（FeatureRepositoryに委譲）
  // ============================================================

  /// バッチ処理でポイントを高速追加
  Future<List<int>> addPointsBatch(
    String tableName,
    List<Map<String, dynamic>> pointData,
  ) => _features.addPointsBatch(tableName, pointData);

  /// バッチ処理でラインを高速追加
  Future<List<int>> addLinesBatch(
    String tableName,
    List<Map<String, dynamic>> lineData,
  ) => _features.addLinesBatch(tableName, lineData);

  /// バッチ処理でポリゴンを高速追加
  Future<List<int>> addPolygonsBatch(
    String tableName,
    List<Map<String, dynamic>> polygonData,
  ) => _features.addPolygonsBatch(tableName, polygonData);

  /// WHERE句でフィルタしたフィーチャのrowIdリストを取得
  Future<List<int>> getFilteredFeatureIds(
    String tableName,
    String whereClause,
  ) => _features.getFilteredFeatureIds(tableName, whereClause);

  /// WHERE句にマッチするフィーチャ数を取得
  Future<int> countFilteredFeatures(String tableName, String whereClause) =>
      _features.countFilteredFeatures(tableName, whereClause);

  /// WHERE句でフィルタしたフィーチャを別レイヤに複製
  Future<int> duplicateFilteredFeatures(
    String sourceTable,
    String targetTable,
    String whereClause,
  ) => _features.duplicateFilteredFeatures(
    sourceTable,
    targetTable,
    whereClause,
  );

  /// レイヤー間でフィーチャをコピー
  Future<int> copyFeaturesBetweenLayers(
    String sourceTable,
    String targetTable,
  ) => _features.copyFeaturesBetweenLayers(sourceTable, targetTable);

  /// フィーチャを完全な属性テーブルとして追加
  Future<int?> addFeatureWithAttributes(
    String tableName,
    Uint8List geometry,
    Map<String, dynamic> attributes,
  ) => _features.addFeatureWithAttributes(tableName, geometry, attributes);

  // ============================================================
  // フィールド計算機
  // ============================================================

  /// SQL式でカラムの値を一括更新
  Future<int> updateColumnWithExpression(
    String tableName,
    String targetColumn,
    String expression,
  ) async {
    final db = await _connection.getDatabase();
    final sanitizedCol = _schema.sanitizeColumnName(targetColumn);
    if (sanitizedCol.isEmpty) {
      throw Exception(t.services.invalidColumnName(name: targetColumn));
    }

    final result = await db.rawUpdate(
      'UPDATE "$tableName" SET "$sanitizedCol" = $expression',
    );
    return result;
  }

  // ============================================================
  // スキーマ変更（カラム削除・リネーム）
  // ============================================================

  /// カラムをリネーム
  Future<void> renameColumn(
    String tableName,
    String oldName,
    String newName,
  ) async {
    final db = await _connection.getDatabase();
    final sanitizedNew = _schema.sanitizeColumnName(newName);
    if (sanitizedNew.isEmpty) {
      throw Exception(t.services.invalidColumnName(name: newName));
    }
    await db.execute(
      'ALTER TABLE "$tableName" RENAME COLUMN "$oldName" TO "$sanitizedNew"',
    );
    _schema.clearPrimaryKeyCache();
  }

  /// カラムを削除
  Future<void> dropColumn(String tableName, String columnName) async {
    final db = await _connection.getDatabase();
    await db.execute('ALTER TABLE "$tableName" DROP COLUMN "$columnName"');
    _schema.clearPrimaryKeyCache();
  }

  /// 指定カラムの統計情報を取得
  Future<Map<String, dynamic>> getColumnStatistics(
    String tableName,
    String columnName,
  ) async {
    final db = await _connection.getDatabase();
    final result = await db.rawQuery(
      'SELECT '
      'COUNT("$columnName") as cnt, '
      "SUM(CASE WHEN typeof(\"$columnName\") IN ('integer','real') THEN \"$columnName\" ELSE NULL END) as total, "
      "AVG(CASE WHEN typeof(\"$columnName\") IN ('integer','real') THEN \"$columnName\" ELSE NULL END) as avg_val, "
      'MIN("$columnName") as min_val, '
      'MAX("$columnName") as max_val, '
      'COUNT(DISTINCT "$columnName") as unique_cnt '
      'FROM "$tableName"',
    );

    if (result.isEmpty) return {};
    final row = result.first;
    return {
      'count': row['cnt'] ?? 0,
      'sum': row['total'],
      'avg': row['avg_val'],
      'min': row['min_val'],
      'max': row['max_val'],
      'unique': row['unique_cnt'] ?? 0,
    };
  }

  /// テキスト検索（全カラム横断）。マッチした rowId のリストを返す。
  Future<List<int>> searchText(
    String tableName,
    String searchText,
    List<String> columns,
  ) async {
    if (searchText.isEmpty || columns.isEmpty) return [];
    final db = await _connection.getDatabase();
    final pkColumn = await _schema.getPrimaryKeyColumn(tableName);
    final conditions = columns
        .map((c) => 'CAST("$c" AS TEXT) LIKE ?')
        .join(' OR ');
    final pattern = '%$searchText%';
    final args = List.filled(columns.length, pattern);
    final result = await db.rawQuery(
      'SELECT "$pkColumn" FROM "$tableName" WHERE $conditions',
      args,
    );
    return result.map((r) => r[pkColumn] as int).toList();
  }

  /// テキスト置換（指定カラム内）
  Future<int> replaceText(
    String tableName,
    String columnName,
    String searchText,
    String replaceText,
  ) async {
    if (searchText.isEmpty) return 0;
    final db = await _connection.getDatabase();
    final sanitized = _schema.sanitizeColumnName(columnName);
    if (sanitized.isEmpty) {
      throw Exception(t.services.invalidColumnName(name: columnName));
    }
    final result = await db.rawUpdate(
      'UPDATE "$tableName" SET "$sanitized" = REPLACE(CAST("$sanitized" AS TEXT), ?, ?) '
      'WHERE CAST("$sanitized" AS TEXT) LIKE ?',
      [searchText, replaceText, '%$searchText%'],
    );
    return result;
  }
}
