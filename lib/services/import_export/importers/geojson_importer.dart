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
// Root Maps: GeoJSON Importer
// GeoJSONインポートクラス（turfパッケージ活用版）
import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';
import 'package:turf/turf.dart' as turf;

import '../../../converters/turf_converter.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/geometry_type.dart';
import '../../../models/nodes/geopackage_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../import_export_models.dart';
import 'base_importer.dart';

/// GeoJSONインポーター（turfパッケージ活用）
class GeoJSONImporter extends BaseImporter {
  @override
  bool canHandle(String extension) {
    final ext = extension.toLowerCase();
    return ext == '.geojson' || ext == '.json';
  }

  @override
  FileFormat get format => FileFormat.geojson;

  @override
  Future<ImportExportResult> import(
    String filePath,
    GeoPackageNode targetGeoPackage, {
    String? layerName,
  }) async {
    try {
      AppLogger.debug('[GeoJSONImporter] インポート開始: $filePath');

      final file = File(filePath);
      if (!file.existsSync()) {
        return ImportExportResult.error('GeoJSONファイルが見つかりません: $filePath');
      }

      final fileContent = await file.readAsString();

      final geoJson = turf.GeoJSONObject.fromJson(json.decode(fileContent));

      if (geoJson is! turf.FeatureCollection) {
        return ImportExportResult.error('FeatureCollection形式のGeoJSONのみサポートしています');
      }

      final turfFeatures = geoJson.features;
      if (turfFeatures.isEmpty) {
        return ImportExportResult.error(t.importExport.noFeatures);
      }

      AppLogger.debug('[GeoJSONImporter] フィーチャ数: ${turfFeatures.length}');

      // フィーチャをジオメトリ型ごとにグループ化
      final grouped = _groupByGeometryType(turfFeatures);
      if (grouped.isEmpty) {
        return ImportExportResult.error(t.importExport.noSupportedGeometry);
      }

      AppLogger.debug('[GeoJSONImporter] ジオメトリ型数: ${grouped.length} (${grouped.keys.map((t) => t.value).join(", ")})');

      final baseName = layerName ?? p.basenameWithoutExtension(filePath);
      final useTypeSuffix = grouped.length > 1;
      final createdLayerNames = <String>[];
      int totalSuccess = 0;
      int totalSkip = 0;

      for (final entry in grouped.entries) {
        final geometryType = entry.key;
        final features = entry.value;

        final rawName = useTypeSuffix ? '${baseName}_${geometryType.value}' : baseName;
        final actualLayerName = await _generateUniqueLayerName(targetGeoPackage, rawName);

        await targetGeoPackage.geoPackageFile.addLayer(actualLayerName, geometryType);
        await _addSchemaFromFeatures(targetGeoPackage, actualLayerName, features);

        final batchData = <Map<String, dynamic>>[];
        int successCount = 0;
        int skipCount = 0;

        for (final feature in features) {
          try {
            final featureData = _convertTurfFeatureToData(feature, geometryType);
            if (featureData != null) {
              batchData.add(featureData);
              successCount++;
            } else {
              skipCount++;
            }

            if (batchData.length >= 1000) {
              await _processBatch(targetGeoPackage, actualLayerName, geometryType, batchData);
              batchData.clear();
            }
          } catch (e) {
            AppLogger.debug('[GeoJSONImporter] フィーチャ処理エラー ($actualLayerName): $e');
            skipCount++;
          }
        }

        if (batchData.isNotEmpty) {
          await _processBatch(targetGeoPackage, actualLayerName, geometryType, batchData);
        }

        createdLayerNames.add(actualLayerName);
        totalSuccess += successCount;
        totalSkip += skipCount;
        AppLogger.debug('[GeoJSONImporter] レイヤ "$actualLayerName": $successCount成功, $skipCountスキップ');
      }

      await targetGeoPackage.updateChildren();

      final createdLayers = targetGeoPackage.children
          .whereType<LayerNode>()
          .where((layer) => createdLayerNames.contains(layer.layerName))
          .toList();

      if (createdLayers.isEmpty) {
        return ImportExportResult.error('GeoJSONレイヤー作成後の取得に失敗しました');
      }

      return ImportExportResult.success(
        createdLayers: createdLayers,
        metadata: {
          'sourceFile': filePath,
          'featureCount': totalSuccess,
          'skippedCount': totalSkip,
          'layerCount': grouped.length,
          'geometryTypes': grouped.keys.map((t) => t.value).toList(),
        },
      );
    } catch (e, stack) {
      AppLogger.debug('[GeoJSONImporter] インポートエラー: $e');
      AppLogger.debug('スタックトレース: $stack');
      return ImportExportResult.error('GeoJSONの読み込みでエラーが発生しました: $e');
    }
  }

