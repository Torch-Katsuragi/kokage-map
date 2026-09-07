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
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../../../models/geometry_type.dart';
import '../../../models/nodes/layer_node.dart';
import '../import_export_models.dart';
import 'base_exporter.dart';

/// CSVエクスポーター
class CSVExporter extends BaseExporter {
  @override
  FileFormat get format => FileFormat.csv;

  @override
  Future<ImportExportResult> export(
    LayerNode layer,
    String outputPath, {
    ExportOptions options = const ExportOptions(),
  }) async {
    try {
      AppLogger.debug('[CSVExporter] エクスポート開始: ${layer.layerName}');

      final features = await layer.geoPackageNode.geoPackageFile.getFeatures(
        layer.layerName,
      );
      final geometryType = await layer.geoPackageNode.geoPackageFile
          .getGeometryType(layer.layerName);

      if (features.isEmpty) {
        return ImportExportResult.error('No features found in layer: ${layer.layerName}');
      }

      final csvLines = <String>[];

      // ヘッダー行
      final headers = [
        'id',
        'name',
        'description',
        'geometry_type',
        'longitude',
        'latitude',
      ];
      csvLines.add(headers.join(','));

      // データ行
      for (final feature in features) {
        final row = <String>[];
        row.add(feature['id']?.toString() ?? '');
        row.add(_escapeCsvValue(feature['name']?.toString() ?? ''));
        row.add(_escapeCsvValue(feature['description']?.toString() ?? ''));
        row.add(geometryType?.value ?? 'unknown');

        // 座標データを取得
        if (geometryType == GeometryType.point && feature['points'] != null) {
          final points = feature['points'] as List<LatLng>;
          if (points.isNotEmpty) {
            row.add(points.first.longitude.toString());
            row.add(points.first.latitude.toString());
          } else {
            row.add('');
            row.add('');
          }
        } else if (geometryType == GeometryType.linestring &&
            feature['lines'] != null) {
          final lines = feature['lines'] as List<LatLng>;
          if (lines.isNotEmpty) {
            // 線の中心点を計算
            final double avgLng =
                lines.map((p) => p.longitude).reduce((a, b) => a + b) /
                    lines.length;
            final double avgLat =
                lines.map((p) => p.latitude).reduce((a, b) => a + b) /
                    lines.length;
            row.add(avgLng.toString());
            row.add(avgLat.toString());
          } else {
            row.add('');
            row.add('');
          }
        } else {
          row.add('');
          row.add('');
        }

        csvLines.add(row.join(','));
      }

      // ファイルに書き込み
      final file = File(outputPath);
      await file.writeAsString(csvLines.join('\n'));

      AppLogger.debug('[CSVExporter] エクスポート完了: ${features.length}個のフィーチャ');

      return ImportExportResult.success(
        metadata: {
          'outputPath': outputPath,
          'featureCount': features.length,
          'geometryType': geometryType?.value,
          'format': 'CSV',
          'fileSize': (await file.stat()).size,
        },
      );
    } catch (e) {
      AppLogger.debug('[CSVExporter] エクスポートエラー: $e');
      return ImportExportResult.error('CSV export failed: $e');
    }
  }

  /// CSV値をエスケープ
  String _escapeCsvValue(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}

