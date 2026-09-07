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
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';
import 'package:sqflite/sqflite.dart';

import '../../services/coordinate/geometry_reprojector.dart';
import '../../services/coordinate/gpkg_crs_resolver.dart';
import '../../utils/app_logger.dart';
import '../../utils/wkb_utils.dart';
import '../geometry_type.dart';
import 'geopackage_connection.dart';
import 'geopackage_schema.dart';
import 'spatial_index_manager.dart';

/// compute()用パラメータ
class _GeometryParseParams {
  final List<Map<String, dynamic>> rows;
  final GeometryType geomType;

  /// re-projection用: ソースCRSのProjection（nullならWGS84で変換不要）
  final Projection? sourceProjection;

  /// re-projection用: 軸入替が必要か
  final bool needsAxisSwap;
  _GeometryParseParams(
    this.rows,
    this.geomType, {
    this.sourceProjection,
    this.needsAxisSwap = false,
  });
}

/// WKBパース＋メタデータパース＋CRS re-projectionを別Isolateで実行するトップレベル関数
List<Map<String, dynamic>> _parseGeometryBatchInIsolate(
  _GeometryParseParams params,
) {
  for (final row in params.rows) {
    final geom = row['geom'] as Uint8List?;
    if (geom != null) {
      var geometry = parseGpkgGeometry(geom);
      if (geometry != null) {
        // CRS re-projection（非WGS84の場合のみ）
        if (params.sourceProjection != null) {
          geometry = GeometryReprojector.reprojectToWgs84(
            geometry,
            params.sourceProjection!,
            needsAxisSwap: params.needsAxisSwap,
          );
        }
        row['geometry'] = geobaseGeometryToLatLngs(geometry);
      }
    }

    final metadataStr = row['kmaps_metadata'] as String?;
    if (metadataStr != null && metadataStr.isNotEmpty) {
      try {
        row['kmaps_metadata'] = jsonDecode(metadataStr) as Map<String, dynamic>;
      } catch (_) {}
    }
  }
  return params.rows;
}

/// Isolate化する閾値（これ以上のフィーチャ数でcompute()を使用）
const _kIsolateThreshold = 500;

/// フィーチャのCRUD操作を管理するリポジトリクラス
class FeatureRepository {
  final GeoPackageConnection connection;
  final GeoPackageSchema schema;
  final SpatialIndexManager spatialIndex;

  FeatureRepository(this.connection, this.schema, this.spatialIndex);

  /// CRS解決結果キャッシュ（テーブル名→CRS情報）
  final Map<String, GpkgCrsInfo> _crsCache = {};

  /// レイヤのCRS情報を取得（キャッシュ付き）
  Future<GpkgCrsInfo> _getLayerCrs(String tableName) async {
    if (_crsCache.containsKey(tableName)) {
      return _crsCache[tableName]!;
    }
    final db = await connection.getDatabase();
    final crs = await GpkgCrsResolver.instance.resolveLayerCrs(db, tableName);
    _crsCache[tableName] = crs;
    return crs;
  }

  /// CRSキャッシュをクリア
  void clearCrsCache() => _crsCache.clear();

  // ============================================================
  // 書き込み前クリンナップ
  // ============================================================

  /// クリンナップ済みテーブルの記録（1テーブルにつき1回だけ実行）
  final Set<String> _cleanedTables = {};

  /// 書き込み前にテーブルをクリンナップする
  ///
  /// 外部ツール（QGIS/GeoPandas等）が作成したGPKGには
  /// SpatiaLite拡張に依存するトリガーが含まれることがあり、
  /// sqfliteでは実行できない。書き込み前に検出・除去する。
  ///
  /// 将来の前処理もここに追加可能。
  Future<void> _prepareForWrite(String tableName) async {
    if (_cleanedTables.contains(tableName)) return;

    final db = await connection.getDatabase();
    await _removeSpatialiteTriggers(db, tableName);
    _cleanedTables.add(tableName);
  }

  /// SpatiaLite依存のトリガーを検出・除去
  ///
  /// QGIS/GeoPandasが生成するRTree自動更新トリガーは
  /// ST_IsEmpty, ST_MinX等のSpatiaLite関数を使用するが、
  /// sqfliteにはSpatiaLite拡張がないためINSERT/UPDATE時にエラーとなる。
  /// こかげマップは独自のSpatialIndexManagerでrtreeを管理するため、
  /// これらのトリガーは不要。
  Future<void> _removeSpatialiteTriggers(Database db, String tableName) async {
    try {
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
          spatialIndex.qgisInterop.rememberTrigger(name, sql);
          triggersToRemove.add(name);
        }
      }

