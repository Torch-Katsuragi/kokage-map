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
// Root Maps: GeoPackage CRS 解決クラス
// gpkg_spatial_ref_sys テーブルからCRS情報を解決し、
// proj4dart Projectionオブジェクトを提供する。
// 3段階フォールバック: ①GPKG内蔵WKT → ②EpsgRegistry → ③epsg.io HTTP

import 'package:http/http.dart' as http;
import 'package:proj4dart/proj4dart.dart';
import 'package:sqflite/sqflite.dart';

import '../../utils/app_logger.dart';
import 'epsg_registry.dart';
import 'projections.dart';

/// GPKG内のCRS情報を保持するデータクラス
class GpkgCrsInfo {
  /// SRS ID（gpkg_spatial_ref_sys.srs_id）
  final int srsId;

  /// EPSGコード文字列（例: "EPSG:6677"）
  final String epsgCode;

  /// 座標参照系の名前
  final String? name;

  /// WKT定義文字列（gpkg_spatial_ref_sys.definition）
  final String? definitionWkt;

  /// Proj4定義文字列
  final String? proj4String;

  /// WGS84系で変換不要か（srsId: 4326, 0, -1, 6668）
  final bool isWgs84;

  /// 軸入れ替えが必要か（JGD2011/JGD2000平面直角座標系）
  final bool needsAxisSwap;

  /// proj4dart Projection（キャッシュ済み）
  final Projection? projection;

  const GpkgCrsInfo({
    required this.srsId,
    required this.epsgCode,
    this.name,
    this.definitionWkt,
    this.proj4String,
    required this.isWgs84,
    required this.needsAxisSwap,
    this.projection,
  });

  /// WGS84のデフォルトCRS情報
  static const GpkgCrsInfo wgs84 = GpkgCrsInfo(
    srsId: 4326,
    epsgCode: 'EPSG:4326',
    name: 'WGS 84',
    isWgs84: true,
    needsAxisSwap: false,
  );

  @override
  String toString() => '$epsgCode ($name)';
}

/// GeoPackageファイルからCRS情報を解決するクラス
class GpkgCrsResolver {
  static final GpkgCrsResolver instance = GpkgCrsResolver._internal();
  factory GpkgCrsResolver() => instance;
  GpkgCrsResolver._internal();

  /// テーブル名→CRSキャッシュ（DB+テーブルのペアでキー生成）
  final Map<String, GpkgCrsInfo> _cache = {};

  /// EpsgRegistryへの参照
  EpsgRegistry get _registry => EpsgRegistry.instance;

  /// キャッシュキーを生成（DBパス + テーブル名）
  String _cacheKey(Database db, String tableName) =>
      '${db.path}::$tableName';

  /// レイヤのCRSを解決（3段階フォールバック）
  ///
  /// 1. gpkg_spatial_ref_sys.definition (WKT) を proj4dart でパース
  /// 2. EpsgRegistryのハードコードから取得
  /// 3. epsg.io HTTP GET → 取得成功ならGPKGに書き戻し
  Future<GpkgCrsInfo> resolveLayerCrs(Database db, String tableName) async {
    // キャッシュチェック
    final key = _cacheKey(db, tableName);
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    try {
      // srs_id を取得
      final srsId = await _getSrsId(db, tableName);
      if (srsId == null) {
        AppLogger.debug('[GpkgCrsResolver] srs_id取得失敗: $tableName → WGS84フォールバック');
        _cache[key] = GpkgCrsInfo.wgs84;
        return GpkgCrsInfo.wgs84;
      }

      // WGS84系は変換不要
      if (_isWgs84SrsId(srsId)) {
        final info = GpkgCrsInfo(
          srsId: srsId,
          epsgCode: 'EPSG:$srsId',
          name: _getWgs84Name(srsId),
          isWgs84: true,
          needsAxisSwap: false,
        );
        _cache[key] = info;
        return info;
      }

      // SRS定義を取得
      final srsRow = await _getSrsDefinition(db, srsId);
      final definition = srsRow?['definition'] as String?;
      final organization = srsRow?['organization'] as String?;
      final orgCoordSysId = srsRow?['organization_coordsys_id'] as int?;
      final srsName = srsRow?['srs_name'] as String?;

      // EPSGコードを決定
      final epsgCode = (organization?.toUpperCase() == 'EPSG' && orgCoordSysId != null)
          ? 'EPSG:$orgCoordSysId'
          : 'EPSG:$srsId';

      final needsAxisSwap = _registry.needsAxisSwap(epsgCode);

      // ① GPKG内蔵WKTから解決
      if (definition != null &&
          definition.isNotEmpty &&
          definition != 'undefined') {
        final projection = Projections.parse(definition);
        if (projection != null) {
          AppLogger.debug('[GpkgCrsResolver] WKTパース成功: $epsgCode ($tableName)');
          final info = GpkgCrsInfo(
            srsId: srsId,
            epsgCode: epsgCode,
            name: srsName,
            definitionWkt: definition,
            isWgs84: false,
            needsAxisSwap: needsAxisSwap,
            projection: projection,
          );
          _cache[key] = info;
          return info;
        }
      }

      // ② EpsgRegistryから解決
      final registryDef = _registry.getByCode(epsgCode);
      if (registryDef != null) {
        final projection = Projections.parse(registryDef.proj4String);
        if (projection != null) {
          AppLogger.debug('[GpkgCrsResolver] EpsgRegistry解決: $epsgCode ($tableName)');
          final info = GpkgCrsInfo(
            srsId: srsId,
            epsgCode: epsgCode,
            name: registryDef.name,
            proj4String: registryDef.proj4String,
            isWgs84: false,
            needsAxisSwap: needsAxisSwap,
            projection: projection,
          );
          _cache[key] = info;
          return info;
        }
      }

      // ③ epsg.io HTTP GETで解決 → GPKGに書き戻し
      final codeNumber = epsgCode.replaceFirst('EPSG:', '');
      final httpResult = await _fetchFromEpsgIo(codeNumber);
      if (httpResult != null) {
        final projection = Projections.parse(httpResult);
        if (projection != null) {
          AppLogger.debug('[GpkgCrsResolver] epsg.io解決: $epsgCode ($tableName)');

          // GPKGに書き戻し（キャッシュ化）
          await _writeBackDefinition(db, srsId, httpResult);

          final info = GpkgCrsInfo(
            srsId: srsId,
            epsgCode: epsgCode,
            name: srsName,
            proj4String: httpResult,
            isWgs84: false,
            needsAxisSwap: needsAxisSwap,
            projection: projection,
          );
          _cache[key] = info;
          return info;
        }
      }

      // 全て失敗 → WGS84フォールバック
      AppLogger.debug('[GpkgCrsResolver] 全解決手段が失敗: $epsgCode ($tableName) → WGS84フォールバック');
      _cache[key] = GpkgCrsInfo.wgs84;
      return GpkgCrsInfo.wgs84;
    } catch (e) {
      AppLogger.debug('[GpkgCrsResolver] CRS解決エラー: $e');
      _cache[key] = GpkgCrsInfo.wgs84;
      return GpkgCrsInfo.wgs84;
    }
  }

