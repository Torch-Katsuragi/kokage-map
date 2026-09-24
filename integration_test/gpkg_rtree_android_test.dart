// Android 本体の SQLite（sqflite）には rtree モジュールが無い。
// QGIS 製（rtree 付き）の gpkg の索引を、geodiff に入っている SQLite で焼き直せるかを実機で確かめる。
//
// 実行: flutter test integration_test/gpkg_rtree_android_test.dart -d <device>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/gpkg_index_repair.dart';
import 'package:root_maps/services/geodiff/geodiff.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite/sqflite.dart';

/// geodiff の SQLite で「[cond] が真であること」を確かめる（偽なら整数あふれのエラーを起こす）
String? sqlAssert(Geodiff g, String path, String cond) =>
    g.execSql(path, 'SELECT CASE WHEN ($cond) THEN 1 ELSE abs(-9223372036854775807 - 1) END;');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Android の SQLite に rtree は無いが、geodiff の SQLite で焼き直せる', () async {
    final tmp = await Directory.systemTemp.createTemp('rtree_android_');
    final path = '${tmp.path}/q.gpkg';
    final g = Geodiff();
    try {
      final f = GeoPackageFile(const ['q.gpkg'], absolutePath: path);
      await f.addLayer('trees', GeometryType.point);
      await f.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {});
      await f.addPointWithAttributes('trees', const LatLng(33.94, 135.97), {});
      await f.flushChanges();
      await f.dispose();

      // QGIS 製と同じ形の rtree を geodiff の SQLite で付ける（1 行だけ＝古い索引）
      expect(
        g.execSql(path, 'CREATE VIRTUAL TABLE rtree_trees_geom USING rtree(id, minx, maxx, miny, maxy);'
            'INSERT INTO rtree_trees_geom VALUES (1, 135.96, 135.96, 33.93, 33.93);'),
        isNull,
      );

      // Android の SQLite では rtree を触れない（2026-09-24 Pixel 9 / Android 17 で確認した前提）
      var db = await openDatabase(path, singleInstance: false);
      Object? androidError;
      try {
        await db.rawQuery('SELECT count(*) FROM rtree_trees_geom');
      } catch (e) {
        androidError = e;
      }
      // ignore: avoid_print
      print('[rtree] Android の SQLite: ${androidError ?? 'rtree を読めた'}');
      // 地物テーブルへの書き込みは普通にできる
      await db.rawInsert('INSERT INTO trees (geom) VALUES (?)', [createWkbPoint(137.0, 35.0)]);
      await db.close();

      final rebuilt = await GpkgIndexRepair.rebuildFile(path);
      expect(rebuilt, 1);

      expect(sqlAssert(g, path, '(SELECT count(*) FROM rtree_trees_geom) = 3'), isNull);
      expect(sqlAssert(g, path, '(SELECT max(maxx) FROM rtree_trees_geom) > 136.99'), isNull);
      db = await openDatabase(path, readOnly: true, singleInstance: false);
      final c = (await db.rawQuery("SELECT max_x, max_y FROM gpkg_contents WHERE table_name = 'trees'")).single;
      await db.close();
      expect(c['max_x'], closeTo(137.0, 1e-6));
      expect(c['max_y'], closeTo(35.0, 1e-6));
    } finally {
      g.dispose();
      await tmp.delete(recursive: true);
    }
  });
}
