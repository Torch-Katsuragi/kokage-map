// QGIS 製の gpkg をアプリで直して外へ出す（Drive へ上げる・base に写す・裏に回る）とき、
// 出ていくファイルが QGIS/GDAL で読める形になっている（ホスト VM、geodiff.dll）。
//
// 2026-10-12 Pixel 9: QGIS 製の gpkg の「調査点」に点を足して同期すると、上がったファイルは
// rtree に点が無く、GDAL の rtree トリガーも落ちたままで、`ogrinfo -spat` で 0 件だった。
// 整合（トリガーの復元・rtree の焼き直し）が GeoPackageFile を閉じるときにしか走らず、
// プロジェクトを開いたままの同期では閉じないため。
//
// Android 本体の SQLite に rtree が無いのは SpatialIndexManager.debugWithoutRtreeModule でまねる
// （編集のたびの rtree 更新が落ちる）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/spatial_index_manager.dart';
import 'package:root_maps/services/google_drive/sync_base_store.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_google_drive.dart';

const _points = '調査点';
const _parcels = '小班';

/// GDAL（QGIS）が作るのと同じ形の gpkg: rtree、ST_ 関数を使う rtree トリガー、件数キャッシュ。
/// [_points] に 1 点、[_parcels] に 1 点
Future<void> _createQgisGpkg(String path) async {
  final db = await databaseFactoryFfi.openDatabase(path);
  await db.execute('PRAGMA application_id = 1196444487');
  await db.execute('PRAGMA user_version = 10400');
  await db.execute('''CREATE TABLE gpkg_spatial_ref_sys (srs_name TEXT NOT NULL, srs_id INTEGER NOT NULL PRIMARY KEY,
    organization TEXT NOT NULL, organization_coordsys_id INTEGER NOT NULL, definition TEXT NOT NULL, description TEXT)''');
  await db.execute("INSERT INTO gpkg_spatial_ref_sys VALUES ('WGS 84', 4326, 'EPSG', 4326, 'GEOGCS[\"WGS 84\"]', NULL)");
  await db.execute('''CREATE TABLE gpkg_contents (table_name TEXT NOT NULL PRIMARY KEY, data_type TEXT NOT NULL,
    identifier TEXT UNIQUE, description TEXT DEFAULT '',
    last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    min_x DOUBLE, min_y DOUBLE, max_x DOUBLE, max_y DOUBLE, srs_id INTEGER)''');
  await db.execute('''CREATE TABLE gpkg_geometry_columns (table_name TEXT NOT NULL, column_name TEXT NOT NULL,
    geometry_type_name TEXT NOT NULL, srs_id INTEGER NOT NULL, z TINYINT NOT NULL, m TINYINT NOT NULL,
    CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name))''');
  await db.execute('CREATE TABLE gpkg_ogr_contents (table_name TEXT NOT NULL PRIMARY KEY, feature_count INTEGER DEFAULT NULL)');
  for (final (i, t) in [_points, _parcels].indexed) {
    await db.execute('CREATE TABLE "$t" (fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom POINT, name TEXT)');
    final x = 135.9 + i * 0.01;
    await db.insert('gpkg_contents', {
      'table_name': t, 'data_type': 'features', 'identifier': t, 'srs_id': 4326, //
      'min_x': x, 'min_y': 33.9, 'max_x': x, 'max_y': 33.9,
    });
    await db.insert('gpkg_geometry_columns', {
      'table_name': t, 'column_name': 'geom', 'geometry_type_name': 'POINT', 'srs_id': 4326, 'z': 0, 'm': 0, //
    });
    await db.insert('gpkg_ogr_contents', {'table_name': t, 'feature_count': 1});
    await db.execute('CREATE VIRTUAL TABLE "rtree_${t}_geom" USING rtree(id, minx, maxx, miny, maxy)');
    // 先に行と rtree を入れてからトリガーを付ける（ホストの SQLite にも ST_ 関数は無い）
    await db.rawInsert('INSERT INTO "$t" (fid, geom, name) VALUES (1, ?, ?)', [createWkbPoint(x, 33.9), 'qgis']);
    await db.execute('INSERT INTO "rtree_${t}_geom" VALUES (1, $x, $x, 33.9, 33.9)');
    await db.execute('''CREATE TRIGGER "rtree_${t}_geom_insert" AFTER INSERT ON "$t"
      WHEN (new."geom" NOT NULL AND NOT ST_IsEmpty(NEW."geom"))
      BEGIN INSERT OR REPLACE INTO "rtree_${t}_geom" VALUES (NEW."fid",
        ST_MinX(NEW."geom"), ST_MaxX(NEW."geom"), ST_MinY(NEW."geom"), ST_MaxY(NEW."geom")); END''');
    await db.execute('''CREATE TRIGGER "rtree_${t}_geom_update1" AFTER UPDATE OF "geom" ON "$t"
      WHEN OLD."fid" = NEW."fid" AND (NEW."geom" NOTNULL AND NOT ST_IsEmpty(NEW."geom"))
      BEGIN INSERT OR REPLACE INTO "rtree_${t}_geom" VALUES (NEW."fid",
        ST_MinX(NEW."geom"), ST_MaxX(NEW."geom"), ST_MinY(NEW."geom"), ST_MaxY(NEW."geom")); END''');
    await db.execute('''CREATE TRIGGER "rtree_${t}_geom_delete" AFTER DELETE ON "$t"
      WHEN old."geom" NOT NULL
      BEGIN DELETE FROM "rtree_${t}_geom" WHERE id = OLD."fid"; END''');
  }
  await db.close();
}