  /// キャッシュをクリア
  void clearCache() => _cache.clear();

  // ========== 内部ヘルパー ==========

  /// gpkg_geometry_columns から srs_id を取得
  Future<int?> _getSrsId(Database db, String tableName) async {
    try {
      final rows = await db.query(
        'gpkg_geometry_columns',
        columns: ['srs_id'],
        where: 'table_name = ?',
        whereArgs: [tableName],
      );
      if (rows.isNotEmpty) return rows.first['srs_id'] as int?;

      // gpkg_contentsからもチェック
      final contentsRows = await db.query(
        'gpkg_contents',
        columns: ['srs_id'],
        where: 'table_name = ?',
        whereArgs: [tableName],
      );
      if (contentsRows.isNotEmpty) return contentsRows.first['srs_id'] as int?;

      return null;
    } catch (e) {
      AppLogger.debug('[GpkgCrsResolver] srs_id取得エラー: $e');
      return null;
    }
  }

  /// gpkg_spatial_ref_sys から定義を取得
  Future<Map<String, dynamic>?> _getSrsDefinition(Database db, int srsId) async {
    try {
      final rows = await db.query(
        'gpkg_spatial_ref_sys',
        where: 'srs_id = ?',
        whereArgs: [srsId],
      );
      return rows.isNotEmpty ? rows.first : null;
    } catch (e) {
      AppLogger.debug('[GpkgCrsResolver] SRS定義取得エラー: $e');
      return null;
    }
  }

  /// epsg.io から proj4 定義を取得
  Future<String?> _fetchFromEpsgIo(String codeNumber) async {
    try {
      final url = Uri.parse('https://epsg.io/$codeNumber.proj4');
      final response = await http.get(url).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        final body = response.body.trim();
        if (body.isNotEmpty && body.startsWith('+proj')) {
          AppLogger.debug('[GpkgCrsResolver] epsg.io取得成功: EPSG:$codeNumber');
          return body;
        }
      }

      AppLogger.debug('[GpkgCrsResolver] epsg.io取得失敗: EPSG:$codeNumber (${response.statusCode})');
      return null;
    } catch (e) {
      AppLogger.debug('[GpkgCrsResolver] epsg.io通信エラー: $e');
      return null;
    }
  }

  /// 取得した定義をGPKGに書き戻し（GPKGがキャッシュになる）
  Future<void> _writeBackDefinition(Database db, int srsId, String proj4String) async {
    try {
      await db.update(
        'gpkg_spatial_ref_sys',
        {'definition': proj4String},
        where: 'srs_id = ?',
        whereArgs: [srsId],
      );
      AppLogger.debug('[GpkgCrsResolver] GPKGに定義を書き戻し完了: srs_id=$srsId');
    } catch (e) {
      AppLogger.debug('[GpkgCrsResolver] GPKG書き戻しエラー: $e');
    }
  }

  /// WGS84系のsrsIdか判定（変換不要）
  bool _isWgs84SrsId(int srsId) {
    return srsId == 4326 || srsId == 0 || srsId == -1 || srsId == 6668;
  }

  /// WGS84系のsrsIdに対応する名前
  String _getWgs84Name(int srsId) {
    switch (srsId) {
      case 4326:
        return 'WGS 84';
      case 6668:
        return 'JGD2011 地理座標系';
      case 0:
        return 'Undefined geographic SRS';
      case -1:
        return 'Undefined cartesian SRS';
      default:
        return 'Unknown';
    }
  }
}
