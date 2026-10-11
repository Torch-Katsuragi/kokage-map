// テスト用の点の Shapefile 一式を GDAL（ogr2ogr）で書く（純 Dart の shp 書き出しは 2026-10-10 に GDAL へ置き換えて消した）
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:root_maps/core/gdal/gdal.dart';

/// [base]（拡張子なし）に点の shp 一式を書く。[points] は (x, y, 属性)。
///
/// - [epsg]: `.prj` に書く座標系（`-a_srs`。座標は変換しない）。null なら `.prj` を書かない
/// - [encoding]: DBF の文字コード（`-lco ENCODING`）。[cpg] が false なら `.cpg` を消し、DBF の LDID も 0 にする
///   （「.cpg も LDID も無い」古い shp。アプリは CP932 とみなす）
Future<void> writePointShp(
  Gdal gdal,
  String base,
  List<(double, double, Map<String, Object?>)> points, {
  String? epsg,
  String encoding = 'CP932',
  bool cpg = true,
}) async {
  final src = p.join(Directory.systemTemp.path, 'shp_fixture_${DateTime.now().microsecondsSinceEpoch}.geojson');
  await File(src).writeAsString(jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      for (final (x, y, props) in points)
        {
          'type': 'Feature',
          'properties': props,
          'geometry': {
            'type': 'Point',
            'coordinates': [x, y],
          },
        },
    ],
  }));
  try {
    await gdal.vectorTranslate(src, '$base.shp', args: [
      '-f', 'ESRI Shapefile',
      '-lco', 'ENCODING=$encoding',
      '-a_srs', epsg ?? 'EPSG:4326',
    ]);
  } finally {
    await File(src).delete();
  }
  if (epsg == null) await File('$base.prj').delete();
  if (!cpg) {
    await File('$base.cpg').delete();
    final dbf = File('$base.dbf');
    final bytes = await dbf.readAsBytes();
    bytes[29] = 0;
    await dbf.writeAsBytes(bytes);
  }
}
