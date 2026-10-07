// 地物の書き込みはレイヤの CRS に合わせる（1 件ずつでもバッチでも）
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
  setUp(() async => tmp = await Directory.systemTemp.createTemp('gpkg_crs_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('EPSG:6674 のレイヤへは平面直角座標で書く', () async {
    final path = '${tmp.path}/c.gpkg';
    var gpkg = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
    await gpkg.addLayer('pts', GeometryType.point);
    await gpkg.flushChanges();
    await gpkg.dispose();

    final db = await openDatabase(path, singleInstance: false);
    await db.execute(
      'INSERT OR IGNORE INTO gpkg_spatial_ref_sys (srs_name, srs_id, organization, organization_coordsys_id, definition) '
      "VALUES ('JGD2011 / Japan Plane Rectangular CS VI', 6674, 'EPSG', 6674, 'undefined')",
    );
    await db.execute("UPDATE gpkg_geometry_columns SET srs_id = 6674 WHERE table_name = 'pts'");
    await db.close();

    gpkg = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
    // 平面直角座標系 VI 系の原点（36N, 136E）
    const origin = LatLng(36, 136);
    await gpkg.addPointWithAttributes('pts', origin, {});
    await gpkg.addPointsBatch('pts', [
      {'point': origin},
    ]);
    await gpkg.flushChanges();
    final rows = await (await gpkg.getDatabase()).rawQuery('SELECT geom FROM pts');
    await gpkg.dispose();

    expect(rows, hasLength(2));
    for (final r in rows) {
      final g = parseGpkgGeometry(r['geom']! as dynamic)! as geo.Point;
      expect(g.position.x, closeTo(0, 0.01));
      expect(g.position.y, closeTo(0, 0.01));
    }
  });
}
