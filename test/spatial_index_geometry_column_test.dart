// 形の列が geom 以外（GDAL の GEOMETRY_NAME・GeoPandas の geometry など）の gpkg でも、
// 編集のたびの rtree 更新が実際の rtree（rtree_<表>_<列>）に入る（ホスト VM）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/qgis_interop.dart';
import 'package:root_maps/models/geopackage/spatial_index_manager.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async => tmp = await Directory.systemTemp.createTemp('rtree_geomcol_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// GDAL（GPKG ドライバ、GEOMETRY_NAME=geometry）が作るのと同じ形: rtree・gpkg_extensions・ST_ 関数のトリガー
  Future<String> gdalStyleGpkg() async {
    final path = '${tmp.path}/parcels.gpkg';
    final db = await openDatabase(path, singleInstance: false);
    await db.execute('''CREATE TABLE gpkg_spatial_ref_sys (srs_name TEXT NOT NULL, srs_id INTEGER PRIMARY KEY,
      organization TEXT NOT NULL, organization_coordsys_id INTEGER NOT NULL, definition TEXT NOT NULL, description TEXT)''');
    await db.execute("INSERT INTO gpkg_spatial_ref_sys VALUES ('WGS 84', 4326, 'EPSG', 4326, 'GEOGCS[\"WGS 84\"]', NULL)");
    await db.execute('''CREATE TABLE gpkg_contents (table_name TEXT NOT NULL PRIMARY KEY, data_type TEXT NOT NULL,
      identifier TEXT UNIQUE, description TEXT DEFAULT '', last_change DATETIME, min_x DOUBLE, min_y DOUBLE,
      max_x DOUBLE, max_y DOUBLE, srs_id INTEGER)''');
    await db.execute('''CREATE TABLE gpkg_geometry_columns (table_name TEXT NOT NULL, column_name TEXT NOT NULL,
      geometry_type_name TEXT NOT NULL, srs_id INTEGER NOT NULL, z TINYINT NOT NULL, m TINYINT NOT NULL,
      CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name))''');
    await db.execute('''CREATE TABLE gpkg_extensions (table_name TEXT, column_name TEXT, extension_name TEXT NOT NULL,
      definition TEXT NOT NULL, scope TEXT NOT NULL)''');
    await db.execute('CREATE TABLE parcels (fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geometry POINT, name TEXT)');
    await db.execute("INSERT INTO gpkg_contents (table_name, data_type, identifier, srs_id) VALUES ('parcels', 'features', 'parcels', 4326)");
    await db.execute("INSERT INTO gpkg_geometry_columns VALUES ('parcels', 'geometry', 'POINT', 4326, 0, 0)");
    await db.execute(
      "INSERT INTO gpkg_extensions VALUES ('parcels', 'geometry', 'gpkg_rtree_index', 'http://www.geopackage.org/spec120/#extension_rtree', 'write-only')",
    );
    await db.execute('CREATE VIRTUAL TABLE rtree_parcels_geometry USING rtree(id, minx, maxx, miny, maxy)');
    // GDAL のトリガー（抜粋。sqflite には ST_ 関数が無いので書き込み前に落とす対象）
    await db.execute('''CREATE TRIGGER rtree_parcels_geometry_insert AFTER INSERT ON parcels
      WHEN (new.geometry NOT NULL AND NOT ST_IsEmpty(NEW.geometry))
      BEGIN INSERT OR REPLACE INTO rtree_parcels_geometry VALUES (NEW.fid,
        ST_MinX(NEW.geometry), ST_MaxX(NEW.geometry), ST_MinY(NEW.geometry), ST_MaxY(NEW.geometry)); END''');
    await db.execute('''CREATE TRIGGER rtree_parcels_geometry_delete AFTER DELETE ON parcels
      WHEN old.geometry NOT NULL
      BEGIN DELETE FROM rtree_parcels_geometry WHERE id = OLD.fid; END''');
    await db.close();
    return path;
  }

  test('追加・更新・削除で rtree_<表>_geometry が実データと合う', () async {
    final path = await gdalStyleGpkg();
    final conn = GeoPackageConnection(const ['parcels.gpkg'], absolutePath: path);
    final spatial = SpatialIndexManager(conn);
    final db = await conn.getDatabase();
    await spatial.removeTableTriggers('parcels');

    Future<List<Map<String, Object?>>> rtree() =>
        db.rawQuery('SELECT id, minx, maxx, miny, maxy FROM rtree_parcels_geometry ORDER BY id');

    // 追加
    final a = createWkbPoint(135.96, 33.93);
    final b = createWkbPoint(135.97, 33.94);
    final idA = await db.rawInsert('INSERT INTO parcels (geometry, name) VALUES (?, ?)', [a, 'a']);
    final idB = await db.rawInsert('INSERT INTO parcels (geometry, name) VALUES (?, ?)', [b, 'b']);
    await spatial.indexRows('parcels', {idA: a, idB: b});
    var rows = await rtree();
    expect(rows.map((r) => r['id']), [idA, idB]);
    expect(rows.first['minx'], closeTo(135.96, 1e-4));

    // 更新（動かす）: 古い範囲が残らない・行が増えない
    final moved = createWkbPoint(136.5, 34.5);
    await db.rawUpdate('UPDATE parcels SET geometry = ? WHERE fid = ?', [moved, idA]);
    await spatial.indexRows('parcels', {idA: moved});
    rows = await rtree();
    expect(rows.length, 2);
    expect(rows.first['minx'], closeTo(136.5, 1e-4));
    expect(rows.first['miny'], closeTo(34.5, 1e-4));

    // 削除
    await db.rawDelete('DELETE FROM parcels WHERE fid = ?', [idB]);
    await spatial.removeFromRTreeIndex('parcels', idB);
    rows = await rtree();
    expect(rows.map((r) => r['id']), [idA]);

    // レイヤの範囲も rtree から出せる
    await QgisInterop.updateContentsBounds(db, 'parcels');
    final contents = (await db.rawQuery("SELECT min_x, max_x FROM gpkg_contents WHERE table_name = 'parcels'")).single;
    expect(contents['min_x'], closeTo(136.5, 1e-4));
    expect(contents['max_x'], closeTo(136.5, 1e-4));

    await conn.dispose();
  });

  test('形を空にした更新は rtree から外す（GDAL のトリガーと同じ）', () async {
    final path = await gdalStyleGpkg();
    final conn = GeoPackageConnection(const ['parcels.gpkg'], absolutePath: path);
    final spatial = SpatialIndexManager(conn);
    final db = await conn.getDatabase();
    await spatial.removeTableTriggers('parcels');

    final a = createWkbPoint(135.96, 33.93);
    final id = await db.rawInsert('INSERT INTO parcels (geometry, name) VALUES (?, ?)', [a, 'a']);
    await spatial.indexRows('parcels', {id: a});
    expect(await db.rawQuery('SELECT id FROM rtree_parcels_geometry'), hasLength(1));

    // 空の点（GeoPackage の空ジオメトリの印つき）
    final empty = Uint8List.fromList([0x47, 0x50, 0x00, 0x11, 0xE6, 0x10, 0x00, 0x00]);
    await db.rawUpdate('UPDATE parcels SET geometry = ? WHERE fid = ?', [empty, id]);
    await spatial.indexRows('parcels', {id: empty});
    expect(await db.rawQuery('SELECT id FROM rtree_parcels_geometry'), isEmpty);

    await conn.dispose();
  });
}
