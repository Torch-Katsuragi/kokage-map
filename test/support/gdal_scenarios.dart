// GDAL の筋書き（ホスト VM の test/gdal_test.dart と実機の integration_test/device/gdal_smoke_test.dart で共有）。
// 入力はその場で書く（実機には test/fixtures が無い）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal.dart';

const gdalScenarioNames = ['スギ1', 'ヒノキ2', '北山村役場'];

const _pointsGeoJson = '''
{"type":"FeatureCollection","features":[
{"type":"Feature","properties":{"name":"スギ1","dbh":32},"geometry":{"type":"Point","coordinates":[135.96,33.93]}},
{"type":"Feature","properties":{"name":"ヒノキ2","dbh":28},"geometry":{"type":"Point","coordinates":[135.961,33.931]}},
{"type":"Feature","properties":{"name":"北山村役場","dbh":0},"geometry":{"type":"Point","coordinates":[135.97,33.94]}}
]}''';

/// 書き出し先の形式 → (拡張子, 追加の引数)。アプリの libgdal.so に入れたベクタのドライバ全部
const gdalScenarioVectorFormats = <String, (String, List<String>)>{
  'GPKG': ('gpkg', []),
  // ⚠ 指定しないと GDAL は shp を ISO-8859-1 で書く（日本語が落ちる）。QGIS の新規 shp は UTF-8
  'ESRI Shapefile': ('shp', ['-lco', 'ENCODING=UTF-8']),
  'GeoJSON': ('geojson', []),
  'GeoJSONSeq': ('geojsons', []),
  'KML': ('kml', []),
  'CSV': ('csv', ['-lco', 'GEOMETRY=AS_XY']),
  'FlatGeobuf': ('fgb', []),
  'GPX': ('gpx', ['-dsco', 'GPX_USE_EXTENSIONS=YES']),
  'GML': ('gml', []),
  // DXF は任意の属性列を持てない（列を落とす）。書くには GDAL_DATA の header.dxf が要る
  'DXF': ('dxf', ['-select', '']),
  'MapInfo File': ('tab', []),
  'OpenFileGDB': ('gdb', []),
};

/// ogrinfo -json -features の 1 枚目のレイヤ
Map<String, dynamic> firstLayer(Map<String, dynamic> info) => (info['layers'] as List).first as Map<String, dynamic>;

/// JSON を鍵（Map の鍵か List の添字）でたどる。途中で無ければ null
Object? dig(Object? json, List<Object> keys) {
  var o = json;
  for (final k in keys) {
    o = switch ((o, k)) {
      (final Map m, _) => m[k],
      (final List l, final int i) when i < l.length => l[i],
      _ => null,
    };
  }
  return o;
}

/// 1 枚目のレイヤの各フィーチャの属性 [field]
List<Object?> featureValues(Map<String, dynamic> info, String field) =>
    [for (final f in firstLayer(info)['features'] as List) dig(f, ['properties', field])];

/// 1 枚目のレイヤの 1 本目のジオメトリ列の CRS の EPSG コード（projjson の id）
Object? layerEpsg(Map<String, dynamic> info) =>
    dig(firstLayer(info), ['geometryFields', 0, 'coordinateSystem', 'projjson', 'id', 'code']);

/// GeoJSON を書いて、各形式に ogr2ogr して読み戻す。形式 → 読み戻した件数
Future<Map<String, int>> gdalVectorRoundTrip(Gdal g, String dir) async {
  final src = p.join(dir, 'points.geojson');
  await File(src).writeAsString(_pointsGeoJson);
  final out = <String, int>{};
  for (final e in gdalScenarioVectorFormats.entries) {
    final (ext, extra) = e.value;
    final dst = p.join(dir, 'rt_${ext}_out.$ext');
    try {
      await g.vectorTranslate(src, dst, args: ['-f', e.key, ...extra]);
      final info = await g.vectorInfo(dst, args: const ['-so']);
      out[e.key] = firstLayer(info)['featureCount'] as int;
    } on GdalException catch (err) {
      throw GdalException('${e.key}: ${err.message}');
    }
  }
  return out;
}

/// Shift_JIS の shp（.cpg も LDID も無い）を作って読む。読めた name 列を返す。iconv（CP932）と既定の文字コードの確認
Future<List<String?>> gdalShiftJisShapefile(Gdal g, String dir) async {
  final src = p.join(dir, 'points_sjis_src.geojson');
  await File(src).writeAsString(_pointsGeoJson);
  final shp = p.join(dir, 'sjis.shp');
  await g.vectorTranslate(src, shp, args: ['-f', 'ESRI Shapefile', '-t_srs', 'EPSG:6674', '-lco', 'ENCODING=CP932']);
  await File(p.join(dir, 'sjis.cpg')).delete();
  final dbf = File(p.join(dir, 'sjis.dbf'));
  final bytes = await dbf.readAsBytes();
  bytes[29] = 0; // LDID（言語ドライバ ID）を「無し」に
  await dbf.writeAsBytes(bytes, flush: true);
  final info = await g.vectorInfo(shp, args: const ['-features']);
  return featureValues(info, 'name').cast<String?>();
}

/// shp（EPSG:6674）→ gpkg で CRS が保たれるか。gpkg のレイヤの EPSG コードを返す
Future<int?> gdalShpToGpkgCrs(Gdal g, String dir) async {
  final shp = p.join(dir, 'sjis.shp'); // gdalShiftJisShapefile が作ったもの
  final gpkg = p.join(dir, 'sjis.gpkg');
  await g.vectorTranslate(shp, gpkg, args: const ['-f', 'GPKG']);
  final info = await g.vectorInfo(gpkg, args: const ['-so']);
  return layerEpsg(info) as int?;
}

/// 8x8 の EPSG:6674 ラスタ（VRT → LZW GeoTIFF）を EPSG:4326 に warp して PNG / JPEG に。PNG の gdalinfo を返す
Future<Map<String, dynamic>> gdalRasterPipeline(Gdal g, String dir) async {
  final vrt = p.join(dir, 'src.vrt');
  await File(vrt).writeAsString('<VRTDataset rasterXSize="8" rasterYSize="8"><SRS>EPSG:6674</SRS>'
      '<GeoTransform>-3700, 10, 0, -229600, 0, -10</GeoTransform>'
      '<VRTRasterBand dataType="Byte" band="1"><NoDataValue>0</NoDataValue></VRTRasterBand></VRTDataset>');
  final tif = p.join(dir, 'dem_6674.tif');
  await g.translate(vrt, tif, args: const ['-of', 'GTiff', '-co', 'COMPRESS=LZW', '-a_nodata', 'none', '-scale', '0', '1', '100', '100']);
  final warped = p.join(dir, 'dem_4326.tif');
  await g.warp(tif, warped, args: const ['-t_srs', 'EPSG:4326', '-ts', '16', '0', '-of', 'GTiff']);
  final png = p.join(dir, 'dem_4326.png');
  await g.translate(warped, png, args: const ['-of', 'PNG']);
  await g.translate(warped, p.join(dir, 'dem_4326.jpg'), args: const ['-of', 'JPEG']);
  return g.rasterInfo(png);
}
