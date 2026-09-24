// GpkgIndexRepair と gpkgEnvelope（ホスト VM）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/gpkg_index_repair.dart';
import 'package:root_maps/services/geodiff/geodiff.dart';
import 'package:root_maps/services/google_drive/gpkg_merger.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => tmp = await Directory.systemTemp.createTemp('gpkg_repair_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('gpkgEnvelope', () {
    test('点', () {
      final env = gpkgEnvelope(createWkbPoint(135.96, 33.93))!;
      expect(env.minX, closeTo(135.96, 1e-12));
      expect(env.maxX, closeTo(135.96, 1e-12));
      expect(env.minY, closeTo(33.93, 1e-12));
      expect(env.maxY, closeTo(33.93, 1e-12));
    });

    test('線（座標から出す）', () {
      final env = gpkgEnvelope(createWkbLineString(const [LatLng(33.9, 135.9), LatLng(34.1, 135.8), LatLng(33.95, 136.2)]))!;
      expect(env.minX, closeTo(135.8, 1e-12));
      expect(env.maxX, closeTo(136.2, 1e-12));
      expect(env.minY, closeTo(33.9, 1e-12));
      expect(env.maxY, closeTo(34.1, 1e-12));
    });

    test('ヘッダーの範囲を読む（big endian・範囲だけ入れた blob）', () {
      // GP, ver0, flags: 範囲 type1, big endian(0), srs 4326, 範囲 = 1,2,3,4、WKB は空の点で壊しておく
      final b = BytesBuilder()
        ..add([0x47, 0x50, 0x00, 0x02])
        ..add((ByteData(4)..setUint32(0, 4326)).buffer.asUint8List());
      for (final v in [1.0, 2.0, 3.0, 4.0]) {
        b.add((ByteData(8)..setFloat64(0, v)).buffer.asUint8List());
      }
      b.add([0x00, 0x00, 0x00, 0x00, 0x01]);
      final env = gpkgEnvelope(b.toBytes())!;
      expect([env.minX, env.maxX, env.minY, env.maxY], [1.0, 2.0, 3.0, 4.0]);
    });

    test('空ジオメトリの印・壊れた blob は null', () {
      expect(gpkgEnvelope(Uint8List.fromList([0x47, 0x50, 0x00, 0x11, 0, 0, 0x10, 0xE6])), isNull);
      expect(gpkgEnvelope(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  Future<String> gpkgWithRtree(String path) async {
    final gpkg = GeoPackageFile(const ['x.gpkg'], absolutePath: path);
    await gpkg.addLayer('trees', GeometryType.point);
    await gpkg.addAttributeColumns('trees', {'name': 'TEXT'});
    await gpkg.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {'name': 'a'});
    await gpkg.addPointWithAttributes('trees', const LatLng(33.94, 135.97), {'name': 'b'});
    await gpkg.flushChanges();
    await gpkg.dispose();
    // QGIS / GDAL 製と同じ形の rtree を後から付ける
    final db = await openDatabase(path, singleInstance: false);
    await db.execute('CREATE VIRTUAL TABLE rtree_trees_geom USING rtree(id, minx, maxx, miny, maxy)');
    await db.execute('INSERT INTO rtree_trees_geom VALUES (1, 135.96, 135.96, 33.93, 33.93)');
    await db.execute('INSERT INTO rtree_trees_geom VALUES (2, 135.97, 135.97, 33.94, 33.94)');
    await db.close();
    return path;
  }

  Future<List<Map<String, Object?>>> q(String path, String sql) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      return await db.rawQuery(sql);
    } finally {
      await db.close();
    }
  }

  test('rebuild: rtree を実データから焼き直し、gpkg_contents の範囲を合わせる', () async {
    final path = await gpkgWithRtree('${tmp.path}/r.gpkg');
    // rtree の外で行を足し・消す（geodiff の rebase が入れた行と同じ状況）
    final db = await openDatabase(path, singleInstance: false);
    await db.execute('INSERT INTO trees (geom, name) SELECT geom, \'far\' FROM trees WHERE fid = 1');
    await db.execute('UPDATE trees SET geom = ? WHERE fid = 3', [createWkbPoint(136.5, 34.5)]);
    await db.execute('DELETE FROM trees WHERE fid = 2');
    await db.close();
    expect((await q(path, 'SELECT id FROM rtree_trees_geom ORDER BY id')).map((r) => r['id']), [1, 2]);

    expect(await GpkgIndexRepair.rebuildFile(path), 1);

    final ids = (await q(path, 'SELECT id FROM rtree_trees_geom ORDER BY id')).map((r) => r['id']).toList();
    expect(ids, [1, 3]);
    final far = (await q(path, 'SELECT minx, miny FROM rtree_trees_geom WHERE id = 3')).single;
    expect(far['minx'], closeTo(136.5, 1e-4));
    expect(far['miny'], closeTo(34.5, 1e-4));
    final c = (await q(path, "SELECT min_x, max_x, min_y, max_y FROM gpkg_contents WHERE table_name = 'trees'")).single;
    expect(c['min_x'], closeTo(135.96, 1e-4));
    expect(c['max_x'], closeTo(136.5, 1e-4));
    expect(c['max_y'], closeTo(34.5, 1e-4));
  });

  test('rtree の無い gpkg（このアプリ製）は何もしない', () async {
    final gpkg = GeoPackageFile(const ['n.gpkg'], absolutePath: '${tmp.path}/n.gpkg');
    await gpkg.addLayer('trees', GeometryType.point);
    await gpkg.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {});
    await gpkg.flushChanges();
    await gpkg.dispose();
    expect(await GpkgIndexRepair.rebuildFile('${tmp.path}/n.gpkg'), 0);
  });

  test('geodiff の rebase で入った行は rtree に無い → 焼き直しで載る', () async {
    final g = Geodiff();
    addTearDown(g.dispose);
    final base = await gpkgWithRtree('${tmp.path}/base.gpkg');
    final mine = '${tmp.path}/mine.gpkg';
    final theirs = '${tmp.path}/theirs.gpkg';
    g.makeCopySqlite(base, mine);
    g.makeCopySqlite(base, theirs);
    // 相手: 遠くに点を足す（rtree は相手側でも放置＝このアプリと同じくトリガー無し）
    var db = await openDatabase(theirs, singleInstance: false);
    await db.rawInsert('INSERT INTO trees (geom, name) VALUES (?, ?)', [createWkbPoint(137.0, 35.0), 'far']);
    await db.close();
    db = await openDatabase(mine, singleInstance: false);
    await db.execute("UPDATE trees SET name = 'mine' WHERE fid = 1");
    await db.close();

    final r = await GpkgMerger(g).rebase(base: base, theirs: theirs, mine: mine);
    expect(r.success, isTrue, reason: r.error);
    expect((await q(mine, 'SELECT count(*) AS n FROM trees')).single['n'], 3);
    expect((await q(mine, 'SELECT count(*) AS n FROM rtree_trees_geom')).single['n'], 2, reason: 'geodiff は rtree を触らない');

    await GpkgIndexRepair.rebuildFile(mine);
    expect((await q(mine, 'SELECT count(*) AS n FROM rtree_trees_geom')).single['n'], 3);
    final c = (await q(mine, "SELECT max_x FROM gpkg_contents WHERE table_name = 'trees'")).single;
    expect(c['max_x'], closeTo(137.0, 1e-4));
  });

  test('closeAllFor: 開いている接続を閉じ、次の呼び出しで開き直す', () async {
    final path = '${tmp.path}/c.gpkg';
    final g1 = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
    await g1.addLayer('t', GeometryType.point);
    final g2 = GeoPackageFile(const ['c.gpkg'], absolutePath: path);
    await g2.getLayerNames();
    expect(GeoPackageConnection.openCountFor(path), 2);

    expect(await GeoPackageConnection.closeAllFor(path), 2);
    expect(GeoPackageConnection.openCountFor(path), 0);
    expect(await GeoPackageConnection.closeAllFor(path), 0);

    expect(await g1.getLayerNames(), ['t']);
    expect(await g2.getLayerNames(), ['t']);
    expect(GeoPackageConnection.openCountFor(path), 2);
    await g1.dispose();
    await g2.dispose();
    expect(GeoPackageConnection.openCountFor(path), 0);
  });
}
