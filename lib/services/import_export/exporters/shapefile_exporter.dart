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
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../../../models/geometry_type.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../utils/wkb_utils.dart';
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
  Future<ImportExportResult> export(
    LayerNode layer,
    String outputPath, {
    ExportOptions options = const ExportOptions(),
  }) async {
    try {
      final targetCrs = options.targetCrs;
      final crsInfo = targetCrs != null ? targetCrs.code : 'WGS84';
      AppLogger.debug('[ShapefileExporter] エクスポート開始: ${layer.layerName} (CRS: $crsInfo)');

      final features = await layer.geoPackageNode.geoPackageFile.getFeatures(
        layer.layerName,
      );
      final geometryType = await layer.geoPackageNode.geoPackageFile
          .getGeometryType(layer.layerName);

      if (features.isEmpty) {
        return ImportExportResult.error('No features found in layer: ${layer.layerName}');
      }

      final shapeType = switch (geometryType) {
        GeometryType.point => ShapeType.point,
        GeometryType.linestring => ShapeType.polyLine,
        GeometryType.polygon => ShapeType.polygon,
        _ => null,
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
      for (final feature in features) {
        final shape = _toShape(feature, geometryType, targetProjection);
        if (shape == null) continue;
        shapes.add(shape);
        attributes.add({
          for (final MapEntry(:key, :value) in feature.entries)
            if (value != null && !_reservedKeys.contains(key.toLowerCase()))
              key: value,
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
          'format': 'Shapefile',
          'crs': targetCrs?.code ?? 'EPSG:4326',
        },
      );
    } catch (e, stackTrace) {
      AppLogger.debug('[ShapefileExporter] エクスポートエラー: $e');
      AppLogger.debug('[ShapefileExporter] スタックトレース: $stackTrace');
      return ImportExportResult.error('Shapefile export failed: $e');
    }
  }

  /// WGS84座標をターゲットCRSに変換し [x, y] で返す。
  /// proj4dartは常に(X=Easting, Y=Northing)順で出力する。
  /// 日本の平面直角座標系の公式定義は(X=Northing, Y=Easting)だが、
  /// QGISを含む多くのGISソフトは(Easting, Northing)として扱うので入れ替えない
  List<double> _project(LatLng p, Projection? target) {
    if (target == null) return [p.longitude, p.latitude];
    final out = Projections.wgs84.transform(target, Point(x: p.longitude, y: p.latitude));
    return [out.x, out.y];
  }

  /// フィーチャの形を Shapefile の部分の並びにする（座標変換込み）。
  /// 多重の形は最初の 1 つだけを書く。面のリングは閉じる
  ShpShape? _toShape(
    Map<String, dynamic> feature,
    GeometryType type,
    Projection? target,
  ) {
    List<List<double>> project(List<LatLng> ring) =>
        [for (final p in ring) _project(p, target)];

    switch (type) {
      case GeometryType.point:
        var points = feature['points'] as List<LatLng>?;
        if (points == null || points.isEmpty) {
          final parsed = _parseGeom(feature);
          if (parsed is List<LatLng>) points = parsed;
        }
        if (points == null || points.isEmpty) return null;
        return [
          [_project(points.first, target)]
        ];

      case GeometryType.linestring:
        var lines = feature['lines'] as List<List<LatLng>>?;
        if (lines == null || lines.isEmpty) {
          final parsed = _parseGeom(feature);
          if (parsed is List<List<LatLng>>) {
            lines = parsed;
          } else if (parsed is List<LatLng>) {
            lines = [parsed];
          }
        }
        if (lines == null || lines.isEmpty) return null;
        return [project(lines.first)];

      case GeometryType.polygon:
        var rings = feature['polygons'] as List<List<LatLng>>?;
        if (rings == null || rings.isEmpty) {
          final parsed = _parseGeom(feature);
          if (parsed is List<List<List<LatLng>>>) {
            rings = parsed.isNotEmpty ? parsed.first : null;
          } else if (parsed is List<List<LatLng>>) {
            rings = parsed;
          }
        }
        if (rings == null || rings.isEmpty) return null;
        return [
          for (final ring in rings)
            project(ring)..closeRing(),
        ];
    }
  }

  /// `geom` 列（GeoPackage のバイナリ）から LatLng の入れ子を取り出す
  Object? _parseGeom(Map<String, dynamic> feature) {
    final geom = feature['geom'];
    final bytes = switch (geom) {
      Uint8List() => geom,
      List<int>() => Uint8List.fromList(geom),
      _ => null,
    };
    if (bytes == null) return null;
    final parsed = parseGpkgGeometry(bytes);
    return parsed == null ? null : geobaseGeometryToLatLngs(parsed);
  }

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
