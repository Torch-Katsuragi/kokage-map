// QGIS 製の gpkg（GDAL 3.13 の rtree トリガーつき）に、どの経路で書いても書ける。
// 外へ出す前にトリガーを戻した（prepareForHandOff）あとも、続けて書ける（ホスト VM）。
//
// 2026-10-12 Pixel 9: QGIS 製の gpkg の「調査点」の属性を編集パネルで変えると、画面には新しい値が出るのに
// ファイルは変わらなかった。ログは `updateFeatureAttributes failed: no such function: ST_IsEmpty`、
// 書き直しも落ち続けて閉じると失われた。トリガーを落とすのが地物の追加・形の更新・削除の経路だけで、
// 属性の UPDATE は落とさずに書いていたため（裏に回る・Drive に上げるたびにトリガーを戻すようにして表に出た）。
//
// ホストの SQLite にも ST_ 関数は無いので、Android と同じく GDAL のトリガーの付いた表に書く文は準備の時点で落ちる。
// GDAL 3.13 の update5・update4 は `AFTER UPDATE ON <表>`（列を問わない）なので、属性だけの UPDATE も落ちる。
// rtree が無いのは SpatialIndexManager.debugWithoutRtreeModule でまねる。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geopackage/gdal_trigger_guard.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/geopackage/gpkg_rtree_triggers.dart';
import 'package:root_maps/models/geopackage/spatial_index_manager.dart';
import 'package:root_maps/utils/background_save_manager.dart';
import 'package:root_maps/utils/wkb_utils.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _points = '調査点';
const _copies = '写し';

/// GDAL 3.13（QGIS 4.2）が作るのと同じ形の gpkg。[_points] に 2 点、[_copies] は空。どちらも rtree とトリガーつき
Future<void> _createQgisGpkg(String path) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
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
  await db.execute('''CREATE TABLE gpkg_extensions (table_name TEXT, column_name TEXT, extension_name TEXT NOT NULL,
    definition TEXT NOT NULL, scope TEXT NOT NULL)''');
  await db.execute('CREATE TABLE gpkg_ogr_contents (table_name TEXT NOT NULL PRIMARY KEY, feature_count INTEGER DEFAULT NULL)');
  for (final t in [_points, _copies]) {
    await db.execute('CREATE TABLE "$t" (fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom POINT, name TEXT, memo TEXT)');
    await db.insert('gpkg_contents', {
      'table_name': t, 'data_type': 'features', 'identifier': t, 'srs_id': 4326, //
      'min_x': 135.9, 'min_y': 33.9, 'max_x': 135.91, 'max_y': 33.91,
    });
    await db.insert('gpkg_geometry_columns', {
      'table_name': t, 'column_name': 'geom', 'geometry_type_name': 'POINT', 'srs_id': 4326, 'z': 0, 'm': 0, //
    });
    await db.insert('gpkg_extensions', {
      'table_name': t, 'column_name': 'geom', 'extension_name': 'gpkg_rtree_index', //
      'definition': 'http://www.geopackage.org/spec120/#extension_rtree', 'scope': 'write-only',
    });
    await db.execute('CREATE VIRTUAL TABLE "rtree_${t}_geom" USING rtree(id, minx, maxx, miny, maxy)');
    final rows = t == _points ? [(1, 135.9, 33.9), (2, 135.91, 33.91)] : const <(int, double, double)>[];
    await db.insert('gpkg_ogr_contents', {'table_name': t, 'feature_count': rows.length});
    // 先に行と rtree を入れてからトリガーを付ける（ホストの SQLite にも ST_ 関数は無い）
    for (final (fid, x, y) in rows) {
      await db.rawInsert('INSERT INTO "$t" (fid, geom, name, memo) VALUES (?, ?, ?, ?)', [fid, createWkbPoint(x, y), 'qgis$fid', null]);
      await db.execute('INSERT INTO "rtree_${t}_geom" VALUES ($fid, $x, $x, $y, $y)');
    }
    for (final sql in GpkgRtreeTriggers.standard(table: t, geomColumn: 'geom', pk: 'fid').values) {
      await db.execute(sql);
    }
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

/// ファイルにある [_points] の行（fid → 列）
Future<Map<int, Map<String, Object?>>> _rows(String path, [String table = _points]) => _read(path, (db) async => {
      for (final r in await db.rawQuery('SELECT * FROM "$table" ORDER BY fid')) r['fid']! as int: r,
    });

/// 別の SQLite（Drive から落とした・geodiff が書いた）が、アプリの知らない間にトリガーを作り直す
Future<void> _recreateTriggersBehindApp(String path, Map<String, String> triggers) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
  for (final MapEntry(key: name, value: sql) in triggers.entries) {
    await db.execute('DROP TRIGGER IF EXISTS "$name"');
    await db.execute(sql);
  }
  await db.close();
}

