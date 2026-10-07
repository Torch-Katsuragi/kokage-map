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

/// 地物ごとのメタデータ（JSON）を入れる列。アプリは列を作らない（古いファイルにだけある）
const metadataColumn = 'kmaps_metadata';

/// 点（WGS84）を geobase の形に
geo.Point toGeoPoint(LatLng pt) =>
    geo.Point(geo.Geographic(lon: pt.longitude, lat: pt.latitude));

/// 線（WGS84）を geobase の MultiLineString に（GeoPackage には Multi で書く）
geo.MultiLineString toGeoMultiLine(List<LatLng> line) => geo.MultiLineString.from([
      line.map((p) => geo.Geographic(lon: p.longitude, lat: p.latitude)),
    ]);

/// 面（外環＋穴、WGS84）を geobase の MultiPolygon に
geo.MultiPolygon toGeoMultiPolygon(List<List<LatLng>> rings) => geo.MultiPolygon.from([
      rings.map(
        (ring) => ring.map((p) => geo.Geographic(lon: p.longitude, lat: p.latitude)),
      ),
    ]);

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

    final metadataStr = row[metadataColumn] as String?;
    if (metadataStr != null && metadataStr.isNotEmpty) {
      try {
        row[metadataColumn] = jsonDecode(metadataStr) as Map<String, dynamic>;
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

  /// レイヤのCRS情報（GpkgCrsResolver が DB とテーブルごとに覚えている）
  Future<GpkgCrsInfo> _getLayerCrs(String tableName) async =>
      GpkgCrsResolver.instance.resolveLayerCrs(await connection.getDatabase(), tableName);

  // ============================================================
  // 書き込み前クリンナップ
  // ============================================================

  /// クリンナップ済みテーブルの記録（1テーブルにつき1回だけ実行）
  final Set<String> _cleanedTables = {};

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
    final n = await db.rawUpdate(
      'UPDATE ${quoteIdent(tableName)} SET ${quoteIdent(column)} = ? WHERE ${quoteIdent(pkColumn)} = ?',
      [value, pk],
    );
    return n > 0;
  }

  /// 書き込み前にテーブルをクリンナップする
  ///
  /// 外部ツール（QGIS/GeoPandas等）が作成したGPKGには
  /// SpatiaLite拡張に依存するトリガーが含まれることがあり、
  /// sqfliteでは実行できない。書き込み前に検出・除去する。
  Future<void> _prepareForWrite(String tableName) async {
    if (_cleanedTables.contains(tableName)) return;

    await spatialIndex.removeTableTriggers(tableName);
    _cleanedTables.add(tableName);
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
    final columnNames = {
      for (final row in await schema.tableInfo(tableName)) row['name'] as String,
    };

    final attributes = <String, dynamic>{};
    if (columnNames.contains('name')) attributes['name'] = name;
    if (columnNames.contains('description')) {
      attributes['description'] = description;
    }
    if (columnNames.contains(metadataColumn) && metadata != null) {
      attributes[metadataColumn] = jsonEncode(metadata);
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

  /// 形（WGS84）と属性で 1 行足し、rowid を返す。失敗は null
  Future<int?> addGeometry(
    String tableName,
    geo.Geometry geom,
    Map<String, dynamic> attributes,
  ) async {
    try {
      await _prepareForWrite(tableName);
      final db = await connection.getDatabase();
      final wkb = await _toLayerWkb(tableName, geom);
      final rowId = await _insertRow(db, tableName, {'geom': wkb, ...attributes});
      await spatialIndex.indexRows(tableName, {rowId: wkb});
      return rowId;
    } catch (e) {
      AppLogger.debug('[ERROR] FeatureRepository: add ${geom.geomType} failed: $e');
      return null;
    }
  }

  /// 形と name・description・メタデータで 1 行足す。
  /// name・description・メタデータ（[metadataColumn]）はレイヤに列があるものだけ書く
  Future<int?> addGeometryWithBasics(
    String tableName,
    geo.Geometry geom, {
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
      return await addGeometry(tableName, geom, attributes);
    } catch (e) {
      AppLogger.debug('[ERROR] FeatureRepository: add ${geom.geomType} failed: $e');
      return null;
    }
  }

  /// 行 [id] の形と name・description・メタデータを書き換える（列があるものだけ）
  Future<bool> updateGeometry(
    String tableName,
    int id,
    geo.Geometry geom, {
    required String name,
    required String description,
    required Map<String, dynamic>? metadata,
  }) async {
    await _prepareForWrite(tableName);
    final wkb = await _toLayerWkb(tableName, geom);
    final ok = await _updateFeatureGeometry(
      tableName,
      id,
      wkb,
      name: name,
      description: description,
      metadata: metadata,
    );
    if (ok) await spatialIndex.indexRows(tableName, {id: wkb});
    return ok;
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

      final rows = await db.rawQuery(
        'SELECT ${selectAllColumns(pkColumn)} FROM ${quoteIdent(tableName)} WHERE ${pkEquals(pkColumn)}',
        [rowId],
      );
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

      final rows = await db.rawQuery(
        'SELECT ${selectAllColumns(pkColumn)} FROM ${quoteIdent(tableName)}',
      );
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

      final sql = StringBuffer('SELECT ${selectAllColumns(pkColumn)} FROM ${quoteIdent(tableName)}');
      final safeWhere = sanitizeFilter(where);
      if (safeWhere != null) sql.write(' WHERE $safeWhere');

      // 2000 行ずつ読む。1 回で読むと 1.5 万面（24MB）が 1 通のメッセージになり、プラットフォームチャネルを塞いで
      // 同じ時間のタイルキャッシュの読み出しまで 2.5 秒待たされていた（2026-10-06、Fold で起動時）。
      // 大きいレイヤはページごとに isolate で解析を始め、次のページの読み込みと重ねる
      final orderCol = pkRef(pkColumn);
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
      final rows = await db.rawQuery(
        'SELECT ${pkRef(pkColumn)} AS id FROM ${quoteIdent(tableName)} WHERE $safeWhere',
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
      return await db.rawQuery(
        'SELECT $columnList FROM ${quoteIdent(tableName)} ORDER BY ${pkRef(pkColumn)}',
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

  /// [dataList] の各要素の [geometryKey] にある形を [build] で作り、残りを属性として一度に足す。
  /// 足した行の rowid を返す。テーブルに無い列は捨てる
  Future<List<int>> addGeometryBatch<T>(
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
      final wkbs = <Uint8List>[];
      // 移す先のレイヤの CRS に合わせる（WGS84 のまま書くと別の CRS のレイヤで位置がずれる）
      final crs = await _getLayerCrs(tableName);

      final tableColumns = await schema.getTableColumns(tableName);
      final tableColumnSet = tableColumns.map((c) => c.toLowerCase()).toSet();

      for (final data in dataList) {
        final geometry = data[geometryKey] as T;
        final wkb = _encodeInCrs(crs, build(geometry));
        wkbs.add(wkb);
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
      final inserted = <int, Uint8List>{
        for (var i = 0; i < results.length; i++)
          if (results[i] case final int id) id: wkbs[i],
      };
      await spatialIndex.indexRows(tableName, inserted);
      return inserted.keys.toList();
    } catch (e) {
      AppLogger.debug('[ERROR] FeatureRepository.addGeometryBatch<$T>: $e');
      return [];
    }
  }

  /// WHERE句でフィルタしたフィーチャのrowIdリストを取得
  Future<List<int>> getFilteredFeatureIds(
    String tableName,
    String whereClause,
  ) async {
    try {
      final db = await connection.getDatabase();
      final pkColumn = await schema.getPrimaryKeyColumn(tableName);

      final rows = await db.rawQuery(
        'SELECT ${pkRef(pkColumn)} FROM ${quoteIdent(tableName)} WHERE $whereClause',
      );
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
      final copiedCount = await _copyRows(sourceTable, targetTable, where: whereClause) ?? 0;
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
      final copiedCount = await _copyRows(sourceTable, targetTable);
      if (copiedCount == null) {
        AppLogger.debug('[FeatureRepository] コピー可能なカラムがありません');
        return 0;
      }
      AppLogger.debug(
        '[FeatureRepository] フィーチャコピー完了: $sourceTable -> $targetTable ($copiedCount件)',
      );
      return copiedCount;
    } catch (e) {
      AppLogger.debug('[FeatureRepository] copyFeaturesBetweenLayers エラー: $e');
      return 0;
    }
  }

  /// [sourceTable] の行（[where] があれば当てはまる行）を [targetTable] へ写し、写した数を返す。
  /// 主キー（id / fid）は写さず振り直させる。写せる列が無ければ null
  Future<int?> _copyRows(String sourceTable, String targetTable, {String? where}) async {
    final columnsToInsert = [
      for (final c in await schema.getTableColumns(sourceTable))
        if (c.toLowerCase() != 'id' && c.toLowerCase() != 'fid') c,
    ];
    if (columnsToInsert.isEmpty) return null;

    final db = await connection.getDatabase();
    final columnList = columnsToInsert.map(quoteIdent).join(', ');
    await db.execute(
      'INSERT INTO ${quoteIdent(targetTable)} ($columnList) '
      'SELECT $columnList FROM ${quoteIdent(sourceTable)}'
      '${where == null ? '' : ' WHERE $where'}',
    );
    final countResult = await db.rawQuery('SELECT changes() as count');
    return (countResult.first['count'] as int?) ?? 0;
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
    final metadataStr = row[metadataColumn] as String?;
    if (metadataStr != null && metadataStr.isNotEmpty) {
      try {
        row[metadataColumn] = jsonDecode(metadataStr) as Map<String, dynamic>;
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
