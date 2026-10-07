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
import 'sql_identifier.dart';

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
  /// 1 行の 1 列にそのまま値を書く（同期の衝突を相手の値に戻すとき）。
  /// 書く前に ST_ トリガーを外す（[_prepareForWrite]）。値の型は呼び手が合わせる（ジオメトリは GPKG の blob）
  Future<bool> setColumnValue(
    String tableName,
    String pkColumn,
    Object pk,
    String column,
    Object? value,
  ) async {
    await _prepareForWrite(tableName);
    final db = await connection.getDatabase();
    String q(String i) => '"${i.replaceAll('"', '""')}"';
    final n = await db.rawUpdate(
      'UPDATE ${q(tableName)} SET ${q(column)} = ? WHERE ${q(pkColumn)} = ?',
      [value, pk],
    );
    return n > 0;
  }

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
        await db.execute('DROP TRIGGER IF EXISTS ${quoteIdent(name)}');
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
    final columns = await db.rawQuery('PRAGMA table_info(${quoteIdent(tableName)});');
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
        updateColumns.add('${quoteIdent(entry.key)} = ?');
        updateValues.add(entry.value);
      }

      updateValues.add(id);
      final whereClause = await schema.buildWhereClause(tableName);
      final sql =
          'UPDATE ${quoteIdent(tableName)} SET ${updateColumns.join(', ')} WHERE $whereClause';
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
  // フィーチャ追加・更新
  // ============================================================

  /// WGS84 の形をレイヤの CRS に移して GeoPackage の WKB にする
  Future<Uint8List> _toLayerWkb(String tableName, geo.Geometry geom) async =>
      _encodeInCrs(await _getLayerCrs(tableName), geom);

  Uint8List _encodeInCrs(GpkgCrsInfo crs, geo.Geometry geom) {
    final target = (!crs.isWgs84 && crs.projection != null)
        ? GeometryReprojector.reprojectFromWgs84(
            geom,
            crs.projection!,
            needsAxisSwap: crs.needsAxisSwap,
          )
        : geom;
    final wkb = createGpkgWkb(target, srsId: crs.srsId);
    _validateAndLogWkb(wkb, '${crs.epsgCode} ${geom.geomType}');
    return wkb;
  }

  Future<int?> _addWithAttributes(
    String tableName,
    geo.Geometry geom,
    List<LatLng> points,
    Map<String, dynamic> attributes,
  ) async {
    try {
      await _prepareForWrite(tableName);
      final db = await connection.getDatabase();
      final wkb = await _toLayerWkb(tableName, geom);
      final rowId = await _insertRow(db, tableName, {'geom': wkb, ...attributes});
      final env = _calculateEnvelope(points);
      if (env != null) await _updateSpatialIndex(tableName, rowId, env);
      return rowId;
    } catch (e) {
      AppLogger.debug('[ERROR] FeatureRepository: add ${geom.geomType} failed: $e');
      return null;
    }
  }

  Future<int?> addPointWithAttributes(
    String tableName,
    LatLng point,
    Map<String, dynamic> attributes,
  ) => _addWithAttributes(tableName, _buildGeoPoint(point), [point], attributes);

  Future<int?> addLineWithAttributes(
    String tableName,
    List<LatLng> line,
    Map<String, dynamic> attributes,
  ) => _addWithAttributes(
    tableName,
    _buildGeoMultiLineString(line),
    line,
    attributes,
  );

  Future<int?> addPolygonWithAttributes(
    String tableName,
    List<List<LatLng>> polygon,
    Map<String, dynamic> attributes,
  ) => _addWithAttributes(
    tableName,
    _buildGeoMultiPolygon(polygon),
    [for (final ring in polygon) ...ring],
    attributes,
  );

  /// name・description・kmaps_metadata はレイヤに列があるものだけ書く
  Future<int?> _addSimple(
    String tableName,
    geo.Geometry geom,
    List<LatLng> points, {
    required String name,
    required String description,
    required Map<String, dynamic>? metadata,
  }) async {
    try {
      final attributes = await _buildSafeAttributes(
        tableName,
        name: name,
        description: description,
        metadata: metadata,
      );
      return await _addWithAttributes(tableName, geom, points, attributes);
    } catch (e) {
      AppLogger.debug('[ERROR] FeatureRepository: add ${geom.geomType} failed: $e');
      return null;
    }
  }

  Future<int?> addPoint(
    String tableName,
    LatLng pt, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _addSimple(
    tableName,
    _buildGeoPoint(pt),
    [pt],
    name: name,
    description: description,
    metadata: metadata,
  );

  Future<int?> addLine(
    String tableName,
    List<LatLng> line, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _addSimple(
    tableName,
    _buildGeoMultiLineString(line),
    line,
    name: name,
    description: description,
    metadata: metadata,
  );

  Future<int?> addPolygon(
    String tableName,
    List<List<LatLng>> rings, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _addSimple(
    tableName,
    _buildGeoMultiPolygon(rings),
    [for (final ring in rings) ...ring],
    name: name,
    description: description,
    metadata: metadata,
  );

  Future<bool> _update(
    String tableName,
    int id,
    geo.Geometry geom, {
    required String name,
    required String description,
    required Map<String, dynamic>? metadata,
  }) async {
    await _prepareForWrite(tableName);
    return _updateFeatureGeometry(
      tableName,
      id,
      await _toLayerWkb(tableName, geom),
      name: name,
      description: description,
      metadata: metadata,
    );
  }

  Future<bool> updatePoint(
    String tableName,
    int id,
    LatLng pt, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _update(
    tableName,
    id,
    _buildGeoPoint(pt),
    name: name,
    description: description,
    metadata: metadata,
  );

  Future<bool> updateLine(
    String tableName,
    int id,
    List<LatLng> line, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _update(
    tableName,
    id,
    _buildGeoMultiLineString(line),
    name: name,
    description: description,
    metadata: metadata,
  );

  Future<bool> updatePolygon(
    String tableName,
    int id,
    List<List<LatLng>> rings, {
    String name = '',
    String description = '',
    Map<String, dynamic>? metadata,
  }) => _update(
    tableName,
    id,
    _buildGeoMultiPolygon(rings),
    name: name,
    description: description,
    metadata: metadata,
  );

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
      final deleted = await db.rawDelete(
        'DELETE FROM ${quoteIdent(tableName)} WHERE $whereClause',
        [id],
      );
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
              ? 'SELECT rowid, * FROM ${quoteIdent(tableName)} WHERE rowid = ?'
              : 'SELECT * FROM ${quoteIdent(tableName)} WHERE ${quoteIdent(pkColumn)} = ?';

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
              ? 'SELECT rowid, * FROM ${quoteIdent(tableName)}'
              : 'SELECT * FROM ${quoteIdent(tableName)}';

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
  /// > フィルタをそのまま通す QGIS と同じ設計だが、**フォルダ設定（`.qgs`） は
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
              ? 'SELECT rowid, * FROM ${quoteIdent(tableName)}'
              : 'SELECT * FROM ${quoteIdent(tableName)}';

      final sql = StringBuffer(selectClause);
      final safeWhere = sanitizeFilter(where);
      if (safeWhere != null) sql.write(' WHERE $safeWhere');

      // 2000 行ずつ読む。1 回で読むと 1.5 万面（24MB）が 1 通のメッセージになり、プラットフォームチャネルを塞いで
      // 同じ時間のタイルキャッシュの読み出しまで 2.5 秒待たされていた（2026-10-06、Fold で起動時）。
      // 大きいレイヤはページごとに isolate で解析を始め、次のページの読み込みと重ねる
      final orderCol = pkColumn == 'rowid' ? 'rowid' : quoteIdent(pkColumn);
      final crs = geomType == null ? null : await _getLayerCrs(tableName);
      final needsReproject = crs != null && !crs.isWgs84 && crs.projection != null;
      if (needsReproject) {
        AppLogger.debug('[FeatureRepository] CRS re-projection: $tableName (${crs.epsgCode}→WGS84)');
      }
      const pageSize = 2000;
      final mutableRows = <Map<String, dynamic>>[];
      final parsing = <Future<List<Map<String, dynamic>>>>[];
      var offset = 0;
      while (true) {
        final page = await db.rawQuery('$sql ORDER BY $orderCol LIMIT $pageSize OFFSET $offset');
        final normalized = <Map<String, dynamic>>[];
        for (final row in page) {
          final normalizedRow = Map<String, dynamic>.from(row);
          _normalizePrimaryKey(normalizedRow, pkColumn);
          if (normalizedRow['id'] == null) continue;
          normalized.add(normalizedRow);
        }
        final last = page.length < pageSize;
        if (geomType != null && (!last || offset > 0 || normalized.length >= _kIsolateThreshold)) {
          parsing.add(compute(
            _parseGeometryBatchInIsolate,
            _GeometryParseParams(
              normalized,
              geomType,
              sourceProjection: needsReproject ? crs.projection : null,
              needsAxisSwap: crs!.needsAxisSwap,
            ),
          ));
        } else {
          mutableRows.addAll(normalized);
        }
        if (last) break;
        offset += pageSize;
      }

      if (geomType == null) return mutableRows;
      if (parsing.isNotEmpty) {
        AppLogger.debug('[FeatureRepository] Isolateパース: $tableName (${parsing.length} ページ)');
        return [for (final part in await Future.wait(parsing)) ...part];
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
      final column = pkColumn == 'rowid' ? 'rowid' : quoteIdent(pkColumn);

      final rows = await db.rawQuery(
        'SELECT $column AS id FROM ${quoteIdent(tableName)} WHERE $safeWhere',
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

      final columnList = columns?.map(quoteIdent).join(', ') ?? '*';
      final orderByClause =
          pkColumn == 'rowid' ? 'ORDER BY rowid' : 'ORDER BY ${quoteIdent(pkColumn)}';

      return await db.rawQuery(
        'SELECT $columnList FROM ${quoteIdent(tableName)} $orderByClause',
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
      final result = await _selectRow(db, tableName, rowId);
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
      final result = await _selectRow(db, tableName, rowId);
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
        'UPDATE ${quoteIdent(tableName)} SET ${quoteIdent(attributeName)} = ? WHERE $whereClause',
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
          .map((key) => '${quoteIdent(key)} = ?')
          .join(', ');
      final values = [...filteredAttributes.values, rowId];
      final whereClause = await schema.buildWhereClause(tableName);
      final sql =
          'UPDATE ${quoteIdent(tableName)} SET $columnAssignments WHERE $whereClause';
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
    geo.Geometry Function(T) build,
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
      // 移す先のレイヤの CRS に合わせる（WGS84 のまま書くと別の CRS のレイヤで位置がずれる）
      final crs = await _getLayerCrs(tableName);

      final tableColumns = await schema.getTableColumns(tableName);
      final tableColumnSet = tableColumns.map((c) => c.toLowerCase()).toSet();

      for (final data in dataList) {
        final geometry = data[geometryKey] as T;
        final wkb = _encodeInCrs(crs, build(geometry));
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
        final columnNames = columns.map(quoteIdent).join(', ');
        final values = columns.map((c) => insertData[c]).toList();

        batch.rawInsert(
          'INSERT INTO ${quoteIdent(tableName)} ($columnNames) VALUES ($placeholders)',
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
    _buildGeoPoint,
  );

  Future<List<int>> addLinesBatch(
    String tableName,
    List<Map<String, dynamic>> lineData,
  ) => _addGeometryBatch<List<LatLng>>(
    tableName,
    lineData,
    'line',
    _buildGeoMultiLineString,
  );

  Future<List<int>> addPolygonsBatch(
    String tableName,
    List<Map<String, dynamic>> polygonData,
  ) => _addGeometryBatch<List<List<LatLng>>>(
    tableName,
    polygonData,
    'rings',
    _buildGeoMultiPolygon,
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
              ? 'SELECT rowid FROM ${quoteIdent(tableName)} WHERE $whereClause'
              : 'SELECT ${quoteIdent(pkColumn)} FROM ${quoteIdent(tableName)} WHERE $whereClause';

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
        'SELECT COUNT(*) as cnt FROM ${quoteIdent(tableName)} WHERE $whereClause',
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

      final columnList = columnsToInsert.map(quoteIdent).join(', ');
      await db.execute('''
        INSERT INTO ${quoteIdent(targetTable)} ($columnList)
        SELECT $columnList FROM ${quoteIdent(sourceTable)}
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

      final columnList = columnsToInsert.map(quoteIdent).join(', ');
      await db.execute('''
        INSERT INTO ${quoteIdent(targetTable)} ($columnList)
        SELECT $columnList FROM ${quoteIdent(sourceTable)}
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
      return await _insertRow(db, tableName, data);
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

  /// 1 行挿入して rowid を返す。
  ///
  /// ⚠ `db.insert` はテーブル名・カラム名を囲まないので "Survey points" のような
  ///   QGIS 由来の名前で構文エラーになる。識別子を自前で囲む
  Future<int> _insertRow(
    DatabaseExecutor db,
    String tableName,
    Map<String, dynamic> data,
  ) {
    final columns = data.keys.toList();
    final placeholders = List.filled(columns.length, '?').join(', ');
    return db.rawInsert(
      'INSERT INTO ${quoteIdent(tableName)} (${columns.map(quoteIdent).join(', ')}) '
      'VALUES ($placeholders)',
      [for (final c in columns) data[c]],
    );
  }

  Future<List<Map<String, Object?>>> _selectRow(
    DatabaseExecutor db,
    String tableName,
    int rowId,
  ) async {
    final whereClause = await schema.buildWhereClause(tableName);
    return db.rawQuery(
      'SELECT * FROM ${quoteIdent(tableName)} WHERE $whereClause',
      [rowId],
    );
  }

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