Future<T> _read<T>(String path, Future<T> Function(Database db) f) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
  try {
    return await f(db);
  } finally {
    await db.close();
  }
}

Future<Map<String, String>> _triggers(String path) => _read(path, (db) async => {
      for (final r in await db.rawQuery("SELECT name, sql FROM sqlite_master WHERE type = 'trigger'"))
        r['name']! as String: r['sql']! as String,
    });

/// 表の fid と rtree の id（QGIS の空間検索で見えるもの）
Future<(List<Object?>, List<Object?>)> _rowsAndIndex(String path, String table) => _read(path, (db) async {
      final fids = [for (final r in await db.rawQuery('SELECT fid FROM "$table" ORDER BY fid')) r['fid']];
      final ids = [for (final r in await db.rawQuery('SELECT id FROM "rtree_${table}_geom" ORDER BY id')) r['id']];
      return (fids, ids);
    });

/// [path] が QGIS/GDAL で読める形か: rtree が行と合い、トリガーが元の定義のまま、範囲と件数が実データに合う
Future<void> _expectQgisConsistent(String path, Map<String, String> originalTriggers, {required int points}) async {
  final (fids, ids) = await _rowsAndIndex(path, _points);
  expect(fids, hasLength(points));
  expect(ids, fids, reason: 'rtree に足した点が無いと QGIS の空間検索で見えない');
  expect(await _triggers(path), originalTriggers, reason: 'GDAL のトリガーを元の定義のまま戻す');
  final c = await _read(path, (db) async => (await db.rawQuery(
        'SELECT c.max_x, c.max_y, o.feature_count FROM gpkg_contents c '
        'JOIN gpkg_ogr_contents o USING (table_name) WHERE table_name = ?',
        [_points],
      ))
          .single);
  expect(c['feature_count'], points);
  expect(c['max_y'] as double, greaterThan(34.0), reason: '足した点（緯度 34 より北）まで範囲が広がる');
}

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_hand_off_');
    SpatialIndexManager.debugWithoutRtreeModule = true; // Android と同じく rtree を書けない
  });
  tearDown(() async {
    SpatialIndexManager.debugWithoutRtreeModule = false;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('prepareForHandOff', () {
    late String path;
    late Map<String, String> original;

    setUp(() async {
      path = p.join(tmp.path, 'qgis.gpkg');
      await _createQgisGpkg(path);
      original = await _triggers(path);
    });

    test('前提: 開いたまま点を足すと、ファイルの rtree に点が無くトリガーも落ちている（実機と同じ）', () async {
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      addTearDown(gpkg.dispose);
      expect(await gpkg.addPointWithAttributes(_points, const LatLng(34.1, 136.1), {'name': 'app'}), isNotNull);

      final (fids, ids) = await _rowsAndIndex(path, _points);
      expect((fids.length, ids.length), (2, 1));
      final names = (await _triggers(path)).keys;
      expect(names.where((n) => n.startsWith('rtree_${_points}_')), isEmpty);
      expect(names.where((n) => n.startsWith('rtree_${_parcels}_')), hasLength(3));
    });

    test('開いたままでも、出ていくファイルは rtree が合いトリガーが戻る。続けて書くとまた落として書ける', () async {
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      await gpkg.addPointWithAttributes(_points, const LatLng(34.1, 136.1), {'name': 'app'});

      await GeoPackageFile.prepareForHandOff(path);
      await _expectQgisConsistent(path, original, points: 2);
      expect(GeoPackageConnection.openCountFor(path), 0, reason: '別の SQLite で書く前に閉じた');

      // 同じ GeoPackageFile で続けて書ける（開き直し、トリガーをまた落とす。落とさないと ST_ 関数が無くて落ちる）
      expect(await gpkg.addPointWithAttributes(_points, const LatLng(34.2, 136.2), {'name': 'again'}), isNotNull);
      expect(await gpkg.getFeatures(_points), hasLength(3));
      expect((await _triggers(path)).keys.where((n) => n.startsWith('rtree_${_points}_')), isEmpty);

      await gpkg.dispose();
      await _expectQgisConsistent(path, original, points: 3);
    });

    test('同じファイルを 2 つの GeoPackageFile で開いていても、戻したあと両方とも書ける', () async {
      final g1 = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      final g2 = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      await g1.addPointWithAttributes(_points, const LatLng(34.1, 136.1), {});
      await g2.addPointWithAttributes(_points, const LatLng(34.15, 136.15), {});
      await GeoPackageFile.prepareForHandOff(path);
      await _expectQgisConsistent(path, original, points: 3);

      expect(await g2.addPointWithAttributes(_points, const LatLng(34.2, 136.2), {}), isNotNull);
      expect(await g1.addPointWithAttributes(_points, const LatLng(34.3, 136.3), {}), isNotNull);
      await g1.dispose();
      await g2.dispose();
      await _expectQgisConsistent(path, original, points: 5);
    });

    test('読んだだけのファイルは書き直さない', () async {
      final before = File(path).readAsBytesSync();
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      addTearDown(gpkg.dispose);
      expect(await gpkg.getFeatures(_points), hasLength(1));
      await GeoPackageFile.prepareForHandOff(path);
      expect(File(path).readAsBytesSync(), before);
      expect(GeoPackageConnection.openCountFor(path), 1, reason: '何もしないときは接続も閉じない');
    });

    test('アプリが作った rtree の無い gpkg（GPS の記録など）は接続を閉じない', () async {
      final own = p.join(tmp.path, 'own.gpkg');
      final gpkg = GeoPackageFile(const ['own.gpkg'], absolutePath: own);
      addTearDown(gpkg.dispose);
      await gpkg.addLayer('t', GeometryType.point);
      await gpkg.addPointWithAttributes('t', const LatLng(34.1, 136.1), {});
      await GeoPackageFile.prepareForHandOff(own);
      expect(GeoPackageConnection.openCountFor(own), 1);
    });

    test('裏に回ったとき（prepareAllForHandOff）も、開いている gpkg を整える', () async {
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      addTearDown(gpkg.dispose);
      await gpkg.addPointWithAttributes(_points, const LatLng(34.1, 136.1), {});
      await GeoPackageFile.prepareAllForHandOff();
      await _expectQgisConsistent(path, original, points: 2);
    });
  });

  group('Drive へ上げる', () {
    late FakeGoogleDrive drive;
    late SyncEngine engine;
    late String rootId;
    late String a;
    late String path;
    late Map<String, String> original;

    setUp(() async {
      drive = FakeGoogleDrive();
      engine = SyncEngine(driveService: drive);
      rootId = drive.createRootFolder('proj');
      a = (await Directory(p.join(tmp.path, 'A')).create()).path;
      KMetaService.instance.clearCache();
      SharedPreferences.setMockInitialValues({});
      path = p.join(a, 'qgis.gpkg');
      await _createQgisGpkg(path);
      original = await _triggers(path);
      final r = await engine.push(a, driveFolder: rootId);
      expect(r.success, isTrue, reason: r.errorMessage);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    tearDown(KMetaService.instance.clearCache);

    /// Drive に上がっている gpkg を手元に写したもの
    Future<String> uploaded() async {
      final out = p.join(tmp.path, 'from_drive_${DateTime.now().microsecondsSinceEpoch}.gpkg');
      await File(out).writeAsBytes(drive.fileAt(rootId, 'qgis.gpkg')!.bytes);
      return out;
    }

    Future<GeoPackageFile> addPointKeepingOpen() async {
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      await gpkg.addPointWithAttributes(_points, const LatLng(34.1, 136.1), {'name': 'app'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return gpkg;
    }

    test('push: 開いたまま足した点が、上がったファイルの rtree にありトリガーも戻っている', () async {
      final gpkg = await addPointKeepingOpen();
      addTearDown(gpkg.dispose);
      final r = await engine.push(a, driveFolder: rootId);
      expect((r.success, r.uploadedCount), (true, 1), reason: r.errorMessage);
      await _expectQgisConsistent(await uploaded(), original, points: 2);
      // 3-way マージの base も同じ形
      await _expectQgisConsistent(SyncBaseStore.basePath(a, 'qgis.gpkg'), original, points: 2);
    });

    test('マージで端末を採用: 上がったファイルの rtree に点がありトリガーも戻っている', () async {
      final gpkg = await addPointKeepingOpen();
      addTearDown(gpkg.dispose);
      final entries = [for (final e in await engine.getMergeEntries(a)) if (e.relativePath == 'qgis.gpkg') e];
      expect(entries, hasLength(1));
      final r = await engine.executeMerge(a, [MergeDecision(entry: entries.single, choice: MergeChoice.local)]);
      expect((r.success, r.uploadedCount), (true, 1), reason: r.errorMessage);
      await _expectQgisConsistent(await uploaded(), original, points: 2);
      await _expectQgisConsistent(SyncBaseStore.basePath(a, 'qgis.gpkg'), original, points: 2);
    });
  });
}
