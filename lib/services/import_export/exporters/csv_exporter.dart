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
// Root Maps: CSV Exporter
// CSVエクスポートクラス
import 'package:latlong2/latlong.dart';

import '../../../models/geometry_type.dart';
import '../import_export_models.dart';
import 'base_exporter.dart';

/// CSVエクスポーター。点はその座標、線は頂点の平均を経緯度の列に書く（面は空）
class CSVExporter extends BaseExporter {
  @override
  FileFormat get format => FileFormat.csv;

  @override
  Future<ImportExportResult> write(ExportSource source, String outputPath, ExportOptions options) {
    final csv = StringBuffer('id,name,description,geometry_type,longitude,latitude');
    final typeName = source.geometryType?.value ?? 'unknown';
    for (final feature in source.features) {
      csv
        ..write('\n')
        ..write(feature['id']?.toString() ?? '')
        ..write(',')
        ..write(_escapeCsvValue(feature['name']?.toString() ?? ''))
        ..write(',')
        ..write(_escapeCsvValue(feature['description']?.toString() ?? ''))
        ..write(',')
        ..write(typeName)
        ..write(',')
        ..write(_lonLat(source.geometryType, source.parts(feature)));
    }
    return writeText(source, outputPath, csv.toString(), featureCount: source.features.length);
  }

  /// `経度,緯度`（座標が無ければ `,`）
  static String _lonLat(GeometryType? type, List<List<LatLng>>? parts) {
    final points = parts?.first;
    if (points == null || points.isEmpty) return ',';
    switch (type) {
      case GeometryType.point:
        return '${points.first.longitude},${points.first.latitude}';
      case GeometryType.linestring:
        // 線の中心点
        final double avgLng = points.map((p) => p.longitude).reduce((a, b) => a + b) / points.length;
        final double avgLat = points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
        return '$avgLng,$avgLat';
      default:
        return ',';
    }
  }

  /// CSV値をエスケープ
  static String _escapeCsvValue(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
