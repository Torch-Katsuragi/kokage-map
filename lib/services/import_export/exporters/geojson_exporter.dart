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
// Root Maps: GeoJSON Exporter
// GeoJSONエクスポートクラス（turfパッケージ活用版）
import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:turf/turf.dart' as turf;

import '../../../converters/turf_converter.dart';
import '../../../models/geometry_type.dart';
import '../../../models/nodes/layer_node.dart';
import '../import_export_models.dart';
import 'base_exporter.dart';

/// GeoJSONエクスポーター（turfパッケージ活用）
class GeoJSONExporter extends BaseExporter {
  @override
  FileFormat get format => FileFormat.geojson;

  @override
  Future<ImportExportResult> export(
    LayerNode layer,
    String outputPath, {
    ExportOptions options = const ExportOptions(),
  }) async {
    try {
      AppLogger.debug('[GeoJSONExporter] エクスポート開始: ${layer.layerName}');

      final features = await layer.geoPackageNode.geoPackageFile.getFeatures(
        layer.layerName,
      );
      final geometryType = await layer.geoPackageNode.geoPackageFile
          .getGeometryType(layer.layerName);

      if (features.isEmpty) {
        return ImportExportResult.error('No features found in layer: ${layer.layerName}');
      }

      // turfのFeatureリストを構築
      final turfFeatures = <turf.Feature>[];

      for (final feature in features) {
        final turfFeature = _createTurfFeature(feature, geometryType);
        if (turfFeature != null) {
          turfFeatures.add(turfFeature);
        }
      }

      // turfのFeatureCollectionを作成
      final featureCollection = TurfConverter.createFeatureCollection(turfFeatures);

      // GeoJSONデータを生成（layer名を追加）
      final geoJsonData = featureCollection.toJson();
      geoJsonData['name'] = layer.layerName;

      // ファイルに書き込み
      final file = File(outputPath);
      final jsonString = const JsonEncoder.withIndent('  ').convert(geoJsonData);
      await file.writeAsString(jsonString);

      AppLogger.debug('[GeoJSONExporter] エクスポート完了: ${turfFeatures.length}個のフィーチャ');

      return ImportExportResult.success(
        metadata: {
          'outputPath': outputPath,
          'featureCount': turfFeatures.length,
          'geometryType': geometryType?.value,
          'format': 'GeoJSON',
          'fileSize': (await file.stat()).size,
        },
      );
    } catch (e) {
      AppLogger.debug('[GeoJSONExporter] エクスポートエラー: $e');
      return ImportExportResult.error('GeoJSON export failed: $e');
    }
  }

  /// フィーチャからturfのFeatureを作成
  turf.Feature? _createTurfFeature(
    Map<String, dynamic> feature,
    GeometryType? geometryType,
  ) {
    try {
      turf.GeometryObject? geometry;

      switch (geometryType) {
        case GeometryType.point:
          final points = feature['points'] as List<LatLng>?;
          if (points != null && points.isNotEmpty) {
            geometry = TurfConverter.createPoint(points.first);
          }

        case GeometryType.linestring:
          final lines = feature['lines'] as List<LatLng>?;
          if (lines != null && lines.length >= 2) {
            geometry = TurfConverter.createLineString(lines);
          }

        case GeometryType.polygon:
          final polygons = feature['polygons'] as List<List<LatLng>>?;
          if (polygons != null && polygons.isNotEmpty) {
            // ポリゴンを閉じる処理
            final closedRings = polygons.map((ring) {
              if (ring.length >= 3) {
                final firstPoint = ring.first;
                final lastPoint = ring.last;
                if (firstPoint.latitude != lastPoint.latitude ||
                    firstPoint.longitude != lastPoint.longitude) {
                  return [...ring, firstPoint];
                }
              }
              return ring;
            }).toList();
            geometry = TurfConverter.createPolygon(closedRings);
          }

        default:
          break;
      }

      if (geometry == null) return null;

      // プロパティを構築
      final properties = <String, dynamic>{
        'id': feature['id'],
        'name': feature['name'] ?? '',
        'description': feature['description'] ?? '',
      };

      // メタデータを追加
      if (feature['metadata'] != null && feature['metadata'] is Map) {
        properties.addAll(feature['metadata'] as Map<String, dynamic>);
      }

      return turf.Feature(geometry: geometry, properties: properties);
    } catch (e) {
      AppLogger.debug('[GeoJSONExporter] Feature作成エラー: $e');
      return null;
    }
  }
}
