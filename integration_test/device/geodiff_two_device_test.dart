// 2 台の実機が PC 上の偽 Drive（tool/sync_relay/relay_server.dart）を共有して、
// 同じ gpkg を別々に直し、行単位マージで 1 つにそろうかを確かめる。
//
// 端末ごとに別プロセス・別の同期帳簿・別の時計で、SyncEngine と libgeodiff.so を本物のまま通す。
// 手順:
//   1. dart run tool/sync_relay/relay_server.dart
//   2. 両端末で adb reverse tcp:8799 tcp:8799
//   3. 端末 A: flutter test integration_test/device/geodiff_two_device_test.dart -d <A> --dart-define=ROLE=A
//      端末 B: flutter test integration_test/device/geodiff_two_device_test.dart -d <B> --dart-define=ROLE=B
//      （同時に走らせる。バリアで手順を合わせる）
// Drive はサーバー上の偽物で、端末の Drive・アプリの設定には触らない。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/services/google_drive/sync_base_store.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'support/relay_drive.dart';

const role = String.fromEnvironment('ROLE');
const runId = String.fromEnvironment('RUN', defaultValue: 'geodiff-2dev');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('2 台の実機で、別々の行の変更と同じ行の衝突が行単位で 1 つにそろう（ROLE=$role）', () async {
    expect(role == 'A' || role == 'B', isTrue, reason: '--dart-define=ROLE=A か B');
    SharedPreferences.setMockInitialValues({}); // 端末の同期帳簿は使わない（この端末の中だけで閉じる）
    final relay = RelayClient();
    final engine = SyncEngine(driveService: RelayGoogleDrive(relay));
    final tmp = await Directory.systemTemp.createTemp('two_dev_');
    final local = p.join(tmp.path, 'proj');
    final gpkg = p.join(local, 'data.gpkg');
    final rootId = await relay.call('createRootFolder', {'name': runId}) as String;
    // ignore: avoid_print
    void log(String m) => print('[2dev $role] $m');

    Future<List<Map<String, Object?>>> rows() async {
      final db = await openDatabase(gpkg, readOnly: true, singleInstance: false);
      try {
        return await db.rawQuery('SELECT fid, name, dbh FROM trees ORDER BY fid');
      } finally {
        await db.close();
      }
    }

    Future<void> sql(String stmt) async {
      final db = await openDatabase(gpkg, singleInstance: false);
      await db.execute(stmt);
      await db.close();
    }

    Future<SyncResult> syncOnce() async {
      KMetaService.instance.clearCache();
      final entries = await engine.getMergeEntries(local);
      final decisions = <MergeDecision>[];
      for (final e in entries) {
        log('entry ${e.relativePath} local=${e.localChange.name} remote=${e.remoteChange.name} mergeable=${e.mergeable}');
        if (e.isConflict) {
          decisions.add(MergeDecision(entry: e, choice: e.mergeable ? MergeChoice.merge : MergeChoice.local));
        } else if (e.localChange != MergeChangeType.none) {
          decisions.add(MergeDecision(entry: e, choice: MergeChoice.local));
        } else if (e.remoteChange != MergeChangeType.none) {
          decisions.add(MergeDecision(entry: e, choice: MergeChoice.remote));
        }
      }
      final r = await engine.executeMerge(local, decisions);
      log('sync ↑${r.uploadedCount} ↓${r.downloadedCount} ⇄${r.mergedCount} 衝突${r.conflicts.length} ${r.errorMessage ?? ''}');
      expect(r.success, isTrue, reason: r.errorMessage);
      return r;
    }

    if (role == 'A') {
      // 1. A が作って上げる
      await Directory(local).create(recursive: true);
      final g = GeoPackageFile(const ['data.gpkg'], absolutePath: gpkg);
      await g.addLayer('trees', GeometryType.point);
      await g.addAttributeColumns('trees', {'name': 'TEXT', 'dbh': 'INTEGER'});
      await g.addPointWithAttributes('trees', const LatLng(33.93, 135.96), {'name': 'スギ1', 'dbh': 32});
      await g.addPointWithAttributes('trees', const LatLng(33.931, 135.961), {'name': 'スギ2', 'dbh': 28});
      await g.addPointWithAttributes('trees', const LatLng(33.932, 135.962), {'name': 'ヒノキ1', 'dbh': 25});
      await g.flushChanges();
      await g.dispose();
      final pushed = await engine.push(local, driveFolder: rootId);
      expect(pushed.success, isTrue, reason: pushed.errorMessage);
      expect(await SyncBaseStore.hasBase(local, 'data.gpkg'), isTrue);
      log('pushed');
      await relay.done('1-pushed');

      // 3. B が落としたら、A は fid=1 の dbh と fid=3 の name を直す
      await relay.waitFor('2-pulled');
      await sql('UPDATE trees SET dbh = 33 WHERE fid = 1');
      await sql("UPDATE trees SET name = 'ヒノキ1(A)' WHERE fid = 3");
      await relay.done('3a-edited');

      // 4. 両方直したら、A が先に上げる
      await relay.waitFor('3b-edited');
      final ra = await syncOnce();
      expect(ra.uploadedCount, 1);
      await relay.done('4-a-synced');

      // 6. B が合わせたら、A は取り込む
      await relay.waitFor('5-b-merged');
      final ra2 = await syncOnce();
      expect(ra2.downloadedCount, 1);
    } else {
      // 2. B が落とす
      await relay.waitFor('1-pushed');
      final pulled = await engine.pull(rootId, local);
      expect(pulled.success, isTrue, reason: pulled.errorMessage);
      expect(await SyncBaseStore.hasBase(local, 'data.gpkg'), isTrue);
      log('pulled');
      await relay.done('2-pulled');

      // 3. B は fid=2 の name と、A と同じ fid=3 の name（=衝突）を直す
      await sql("UPDATE trees SET name = 'スギ2(B)' WHERE fid = 2");
      await sql("UPDATE trees SET name = 'ヒノキ1(B)' WHERE fid = 3");
      await relay.done('3b-edited');

      // 5. A が上げたら、B は行単位で合わせる
      await relay.waitFor('4-a-synced');
      final rb = await syncOnce();
      expect(rb.mergedCount, 1, reason: 'A の変更に気づいて合わせるはず');
      expect(rb.conflicts.length, 1);
      expect(rb.conflicts.single.fid, '3');
      expect(rb.conflicts.single.theirs, 'ヒノキ1(A)');
      expect(rb.conflicts.single.mine, 'ヒノキ1(B)');
      await relay.done('5-b-merged');
    }

    // 最後に両端末の中身をそろえて報告（B は A の取り込みを待つ）
    if (role == 'B') await relay.waitFor('6-a-final');
    final result = await rows();
    await relay.call('report', {'role': role, 'data': result});
    log('final $result');
    if (role == 'A') await relay.done('6-a-final');

    expect(result, [
      {'fid': 1, 'name': 'スギ1', 'dbh': 33},
      {'fid': 2, 'name': 'スギ2(B)', 'dbh': 28},
      {'fid': 3, 'name': 'ヒノキ1(B)', 'dbh': 25}, // 後から合わせた B の値が残る
    ]);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }, timeout: const Timeout(Duration(minutes: 30)));
}
