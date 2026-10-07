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
import 'package:latlong2/latlong.dart';

import '../../../models/geometry_type.dart';
import '../import_export_models.dart';
import 'base_exporter.dart';

/// KMLエクスポーター。面は外周だけを書く
class KMLExporter extends BaseExporter {
  @override
  FileFormat get format => FileFormat.kml;

  @override
  Future<ImportExportResult> write(ExportSource source, String outputPath, ExportOptions options) {
    final kml = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
      ..writeln('  <Document>')
      ..writeln('    <name>${_escapeXmlValue(source.layer.layerName)}</name>');

    for (final feature in source.features) {
      kml
        ..writeln('    <Placemark>')
        ..writeln('      <name>${_escapeXmlValue(feature['name']?.toString() ?? 'Feature ${feature['id']}')}</name>');
      final description = feature['description']?.toString();
      if (description != null && description.isNotEmpty) {
        kml.writeln('      <description>${_escapeXmlValue(description)}</description>');
      }
      _writeGeometry(kml, source.geometryType, source.parts(feature));
      kml.writeln('    </Placemark>');
    }

    kml
      ..writeln('  </Document>')
      ..writeln('</kml>');
    return writeText(source, outputPath, kml.toString(), featureCount: source.features.length);
  }

  static void _writeGeometry(StringBuffer kml, GeometryType? type, List<List<LatLng>>? parts) {
    if (parts == null) return;
    final first = parts.first;
    switch (type) {
      case GeometryType.point:
        final point = first.first;
        kml
          ..writeln('      <Point>')
          ..writeln('        <coordinates>${point.longitude},${point.latitude},0</coordinates>')
          ..writeln('      </Point>');
      case GeometryType.linestring:
        if (first.isEmpty) return;
        kml
          ..writeln('      <LineString>')
          ..writeln('        <coordinates>');
        _writeCoordinates(kml, first, '          ');
        kml
          ..writeln('        </coordinates>')
          ..writeln('      </LineString>');
      case GeometryType.polygon:
        kml
          ..writeln('      <Polygon>')
          ..writeln('        <outerBoundaryIs>')
          ..writeln('          <LinearRing>')
          ..writeln('            <coordinates>');
        _writeCoordinates(kml, first, '              ');
        kml
          ..writeln('            </coordinates>')
          ..writeln('          </LinearRing>')
          ..writeln('        </outerBoundaryIs>')
          ..writeln('      </Polygon>');
      case null:
        return;
    }
  }

  static void _writeCoordinates(StringBuffer kml, List<LatLng> points, String indent) {
    for (final point in points) {
      kml.write('$indent${point.longitude},${point.latitude},0\n');
    }
  }

  /// XML値をエスケープ
  static String _escapeXmlValue(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
