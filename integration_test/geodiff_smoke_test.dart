// libgeodiff.so の実機スモーク: 読めるか・version が返るか・A/B の 3-way rebase が通るか
//
// 実行: flutter test integration_test/geodiff_smoke_test.dart -d <device>
// 同じ筋のホスト VM 版は test/geodiff_rebase_test.dart（geodiff.dll）。
// 2026-09-18 Pixel 9（Android 17）で 2/2 通過。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/geodiff/geodiff.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Geodiff g;
  late Directory tmp;

  setUpAll(() async {
    g = Geodiff();
    tmp = await Directory.systemTemp.createTemp('geodiff_');
  });
  tearDownAll(() async {
    g.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('libgeodiff.so が読めて version が返る', () {
    // ignore: avoid_print
    print('[geodiff] version=${g.version}');
    expect(Geodiff.isSupported, isTrue);
    expect(g.version, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  test('このアプリの gpkg で A/B の 3-way rebase が通り、衝突だけ conflict.json に出る', () async {
    final base = '${tmp.path}/base.gpkg';
    final gpkg = GeoPackageFile(const ['base.gpkg'], absolutePath: base);
    await gpkg.addLayer('trees', GeometryType.point);
    await gpkg.addAttributeColumns('trees', {'name': 'TEXT', 'description': 'TEXT'});
    await gpkg.addPoint('trees', const LatLng(33.93, 135.96), name: 'スギ1', description: '胸高32cm');
    await gpkg.addPoint('trees', const LatLng(33.931, 135.961), name: 'スギ2', description: '胸高28cm');
    await gpkg.addPoint('trees', const LatLng(33.932, 135.962), name: 'ヒノキ1', description: '胸高25cm');
    await gpkg.flushChanges();
    await gpkg.dispose();

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
    // ignore: avoid_print
    print('[geodiff] rebase rc=$rc lastError=${g.lastError}');
    expect(rc, anyOf(GeodiffResult.success, GeodiffResult.conflicts), reason: g.lastError);

    db = await openDatabase(a, readOnly: true);
    final rows = await db.rawQuery('SELECT fid, name, description FROM trees ORDER BY fid');
    await db.close();
    // ignore: avoid_print
    print('[geodiff] A after rebase: $rows');
    expect(rows.map((r) => r['fid']).toList(), [1, 2, 4]);
    expect(rows[0]['name'], 'スギ1(A改名)'); // ローカル優先
    expect(rows[1]['description'], '胸高29cm(B測り直し)'); // B の変更が載った
    expect(rows[2]['name'], 'スギ4(Aが追加)');

    final j = jsonDecode(await File(conflict).readAsString()) as Map<String, dynamic>;
    // ignore: avoid_print
    print('[geodiff] conflict: ${jsonEncode(j)}');
    final entries = j['geodiff'] as List;
    expect(entries.length, 1);
    final first = entries.first as Map<String, dynamic>;
    expect(first['table'], 'trees');
    expect(first['fid'], '1');
  });
}
