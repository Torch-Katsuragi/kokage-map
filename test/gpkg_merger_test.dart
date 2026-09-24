// GpkgMerger / SyncBaseStore（ホスト VM、geodiff.dll）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/geodiff/geodiff.dart';
import 'package:root_maps/services/google_drive/gpkg_merger.dart';
import 'package:root_maps/services/google_drive/sync_base_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Geodiff g;
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    g = Geodiff();
  });
  tearDownAll(() => g.dispose());
  setUp(() async => tmp = await Directory.systemTemp.createTemp('gpkg_merger_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> makeGpkg(String path) async {
    final gpkg = GeoPackageFile(const ['x.gpkg'], absolutePath: path);
    await gpkg.addLayer('trees', GeometryType.point);
    await gpkg.addAttributeColumns('trees', {'name': 'TEXT', 'dbh': 'INTEGER'});
    await gpkg.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {'name': 'スギ1', 'dbh': 32});
    await gpkg.addPointWithAttributes('trees', const LatLng(33.931, 135.961), {'name': 'スギ2', 'dbh': 28});
    await gpkg.flushChanges();
    await gpkg.dispose();
    return path;
  }

  Future<void> sql(String path, String stmt) async {
    final db = await openDatabase(path);
    await db.execute(stmt);
    await db.close();
  }

  Future<List<Map<String, Object?>>> rows(String path) async {
    final db = await openDatabase(path, readOnly: true);
    try {
      return await db.rawQuery('SELECT fid, name, dbh FROM trees ORDER BY fid');
    } finally {
      await db.close();
    }
  }

  group('GpkgMerger', () {
    test('衝突なし: 別の行の変更が両方載る', () async {
      final base = await makeGpkg('${tmp.path}/base.gpkg');
      final mine = '${tmp.path}/mine.gpkg';
      final theirs = '${tmp.path}/theirs.gpkg';
      g.makeCopySqlite(base, mine);
      g.makeCopySqlite(base, theirs);
      await sql(mine, 'UPDATE trees SET dbh=33 WHERE fid=1');
      await sql(theirs, "UPDATE trees SET name='スギ2(改)' WHERE fid=2");

      final r = await GpkgMerger(g).rebase(base: base, theirs: theirs, mine: mine);
      expect(r.success, isTrue, reason: r.error);
      expect(r.conflicts, isEmpty);
      final after = await rows(mine);
      expect(after[0]['dbh'], 33);
      expect(after[1]['name'], 'スギ2(改)');
      expect(File('$mine.conflict.json').existsSync(), isFalse, reason: '衝突ファイルは片付ける');
    });

    test('衝突あり: 同じ行・同じ列は mine が残り、theirs の値が記録に出る', () async {
      final base = await makeGpkg('${tmp.path}/base.gpkg');
      final mine = '${tmp.path}/mine.gpkg';
      final theirs = '${tmp.path}/theirs.gpkg';
      g.makeCopySqlite(base, mine);
      g.makeCopySqlite(base, theirs);
      await sql(mine, 'UPDATE trees SET dbh=33 WHERE fid=1');
      await sql(theirs, 'UPDATE trees SET dbh=31 WHERE fid=1');
      await sql(theirs, 'DELETE FROM trees WHERE fid=2');

      final r = await GpkgMerger(g).rebase(base: base, theirs: theirs, mine: mine);
      expect(r.success, isTrue, reason: r.error);
      expect(r.conflicts.length, 1);
      final c = r.conflicts.single;
      expect(c.table, 'trees');
      expect(c.fid, '1');
      expect(c.base, 32);
      expect(c.theirs, 31);
      expect(c.mine, 33);
      final after = await rows(mine);
      expect(after.map((e) => e['fid']).toList(), [1]); // theirs の削除は載る
      expect(after[0]['dbh'], 33); // mine 優先
    });

    test('相手が消した行をこちらが直していたら、行は消えて theirsDeleted の衝突になる', () async {
      final base = await makeGpkg('${tmp.path}/base.gpkg');
      final mine = '${tmp.path}/mine.gpkg';
      final theirs = '${tmp.path}/theirs.gpkg';
      g.makeCopySqlite(base, mine);
      g.makeCopySqlite(base, theirs);
      await sql(theirs, 'DELETE FROM trees WHERE fid=1');
      await sql(mine, 'UPDATE trees SET dbh=40 WHERE fid=1');

      final r = await GpkgMerger(g).rebase(base: base, theirs: theirs, mine: mine);
      expect(r.success, isTrue, reason: r.error);
      expect((await rows(mine)).map((e) => e['fid']), [2]);
      expect(r.conflicts.single.theirsDeleted, isTrue);
      expect(r.conflicts.single.mine, 40);
    });

    test('相手が直した行をこちらが消していたら、行は消え、衝突は記録されない（geodiff の仕様）', () async {
      final base = await makeGpkg('${tmp.path}/base.gpkg');
      final mine = '${tmp.path}/mine.gpkg';
      final theirs = '${tmp.path}/theirs.gpkg';
      g.makeCopySqlite(base, mine);
      g.makeCopySqlite(base, theirs);
      await sql(theirs, 'UPDATE trees SET dbh=40 WHERE fid=1');
      await sql(mine, 'DELETE FROM trees WHERE fid=1');

      final r = await GpkgMerger(g).rebase(base: base, theirs: theirs, mine: mine);
      expect(r.success, isTrue, reason: r.error);
      expect((await rows(mine)).map((e) => e['fid']), [2]);
      expect(r.conflicts, isEmpty);
    });

    test('base が壊れていれば失敗を返し、mine は触らない', () async {
      final base = '${tmp.path}/base.gpkg';
      File(base).writeAsStringSync('not a database');
      final mine = await makeGpkg('${tmp.path}/mine.gpkg');
      final theirs = await makeGpkg('${tmp.path}/theirs.gpkg');
      final before = await rows(mine);

      final r = await GpkgMerger(g).rebase(base: base, theirs: theirs, mine: mine);
      expect(r.success, isFalse);
      expect(r.error, isNotNull);
      expect(await rows(mine), before);
    });

    test('hasChanges: 変更なし=0、あり=1', () async {
      final base = await makeGpkg('${tmp.path}/base.gpkg');
      final same = '${tmp.path}/same.gpkg';
      g.makeCopySqlite(base, same);
      expect(await GpkgMerger(g).hasChanges(base: base, modified: same), 0);
      await sql(same, 'UPDATE trees SET dbh=1 WHERE fid=1');
      expect(await GpkgMerger(g).hasChanges(base: base, modified: same), 1);
    });
  });

  group('SyncBaseStore', () {
    test('.sync 配下の判定', () {
      expect(SyncBaseStore.isInside('.sync'), isTrue);
      expect(SyncBaseStore.isInside('.sync/base/a.gpkg'), isTrue);
      expect(SyncBaseStore.isInside('.sync\\base\\a.gpkg'), isTrue);
      expect(SyncBaseStore.isInside('a/.sync/x'), isFalse);
      expect(SyncBaseStore.isInside('data.gpkg'), isFalse);
    });

    test('saveBase は .sync/base/<相対パス> に写し、gpkg 以外は何もしない', () async {
      final local = tmp.path;
      await Directory(p.join(local, 'sub')).create();
      await makeGpkg(p.join(local, 'sub', 'data.gpkg'));
      File(p.join(local, 'photo.jpg')).writeAsBytesSync([1, 2, 3]);

      expect(await SyncBaseStore.hasBase(local, 'sub/data.gpkg'), isFalse);
      expect(await SyncBaseStore.saveBase(local, 'sub/data.gpkg', geodiff: g), isTrue);
      expect(await SyncBaseStore.hasBase(local, 'sub/data.gpkg'), isTrue);
      expect(File(SyncBaseStore.basePath(local, 'sub/data.gpkg')).existsSync(), isTrue);
      expect((await rows(SyncBaseStore.basePath(local, 'sub/data.gpkg'))).length, 2);

      expect(await SyncBaseStore.saveBase(local, 'photo.jpg', geodiff: g), isFalse);
      expect(await SyncBaseStore.hasBase(local, 'photo.jpg'), isFalse);

      await SyncBaseStore.removeBase(local, 'sub/data.gpkg');
      expect(await SyncBaseStore.hasBase(local, 'sub/data.gpkg'), isFalse);
    });

    test('libgeodiff が読めない端末では、落ちずに base を持たない（＝行単位マージをしない）', () async {
      final local = tmp.path;
      await makeGpkg(p.join(local, 'data.gpkg'));
      Geodiff.libraryPathOverride = p.join(local, 'no_such_geodiff.dll');
      addTearDown(() => Geodiff.libraryPathOverride = null);

      expect(await SyncBaseStore.saveBase(local, 'data.gpkg'), isFalse);
      expect(await SyncBaseStore.hasBase(local, 'data.gpkg'), isFalse);
    });
  });
}
