// Drive 同期の行単位マージ（geodiff）を、2 台の端末で往復させるシナリオ。
//
// ホスト VM（test/geodiff_sync_roundtrip_test.dart、geodiff.dll + sqflite_common_ffi）と
// 実機（integration_test/geodiff_sync_roundtrip_test.dart、libgeodiff.so + Android の sqflite）で
// 同じものを回す。Drive はメモリ上の偽物、SyncEngine の push / pull / getMergeEntries / executeMerge は本物。
// 設計: docs/technical/drive-geodiff-sync.md
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/google_drive/sync_base_store.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/sync_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'fake_google_drive.dart';

/// データベースの用意（ホスト VM なら ffi を差す）は呼び手が済ませておくこと
void defineGeodiffRoundtripTests() {
  late Directory tmp;
  late FakeGoogleDrive drive;
  late SyncEngine engine;
  late String rootId;
  late String a; // 端末 A のプロジェクト dir
  late String b; // 端末 B のプロジェクト dir
  final ledgers = <String, SyncLedgerEntry?>{}; // 端末ごとの同期帳簿
  String? current; // いまの端末

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('geodiff_rt_');
    drive = FakeGoogleDrive();
    engine = SyncEngine(driveService: drive);
    rootId = drive.createRootFolder('proj');
    a = p.join(tmp.path, 'A');
    b = p.join(tmp.path, 'B');
    await Directory(a).create();
    KMetaService.instance.clearCache();
    SharedPreferences.setMockInitialValues({});
    ledgers.clear();
    current = null;
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));

  // 同期の帳簿（files / lastSyncedTime）は端末ごとの SharedPreferences に `drive:<driveId>` で入る。
  // 2 台を 1 プロセスで模すので、端末を切り替えるたびに帳簿を入れ替える（実機では端末ごとに別）
  Future<void> asDevice(String dev) async {
    final key = SyncLedger.keyFor(driveId: rootId, folderPath: '');
    if (current != null) ledgers[current!] = await SyncLedger.instance.read(key);
    current = dev;
    final next = ledgers[dev];
    if (next != null) {
      await SyncLedger.instance.write(key, next);
    } else {
      await SyncLedger.instance.remove(key);
    }
    KMetaService.instance.clearCache();
  }

  Future<void> makeGpkg(String path) async {
    final gpkg = GeoPackageFile(const ['data.gpkg'], absolutePath: path);
    await gpkg.addLayer('trees', GeometryType.point);
    await gpkg.addAttributeColumns('trees', {'name': 'TEXT', 'dbh': 'INTEGER'});
    await gpkg.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {'name': 'スギ1', 'dbh': 32});
    await gpkg.addPointWithAttributes('trees', const LatLng(33.931, 135.961), {'name': 'スギ2', 'dbh': 28});
    await gpkg.flushChanges();
    await gpkg.dispose();
  }

  Future<void> sql(String path, String stmt) async {
    final db = await openDatabase(path, singleInstance: false);
    await db.execute(stmt);
    await db.close();
  }

  Future<List<Map<String, Object?>>> rows(String path) async {
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      return await db.rawQuery('SELECT fid, name, dbh FROM trees ORDER BY fid');
    } finally {
      await db.close();
    }
  }

  /// 自動同期と同じ判断で 1 回同期する（衝突は merge、片側だけの変更はその側）
  Future<SyncResult> syncOnce(String local) async {
    await asDevice(local);
    final entries = await engine.getMergeEntries(local);
    final decisions = <MergeDecision>[];
    for (final e in entries) {
      if (e.isConflict) {
        expect(e.mergeable, isTrue, reason: '${e.relativePath} は base があるので行単位で合わせられるはず');
        decisions.add(MergeDecision(entry: e, choice: MergeChoice.merge));
      } else if (e.localChange != MergeChangeType.none) {
        decisions.add(MergeDecision(entry: e, choice: MergeChoice.local));
      } else if (e.remoteChange != MergeChangeType.none) {
        decisions.add(MergeDecision(entry: e, choice: MergeChoice.remote));
      }
    }
    final r = await engine.executeMerge(local, decisions);
    expect(r.success, isTrue, reason: r.errorMessage);
    return r;
  }

  /// A が作って上げ、B が落とす（両方に base ができる）
  Future<void> share() async {
    await makeGpkg(p.join(a, 'data.gpkg'));
    await asDevice(a);
    final pushed = await engine.push(a, driveFolder: rootId);
    expect(pushed.success, isTrue, reason: pushed.errorMessage);
    expect(await SyncBaseStore.hasBase(a, 'data.gpkg'), isTrue, reason: 'push のあと A に base');
    await asDevice(b);
    final pulled = await engine.pull(rootId, b);
    expect(pulled.success, isTrue, reason: pulled.errorMessage);
    expect(File(p.join(b, 'data.gpkg')).existsSync(), isTrue);
    expect(await SyncBaseStore.hasBase(b, 'data.gpkg'), isTrue, reason: 'pull のあと B に base');
    await tick();
  }

  test('別々の行の変更は、両端末で両方そろう', () async {
    await share();

    await sql(p.join(a, 'data.gpkg'), 'UPDATE trees SET dbh = 33 WHERE fid = 1');
    await sql(p.join(b, 'data.gpkg'), "UPDATE trees SET name = 'スギ2(B)' WHERE fid = 2");
    await tick();

    // A が先に上げる（片側だけの変更なので local）
    final ra = await syncOnce(a);
    expect(ra.uploadedCount, 1);
    expect(ra.mergedCount, 0);
    await tick();

    // B は両方変わっている → 行単位で合わせる
    final rb = await syncOnce(b);
    expect(rb.mergedCount, 1);
    expect(rb.conflicts, isEmpty);
    expect(drive.calls['uploadFileById'], greaterThanOrEqualTo(1));
    await tick();

    // A は相手の変更を取り込むだけ
    final ra2 = await syncOnce(a);
    expect(ra2.downloadedCount, 1);

    final expected = [
      {'fid': 1, 'name': 'スギ1', 'dbh': 33},
      {'fid': 2, 'name': 'スギ2(B)', 'dbh': 28},
    ];
    expect(await rows(p.join(a, 'data.gpkg')), expected);
    expect(await rows(p.join(b, 'data.gpkg')), expected);

    // base は Drive に上がらない
    expect(drive.allPaths(rootId).where((x) => x.startsWith('.sync')), isEmpty);
    // 次の同期は何もしない
    await tick();
    await asDevice(a);
    expect(await engine.getMergeEntries(a), isEmpty);
    await asDevice(b);
    expect(await engine.getMergeEntries(b), isEmpty);
  });

  test('同じ行・同じ列は後から合わせた端末の値が残り、衝突として返る', () async {
    await share();

    await sql(p.join(a, 'data.gpkg'), 'UPDATE trees SET dbh = 33 WHERE fid = 1');
    await sql(p.join(b, 'data.gpkg'), 'UPDATE trees SET dbh = 31 WHERE fid = 1');
    await sql(p.join(b, 'data.gpkg'), 'DELETE FROM trees WHERE fid = 2');
    await tick();

    await syncOnce(a);
    await tick();
    final rb = await syncOnce(b);
    expect(rb.mergedCount, 1);
    expect(rb.conflicts.length, 1);
    final c = rb.conflicts.single;
    expect(c.table, 'trees');
    expect(c.fid, '1');
    expect(c.base, 32);
    expect(c.theirs, 33); // A が上げた値
    expect(c.mine, 31); // B の値が残る
    await tick();
    await syncOnce(a);

    final expected = [
      {'fid': 1, 'name': 'スギ1', 'dbh': 31},
    ];
    expect(await rows(p.join(a, 'data.gpkg')), expected);
    expect(await rows(p.join(b, 'data.gpkg')), expected);
  });

  test('両端末の追加は fid がぶつかっても両方残る', () async {
    await share();

    final gA = GeoPackageFile(const ['data.gpkg'], absolutePath: p.join(a, 'data.gpkg'));
    await gA.addPointWithAttributes('trees', const LatLng(33.94, 135.97), {'name': 'Aの追加', 'dbh': 20});
    await gA.flushChanges();
    await gA.dispose();
    final gB = GeoPackageFile(const ['data.gpkg'], absolutePath: p.join(b, 'data.gpkg'));
    await gB.addPointWithAttributes('trees', const LatLng(33.95, 135.98), {'name': 'Bの追加', 'dbh': 21});
    await gB.flushChanges();
    await gB.dispose();
    await tick();

    await syncOnce(a);
    await tick();
    final rb = await syncOnce(b);
    expect(rb.mergedCount, 1);
    await tick();
    await syncOnce(a);

    final ra = await rows(p.join(a, 'data.gpkg'));
    final rbRows = await rows(p.join(b, 'data.gpkg'));
    expect(ra, rbRows);
    final names = ra.map((r) => r['name']).toSet();
    expect(names, containsAll(<String>['スギ1', 'スギ2', 'Aの追加', 'Bの追加']));
    expect(ra.length, 4);
  });

  test('端末の時計が Drive より進んでいても、相手の変更を見落とさない', () async {
    // 端末の時計が 5 秒進んでいる（= Drive の時計が 5 秒遅れている）
    drive.serverClockOffset = const Duration(seconds: -5);
    await share();

    await sql(p.join(a, 'data.gpkg'), 'UPDATE trees SET dbh = 33 WHERE fid = 1');
    await sql(p.join(b, 'data.gpkg'), "UPDATE trees SET name = 'スギ2(B)' WHERE fid = 2");
    await tick();

    await syncOnce(a); // A の変更が Drive に上がる（Drive の時刻は B の lastSyncedTime より前）
    await tick();
    final rb = await syncOnce(b);
    expect(rb.mergedCount, 1, reason: 'B は A の変更に気づいて行単位で合わせるはず');
    await tick();
    await syncOnce(a);

    final expected = [
      {'fid': 1, 'name': 'スギ1', 'dbh': 33},
      {'fid': 2, 'name': 'スギ2(B)', 'dbh': 28},
    ];
    expect(await rows(p.join(a, 'data.gpkg')), expected);
    expect(await rows(p.join(b, 'data.gpkg')), expected);
  });

  test('base が無い gpkg は mergeable にならず、今までどおりの二択', () async {
    await share();
    await SyncBaseStore.removeBase(b, 'data.gpkg');

    await sql(p.join(a, 'data.gpkg'), 'UPDATE trees SET dbh = 33 WHERE fid = 1');
    await sql(p.join(b, 'data.gpkg'), "UPDATE trees SET name = 'x' WHERE fid = 2");
    await tick();
    await syncOnce(a);
    await tick();

    await asDevice(b);
    final entries = await engine.getMergeEntries(b);
    final e = entries.singleWhere((x) => x.relativePath == 'data.gpkg');
    expect(e.isConflict, isTrue);
    expect(e.mergeable, isFalse);
  });

  test('merge の前にアプリの接続を閉じる（開いたままの GeoPackageFile は開き直して使える）', () async {
    await share();
    final pathB = p.join(b, 'data.gpkg');
    final open = GeoPackageFile(const ['data.gpkg'], absolutePath: pathB);
    await open.getLayerNames(); // 開いた状態にする
    expect(GeoPackageConnection.openCountFor(pathB), 1);

    await sql(p.join(a, 'data.gpkg'), 'UPDATE trees SET dbh = 33 WHERE fid = 1');
    await sql(pathB, "UPDATE trees SET name = 'スギ2(B)' WHERE fid = 2");
    await tick();
    await syncOnce(a);
    await tick();
    final rb = await syncOnce(b);
    expect(rb.mergedCount, 1);
    expect(GeoPackageConnection.openCountFor(pathB), 0, reason: 'rebase の前に閉じた');

    // 閉じられた側は次の呼び出しで開き直す
    expect(await open.getLayerNames(), contains('trees'));
    expect(GeoPackageConnection.openCountFor(pathB), 1);
    await open.dispose();
  });
}
