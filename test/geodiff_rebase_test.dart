// geodiff の 3-way rebase（ホスト VM、third_party/geodiff/windows/geodiff.dll）
//
// このアプリが作った gpkg を base に、A と B が独立に編集したものを rebase で 1 つに載せる。
// 実機版は integration_test/geodiff_smoke_test.dart。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/geodiff/geodiff.dart';
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

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('geodiff_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> makeBase() async {
    final base = '${tmp.path}/base.gpkg';
    final gpkg = GeoPackageFile(const ['base.gpkg'], absolutePath: base);
    await gpkg.addLayer('trees', GeometryType.point);
    await gpkg.addAttributeColumns('trees', {'name': 'TEXT', 'description': 'TEXT'});
    await gpkg.addPoint('trees', const LatLng(33.93, 135.96), name: 'スギ1', description: '胸高32cm');
    await gpkg.addPoint('trees', const LatLng(33.931, 135.961), name: 'スギ2', description: '胸高28cm');
    await gpkg.addPoint('trees', const LatLng(33.932, 135.962), name: 'ヒノキ1', description: '胸高25cm');
    await gpkg.flushChanges();
    await gpkg.dispose();
    return base;
  }

  Future<List<Map<String, Object?>>> rows(String path) async {
    final db = await openDatabase(path, readOnly: true);
    try {
      return await db.rawQuery('SELECT fid, name, description FROM trees ORDER BY fid');
    } finally {
      await db.close();
    }
  }

  test('version が返る', () {
    expect(g.version, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  test('同じ base からの独立編集が rebase で 1 つに載り、衝突だけ conflict.json に出る', () async {
    final base = await makeBase();
    final a = '${tmp.path}/A.gpkg';
    final b = '${tmp.path}/B.gpkg';
    expect(g.makeCopySqlite(base, a), GeodiffResult.success, reason: g.lastError);
    expect(g.makeCopySqlite(base, b), GeodiffResult.success, reason: g.lastError);

    // A: 追加 + fid=1 改名 / B: fid=2 測り直し + fid=3 削除 + fid=1 を別名に（=衝突）
    var db = await openDatabase(a);
    await db.rawInsert(
        "INSERT INTO trees (geom, name, description) SELECT geom, 'スギ4(Aが追加)', '胸高30cm' FROM trees WHERE fid=1");
    await db.rawUpdate("UPDATE trees SET name='スギ1(A改名)' WHERE fid=1");
    await db.close();
    db = await openDatabase(b);
    await db.rawUpdate("UPDATE trees SET description='胸高29cm(B測り直し)' WHERE fid=2");
    await db.rawDelete('DELETE FROM trees WHERE fid=3');
    await db.rawUpdate("UPDATE trees SET name='スギ1(B改名)' WHERE fid=1");
    await db.close();

    final aDiff = '${tmp.path}/a.diff';
    final bDiff = '${tmp.path}/b.diff';
    expect(g.createChangeset(base, a, aDiff), GeodiffResult.success, reason: g.lastError);
    expect(g.createChangeset(base, b, bDiff), GeodiffResult.success, reason: g.lastError);
    expect(g.hasChanges(aDiff), 1);
    expect(g.changesCount(aDiff), 2);
    expect(g.changesCount(bDiff), 3);

    final conflict = '${tmp.path}/conflict.json';
    final rc = g.rebase(base, b, a, conflict);
    expect(rc, anyOf(GeodiffResult.success, GeodiffResult.conflicts), reason: g.lastError);

    final after = await rows(a);
    expect(after.map((r) => r['fid']).toList(), [1, 2, 4]);
    expect(after[0]['name'], 'スギ1(A改名)'); // ローカル優先
    expect(after[1]['description'], '胸高29cm(B測り直し)'); // B の変更が載った
    expect(after[2]['name'], 'スギ4(Aが追加)');

    final j = jsonDecode(await File(conflict).readAsString()) as Map<String, dynamic>;
    final entries = j['geodiff'] as List;
    expect(entries.length, 1);
    final first = entries.first as Map<String, dynamic>;
    expect(first['table'], 'trees');
    expect(first['fid'], '1');
    final change = (first['changes'] as List).first as Map<String, dynamic>;
    expect(change['base'], 'スギ1');
    expect(change['old'], 'スギ1(B改名)');
    expect(change['new'], 'スギ1(A改名)');
  });

  test('変更が無ければ hasChanges は 0', () async {
    final base = await makeBase();
    final same = '${tmp.path}/same.gpkg';
    expect(g.makeCopySqlite(base, same), GeodiffResult.success);
    final d = '${tmp.path}/none.diff';
    expect(g.createChangeset(base, same, d), GeodiffResult.success, reason: g.lastError);
    expect(g.hasChanges(d), 0);
    expect(g.changesCount(d), 0);
  });

  test('片方だけの変更は applyChangeset でそのまま当たる', () async {
    final base = await makeBase();
    final a = '${tmp.path}/A.gpkg';
    final b = '${tmp.path}/B.gpkg';
    g.makeCopySqlite(base, a);
    g.makeCopySqlite(base, b);
    final db = await openDatabase(a);
    await db.rawUpdate("UPDATE trees SET description='胸高33cm' WHERE fid=1");
    await db.close();
    final d = '${tmp.path}/a.diff';
    expect(g.createChangeset(base, a, d), GeodiffResult.success);
    expect(g.applyChangeset(b, d), GeodiffResult.success, reason: g.lastError);
    expect((await rows(b))[0]['description'], '胸高33cm');
  });
}
