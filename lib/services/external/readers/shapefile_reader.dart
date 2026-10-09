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
// Shapefile（.shp と付属一式）の読み手

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../../../core/fs/k_file_system.dart';
import '../../../models/geometry_type.dart';
import '../../../utils/app_logger.dart';
import '../../coordinate/epsg_registry.dart';
import '../../coordinate/wkt_parser.dart';
import '../../import_export/parsers/dbf_reader.dart';
import '../../import_export/parsers/shapefile_binary_parser.dart';
import '../external_dataset.dart';
import '../external_dataset_writer.dart';
import '../external_readers.dart';

class ShapefileReader extends ExternalReader {
  /// 付属ファイル（変換で一緒に消す・更新の判定に使う）
  static const sidecars = {
    '.shx', '.dbf', '.prj', '.cpg', '.qix', '.sbn', '.sbx', '.shp.xml', '.fix', '.aih', '.ain', //
  };

  /// `.cpg` が無いときの文字コード（日本の shp はほとんどこれ）
  static const defaultEncoding = 'Shift_JIS';

  @override
  Set<String> get extensions => const {'.shp'};

  @override
  Set<String> get sidecarExtensions => sidecars;

  /// `.prj` の座標系。無い・読めなければ null（WGS84 とみなす）
  static Future<EpsgDefinition?> readPrj(String shpPath) async {
    final prj = await findSidecar(shpPath, '.prj');
    if (prj == null) return null;
    try {
      return WktParser.toEpsgDefinition(await fs.readAsString(prj));
    } catch (e) {
      AppLogger.debug('[ShapefileReader] .prj を読めない: $e');
      return null;
    }
  }

  /// `.dbf` の文字コード（`.cpg` の中身。無ければ [defaultEncoding]）
  static Future<String> dbfEncoding(String shpPath) async {
    final cpg = await findSidecar(shpPath, '.cpg');
    if (cpg == null) return defaultEncoding;
    try {
      final text = (await fs.readAsString(cpg)).trim();
      return text.isEmpty ? defaultEncoding : text;
    } catch (e) {
      AppLogger.debug('[ShapefileReader] .cpg を読めない: $e');
      return defaultEncoding;
    }
  }

  @override
  Future<List<ExternalDataset>> read(String path) async {
    final shpBytes = await fs.readAsBytes(path);
    final info = ShapefileBinaryParser.infoFromBytes(shpBytes);
    if (info == null) throw FormatException('SHP ファイルが短すぎます: $path');

    final crs = await readPrj(path);
    final dbfPath = await findSidecar(path, '.dbf');
    // DbfReader は fs 経由で読み、日本語の文字コードは純 Dart で解く（web でも動く）
    final dbf = dbfPath == null ? null : await DbfReader.read(dbfPath, encoding: await dbfEncoding(path));

    final geometryType = switch (info['geometryType']) {
      'LineString' => GeometryType.linestring,
      'Polygon' => GeometryType.polygon,
      _ => GeometryType.point,
    };

    final columns = <String, String>{
      if (dbf != null)
        for (final MapEntry(key: name, value: values) in dbf.entries)
          name: sqliteTypeOf(values.firstWhere((v) => v != null, orElse: () => null)),
    };

    final features = <Map<String, dynamic>>[];
    for (final record in ShapefileBinaryParser.records(shpBytes, sourceCoordinateSystem: crs)) {
      // DBF で削除済みの行のレコードは読み飛ばす（GDAL/QGIS と同じ）
      if (DbfReader.isDeletedRecord(dbf, record.index)) continue;
      final data = _featureData(record, DbfReader.getAttributesForRecord(dbf, record.index));
      if (data != null) features.add(data);
    }

    return [
      ExternalDataset(
        layerName: p.basenameWithoutExtension(path),
        geometryType: geometryType,
        columns: columns,
        features: features,
      ),
    ];
  }

  /// レコードを GeoPackage に書く形にする。形の種類が合わなければ null
  static Map<String, dynamic>? _featureData(ShpRecord record, Map<String, dynamic> attributes) {
    final geometry = record.geometry;
    return switch (record.shapeType) {
      ShapeType.point when geometry is LatLng => {...attributes, 'point': geometry},
      ShapeType.polyLine when geometry is List<LatLng> && geometry.length >= 2 => {...attributes, 'line': geometry},
      ShapeType.polygon when geometry is List<List<LatLng>> && geometry.isNotEmpty => {...attributes, 'rings': geometry},
      _ => null,
    };
  }
}
