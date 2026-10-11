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
// Root Maps: レイヤの書き出し
// レイヤの gpkg を GDAL の ogr2ogr で各形式に書く（QGIS の「名前を付けて保存」と同じ部品）。
// 設計は docs/technical/import-export.md
import 'package:path/path.dart' as p;

import '../../core/gdal/gdal_provider.dart';
import '../../i18n/strings.g.dart';
import '../../models/geometry_type.dart';
import '../../models/geopackage/feature_repository.dart' show metadataColumn;
import '../../models/gnss_quality.dart';
import '../../models/nodes/layer_node.dart';
import '../../utils/app_logger.dart';
import '../coordinate/epsg_registry.dart';
import '../external/external_source.dart';
import 'import_export_models.dart';

export 'import_export_models.dart';

/// レイヤの書き出しの窓口
class ImportExportService {
  /// シングルトンインスタンス
  static final ImportExportService _instance = ImportExportService._internal();
  factory ImportExportService() => _instance;
  ImportExportService._internal();

  /// 点を POINT として書く形式。アプリの点レイヤは MULTIPOINT と宣言して中身は 1 点ずつなので、宣言どおりに書くと
  /// GeoJSON・KML・FlatGeobuf でも MultiPoint になる（2026-10-11 web で確認）。GPKG だけは元の宣言のまま写す
  static const _singlePointFormats = {
    FileFormat.shapefile,
    FileFormat.csv,
    FileFormat.gpx,
    FileFormat.geojson,
    FileFormat.kml,
    FileFormat.flatgeobuf,
  };

  /// 書き出せる形式（ダイアログの選択肢の順）
  List<FileFormat> getSupportedExportFormats() => FileFormat.values;

  /// `ogr2ogr` の引数（書き出し先・読み元のパスを除く）。
  ///
  /// 座標系はレイヤのまま（[targetCrs] を選んだときだけ `-t_srs`）。形式の決まりで WGS 84 しか書けない形式は 4326 にする。
  /// [rowNumberPk] を渡すと、その主キーの順に ROW_NUM 列を足す（`-sql`）。
  /// [gnssQuality] なら GPS 測量の品質を列に広げる（[gnssQualityColumns]。レイヤにメタデータの列があるときだけ渡す）
  static List<String> exportArgs({
    required FileFormat format,
    required String layerName,
    required GeometryType? geometryType,
    EpsgDefinition? targetCrs,
    String? rowNumberPk,
    bool gnssQuality = false,
  }) {
    String quote(String name) => '"${name.replaceAll('"', '""')}"';
    final extraColumns = [
      if (rowNumberPk != null) 'ROW_NUMBER() OVER (ORDER BY ${quote(rowNumberPk)}) AS ROW_NUM',
      if (gnssQuality) ...gnssQualityColumns,
    ];
    return [
      '-f', format.driver,
      if (format.wgs84Only)
        ...['-t_srs', 'EPSG:4326']
      else if (targetCrs != null)
        ...['-t_srs', targetCrs.code],
      ...switch (format) {
        // QGIS の新規 shp と同じ UTF-8（.cpg に UTF-8 と書く）。付けないと GDAL は ISO-8859-1 で書き、日本語が落ちる
        FileFormat.shapefile => ['-lco', 'ENCODING=UTF-8'],
        FileFormat.geojson => ['-lco', 'RFC7946=YES'],
        FileFormat.csv => ['-lco', geometryType == GeometryType.point ? 'GEOMETRY=AS_XY' : 'GEOMETRY=AS_WKT'],
        // 属性は <extensions> に書く。点は waypoints、線は tracks
        FileFormat.gpx => ['-dsco', 'GPX_USE_EXTENSIONS=YES'],
        // DXF は任意の属性列を持てない（形だけ書く）
        FileFormat.dxf => ['-select', ''],
        _ => const <String>[],
      },
      // アプリの点レイヤは MULTIPOINT と宣言して POINT を入れている。shp（MultiPoint の shp は古いソフトが読めないことがある）・
      // CSV の X/Y・GPX の waypoint は POINT しか受け付けないので、点として書く
      if (geometryType == GeometryType.point && _singlePointFormats.contains(format)) ...['-nlt', 'POINT'],
      if (extraColumns.isNotEmpty && format != FileFormat.dxf) ...[
        '-sql',
        'SELECT *, ${extraColumns.join(', ')} FROM ${quote(layerName)}',
        '-nln', layerName,
      ] else
        layerName,
    ];
  }

