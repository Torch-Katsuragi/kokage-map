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

      // バイト列から直接 JSON にする（文字列を 1 本挟まない）
      final decoded = utf8.decoder.fuse(json.decoder).convert(await file.readAsBytes());
      final geoJson = turf.GeoJSONObject.fromJson(decoded as Map<String, dynamic>);

      if (geoJson is! turf.FeatureCollection) {
        return ImportExportResult.error('FeatureCollection形式のGeoJSONのみサポートしています');
      }

      final turfFeatures = geoJson.features;
      if (turfFeatures.isEmpty) {
        return ImportExportResult.error(t.importExport.noFeatures);
      }

      AppLogger.debug('[GeoJSONImporter] フィーチャ数: ${turfFeatures.length}');

      // フィーチャをジオメトリ型ごとにグループ化
      final grouped = <GeometryType, List<turf.Feature>>{};
      for (final feature in turfFeatures) {
        final type = _detectGeometryType(feature);
        if (type != null) grouped.putIfAbsent(type, () => []).add(feature);
      }
      if (grouped.isEmpty) {
        return ImportExportResult.error(t.importExport.noSupportedGeometry);
      }

      AppLogger.debug('[GeoJSONImporter] ジオメトリ型数: ${grouped.length} (${grouped.keys.map((t) => t.value).join(", ")})');

      final baseName = layerName ?? p.basenameWithoutExtension(filePath);
      final useTypeSuffix = grouped.length > 1;
      final createdLayerNames = <String>[];
      int totalSuccess = 0;
      int totalSkip = 0;

      for (final MapEntry(key: geometryType, value: features) in grouped.entries) {
        final rawName = useTypeSuffix ? '${baseName}_${geometryType.value}' : baseName;
        final actualLayerName = await uniqueLayerName(targetGeoPackage, rawName);

        await targetGeoPackage.geoPackageFile.addLayer(actualLayerName, geometryType);
        await _addSchemaFromFeatures(targetGeoPackage, actualLayerName, features);

        final batch = <Map<String, dynamic>>[];
        int successCount = 0;
        int skipCount = 0;

        for (final feature in features) {
          try {
            final featureData = _convertTurfFeatureToData(feature, geometryType);
            if (featureData != null) {
              batch.add(featureData);
              successCount++;
            } else {
              skipCount++;
            }

            if (batch.length >= BaseImporter.batchSize) {
              await addBatch(targetGeoPackage, actualLayerName, geometryType, batch);
              batch.clear();
            }
          } catch (e) {
            AppLogger.debug('[GeoJSONImporter] フィーチャ処理エラー ($actualLayerName): $e');
            skipCount++;
          }
        }
        await addBatch(targetGeoPackage, actualLayerName, geometryType, batch);

        createdLayerNames.add(actualLayerName);
        totalSuccess += successCount;
        totalSkip += skipCount;
        AppLogger.debug('[GeoJSONImporter] レイヤ "$actualLayerName": $successCount成功, $skipCountスキップ');
      }

      final createdLayers = await reloadLayers(targetGeoPackage, createdLayerNames);
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

  /// turfのFeatureからジオメトリタイプを判定（多重の形も同じ種類）
  static GeometryType? _detectGeometryType(turf.Feature feature) => switch (feature.geometry) {
    turf.Point() || turf.MultiPoint() => GeometryType.point,
    turf.LineString() || turf.MultiLineString() => GeometryType.linestring,
    turf.Polygon() || turf.MultiPolygon() => GeometryType.polygon,
    _ => null,
  };

  static List<LatLng> _latLngs(List<turf.Position> positions) => [
    for (final pos in positions) LatLng(pos.lat.toDouble(), pos.lng.toDouble()),
  ];

  /// turfのFeatureをGeoPackage保存用データに変換。
  /// 多重の形は最初の 1 つだけ。2 点未満の線・3 点未満の外周の面は捨てる（null）
  static Map<String, dynamic>? _convertTurfFeatureToData(
    turf.Feature turfFeature,
    GeometryType geometryType,
  ) {
    try {
      final geometry = turfFeature.geometry;
      if (geometry == null) return null;

      final featureData = Map<String, dynamic>.from(turfFeature.properties ?? {});

      switch (geometryType) {
        case GeometryType.point:
          switch (geometry) {
            case turf.Point():
              featureData['point'] = TurfConverter.pointToLatlng(geometry);
            case turf.MultiPoint(:final coordinates):
              if (coordinates.isNotEmpty) featureData['point'] = _latLngs([coordinates.first]).first;
            default:
              return null;
          }

        case GeometryType.linestring:
          final line = switch (geometry) {
            turf.LineString() => TurfConverter.lineStringToLatlngs(geometry),
            turf.MultiLineString(:final coordinates) when coordinates.isNotEmpty => _latLngs(coordinates.first),
            _ => null,
          };
          if (line == null || line.length < 2) return null;
          featureData['line'] = line;

        case GeometryType.polygon:
          final rings = switch (geometry) {
            turf.Polygon() => TurfConverter.polygonToLatlngs(geometry),
            turf.MultiPolygon(:final coordinates) when coordinates.isNotEmpty && coordinates.first.isNotEmpty => [
              for (final ring in coordinates.first) _latLngs(ring),
            ],
            _ => null,
          };
          if (rings == null || rings.isEmpty || rings.first.length < 3) return null;
          featureData['rings'] = rings;
      }

      return featureData;
    } catch (e) {
      AppLogger.debug('[GeoJSONImporter] Feature変換エラー: $e');
      return null;
    }
  }

  /// turfのFeatureリストからスキーマを抽出してGeoPackageに追加（列の型は最初に出てきた値で決める）
  Future<void> _addSchemaFromFeatures(
    GeoPackageNode targetGeoPackage,
    String layerName,
    List<turf.Feature> features,
  ) async {
    try {
      final attributeSchema = <String, String>{};
      for (final feature in features) {
        for (final MapEntry(:key, :value) in (feature.properties ?? const <String, dynamic>{}).entries) {
          attributeSchema.putIfAbsent(key, () => BaseImporter.sqliteTypeOf(value));
        }
      }
      if (attributeSchema.isNotEmpty) {
        await targetGeoPackage.geoPackageFile.addAttributeColumns(layerName, attributeSchema);
      }
    } catch (e) {
      AppLogger.debug('[GeoJSONImporter] スキーマ追加エラー: $e');
    }
  }
}