      if (triggersToRemove.isEmpty) return;

      // トリガーを除去
      for (final name in triggersToRemove) {
        await db.execute('DROP TRIGGER IF EXISTS "$name"');
      }

      AppLogger.debug(
        '[FeatureRepository] 🧹 SpatiaLiteトリガーを除去: '
        '$tableName (${triggersToRemove.length}個: '
        '${triggersToRemove.join(", ")})',
      );
    } catch (e) {
      AppLogger.debug('[FeatureRepository] ⚠️ トリガー除去エラー: $tableName - $e');
    }
  }

  // ============================================================
  // エンベロープ計算（共通）
  // ============================================================

  ({double minX, double minY, double maxX, double maxY})? _calculateEnvelope(
    List<LatLng> coordinates,
  ) {
    if (coordinates.isEmpty) return null;
    double minX = coordinates.first.longitude;
    double maxX = minX;
    double minY = coordinates.first.latitude;
    double maxY = minY;
    for (final pt in coordinates) {
      if (pt.longitude < minX) minX = pt.longitude;
      if (pt.longitude > maxX) maxX = pt.longitude;
      if (pt.latitude < minY) minY = pt.latitude;
      if (pt.latitude > maxY) maxY = pt.latitude;
    }
    return (minX: minX, minY: minY, maxX: maxX, maxY: maxY);
  }

  ({double minX, double minY, double maxX, double maxY})?
  _calculatePolygonEnvelope(List<List<LatLng>> rings) {
    final allPoints = rings.expand((ring) => ring).toList();
    return _calculateEnvelope(allPoints);
  }

  Future<void> _updateSpatialIndex(
    String tableName,
    int rowId,
    ({double minX, double minY, double maxX, double maxY}) envelope,
  ) async {
    await spatialIndex.updateLayerEnvelope(
      tableName,
      envelope.minX,
      envelope.minY,
      envelope.maxX,
      envelope.maxY,
    );
    await spatialIndex.updateRTreeIndex(
      tableName,
      rowId,
      envelope.minX,
      envelope.minY,
      envelope.maxX,
      envelope.maxY,
    );
  }

  // ============================================================
  // 属性ビルダー（共通）
  // ============================================================

  Future<Map<String, dynamic>> _buildSafeAttributes(
    String tableName, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    final db = await connection.getDatabase();
    final columns = await db.rawQuery('PRAGMA table_info("$tableName");');
    final columnNames = columns.map((row) => row['name'] as String).toSet();

    final attributes = <String, dynamic>{};
    if (columnNames.contains('name')) attributes['name'] = name;
    if (columnNames.contains('description')) {
      attributes['description'] = description;
    }
    if (columnNames.contains('kmaps_metadata') && metadata != null) {
      attributes['kmaps_metadata'] = jsonEncode(metadata);
    }
    return attributes;
  }

  Future<bool> _updateFeatureGeometry(
    String tableName,
    int id,
    Uint8List wkb, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final db = await connection.getDatabase();
      final attributes = await _buildSafeAttributes(
        tableName,
        name: name,
        description: description,
        metadata: metadata,
      );

      final updateColumns = <String>['geom = ?'];
      final updateValues = <dynamic>[wkb];

      for (final entry in attributes.entries) {
        updateColumns.add('"${entry.key}" = ?');
        updateValues.add(entry.value);
      }

      updateValues.add(id);
      final whereClause = await schema.buildWhereClause(tableName);
      final sql =
          'UPDATE "$tableName" SET ${updateColumns.join(', ')} WHERE $whereClause';
      final affectedRows = await db.rawUpdate(sql, updateValues);
      return affectedRows > 0;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] _updateFeatureGeometry: エラー発生 - $e');
      return false;
    }
  }

  // ============================================================
  // WKBバリデーション（共通）
  // ============================================================

  void _validateAndLogWkb(Uint8List wkb, String context) {
    if (!validateWkbData(wkb)) {
      AppLogger.debug('[FeatureRepository] 警告: 無効なWKBデータが生成されました');
      debugWkbData(wkb, context);
    }
  }

  // ============================================================
  // geobase Geometry 構築ヘルパー
  // ============================================================

  geo.Point _buildGeoPoint(LatLng pt) =>
      geo.Point(geo.Geographic(lon: pt.longitude, lat: pt.latitude));

  geo.MultiLineString _buildGeoMultiLineString(List<LatLng> line) =>
      geo.MultiLineString.from([
        line.map((p) => geo.Geographic(lon: p.longitude, lat: p.latitude)),
      ]);

  geo.MultiPolygon _buildGeoMultiPolygon(List<List<LatLng>> rings) => geo
      .MultiPolygon.from([
    rings.map(
      (ring) =>
          ring.map((p) => geo.Geographic(lon: p.longitude, lat: p.latitude)),
    ),
  ]);

  // ============================================================
  // フィーチャ追加（WithAttributes版）
  // ============================================================

  Future<int?> addPointWithAttributes(
    String tableName,
    LatLng point,
    Map<String, dynamic> attributes,
  ) async {
    try {
      await _prepareForWrite(tableName);
      final db = await connection.getDatabase();
      final crs = await _getLayerCrs(tableName);
      final geom = _buildGeoPoint(point);

      // 非WGS84の場合はWGS84→ソースCRSに逆変換
      final targetGeom =
          (!crs.isWgs84 && crs.projection != null)
              ? GeometryReprojector.reprojectFromWgs84(
                geom,
                crs.projection!,
                needsAxisSwap: crs.needsAxisSwap,
              )
              : geom;

      if (!crs.isWgs84 && targetGeom is geo.Point) {
        AppLogger.debug(
          '[FeatureRepository] CRS逆変換: '
          'WGS84(${point.longitude}, ${point.latitude}) → '
          '${crs.epsgCode}(${targetGeom.position.x}, ${targetGeom.position.y})',
        );
      }

      final wkb = createGpkgWkb(targetGeom, srsId: crs.srsId);
      _validateAndLogWkb(
        wkb,
        'addPointWithAttributes - ${point.latitude}, ${point.longitude}',
      );

      final data = <String, dynamic>{'geom': wkb, ...attributes};
      final rowId = await db.insert(tableName, data);

      final env = _calculateEnvelope([point]);
      if (env != null) await _updateSpatialIndex(tableName, rowId, env);

      return rowId;
    } catch (e) {
      AppLogger.debug(
        '[ERROR] FeatureRepository: addPointWithAttributes failed: $e',
      );
      return null;
    }
  }

  Future<int?> addLineWithAttributes(
    String tableName,
    List<LatLng> line,
    Map<String, dynamic> attributes,
  ) async {
    try {
      await _prepareForWrite(tableName);
      final db = await connection.getDatabase();
      final crs = await _getLayerCrs(tableName);
      final geom = _buildGeoMultiLineString(line);

      final targetGeom =
          (!crs.isWgs84 && crs.projection != null)
              ? GeometryReprojector.reprojectFromWgs84(
                geom,
                crs.projection!,
                needsAxisSwap: crs.needsAxisSwap,
              )
              : geom;

      final wkb = createGpkgWkb(targetGeom, srsId: crs.srsId);

      final data = <String, dynamic>{'geom': wkb, ...attributes};
      final rowId = await db.insert(tableName, data);

      final env = _calculateEnvelope(line);
      if (env != null) await _updateSpatialIndex(tableName, rowId, env);

      return rowId;
    } catch (e) {
      AppLogger.debug(
        '[ERROR] FeatureRepository: addLineWithAttributes failed: $e',
      );
      return null;
    }
  }

  Future<int?> addPolygonWithAttributes(
    String tableName,
    List<List<LatLng>> polygon,
    Map<String, dynamic> attributes,
  ) async {
    try {
      await _prepareForWrite(tableName);
      final db = await connection.getDatabase();
      final crs = await _getLayerCrs(tableName);
      final geom = _buildGeoMultiPolygon(polygon);

      final targetGeom =
          (!crs.isWgs84 && crs.projection != null)
              ? GeometryReprojector.reprojectFromWgs84(
                geom,
                crs.projection!,
                needsAxisSwap: crs.needsAxisSwap,
              )
              : geom;

      final wkb = createGpkgWkb(targetGeom, srsId: crs.srsId);

      final data = <String, dynamic>{'geom': wkb, ...attributes};
      final rowId = await db.insert(tableName, data);

      final env = _calculatePolygonEnvelope(polygon);
      if (env != null) await _updateSpatialIndex(tableName, rowId, env);

      return rowId;
    } catch (e) {
      AppLogger.debug(
        '[ERROR] FeatureRepository: addPolygonWithAttributes failed: $e',
      );
      return null;
    }
  }

  // ============================================================
  // フィーチャ追加（簡易版）
  // ============================================================

  Future<int?> addPoint(
    String tableName,
    LatLng pt, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final attributes = await _buildSafeAttributes(
        tableName,
        name: name,
        description: description,
        metadata: metadata,
      );
      return await addPointWithAttributes(tableName, pt, attributes);
    } catch (e) {
      AppLogger.debug('[ERROR] FeatureRepository: addPoint failed: $e');
      return null;
    }
  }

  Future<int?> addLine(
    String tableName,
    List<LatLng> line, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    final attributes = <String, dynamic>{
      'name': name,
      'description': description,
    };
    if (metadata != null) attributes['kmaps_metadata'] = jsonEncode(metadata);
    return addLineWithAttributes(tableName, line, attributes);
  }

  Future<int?> addPolygon(
    String tableName,
    List<List<LatLng>> rings, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    final attributes = <String, dynamic>{
      'name': name,
      'description': description,
    };
    if (metadata != null) attributes['kmaps_metadata'] = jsonEncode(metadata);
    return addPolygonWithAttributes(tableName, rings, attributes);
  }

  // ============================================================
  // フィーチャ更新
  // ============================================================

  Future<bool> updatePoint(
    String tableName,
    int id,
    LatLng pt, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    await _prepareForWrite(tableName);
    final crs = await _getLayerCrs(tableName);
    final geom = _buildGeoPoint(pt);

    final targetGeom =
        (!crs.isWgs84 && crs.projection != null)
            ? GeometryReprojector.reprojectFromWgs84(
              geom,
              crs.projection!,
              needsAxisSwap: crs.needsAxisSwap,
            )
            : geom;

    final wkb = createGpkgWkb(targetGeom, srsId: crs.srsId);
    _validateAndLogWkb(wkb, 'updatePoint - ${pt.latitude}, ${pt.longitude}');
    return _updateFeatureGeometry(
      tableName,
      id,
      wkb,
      name: name,
      description: description,
      metadata: metadata,
    );
  }

  Future<bool> updateLine(
    String tableName,
    int id,
    List<LatLng> line, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    await _prepareForWrite(tableName);
    final crs = await _getLayerCrs(tableName);
    final geom = _buildGeoMultiLineString(line);

    final targetGeom =
        (!crs.isWgs84 && crs.projection != null)
            ? GeometryReprojector.reprojectFromWgs84(
              geom,
              crs.projection!,
              needsAxisSwap: crs.needsAxisSwap,
            )
            : geom;

    final wkb = createGpkgWkb(targetGeom, srsId: crs.srsId);
    return _updateFeatureGeometry(
      tableName,
      id,
      wkb,
      name: name,
      description: description,
      metadata: metadata,
    );
  }

  Future<bool> updatePolygon(
    String tableName,
    int id,
    List<List<LatLng>> rings, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) async {
    await _prepareForWrite(tableName);
    final crs = await _getLayerCrs(tableName);
    final geom = _buildGeoMultiPolygon(rings);

    final targetGeom =
        (!crs.isWgs84 && crs.projection != null)
            ? GeometryReprojector.reprojectFromWgs84(
              geom,
              crs.projection!,
              needsAxisSwap: crs.needsAxisSwap,
            )
            : geom;

    final wkb = createGpkgWkb(targetGeom, srsId: crs.srsId);
    return _updateFeatureGeometry(
      tableName,
      id,
      wkb,
      name: name,
      description: description,
      metadata: metadata,
    );
  }

  // ============================================================
  // 共通 Feature 操作
  // ============================================================

  /// 行を削除する。実際に消えた行があれば true
  ///
  /// ⚠ 0 件削除（主キー名の取り違え等）を成功扱いにしない。以前は戻り値が無く、
  ///   UI から消えたのに再起動で復活する事故を誰も検知できなかった
  Future<bool> removeFeature(String tableName, int id) async {
    try {
      await _prepareForWrite(tableName);
      final db = await connection.getDatabase();
      final whereClause = await schema.buildWhereClause(tableName);
      final deleted = await db.delete(tableName, where: whereClause, whereArgs: [id]);
      await spatialIndex.removeFromRTreeIndex(tableName, id);
      if (deleted == 0) {
        AppLogger.debug('[FeatureRepository] removeFeature: 0件削除 ($tableName id=$id where=$whereClause)');
      }
      return deleted > 0;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] removeFeature: エラー発生 - $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> getFeature(
    String tableName,
    int rowId,
    GeometryType? geomType,
  ) async {
    try {
      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);

      final selectClause =
          pkColumn == 'rowid'
              ? 'SELECT rowid, * FROM "$tableName" WHERE rowid = ?'
              : 'SELECT * FROM "$tableName" WHERE "$pkColumn" = ?';

      final rows = await db.rawQuery(selectClause, [rowId]);
      if (rows.isEmpty) return null;

      final row = Map<String, dynamic>.from(rows.first);
      _normalizePrimaryKey(row, pkColumn);

      final geom = row['geom'] as Uint8List?;
      if (geom != null && geomType != null) {
        var geometry = parseGpkgGeometry(geom);
        if (geometry != null) {
          // 非WGS84の場合はre-projection
          final crs = await _getLayerCrs(tableName);
          if (!crs.isWgs84 && crs.projection != null) {
            geometry = GeometryReprojector.reprojectToWgs84(
              geometry,
              crs.projection!,
              needsAxisSwap: crs.needsAxisSwap,
            );
          }
          row['geometry'] = geobaseGeometryToLatLngs(geometry);
        }
      }

      _parseMetadata(row);
      return row;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] getFeature: エラー発生 - $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getFeatures(String tableName) async {
    try {
      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);

      final selectClause =
          pkColumn == 'rowid'
              ? 'SELECT rowid, * FROM "$tableName"'
              : 'SELECT * FROM "$tableName"';

      final rows = await db.rawQuery(selectClause);
      return rows.map((row) {
        final normalizedRow = Map<String, dynamic>.from(row);
        _normalizePrimaryKey(normalizedRow, pkColumn);
        return normalizedRow;
      }).toList();
    } catch (e) {
      AppLogger.debug('[FeatureRepository] getFeatures: エラー発生 - $e');
      return [];
    }
  }

  /// 全フィーチャをジオメトリパース済みで一括取得
  /// 非WGS84のレイヤはWGS84にre-projectionして返す
  /// [where] は SQL の WHERE 句（QGIS の subset string と同じ書き方）。
  /// null / 空なら絞り込み無し。View のフィルタがここに来る。
  ///
  /// > [!WARNING] [where] は文字列としてSQLに埋め込まれる
  /// > バインド変数にはできない（条件式そのものだから）。ユーザーが書いた
  /// > フィルタをそのまま通す QGIS と同じ設計だが、**`.kmeta.json` は
  /// > Drive経由で他人から届きうる**。文の切り替え（`;`）だけは弾いておく。
  /// > それ以上は SQLite の `SELECT` の外に出られないので許す。
  Future<List<Map<String, dynamic>>> getFeaturesWithGeometry(
    String tableName,
    GeometryType? geomType, {
    String? where,
  }) async {
    try {
      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);

      final selectClause =
          pkColumn == 'rowid'
              ? 'SELECT rowid, * FROM "$tableName"'
              : 'SELECT * FROM "$tableName"';

      final sql = StringBuffer(selectClause);
      final safeWhere = sanitizeFilter(where);
      if (safeWhere != null) sql.write(' WHERE $safeWhere');

      final rows = await db.rawQuery(sql.toString());

      final mutableRows = <Map<String, dynamic>>[];
      for (final row in rows) {
        final normalizedRow = Map<String, dynamic>.from(row);
        _normalizePrimaryKey(normalizedRow, pkColumn);
        if (normalizedRow['id'] == null) continue;
        mutableRows.add(normalizedRow);
      }

      if (geomType == null) return mutableRows;

      // CRS情報を取得
      final crs = await _getLayerCrs(tableName);
      final needsReproject = !crs.isWgs84 && crs.projection != null;

      if (needsReproject) {
        AppLogger.debug(
          '[FeatureRepository] CRS re-projection: $tableName (${crs.epsgCode}→WGS84, ${mutableRows.length}件)',
        );
      }

      if (mutableRows.length >= _kIsolateThreshold) {
        AppLogger.debug(
          '[FeatureRepository] Isolateパース: $tableName (${mutableRows.length}件)',
        );
        return await compute(
          _parseGeometryBatchInIsolate,
          _GeometryParseParams(
            mutableRows,
            geomType,
            sourceProjection: needsReproject ? crs.projection : null,
            needsAxisSwap: crs.needsAxisSwap,
          ),
        );
      }

      for (final row in mutableRows) {
        final geom = row['geom'] as Uint8List?;
        if (geom != null) {
          var geometry = parseGpkgGeometry(geom);
          if (geometry != null) {
            // 非WGS84の場合はre-projection
            if (needsReproject) {
              geometry = GeometryReprojector.reprojectToWgs84(
                geometry,
                crs.projection!,
                needsAxisSwap: crs.needsAxisSwap,
              );
            }
            row['geometry'] = geobaseGeometryToLatLngs(geometry);
          }
        }
        _parseMetadata(row);
      }

      return mutableRows;
    } catch (e) {
      AppLogger.debug(
        '[FeatureRepository] getFeaturesWithGeometry: エラー発生 - $e',
      );
      return [];
    }
  }

  /// [where] に当てはまるフィーチャの主キーだけを返す。
  ///
  /// View ごとの「どのフィーチャが自分のものか」を知るために使う。
  /// ジオメトリを読まないので、フィーチャ本体の読み込みに比べてずっと軽い。
  Future<Set<int>> getFeatureIds(String tableName, {String? where}) async {
    try {
      final safeWhere = sanitizeFilter(where);
      if (safeWhere == null) return const {};

      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);
      final column = pkColumn == 'rowid' ? 'rowid' : '"$pkColumn"';

      final rows = await db.rawQuery(
        'SELECT $column AS id FROM "$tableName" WHERE $safeWhere',
      );
      return {
        for (final row in rows)
          if (row['id'] is int) row['id'] as int,
      };
    } catch (e) {
      AppLogger.debug('[FeatureRepository] getFeatureIds: エラー発生 - $e');
      return const {};
    }
  }

  /// フィルタ文字列を検査する。使えないものは null（＝絞り込み無し）にする。
  ///
  /// 弾くのは「文を切り替えられる形」だけ。式として書かれている限りは通す。
  static String? sanitizeFilter(String? filter) {
    final trimmed = filter?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.contains(';')) {
      AppLogger.debug('[FeatureRepository] フィルタに ";" があるので無視: $trimmed');
      return null;
    }
    return trimmed;
  }

  Future<List<Map<String, dynamic>>> getAllFeatureAttributes(
    String tableName, {
    List<String>? columns,
  }) async {
    try {
      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);

      final columnList = columns?.join(', ') ?? '*';
      final orderByClause =
          pkColumn == 'rowid' ? 'ORDER BY rowid' : 'ORDER BY "$pkColumn"';

      return await db.rawQuery(
        'SELECT $columnList FROM "$tableName" $orderByClause',
      );
    } catch (e) {
      AppLogger.debug('[FeatureRepository] getAllFeatureAttributes エラー発生 - $e');
      return [];
    }
  }

  // ============================================================
  // 属性操作
  // ============================================================

  Future<dynamic> getFeatureAttribute(
    String tableName,
    int rowId,
    String attributeName,
  ) async {
    try {
      final db = await connection.getDatabase();
      final whereClause = await schema.buildWhereClause(tableName);
      final result = await db.query(
        tableName,
        where: whereClause,
        whereArgs: [rowId],
      );
      return result.isNotEmpty ? result.first[attributeName] : null;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] getFeatureAttribute: エラー発生 - $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getFeatureAttributes(
    String tableName,
    int rowId,
  ) async {
    try {
      final db = await connection.getDatabase();
      final whereClause = await schema.buildWhereClause(tableName);
      final result = await db.query(
        tableName,
        where: whereClause,
        whereArgs: [rowId],
      );
      return result.isNotEmpty ? Map<String, dynamic>.from(result.first) : null;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] getFeatureAttributes: エラー発生 - $e');
      return null;
    }
  }

  Future<bool> updateFeatureAttribute(
    String tableName,
    int rowId,
    String attributeName,
    dynamic newValue,
  ) async {
    try {
      final db = await connection.getDatabase();
      final whereClause = await schema.buildWhereClause(tableName);
      final rowsUpdated = await db.rawUpdate(
        'UPDATE "$tableName" SET "$attributeName" = ? WHERE $whereClause',
        [newValue, rowId],
      );
      return rowsUpdated > 0;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] updateFeatureAttribute: エラー発生 - $e');
      return false;
    }
  }

  Future<bool> updateFeatureAttributes(
    String tableName,
    int rowId,
    Map<String, dynamic> attributes,
  ) async {
    try {
      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);
      final existingColumns =
          (await schema.getColumnNames(tableName, getAll: true)).toSet();

      final filteredAttributes = <String, dynamic>{};
      for (final entry in attributes.entries) {
        final key = entry.key;
        final value = entry.value;

        if (_isReservedColumn(key, pkColumn)) continue;
        if (!existingColumns.contains(key)) {
          AppLogger.debug('[FeatureRepository] カラム未存在のためスキップ: $key');
          continue;
        }
        if (_isSupportedType(value)) {
          filteredAttributes[key] = value;
        } else {
          AppLogger.debug(
            '[FeatureRepository] サポートされていない型: $key = ${value.runtimeType}',
          );
        }
      }

      if (filteredAttributes.isEmpty) return true;

      final columnAssignments = filteredAttributes.keys
          .map((key) => '"$key" = ?')
          .join(', ');
      final values = [...filteredAttributes.values, rowId];
      final whereClause = await schema.buildWhereClause(tableName);
      final sql =
          'UPDATE "$tableName" SET $columnAssignments WHERE $whereClause';
      final rowsUpdated = await db.rawUpdate(sql, values);
      return rowsUpdated > 0;
    } catch (e) {
      AppLogger.debug(
        '[ERROR] FeatureRepository: updateFeatureAttributes failed: $e',
      );
      return false;
    }
  }

  // ============================================================
  // バッチ操作
  // ============================================================

  Future<List<int>> _addGeometryBatch<T>(
    String tableName,
    List<Map<String, dynamic>> dataList,
    String geometryKey,
    Uint8List Function(T) createWkb,
  ) async {
    final reservedColumns = {
      'fid',
      'geom',
      'id',
      'rowid',
      'geometry',
      geometryKey,
    };

    try {
      await _prepareForWrite(tableName);
      final db = await connection.getDatabase();
      final batch = db.batch();
      final insertedIds = <int>[];

      final tableColumns = await schema.getTableColumns(tableName);
      final tableColumnSet = tableColumns.map((c) => c.toLowerCase()).toSet();

      for (final data in dataList) {
        final geometry = data[geometryKey] as T;
        final wkb = createWkb(geometry);
        final insertData = <String, dynamic>{'geom': wkb};

        data.forEach((key, value) {
          if (!reservedColumns.contains(key.toLowerCase())) {
            final sanitizedKey = schema.sanitizeColumnName(key);
            if (sanitizedKey.isNotEmpty &&
                tableColumnSet.contains(sanitizedKey.toLowerCase())) {
              insertData[sanitizedKey] = value;
            }
          }
        });

        final columns = insertData.keys.toList();
        final placeholders = List.filled(columns.length, '?').join(', ');
        final columnNames = columns.map((c) => '"$c"').join(', ');
        final values = columns.map((c) => insertData[c]).toList();

        batch.rawInsert(
          'INSERT INTO "$tableName" ($columnNames) VALUES ($placeholders)',
          values,
        );
      }

      final results = await batch.commit(noResult: false);
      for (final result in results) {
        if (result is int) insertedIds.add(result);
      }
      return insertedIds;
    } catch (e) {
      AppLogger.debug('[ERROR] FeatureRepository._addGeometryBatch<$T>: $e');
      return [];
    }
  }

  Future<List<int>> addPointsBatch(
    String tableName,
    List<Map<String, dynamic>> pointData,
  ) => _addGeometryBatch<LatLng>(
    tableName,
    pointData,
    'point',
    (point) => createGpkgWkb(_buildGeoPoint(point)),
  );

  Future<List<int>> addLinesBatch(
    String tableName,
    List<Map<String, dynamic>> lineData,
  ) => _addGeometryBatch<List<LatLng>>(
    tableName,
    lineData,
    'line',
    (line) => createGpkgWkb(_buildGeoMultiLineString(line)),
  );

  Future<List<int>> addPolygonsBatch(
    String tableName,
    List<Map<String, dynamic>> polygonData,
  ) => _addGeometryBatch<List<List<LatLng>>>(
    tableName,
    polygonData,
    'rings',
    (rings) => createGpkgWkb(_buildGeoMultiPolygon(rings)),
  );

  /// WHERE句でフィルタしたフィーチャのrowIdリストを取得
  Future<List<int>> getFilteredFeatureIds(
    String tableName,
    String whereClause,
  ) async {
    try {
      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);

      final selectClause =
          pkColumn == 'rowid'
              ? 'SELECT rowid FROM "$tableName" WHERE $whereClause'
              : 'SELECT "$pkColumn" FROM "$tableName" WHERE $whereClause';

      final rows = await db.rawQuery(selectClause);
      return rows
          .map((row) {
            final val = row.values.first;
            return val is int ? val : 0;
          })
          .where((id) => id != 0)
          .toList();
    } catch (e) {
      AppLogger.debug('[FeatureRepository] getFilteredFeatureIds: エラー発生 - $e');
      return [];
    }
  }

  Future<int> countFilteredFeatures(
    String tableName,
    String whereClause,
  ) async {
    try {
      final db = await connection.getDatabase();
      final result = await db.rawQuery(
        'SELECT COUNT(*) as cnt FROM "$tableName" WHERE $whereClause',
      );
      return (result.first['cnt'] as int?) ?? 0;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] countFilteredFeatures: エラー発生 - $e');
      return -1;
    }
  }

  Future<int> duplicateFilteredFeatures(
    String sourceTable,
    String targetTable,
    String whereClause,
  ) async {
    try {
      final db = await connection.getDatabase();
      final sourceColumns = await schema.getTableColumns(sourceTable);
      final columnsToInsert =
          sourceColumns
              .where((c) => c.toLowerCase() != 'id' && c.toLowerCase() != 'fid')
              .toList();

      if (columnsToInsert.isEmpty) return 0;

      final columnList = columnsToInsert.map((c) => '"$c"').join(', ');
      await db.execute('''
        INSERT INTO "$targetTable" ($columnList)
        SELECT $columnList FROM "$sourceTable"
        WHERE $whereClause
      ''');

      final countResult = await db.rawQuery('SELECT changes() as count');
      final copiedCount = (countResult.first['count'] as int?) ?? 0;
      AppLogger.debug(
        '[FeatureRepository] duplicateFilteredFeatures: '
        '$sourceTable -> $targetTable ($copiedCount件, WHERE: $whereClause)',
      );
      return copiedCount;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] duplicateFilteredFeatures エラー: $e');
      return 0;
    }
  }

  Future<int> copyFeaturesBetweenLayers(
    String sourceTable,
    String targetTable,
  ) async {
    try {
      final db = await connection.getDatabase();
      final sourceColumns = await schema.getTableColumns(sourceTable);
      final columnsToInsert =
          sourceColumns
              .where((c) => c.toLowerCase() != 'id' && c.toLowerCase() != 'fid')
              .toList();

      if (columnsToInsert.isEmpty) {
        AppLogger.debug('[FeatureRepository] コピー可能なカラムがありません');
        return 0;
      }

      final columnList = columnsToInsert.map((c) => '"$c"').join(', ');
      await db.execute('''
        INSERT INTO "$targetTable" ($columnList)
        SELECT $columnList FROM "$sourceTable"
      ''');

      final countResult = await db.rawQuery('SELECT changes() as count');
      final copiedCount = (countResult.first['count'] as int?) ?? 0;
      AppLogger.debug(
        '[FeatureRepository] フィーチャコピー完了: $sourceTable -> $targetTable ($copiedCount件)',
      );
      return copiedCount;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] copyFeaturesBetweenLayers エラー: $e');
      return 0;
    }
  }

  Future<int?> addFeatureWithAttributes(
    String tableName,
    Uint8List geometry,
    Map<String, dynamic> attributes,
  ) async {
    try {
      final db = await connection.getDatabase();
      final data = <String, dynamic>{'geom': geometry, ...attributes};
      return await db.insert(tableName, data);
    } catch (e) {
      AppLogger.debug(
        '[FeatureRepository] addFeatureWithAttributes エラー発生 - $e',
      );
      return null;
    }
  }

  // ============================================================
  // プライベートヘルパー
  // ============================================================

  void _normalizePrimaryKey(Map<String, dynamic> row, String pkColumn) {
    if (pkColumn != 'id') {
      if (row.containsKey(pkColumn)) {
        row['id'] = row[pkColumn];
      } else {
        AppLogger.debug(
          '[FeatureRepository] 警告: PRIMARY KEYカラム "$pkColumn" が見つかりません',
        );
        row['id'] = 0;
      }
    }
  }

  void _parseMetadata(Map<String, dynamic> row) {
    final metadataStr = row['kmaps_metadata'] as String?;
    if (metadataStr != null && metadataStr.isNotEmpty) {
      try {
        row['kmaps_metadata'] = jsonDecode(metadataStr) as Map<String, dynamic>;
      } catch (e) {
        AppLogger.debug('[FeatureRepository] メタデータのJSONパースエラー - $e');
      }
    }
  }

  bool _isReservedColumn(String key, String pkColumn) =>
      key == 'geometry' || key == 'geom' || key == pkColumn || key == 'id';

  bool _isSupportedType(dynamic value) =>
      value == null ||
      value is String ||
      value is num ||
      value is bool ||
      value is Uint8List;
}