  /// GPS 測量の品質を列に広げる SELECT の式（GPKG の SQLite の JSON 関数で kmaps_metadata の測量の記録を読む）。
  /// 点はその 1 点、線・面は頂点の中で最も悪い値（種類・衛星数・平均回数は最小、精度は最大）。
  /// 記録の無い地物（ペンで描いた・quality の無い以前の記録）は NULL。壊れた JSON も NULL（書き出しは止めない）
  static List<String> get gnssQualityColumns {
    const records = "FROM json_each(CASE WHEN json_valid($metadataColumn) THEN $metadataColumn END, '\$.drawing_points') "
        "WHERE json_extract(value, '\$.quality') IS NOT NULL";
    String agg(String fn, String key) => "(SELECT $fn(json_extract(value, '\$.quality.$key')) $records)";
    final rank = [for (final f in GnssFix.values) "WHEN '${f.code}' THEN ${f.index}"].join(' ');
    final label = [for (final f in GnssFix.values) "WHEN ${f.index} THEN '${f.label}'"].join(' ');
    return [
      "CASE (SELECT MIN(CASE json_extract(value, '\$.quality.fix') $rank END) $records) $label END AS gnss_fix",
      '${agg('MIN', 'sats')} AS gnss_sats',
      '${agg('MAX', 'hacc')} AS gnss_hacc',
      '${agg('MIN', 'avg_n')} AS gnss_avg_n',
    ];
  }

  /// [layer] を [outputPath] に書き出す（[outputPath] は `fs` のパス。Shapefile なら付属ファイルも同じフォルダに）。
  ///
  /// 保存待ちの編集は先に gpkg へ書き込む（web は OPFS の元ファイルへのチェックインまで）。
  /// [format] を省けば [outputPath] の拡張子から決める
  Future<ImportExportResult> exportLayer(
    LayerNode layer,
    String outputPath, {
    FileFormat? format,
    ExportOptions options = const ExportOptions(),
  }) async {
    try {
      final targetFormat = format ?? FileFormat.fromExtension(p.extension(outputPath));
      if (targetFormat == null) {
        return ImportExportResult.error(t.importExport.exportUnsupported(format: p.extension(outputPath)));
      }
      final gpkg = layer.geoPackageFile;
      final src = gpkg.getAbsolutePath();
      if (src == null) return ImportExportResult.error(t.importExport.exportFailedShort);

      // 保存待ちの編集を gpkg へ。web は sqlite3 WASM の写しから元ファイルへ（GDAL は元ファイルを読む）
      await gpkg.flushChanges();
      await gpkg.checkIn();

      final geometryType = await gpkg.getGeometryType(layer.layerName);
      if (!targetFormat.supports(geometryType)) {
        return ImportExportResult.error(t.importExport.exportUnsupported(format: targetFormat.value));
      }
      final args = exportArgs(
        format: targetFormat,
        layerName: layer.layerName,
        geometryType: geometryType,
        targetCrs: options.targetCrs,
        rowNumberPk: options.includeRowNumber ? await gpkg.getPrimaryKeyColumn(layer.layerName) : null,
        gnssQuality: options.includeGnssQuality &&
            (await gpkg.getColumnNames(layer.layerName, getAll: true)).contains(metadataColumn),
      );
      AppLogger.debug('[ImportExportService] ogr2ogr ${args.join(' ')} $outputPath $src');
      await ExternalGdal.instance.vectorTranslate(src, outputPath, args: args);

      return ImportExportResult.success(
        metadata: {
          'format': targetFormat.value,
          'featureCount': await gpkg.countFilteredFeatures(layer.layerName, '1=1'),
          'crs': targetFormat.wgs84Only ? 'EPSG:4326' : options.targetCrs?.code ?? t.importExport.crsKeep,
        },
      );
    } on GdalException catch (e) {
      AppLogger.debug('[ImportExportService] 書き出しエラー: $e');
      return ImportExportResult.error(t.importExport.exportFailed(error: e.message));
    } catch (e) {
      AppLogger.debug('[ImportExportService] 書き出しエラー: $e');
      return ImportExportResult.error(t.importExport.exportFailed(error: e.toString()));
    }
  }
}
