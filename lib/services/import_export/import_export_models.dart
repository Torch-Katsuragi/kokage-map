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
// Root Maps: Import/Export Models
// 書き出しの形式（GDAL のドライバ）と結果
import '../../../models/geometry_type.dart';
import '../../../models/nodes/layer_node.dart';
import '../coordinate/epsg_registry.dart';

/// 書き出しの形式。中身は GDAL のドライバ（`ogr2ogr -f`）。設計は docs/technical/import-export.md
enum FileFormat {
  geopackage('GeoPackage', '.gpkg', 'GPKG'),
  shapefile('Shapefile', '.shp', 'ESRI Shapefile'),
  geojson('GeoJSON', '.geojson', 'GeoJSON', wgs84Only: true),
  kml('KML', '.kml', 'KML', wgs84Only: true),
  csv('CSV', '.csv', 'CSV'),
  gpx('GPX', '.gpx', 'GPX', wgs84Only: true),
  flatgeobuf('FlatGeobuf', '.fgb', 'FlatGeobuf'),
  dxf('DXF', '.dxf', 'DXF');

  const FileFormat(this.value, this.extension, this.driver, {this.wgs84Only = false});

  /// 表示名
  final String value;

  /// 形式に対応する拡張子（`.` 付き）
  final String extension;

  /// GDAL のドライバ名（`-f`）
  final String driver;

  /// 形式の決まりで WGS 84（EPSG:4326）でしか書けない（GeoJSON は RFC 7946、KML・GPX は仕様）
  final bool wgs84Only;

  /// [geometryType] のレイヤを書き出せるか（GPX は点・線だけ。面はドライバが受け付けない）
  bool supports(GeometryType? geometryType) => this != gpx || geometryType != GeometryType.polygon;

  /// ファイル拡張子（`.` 付き・大小は問わない）から形式を判定。`.json` も GeoJSON。分からなければ null
  static FileFormat? fromExtension(String extension) {
    final ext = extension.toLowerCase();
    if (ext == '.json') return FileFormat.geojson;
    for (final f in values) {
      if (f.extension == ext) return f;
    }
    return null;
  }
}

/// 書き出しの結果
class ImportExportResult {
  final bool success;
  final String? errorMessage;
  final List<LayerNode>? createdLayers;
  final Map<String, dynamic>? metadata;

  ImportExportResult({
    required this.success,
    this.errorMessage,
    this.createdLayers,
    this.metadata,
  });

  factory ImportExportResult.success({
    LayerNode? createdLayer,
    List<LayerNode>? createdLayers,
    Map<String, dynamic>? metadata,
  }) {
    final layers = createdLayers ?? (createdLayer != null ? [createdLayer] : null);
    return ImportExportResult(
      success: true,
      createdLayers: layers,
      metadata: metadata,
    );
  }

  factory ImportExportResult.error(String message) {
    return ImportExportResult(success: false, errorMessage: message);
  }
}

/// 書き出しの設定
class ExportOptions {
  /// 書き出す座標系。null ならレイヤの座標系のまま（QGIS の「名前を付けて保存」と同じ）。
  /// [FileFormat.wgs84Only] の形式では使わない
  final EpsgDefinition? targetCrs;

  /// 行番号の列（ROW_NUM。属性テーブルの # と同じ、主キー順に 1 から）を足すか
  final bool includeRowNumber;

  const ExportOptions({
    this.targetCrs,
    this.includeRowNumber = false,
  });
}
