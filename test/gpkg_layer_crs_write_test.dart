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
    // QGIS 製と同じ形の R-Tree（アプリが自分で入れ直す）
    await db.execute('CREATE VIRTUAL TABLE rtree_pts_geom USING rtree(id, minx, maxx, miny, maxy)');
    await db.execute("UPDATE gpkg_contents SET min_x = NULL, min_y = NULL, max_x = NULL, max_y = NULL WHERE table_name = 'pts'");
    await db.close();

    gpkg = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
    // 平面直角座標系 VI 系の原点（36N, 136E）
    const origin = LatLng(36, 136);
    await gpkg.addPointWithAttributes('pts', origin, {});
    await gpkg.addPointsBatch('pts', [
      {'point': origin},
    ]);
    // 1 件目を東へ動かす（VI 系の原点から経度方向に少し）
    final moved = await gpkg.addPointWithAttributes('pts', origin, {});
    await gpkg.updatePoint('pts', moved!, const LatLng(36, 136.01));
    await gpkg.flushChanges();
    final db2 = await gpkg.getDatabase();
    final rows = await db2.rawQuery('SELECT fid, geom FROM pts ORDER BY fid');
    final rtree = await db2.rawQuery('SELECT id, minx, miny FROM rtree_pts_geom ORDER BY id');
    final contents = (await db2.rawQuery("SELECT min_x, max_x FROM gpkg_contents WHERE table_name = 'pts'")).single;
    await gpkg.dispose();

    expect(rows, hasLength(3));
    for (final r in rows.take(2)) {
      final g = parseGpkgGeometry(r['geom']! as dynamic)! as geo.Point;
      expect(g.position.x, closeTo(0, 0.01));
      expect(g.position.y, closeTo(0, 0.01));
    }
    // 索引もレイヤの範囲も保存した座標（平面直角・m）と同じ値で入る。WGS84（136 度）ではない。
    // 動かした 3 件目は更新のあとの位置
    expect(rtree.map((r) => r['id']), [1, 2, 3]);
    for (var i = 0; i < 3; i++) {
      final p = (parseGpkgGeometry(rows[i]['geom']! as dynamic)! as geo.Point).position;
      expect(rtree[i]['minx']! as num, closeTo(p.x, 0.01));
      expect(rtree[i]['miny']! as num, closeTo(p.y, 0.01));
    }
    final movedPos = (parseGpkgGeometry(rows[2]['geom']! as dynamic)! as geo.Point).position;
    expect(movedPos.x.abs() + movedPos.y.abs(), greaterThan(800)); // 0.01 度 ≒ 900 m
    expect(contents['min_x']! as num, lessThan(1));
    expect(contents['max_x']! as num, lessThan(1000));
  });
  test('EPSG:6674 のレイヤへ面を書いて読み戻すと元の位置（座標が潰れない）', () async {
    final path = '${tmp.path}/g.gpkg';
    var gpkg = GeoPackageFile(const ['g.gpkg'], absolutePath: path);
    await gpkg.addLayer('polys', GeometryType.polygon);
    await gpkg.flushChanges();
    await gpkg.dispose();
    final db = await openDatabase(path, singleInstance: false);
    await db.execute(
      'INSERT OR IGNORE INTO gpkg_spatial_ref_sys (srs_name, srs_id, organization, organization_coordsys_id, definition) '
      "VALUES ('JGD2011 / Japan Plane Rectangular CS VI', 6674, 'EPSG', 6674, 'undefined')",
    );
    await db.execute("UPDATE gpkg_geometry_columns SET srs_id = 6674 WHERE table_name = 'polys'");
    await db.close();

    gpkg = GeoPackageFile(const ['g.gpkg'], absolutePath: path);
    const ring = [LatLng(33.90, 135.95), LatLng(33.90, 135.97), LatLng(33.92, 135.97), LatLng(33.90, 135.95)];
    final id = await gpkg.addPolygonWithAttributes('polys', [ring], {});
    final stored = (await (await gpkg.getDatabase()).rawQuery('SELECT geom FROM polys')).single;
    final g = parseGpkgGeometry(stored['geom']! as dynamic)!;
    final back = await gpkg.getFeature('polys', id!);
    await gpkg.dispose();

    // 保存した値は m（数万 m 台）。緯度経度の範囲に丸められていない
    final p0 = (g as geo.MultiPolygon).polygons.first.exterior!.positions.first;
    expect(p0.x.abs() + p0.y.abs(), greaterThan(10000));
    // 読み戻すと元の緯度経度
    Object first = back!['geometry'] as List;
    while (first is List) {
      first = first.first as Object; // 多重の面・リングの入れ子を最初の点までたどる
    }
    first as LatLng;
    expect(first.latitude, closeTo(33.90, 1e-6));
    expect(first.longitude, closeTo(135.95, 1e-6));
  });
}