  /// フィーチャをジオメトリ型ごとにグループ化
  Map<GeometryType, List<turf.Feature>> _groupByGeometryType(List<turf.Feature> features) {
    final grouped = <GeometryType, List<turf.Feature>>{};
    for (final feature in features) {
      final type = _detectGeometryType(feature);
      if (type == null) continue;
      grouped.putIfAbsent(type, () => []).add(feature);
    }
    return grouped;
  }

  /// turfのFeatureからジオメトリタイプを判定
  GeometryType? _detectGeometryType(turf.Feature feature) {
    final geometry = feature.geometry;
    if (geometry is turf.Point) return GeometryType.point;
    if (geometry is turf.MultiPoint) return GeometryType.point;
    if (geometry is turf.LineString) return GeometryType.linestring;
    if (geometry is turf.MultiLineString) return GeometryType.linestring;
    if (geometry is turf.Polygon) return GeometryType.polygon;
    if (geometry is turf.MultiPolygon) return GeometryType.polygon;
    return null;
  }

  /// turfのFeatureをGeoPackage保存用データに変換
  Map<String, dynamic>? _convertTurfFeatureToData(
    turf.Feature turfFeature,
    GeometryType geometryType,
  ) {
    try {
      final geometry = turfFeature.geometry;
      if (geometry == null) return null;

      // プロパティを取得
      final properties = turfFeature.properties ?? {};
      final featureData = Map<String, dynamic>.from(properties);

      switch (geometryType) {
        case GeometryType.point:
          if (geometry is turf.Point) {
            featureData['point'] = TurfConverter.pointToLatlng(geometry);
          } else if (geometry is turf.MultiPoint) {
            // MultiPointの最初のポイントを使用
            final coords = geometry.coordinates;
            if (coords.isNotEmpty) {
              featureData['point'] = LatLng(
                coords.first.lat.toDouble(),
                coords.first.lng.toDouble(),
              );
            }
          } else {
            return null;
          }

        case GeometryType.linestring:
          if (geometry is turf.LineString) {
            final line = TurfConverter.lineStringToLatlngs(geometry);
            if (line.length >= 2) {
              featureData['line'] = line;
            } else {
              return null;
            }
          } else if (geometry is turf.MultiLineString) {
            // MultiLineStringの最初のラインを使用
            final coords = geometry.coordinates;
            if (coords.isNotEmpty && coords.first.length >= 2) {
              featureData['line'] = coords.first
                  .map((pos) => LatLng(pos.lat.toDouble(), pos.lng.toDouble()))
                  .toList();
            } else {
              return null;
            }
          } else {
            return null;
          }

        case GeometryType.polygon:
          if (geometry is turf.Polygon) {
            final rings = TurfConverter.polygonToLatlngs(geometry);
            if (rings.isNotEmpty && rings.first.length >= 3) {
              featureData['rings'] = rings;
            } else {
              return null;
            }
          } else if (geometry is turf.MultiPolygon) {
            // MultiPolygonの最初のポリゴンを使用
            final coords = geometry.coordinates;
            if (coords.isNotEmpty && coords.first.isNotEmpty) {
              final rings = coords.first
                  .map((ring) => ring
                      .map((pos) => LatLng(pos.lat.toDouble(), pos.lng.toDouble()))
                      .toList())
                  .toList();
              if (rings.isNotEmpty && rings.first.length >= 3) {
                featureData['rings'] = rings;
              } else {
                return null;
              }
            } else {
              return null;
            }
          } else {
            return null;
          }
      }

      return featureData;
    } catch (e) {
      AppLogger.debug('[GeoJSONImporter] Feature変換エラー: $e');
      return null;
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

  /// turfのFeatureリストからスキーマを抽出してGeoPackageに追加
  Future<void> _addSchemaFromFeatures(
    GeoPackageNode targetGeoPackage,
    String layerName,
    List<turf.Feature> features,
  ) async {
    try {
      final attributeSchema = <String, String>{};

      for (final feature in features) {
        final properties = feature.properties;
        if (properties == null) continue;

        for (final entry in properties.entries) {
          final fieldName = entry.key;
          final value = entry.value;

          if (attributeSchema.containsKey(fieldName)) continue;

          String sqliteType = 'TEXT';
          if (value is num || value is int || value is double) {
            sqliteType = 'REAL';
          } else if (value is bool) {
            sqliteType = 'INTEGER';
          }

          attributeSchema[fieldName] = sqliteType;
        }
      }

      if (attributeSchema.isNotEmpty) {
        await targetGeoPackage.geoPackageFile.addAttributeColumns(
          layerName,
          attributeSchema,
        );
      }
    } catch (e) {
      AppLogger.debug('[GeoJSONImporter] スキーマ追加エラー: $e');
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