void main() {
  late Directory tmp;
  late String path;
  late Map<String, String> original;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_write_guard_');
    SpatialIndexManager.debugWithoutRtreeModule = true; // Android と同じく rtree を書けない
    path = p.join(tmp.path, 'qgis.gpkg');
    await _createQgisGpkg(path);
    original = await _triggers(path);
    expect(original, hasLength(14), reason: '前提: 2 表 × GDAL 3.13 の 7 つ');
  });
  tearDown(() async {
    SpatialIndexManager.debugWithoutRtreeModule = false;
    BackgroundSaveManager.instance.onPersistentFailure = null;
    await BackgroundSaveManager.instance.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('前提: トリガーが付いたままだと、属性だけの UPDATE も ST_ 関数が無くて落ちる（実機と同じ）', () async {
    final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    await expectLater(
      db.rawUpdate('UPDATE "$_points" SET name = ? WHERE fid = 1', ['x']),
      throwsA(predicate((Object e) => GdalTriggerGuard.isMissingSpatialSupport(e) && '$e'.contains('ST_IsEmpty'))),
    );
  });

  test('開いてすぐ属性を書ける。外へ出す前にトリガーを戻したあとも書ける', () async {
    final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
    expect(await gpkg.updateFeatureAttributes(_points, 1, {'name': '杉', 'memo': '一回目'}), isTrue);
    expect((await _rows(path))[1]!['name'], '杉');

    await GeoPackageFile.prepareForHandOff(path);
    expect(await _triggers(path), original, reason: '出ていくファイルはトリガーが元の定義のまま');

    expect(await gpkg.updateFeatureAttributes(_points, 1, {'name': '檜'}), isTrue);
    expect(await gpkg.updateFeatureAttribute(_points, 2, 'memo', '二回目'), isTrue);
    final rows = await _rows(path);
    expect((rows[1]!['name'], rows[2]!['memo']), ('檜', '二回目'));

    await gpkg.dispose();
    expect(await _triggers(path), original, reason: '閉じたあとも元の定義のまま');
  });

  test('戻したあと、削除・追加・置換・列の追加と計算・写し・衝突の解決のどれも書ける', () async {
    final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
    expect(await gpkg.updateFeatureAttributes(_points, 1, {'name': 'a'}), isTrue);
    await GeoPackageFile.prepareForHandOff(path);
    expect(await _triggers(path), original);

    expect(await gpkg.removeFeature(_points, 2), isTrue);
    await GeoPackageFile.prepareForHandOff(path);

    final added = await gpkg.addPointWithAttributes(_points, const LatLng(34.1, 136.1), {'name': 'app'});
    expect(added, isNotNull);
    await GeoPackageFile.prepareForHandOff(path);

    expect((await gpkg.replaceText(_points, 'name', 'app', 'アプリ')).replaced, 1);
    await GeoPackageFile.prepareForHandOff(path);

    await gpkg.addAttributeColumn(_points, 'dbh', 'REAL');
    expect(await gpkg.updateColumnWithExpression(_points, 'dbh', '12.5'), 2);
    await GeoPackageFile.prepareForHandOff(path);

    expect(await gpkg.copyFeaturesBetweenLayers(_points, _copies), 2);
    await GeoPackageFile.prepareForHandOff(path);

    expect(await gpkg.setColumnValue(_points, 'fid', 1, 'memo', '衝突'), isTrue);
    await GeoPackageFile.prepareForHandOff(path);

    final rows = await _rows(path);
    expect(rows.keys, [1, added]);
    expect((rows[1]!['name'], rows[1]!['memo'], rows[1]!['dbh']), ('a', '衝突', 12.5));
    expect(rows[added]!['name'], 'アプリ');
    expect(await _rows(path, _copies), hasLength(2));
    expect(await _triggers(path), original);
    await gpkg.dispose();
    expect(await _triggers(path), original);
  });

  test('別の SQLite がトリガーを作り直していても（落とし済みの印が古い）、落とし直して書ける', () async {
    final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
    addTearDown(gpkg.dispose);
    expect(await gpkg.updateFeatureAttributes(_points, 1, {'name': 'a'}), isTrue);
    await _recreateTriggersBehindApp(path, original);

    expect(await gpkg.updateFeatureAttributes(_points, 1, {'name': 'b'}), isTrue);
    expect(await gpkg.removeFeature(_points, 2), isTrue);
    final rows = await _rows(path);
    expect(rows.keys, [1]);
    expect(rows[1]!['name'], 'b');
  });

  test('トランザクション・バッチで書く文も、そのトランザクションで落としてから書く', () async {
    final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
    addTearDown(gpkg.dispose);
    final db = await gpkg.getDatabase();
    await db.transaction((txn) async {
      await txn.rawUpdate('UPDATE "$_points" SET name = ? WHERE fid = 1', ['txn']);
    });
    await GeoPackageFile.prepareForHandOff(path);
    final batch = (await gpkg.getDatabase()).batch()..rawUpdate('UPDATE "$_points" SET name = ? WHERE fid = 2', ['batch']);
    await batch.commit(noResult: true);
    final rows = await _rows(path);
    expect((rows[1]!['name'], rows[2]!['name']), ('txn', 'batch'));
  });

  test('読むだけならトリガーを落とさない（見ただけのファイルを変えない）', () async {
    final before = File(path).readAsBytesSync();
    final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
    expect(await gpkg.getFeatures(_points), hasLength(2));
    final db = await gpkg.getDatabase();
    await db.transaction((txn) => txn.rawQuery('SELECT count(*) FROM "$_points"'));
    await db.execute('PRAGMA foreign_keys');
    expect(await _triggers(path), original);
    await gpkg.dispose();
    expect(File(path).readAsBytesSync(), before);
  });

  group('BackgroundSaveManager', () {
    test('戻したあとの保留中の属性も、待たずに書ける', () async {
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      addTearDown(gpkg.dispose);
      gpkg.queueAttributeUpdate(_points, 1, 'name', '一回目');
      await gpkg.flushChanges();
      await GeoPackageFile.prepareForHandOff(path);
      expect(await _triggers(path), original);

      gpkg.queueAttributeUpdate(_points, 1, 'name', '二回目');
      gpkg.queueAttributeUpdate(_points, 2, 'memo', 'メモ');
      await gpkg.flushChanges();
      expect(BackgroundSaveManager.instance.getPendingChangesStatus(), isEmpty, reason: '書き直し待ちに回らない');
      final rows = await _rows(path);
      expect((rows[1]!['name'], rows[2]!['memo']), ('二回目', 'メモ'));
    });

    test('別の SQLite がトリガーを作り直したあとの保存も、待たずに書ける', () async {
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      addTearDown(gpkg.dispose);
      gpkg.queueAttributeUpdate(_points, 1, 'name', 'a');
      await gpkg.flushChanges();
      await _recreateTriggersBehindApp(path, original);

      gpkg.queueAttributeUpdate(_points, 1, 'name', 'b');
      await gpkg.flushChanges();
      expect(BackgroundSaveManager.instance.getPendingChangesStatus(), isEmpty);
      expect((await _rows(path))[1]!['name'], 'b');
    });

    test('保存が落ち続けたら知らせ、閉じるときに捨てた分も知らせる', () async {
      final calls = <String>[];
      BackgroundSaveManager.instance.onPersistentFailure =
          (count, files, {required discarded}) => calls.add('$count $files $discarded');
      // memo を書くと必ず落ちる（行はあるので捨てずに書き直しへ回る。rtree・ST_ のトリガーではないので落とさない）
      await _recreateTriggersBehindApp(path, {
        'lock_memo': "CREATE TRIGGER lock_memo BEFORE UPDATE OF memo ON \"$_points\" BEGIN SELECT RAISE(ABORT, 'locked'); END",
      });
      final gpkg = GeoPackageFile(const ['qgis.gpkg'], absolutePath: path);
      gpkg.queueAttributeUpdate(_points, 1, 'memo', 'x');
      await gpkg.flushChanges();
      await gpkg.flushChanges();
      expect(calls, isEmpty, reason: '一時的な失敗では知らせない');
      await gpkg.flushChanges();
      expect(calls, ['1 [qgis.gpkg] false']);
      await gpkg.flushChanges();
      expect(calls, hasLength(1), reason: '落ち続けている間は 1 回だけ');

      await gpkg.dispose();
      expect(calls.last, '1 [qgis.gpkg] true');
    });
  });

  test('GeoPackageConnection.getDatabase は書く前に落とす接続を返す（経路ごとに落とさない）', () async {
    final conn = GeoPackageConnection(const ['qgis.gpkg'], absolutePath: path);
    addTearDown(conn.dispose);
    final db = await conn.getDatabase();
    expect(db, isA<GuardedDatabase>());
    expect(identical(await conn.getDatabase(), db), isTrue);
    expect(await db.rawUpdate('UPDATE "$_points" SET memo = ? WHERE fid = 2', ['直']), 1);
  });
}
