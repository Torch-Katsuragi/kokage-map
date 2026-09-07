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
// Root Maps: Shapefile Importer
// シェープファイルインポートクラス
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/geometry_type.dart';
import '../../../models/nodes/geopackage_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../import_export_models.dart';
import '../parsers/dbf_reader.dart';
import '../parsers/prj_reader.dart';
import '../parsers/shapefile_binary_parser.dart';
import 'base_importer.dart';

/// シェープファイルインポーター
class ShapefileImporter extends BaseImporter {
  @override
  bool canHandle(String extension) {
    return extension.toLowerCase() == '.shp';
  }

  @override
  FileFormat get format => FileFormat.shapefile;

  @override
  Future<ImportExportResult> import(
    String filePath,
    GeoPackageNode targetGeoPackage, {
    String? layerName,
  }) async {
    try {
      AppLogger.debug('[ShapefileImporter] インポート開始: $filePath');

      // ファイル存在確認
      final shpFile = File(filePath);
      if (!shpFile.existsSync()) {
        return ImportExportResult.error('SHPファイルが見つかりません: $filePath');
      }

      final basePath = p.withoutExtension(filePath);
      final dbfFile = File('$basePath.dbf');
      final prjFile = File('$basePath.prj');
      final cpgFile = File('$basePath.cpg');

      // CPGファイルから文字コードを読み取り
      String? dbfEncoding;
      if (cpgFile.existsSync()) {
        try {
          dbfEncoding = (await cpgFile.readAsString()).trim();
          AppLogger.debug('[ShapefileImporter] CPGファイルから文字コード取得: $dbfEncoding');
        } catch (e) {
          AppLogger.debug('[ShapefileImporter] CPGファイル読み込みエラー: $e');
        }
      }

      // DBF属性データ読み込み
      Map<String, List<dynamic>>? dbfData;
      if (dbfFile.existsSync()) {
        dbfData = await DbfReader.read(
          dbfFile.path,
          encoding: dbfEncoding ?? 'Shift_JIS',
        );
        if (dbfData != null) {
          AppLogger.debug('[ShapefileImporter] DBF属性データ読み込み成功');
          AppLogger.debug('  フィールド数: ${dbfData.keys.length}');
          AppLogger.debug('  レコード数: ${dbfData.values.firstOrNull?.length ?? 0}');
        }
      }

      // PRJ座標系読み込み
      final sourceCoordinateSystem = prjFile.existsSync()
          ? await PrjReader.read(prjFile.path)
          : null;
      if (sourceCoordinateSystem != null) {
        AppLogger.debug('[ShapefileImporter] 座標系: ${sourceCoordinateSystem.name}');
      }

      // SHP基本情報読み込み
      final shapeInfo = await ShapefileBinaryParser.readInfo(filePath);
      if (shapeInfo == null) {
        return ImportExportResult.error(t.importExport.shapefileReadError);
      }

      // レイヤ名決定
      final fileName = p.basenameWithoutExtension(filePath);
      final actualLayerName = await _generateUniqueLayerName(
        targetGeoPackage,
        layerName ?? fileName,
      );

      // ジオメトリタイプ
      final geometryType = _convertShapeTypeToGeometryType(
        shapeInfo['geometryType'] as String,
      );

      // レイヤ作成
      await targetGeoPackage.geoPackageFile.addLayer(actualLayerName, geometryType);

      // DBFスキーマをGeoPackageに追加
      if (dbfData != null) {
        await _addDbfSchemaToGeoPackage(targetGeoPackage, actualLayerName, dbfData);
      }

      // フィーチャをインポート
      int featureCount = 0;
      final batchData = <Map<String, dynamic>>[];
      const batchSize = 1000;

      await ShapefileBinaryParser.parseRecords(
        filePath,
        sourceCoordinateSystem: sourceCoordinateSystem,
        onRecord: (recordIndex, shapeType, geometry) async {
          final attributes = DbfReader.getAttributesForRecord(dbfData, featureCount);
          
          Map<String, dynamic>? featureData;

          switch (shapeType) {
            case ShapeType.point:
              if (geometry is LatLng) {
                featureData = {'point': geometry, ...attributes};
              }
            case ShapeType.polyLine:
              if (geometry is List<LatLng> && geometry.isNotEmpty) {
                featureData = {'line': geometry, ...attributes};
              }
            case ShapeType.polygon:
              if (geometry is List<List<LatLng>> && geometry.isNotEmpty) {
                featureData = {'rings': geometry, ...attributes};
              }
          }

          if (featureData != null) {
            batchData.add(featureData);
            featureCount++;

            // バッチ処理
            if (batchData.length >= batchSize) {
              await _processBatch(targetGeoPackage, actualLayerName, geometryType, batchData);
              batchData.clear();
              AppLogger.debug('[ShapefileImporter] バッチ処理完了: $featureCount件');
            }
          }
        },
      );

      // 残りのバッチを処理
      if (batchData.isNotEmpty) {
        await _processBatch(targetGeoPackage, actualLayerName, geometryType, batchData);
      }

      // レイヤ更新
      await targetGeoPackage.updateChildren();

      // 作成されたレイヤノードを取得
      final createdLayer = targetGeoPackage.children
          .whereType<LayerNode>()
          .where((layer) => layer.layerName == actualLayerName)
          .firstOrNull;

      if (createdLayer == null) {
        return ImportExportResult.error(t.importExport.layerFetchError(name: actualLayerName));
      }

      AppLogger.debug('[ShapefileImporter] インポート完了: $featureCount個のフィーチャ');

      return ImportExportResult.success(
        createdLayer: createdLayer,
        metadata: {
          'sourceFile': filePath,
          'fileName': fileName,
          'featureCount': featureCount,
          'geometryType': geometryType.value,
          'shapeInfo': shapeInfo,
        },
      );
    } catch (e, stack) {
      AppLogger.debug('[ShapefileImporter] インポートエラー: $e');
      AppLogger.debug('スタックトレース: $stack');
      return ImportExportResult.error(t.importExport.shapefileError(error: e.toString()));
    }
  }

