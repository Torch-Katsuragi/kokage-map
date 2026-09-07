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
// Root Maps: KML Exporter
// KMLエクスポートクラス
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../../../models/geometry_type.dart';
import '../../../models/nodes/layer_node.dart';
import '../import_export_models.dart';
import 'base_exporter.dart';

/// KMLエクスポーター
class KMLExporter extends BaseExporter {
  @override
  FileFormat get format => FileFormat.kml;

  @override
  Future<ImportExportResult> export(
    LayerNode layer,
    String outputPath, {
    ExportOptions options = const ExportOptions(),
  }) async {
    try {
      AppLogger.debug('[KMLExporter] エクスポート開始: ${layer.layerName}');

      final features = await layer.geoPackageNode.geoPackageFile.getFeatures(
        layer.layerName,
      );
      final geometryType = await layer.geoPackageNode.geoPackageFile
          .getGeometryType(layer.layerName);

      if (features.isEmpty) {
        return ImportExportResult.error('No features found in layer: ${layer.layerName}');
      }

      final kmlContent = StringBuffer();
      kmlContent.writeln('<?xml version="1.0" encoding="UTF-8"?>');
      kmlContent.writeln('<kml xmlns="http://www.opengis.net/kml/2.2">');
      kmlContent.writeln('  <Document>');
      kmlContent.writeln('    <name>${_escapeXmlValue(layer.layerName)}</name>');

      for (final feature in features) {
        kmlContent.writeln('    <Placemark>');
        kmlContent.writeln(
          '      <name>${_escapeXmlValue(feature['name']?.toString() ?? 'Feature ${feature['id']}')}</name>',
        );
        if (feature['description'] != null &&
            feature['description'].toString().isNotEmpty) {
          kmlContent.writeln(
            '      <description>${_escapeXmlValue(feature['description'].toString())}</description>',
          );
        }

        // ジオメトリ
        if (geometryType == GeometryType.point && feature['points'] != null) {
          final points = feature['points'] as List<LatLng>;
          if (points.isNotEmpty) {
            final point = points.first;
            kmlContent.writeln('      <Point>');
            kmlContent.writeln(
              '        <coordinates>${point.longitude},${point.latitude},0</coordinates>',
            );
            kmlContent.writeln('      </Point>');
          }
        } else if (geometryType == GeometryType.linestring &&
            feature['lines'] != null) {
          final lines = feature['lines'] as List<LatLng>;
          if (lines.isNotEmpty) {
            kmlContent.writeln('      <LineString>');
            kmlContent.writeln('        <coordinates>');
            for (final point in lines) {
              kmlContent.write('          ${point.longitude},${point.latitude},0\n');
            }
            kmlContent.writeln('        </coordinates>');
            kmlContent.writeln('      </LineString>');
          }
        } else if (geometryType == GeometryType.polygon &&
            feature['polygons'] != null) {
          final polygons = feature['polygons'] as List<List<LatLng>>;
          if (polygons.isNotEmpty) {
            kmlContent.writeln('      <Polygon>');
            kmlContent.writeln('        <outerBoundaryIs>');
            kmlContent.writeln('          <LinearRing>');
            kmlContent.writeln('            <coordinates>');
            for (final point in polygons.first) {
              kmlContent.write('              ${point.longitude},${point.latitude},0\n');
            }
            kmlContent.writeln('            </coordinates>');
            kmlContent.writeln('          </LinearRing>');
            kmlContent.writeln('        </outerBoundaryIs>');
            kmlContent.writeln('      </Polygon>');
          }
        }

        kmlContent.writeln('    </Placemark>');
      }

      kmlContent.writeln('  </Document>');
      kmlContent.writeln('</kml>');

      // ファイルに書き込み
      final file = File(outputPath);
      await file.writeAsString(kmlContent.toString());

      AppLogger.debug('[KMLExporter] エクスポート完了: ${features.length}個のフィーチャ');

      return ImportExportResult.success(
        metadata: {
          'outputPath': outputPath,
          'featureCount': features.length,
          'geometryType': geometryType?.value,
          'format': 'KML',
          'fileSize': (await file.stat()).size,
        },
      );
    } catch (e) {
      AppLogger.debug('[KMLExporter] エクスポートエラー: $e');
      return ImportExportResult.error('KML export failed: $e');
    }
  }

  /// XML値をエスケープ
  String _escapeXmlValue(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}

