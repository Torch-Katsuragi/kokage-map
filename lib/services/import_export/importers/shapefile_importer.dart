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
      final dbfData = await _readDbf(basePath);

      // PRJ座標系読み込み
      final prjFile = File('$basePath.prj');
      final sourceCoordinateSystem = prjFile.existsSync() ? await PrjReader.read(prjFile.path) : null;
      if (sourceCoordinateSystem != null) {
        AppLogger.debug('[ShapefileImporter] 座標系: ${sourceCoordinateSystem.name}');
      }

      // SHP は 1 回だけ読む（基本情報もレコードも同じバイト列から）
      final shpBytes = await ShapefileBinaryParser.readBytes(filePath);
      final shapeInfo = shpBytes == null ? null : ShapefileBinaryParser.infoFromBytes(shpBytes);
      if (shpBytes == null || shapeInfo == null) {
        return ImportExportResult.error(t.importExport.shapefileReadError);
      }

      // レイヤ名決定
      final fileName = p.basenameWithoutExtension(filePath);
      final actualLayerName = await uniqueLayerName(targetGeoPackage, layerName ?? fileName);
      final geometryType = _convertShapeTypeToGeometryType(shapeInfo['geometryType'] as String);

      // レイヤ作成と DBF のスキーマ
      await targetGeoPackage.geoPackageFile.addLayer(actualLayerName, geometryType);
      if (dbfData != null) {
        await _addDbfSchema(targetGeoPackage, actualLayerName, dbfData);
      }

      // フィーチャをインポート（書くときだけ待つ）
      int featureCount = 0;
      final batch = <Map<String, dynamic>>[];
      for (final record in ShapefileBinaryParser.records(shpBytes, sourceCoordinateSystem: sourceCoordinateSystem)) {
        // DBF で削除済みの行は GDAL/QGIS と同じくフィーチャごと読み飛ばす
        if (DbfReader.isDeletedRecord(dbfData, record.index)) continue;
        final featureData = _featureData(record, DbfReader.getAttributesForRecord(dbfData, record.index));
        if (featureData == null) continue;
        batch.add(featureData);
        featureCount++;
        if (batch.length >= BaseImporter.batchSize) {
          await addBatch(targetGeoPackage, actualLayerName, geometryType, batch);
          batch.clear();
          AppLogger.debug('[ShapefileImporter] バッチ処理完了: $featureCount件');
        }
      }
      await addBatch(targetGeoPackage, actualLayerName, geometryType, batch);

      final createdLayer = (await reloadLayers(targetGeoPackage, [actualLayerName])).firstOrNull;
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

  /// `.dbf` の属性。文字コードは `.cpg` に従う（無ければ Shift_JIS）
  Future<Map<String, List<dynamic>>?> _readDbf(String basePath) async {
    final dbfFile = File('$basePath.dbf');
    final cpgFile = File('$basePath.cpg');

    String? dbfEncoding;
    if (cpgFile.existsSync()) {
      try {
        dbfEncoding = (await cpgFile.readAsString()).trim();
        AppLogger.debug('[ShapefileImporter] CPGファイルから文字コード取得: $dbfEncoding');
      } catch (e) {
        AppLogger.debug('[ShapefileImporter] CPGファイル読み込みエラー: $e');
      }
    }

    if (!dbfFile.existsSync()) return null;
    final dbfData = await DbfReader.read(dbfFile.path, encoding: dbfEncoding ?? 'Shift_JIS');
    if (dbfData != null) {
      AppLogger.debug('[ShapefileImporter] DBF属性データ読み込み成功');
      AppLogger.debug('  フィールド数: ${dbfData.keys.length}');
      AppLogger.debug('  レコード数: ${dbfData.values.firstOrNull?.length ?? 0}');
    }
    return dbfData;
  }

  /// レコードを GeoPackage に書く形にする。形の種類が合わなければ null
  static Map<String, dynamic>? _featureData(ShpRecord record, Map<String, dynamic> attributes) {
    final geometry = record.geometry;
    return switch (record.shapeType) {
      ShapeType.point when geometry is LatLng => {'point': geometry, ...attributes},
      ShapeType.polyLine when geometry is List<LatLng> && geometry.isNotEmpty => {'line': geometry, ...attributes},
      ShapeType.polygon when geometry is List<List<LatLng>> && geometry.isNotEmpty => {
        'rings': geometry,
        ...attributes,
      },
      _ => null,
    };
  }

  /// シェープタイプをGeometryTypeに変換
  static GeometryType _convertShapeTypeToGeometryType(String shapeTypeString) =>
      switch (shapeTypeString.toLowerCase()) {
        'linestring' || 'polyline' => GeometryType.linestring,
        'polygon' => GeometryType.polygon,
        _ => GeometryType.point,
      };

  /// DBFスキーマをGeoPackageに追加（列の型は最初の値で決める）
  Future<void> _addDbfSchema(
    GeoPackageNode targetGeoPackage,
    String layerName,
    Map<String, List<dynamic>> dbfData,
  ) async {
    try {
      final attributeSchema = <String, String>{
        for (final MapEntry(key: fieldName, value: values) in dbfData.entries)
          fieldName: BaseImporter.sqliteTypeOf(values.firstOrNull),
      };
      if (attributeSchema.isNotEmpty) {
        await targetGeoPackage.geoPackageFile.addAttributeColumns(layerName, attributeSchema);
      }
    } catch (e) {
      AppLogger.debug('[ShapefileImporter] DBFスキーマ追加エラー: $e');
    }
  }
}
