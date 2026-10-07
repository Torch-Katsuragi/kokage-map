// GeoPackage の座標は CRS の軸順によらず x = 東・y = 北（GDAL / QGIS と同じ）
//
// fixtures/qgis_6674_point.gpkg は QGIS 4.2.2 同梱の ogr2ogr で作った EPSG:6674（平面直角 VI 系）の点 1 つ
// （36N, 136.01E → x = 901.5 m（東）, y = 0.05 m（北））。定義の WKT は AXIS が北・東の順。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => tmp = await Directory.systemTemp.createTemp('gpkg_axis_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<List<geo.Position>> storedPoints(GeoPackageFile gpkg, String table) async {
    final rows = await (await gpkg.getDatabase()).rawQuery('SELECT geom FROM "$table" ORDER BY fid');
    return [for (final r in rows) (parseGpkgGeometry(r['geom']! as dynamic)! as geo.Point).position];
  }

  test('QGIS 製の平面直角の点を正しい位置で読み、書くときも x = 東', () async {
    final path = '${tmp.path}/q.gpkg';
    File('test/fixtures/qgis_6674_point.gpkg').copySync(path);
    final gpkg = GeoPackageFile(const ['q.gpkg'], absolutePath: path);

    final read = (await gpkg.getFeaturesWithGeometry('pts')).single['geometry'] as List;
    final p = read.single as LatLng;
    expect(p.latitude, closeTo(36.0, 1e-9));
    expect(p.longitude, closeTo(136.01, 1e-9));

    await gpkg.addPointWithAttributes('pts', const LatLng(36.0, 136.02), {});
    final stored = await storedPoints(gpkg, 'pts');
    await gpkg.dispose();
    expect(stored[1].x, closeTo(1803.09, 0.01), reason: 'QGIS と同じく x は東（1803 m）');
    expect(stored[1].y, closeTo(0.18, 0.01));
  });

  for (final (label, definition) in [
    ('定義なし（登録済みの proj4 で解決）', 'undefined'),
    (
      'AXIS の無い ESRI 形式の WKT',
      'PROJCS["JGD_2011_Japan_Zone_6",GEOGCS["GCS_JGD_2011",DATUM["D_JGD_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],'
          'PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],'
          'PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",136.0],'
          'PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    ),
  ]) {
    test('$label の平面直角レイヤでも x = 東で書き、同じ位置で読み戻す', () async {
      final path = '${tmp.path}/u.gpkg';
      var gpkg = GeoPackageFile(const ['u.gpkg'], absolutePath: path);
      await gpkg.addLayer('pts', GeometryType.point);
      await gpkg.flushChanges();
      await gpkg.dispose();
      final db = await openDatabase(path, singleInstance: false);
      await db.execute(
        'INSERT OR IGNORE INTO gpkg_spatial_ref_sys (srs_name, srs_id, organization, organization_coordsys_id, definition) '
        "VALUES ('JGD2011 / Japan Plane Rectangular CS VI', 6674, 'EPSG', 6674, ?)",
        [definition],
      );
      await db.execute("UPDATE gpkg_geometry_columns SET srs_id = 6674 WHERE table_name = 'pts'");
      await db.close();

      gpkg = GeoPackageFile(const ['u.gpkg'], absolutePath: path);
      await gpkg.addPointWithAttributes('pts', const LatLng(36.0, 136.01), {});
      final stored = await storedPoints(gpkg, 'pts');
      final back = ((await gpkg.getFeaturesWithGeometry('pts')).single['geometry'] as List).single as LatLng;
      await gpkg.dispose();

      expect(stored.single.x, closeTo(901.55, 0.01));
      expect(stored.single.y, closeTo(0.05, 0.01));
      expect(back.longitude, closeTo(136.01, 1e-9));
      expect(back.latitude, closeTo(36.0, 1e-9));
    });
  }
}
