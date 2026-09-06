// 同期の帳簿（端末ごと）と共有ファイル（リンク情報）の分離
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/services/sync_ledger.dart';

void main() {
  final full = KMetaSync(
    driveId: 'd1',
    driveFolderName: 'Kitayama',
    driveUrl: 'https://drive/x',
    isReadOnly: false,
    lastSynced: DateTime(2026, 9, 6, 12, 0),
    driveRevisionId: 'rev9',
    deviceId: 'dev-A',
    files: {
      'a.gpkg': KMetaSyncFile(driveFileId: 'f1', lastSyncedTime: DateTime(2026, 9, 6)),
    },
  );

  test('linkOnly はリンク情報だけを残す', () {
    final link = full.linkOnly();
    expect(link.driveId, 'd1');
    expect(link.driveFolderName, 'Kitayama');
    expect(link.driveUrl, 'https://drive/x');
    expect(link.isReadOnly, false);
    expect(link.hasBookkeeping, isFalse);
    expect(full.hasBookkeeping, isTrue);
    // 共有ファイルに書く JSON に帳簿が混ざらない
    final json = link.toJson();
    expect(json.containsKey('files'), isFalse);
    expect(json.containsKey('lastSynced'), isFalse);
    expect(json.containsKey('deviceId'), isFalse);
  });

  test('帳簿は JSON で往復し、リンク情報に重ねられる', () {
    final entry = SyncLedgerEntry.fromSync(full);
    final again = SyncLedgerEntry.fromJson(entry.toJson());
    expect(again.deviceId, 'dev-A');
    expect(again.driveRevisionId, 'rev9');
    expect(again.lastSynced, DateTime(2026, 9, 6, 12, 0));
    expect(again.files['a.gpkg']!.driveFileId, 'f1');

    final merged = again.applyTo(full.linkOnly());
    expect(merged.driveId, 'd1');
    expect(merged.files.length, 1);
    expect(merged.deviceId, 'dev-A');
  });

  test('キーはリンク済みなら driveId、未リンクならパスのハッシュ', () {
    expect(SyncLedger.keyFor(driveId: 'd1', folderPath: '/x'), 'drive:d1');
    final a = SyncLedger.keyFor(driveId: null, folderPath: '/x/y');
    final b = SyncLedger.keyFor(driveId: '', folderPath: '/x/y');
    expect(a, b);
    expect(a, startsWith('path:'));
    expect(a, isNot(SyncLedger.keyFor(driveId: null, folderPath: '/x/z')));
  });
}
