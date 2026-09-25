// 同じ Drive フォルダを 1 台で 2 か所にクローンしても、帳簿が混ざらない（SyncLedger.resolveKey）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/sync_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  var seq = 0;
  late String drive; // テストごとに別の Drive ID（帳簿のキャッシュが持ち越されないように）

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('ledger_owner_');
    drive = 'drive-${DateTime.now().microsecondsSinceEpoch}-${seq++}';
  });
  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> dir(String name) async => (await Directory(p.join(tmp.path, name)).create()).path;
  final t1 = DateTime.utc(2026, 9, 24, 1);
  final t2 = DateTime.utc(2026, 9, 24, 2);

  test('2 か所にクローンしたら、帳簿を分ける（互いの同期時刻を上書きしない）', () async {
    final a = await dir('A');
    final b = await dir('B');
    await KMetaService.instance.setDriveSync(a, driveId: drive, files: {'x.gpkg': KMetaSyncFile(driveFileId: 'f', lastSyncedTime: t1)});
    await KMetaService.instance.setDriveSync(b, driveId: drive, files: {'x.gpkg': KMetaSyncFile(driveFileId: 'f', lastSyncedTime: t2)});
    KMetaService.instance.clearCache();

    expect((await KMetaService.instance.getMeta(a)).sync.files['x.gpkg']!.lastSyncedTime, t1);
    expect((await KMetaService.instance.getMeta(b)).sync.files['x.gpkg']!.lastSyncedTime, t2);
    expect(await SyncLedger.instance.resolveKey(driveId: drive, folderPath: a), 'drive:$drive');
    expect(await SyncLedger.instance.resolveKey(driveId: drive, folderPath: b), startsWith('drive:$drive@'));
  });

  test('同じ dir をリンク越しの別名で開いても、同じ帳簿（/sdcard と /storage/emulated/0）', () async {
    final a = await dir('A');
    final alias = p.join(tmp.path, 'alias');
    await Link(alias).create(a); // Windows ではジャンクション
    await KMetaService.instance.setDriveSync(a, driveId: drive, files: {'x.gpkg': KMetaSyncFile(driveFileId: 'f', lastSyncedTime: t1)});
    KMetaService.instance.clearCache();

    expect(await SyncLedger.instance.resolveKey(driveId: drive, folderPath: alias), 'drive:$drive');
    expect((await KMetaService.instance.getMeta(alias)).sync.files['x.gpkg']!.lastSyncedTime, t1);
  });

  test('持ち主の dir が消えていたら（動かした）、今までどおり帳簿を引き継ぐ', () async {
    final a = await dir('A');
    await KMetaService.instance.setDriveSync(a, driveId: drive, files: {'x.gpkg': KMetaSyncFile(driveFileId: 'f', lastSyncedTime: t1)});
    final moved = p.join(tmp.path, 'Moved');
    await Directory(a).rename(moved);
    KMetaService.instance.clearCache();

    expect(await SyncLedger.instance.resolveKey(driveId: drive, folderPath: moved), 'drive:$drive');
    expect((await KMetaService.instance.getMeta(moved)).sync.files['x.gpkg']!.lastSyncedTime, t1);
  });

  test('持ち主の dir が Drive とのリンクを外していたら引き継ぐ', () async {
    final a = await dir('A');
    final b = await dir('B');
    await KMetaService.instance.setDriveSync(a, driveId: drive, files: {'x.gpkg': KMetaSyncFile(driveFileId: 'f', lastSyncedTime: t1)});
    await KMeta.empty.saveToFile(a); // A はリンクを外した
    KMetaService.instance.clearCache();
    expect(await SyncLedger.instance.resolveKey(driveId: drive, folderPath: b), 'drive:$drive');
  });

  test('持ち主の記録が無い古い帳簿は、今までどおり drive キー', () async {
    final a = await dir('A');
    await SyncLedger.instance.write('drive:$drive', SyncLedgerEntry(lastSynced: t1));
    expect(await SyncLedger.instance.resolveKey(driveId: drive, folderPath: a), 'drive:$drive');
  });

  test('JSON の往復で持ち主が残る', () {
    final e = SyncLedgerEntry(lastSynced: t1).withOwner('/x/y');
    expect(SyncLedgerEntry.fromJson(e.toJson()).owner, '/x/y');
  });
}