  /// 重複しないレイヤ名を生成
  Future<String> _generateUniqueLayerName(
    GeoPackageNode geoPackageNode,
    String baseName,
  ) async {
    final existingLayerNames = await geoPackageNode.geoPackageFile.getLayerNames();

    if (!existingLayerNames.contains(baseName)) {
      return baseName;
    }

    int counter = 1;
    String candidateName;
    do {
      candidateName = '${baseName}_$counter';
      counter++;
    } while (existingLayerNames.contains(candidateName));

    return candidateName;
  }

  /// シェープタイプをGeometryTypeに変換
  GeometryType _convertShapeTypeToGeometryType(String shapeTypeString) {
    switch (shapeTypeString.toLowerCase()) {
      case 'point':
        return GeometryType.point;
      case 'linestring':
      case 'polyline':
        return GeometryType.linestring;
      case 'polygon':
        return GeometryType.polygon;
      default:
        return GeometryType.point;
    }
  }

  /// DBFスキーマをGeoPackageに追加
  Future<void> _addDbfSchemaToGeoPackage(
    GeoPackageNode targetGeoPackage,
    String layerName,
    Map<String, List<dynamic>> dbfData,
  ) async {
    try {
      final attributeSchema = <String, String>{};

      for (final entry in dbfData.entries) {
        final fieldName = entry.key;
        final values = entry.value;

        String sqliteType = 'TEXT';
        if (values.isNotEmpty && values.first != null) {
          final firstValue = values.first;
          if (firstValue is num || firstValue is int || firstValue is double) {
            sqliteType = 'REAL';
          } else if (firstValue is bool) {
            sqliteType = 'INTEGER';
          }
        }

        attributeSchema[fieldName] = sqliteType;
      }

      if (attributeSchema.isNotEmpty) {
        await targetGeoPackage.geoPackageFile.addAttributeColumns(
          layerName,
          attributeSchema,
        );
      }
    } catch (e) {
      AppLogger.debug('[ShapefileImporter] DBFスキーマ追加エラー: $e');
    }
  }

  /// バッチデータを処理
  Future<void> _processBatch(
    GeoPackageNode targetGeoPackage,
    String layerName,
    GeometryType geometryType,
    List<Map<String, dynamic>> batchData,
  ) async {
    if (batchData.isEmpty) return;

    switch (geometryType) {
      case GeometryType.point:
        await targetGeoPackage.geoPackageFile.addPointsBatch(layerName, batchData);
      case GeometryType.linestring:
        await targetGeoPackage.geoPackageFile.addLinesBatch(layerName, batchData);
      case GeometryType.polygon:
        await targetGeoPackage.geoPackageFile.addPolygonsBatch(layerName, batchData);
    }
  }
}

