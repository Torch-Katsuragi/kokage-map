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
// Root Maps: Shapefile Exporter
// Shapefileエクスポートクラス（CRS変換対応）
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';

import '../../../models/geometry_type.dart';
import '../../../utils/app_logger.dart';
import '../../coordinate/epsg_registry.dart';
import '../../coordinate/projections.dart';
import '../import_export_models.dart';
import '../parsers/shapefile_binary_parser.dart' show ShapeType;
import 'base_exporter.dart';
import 'shapefile_writer.dart';

/// Shapefileエクスポーター（CRS変換対応）
class ShapefileExporter extends BaseExporter {
  final EpsgRegistry _epsgRegistry = EpsgRegistry();

  /// 属性に出さない列（形の列と GeoPackage の内部列）
  static const _reservedKeys = {
    'fid', 'geom', 'id', 'rowid', 'geometry',
    'points', 'lines', 'polygons', 'rings', 'point', 'line',
  };

  @override
  FileFormat get format => FileFormat.shapefile;

  @override
  Future<ImportExportResult> write(ExportSource source, String outputPath, ExportOptions options) async {
    final targetCrs = options.targetCrs;
    final geometryType = source.geometryType;
    AppLogger.debug('[ShapefileExporter] CRS: ${targetCrs?.code ?? 'WGS84'}');

    final shapeType = switch (geometryType) {
      GeometryType.point => ShapeType.point,
      GeometryType.linestring => ShapeType.polyLine,
      GeometryType.polygon => ShapeType.polygon,
      null => null,
    };
    if (geometryType == null || shapeType == null) {
      return ImportExportResult.error('Unsupported geometry type: ${geometryType?.value}');
    }

    // 座標変換用の投影を準備
    Projection? targetProjection;
    if (targetCrs != null && !options.isWgs84) {
      targetProjection = Projections.parse(targetCrs.proj4String);
      if (targetProjection == null) {
        return ImportExportResult.error('Invalid CRS definition: ${targetCrs.code}');
      }
      AppLogger.debug('[ShapefileExporter] 座標変換有効: ${targetCrs.code}');
    }

    final shapes = <ShpShape>[];
    final attributes = <Map<String, dynamic>>[];
    for (final feature in source.features) {
      final parts = source.parts(feature);
      if (parts == null) continue;
      shapes.add([
        for (final part in parts)
          if (geometryType == GeometryType.polygon)
            _project(part, targetProjection)..closeRing()
          else
            _project(part, targetProjection),
      ]);
      attributes.add({
        for (final MapEntry(:key, :value) in feature.entries)
          if (value != null && !_reservedKeys.contains(key.toLowerCase())) key: value,
      });
    }

    if (shapes.isEmpty) {
      return ImportExportResult.error('No valid features could be converted for export');
    }

    final basePath = _getBasePathWithoutExtension(outputPath);
    final shpShx = encodeShpShx(shapeType, shapes);
    await Future.wait([
      File('$basePath.shp').writeAsBytes(shpShx.shp),
      File('$basePath.shx').writeAsBytes(shpShx.shx),
      File('$basePath.dbf').writeAsBytes(
        encodeDbf(attributes, includeRowNumber: options.includeRowNumber),
      ),
      File('$basePath.cpg').writeAsString('CP932'),
      File('$basePath.prj').writeAsString(_prjWkt(targetCrs)),
    ]);

    AppLogger.debug('[ShapefileExporter] エクスポート完了: ${shapes.length}個のフィーチャ');

    return ImportExportResult.success(
      metadata: {
        'outputPath': outputPath,
        'featureCount': shapes.length,
        'geometryType': geometryType.value,
        'format': format.value,
        'crs': targetCrs?.code ?? 'EPSG:4326',
      },
    );
  }

  /// WGS84座標をターゲットCRSに変換し [x, y] の並びで返す。
  /// proj4dartは常に(X=Easting, Y=Northing)順で出力する。
  /// 日本の平面直角座標系の公式定義は(X=Northing, Y=Easting)だが、
  /// QGISを含む多くのGISソフトは(Easting, Northing)として扱うので入れ替えない
  static List<List<double>> _project(List<LatLng> points, Projection? target) => [
    for (final p in points)
      if (target == null)
        [p.longitude, p.latitude]
      else
        switch (Projections.wgs84.transform(target, Point(x: p.longitude, y: p.latitude))) {
          final out => [out.x, out.y],
        },
  ];

  /// レジストリ未登録のCRSはWGS84のWKTにフォールバック
  String _prjWkt(EpsgDefinition? targetCrs) {
    if (targetCrs != null) {
      final wkt = _epsgRegistry.getWktString(targetCrs.code);
      if (wkt != null) return wkt;
      AppLogger.debug('[ShapefileExporter] PRJ: ${targetCrs.code} 未登録、WGS84使用');
    }
    return _epsgRegistry.getWktString('EPSG:4326')!;
  }

  /// 拡張子なしのベースパスを取得
  String _getBasePathWithoutExtension(String outputPath) {
    final lastDotIndex = outputPath.lastIndexOf('.');
    final lastSeparatorIndex = [
      outputPath.lastIndexOf('/'),
      outputPath.lastIndexOf('\\'),
    ].reduce((a, b) => a > b ? a : b);

    if (lastDotIndex == -1 || lastDotIndex < lastSeparatorIndex) {
      return outputPath;
    }

    return outputPath.substring(0, lastDotIndex);
  }
}

extension on List<List<double>> {
  void closeRing() {
    if (isEmpty) return;
    final first = this.first;
    final last = this.last;
    if (first[0] != last[0] || first[1] != last[1]) add([first[0], first[1]]);
  }
}
