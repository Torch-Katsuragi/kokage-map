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

import 'package:latlong2/latlong.dart';
import 'package:turf/turf.dart' as turf;

import '../../../converters/turf_converter.dart';
import '../../../models/geometry_type.dart';
import '../../../utils/app_logger.dart';
import '../import_export_models.dart';
import 'base_exporter.dart';

/// GeoJSONエクスポーター（turfパッケージ活用）
class GeoJSONExporter extends BaseExporter {
  @override
  FileFormat get format => FileFormat.geojson;

  @override
  Future<ImportExportResult> write(ExportSource source, String outputPath, ExportOptions options) {
    final turfFeatures = <turf.Feature>[
      for (final feature in source.features)
        ?_createTurfFeature(source, feature),
    ];

    // GeoJSONデータを生成（layer名を追加）
    final geoJsonData = TurfConverter.createFeatureCollection(turfFeatures).toJson();
    geoJsonData['name'] = source.layer.layerName;

    // 文字列を経ずに UTF-8 のバイト列にする（JsonEncoder.withIndent と同じ書式）
    final bytes = JsonUtf8Encoder('  ').convert(geoJsonData);
    return writeSingleFile(source, outputPath, bytes, featureCount: turfFeatures.length);
  }

  /// フィーチャからturfのFeatureを作成
  turf.Feature? _createTurfFeature(ExportSource source, Map<String, dynamic> feature) {
    try {
      final parts = source.parts(feature);
      final turf.GeometryObject? geometry = switch (source.geometryType) {
        GeometryType.point when parts != null => TurfConverter.createPoint(parts.first.first),
        GeometryType.linestring when parts != null && parts.first.length >= 2 =>
          TurfConverter.createLineString(parts.first),
        GeometryType.polygon when parts != null => TurfConverter.createPolygon([
          for (final ring in parts) _closed(ring),
        ]),
        _ => null,
      };
      if (geometry == null) return null;

      final properties = <String, dynamic>{
        'id': feature['id'],
        'name': feature['name'] ?? '',
        'description': feature['description'] ?? '',
      };
      if (feature['metadata'] case final Map<String, dynamic> metadata) {
        properties.addAll(metadata);
      }
      return turf.Feature(geometry: geometry, properties: properties);
    } catch (e) {
      AppLogger.debug('[GeoJSONExporter] Feature作成エラー: $e');
      return null;
    }
  }

  /// 3 点以上で閉じていないリングは始点を足して閉じる
  static List<LatLng> _closed(List<LatLng> ring) {
    if (ring.length >= 3) {
      final first = ring.first;
      final last = ring.last;
      if (first.latitude != last.latitude || first.longitude != last.longitude) {
        return [...ring, first];
      }
    }
    return ring;
  }
}
