// KMetaSyncFile.remoteModifiedTime（リモートの変更判定を Drive の時刻どうしで行う）
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/kmeta.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 24, 1, 0, 0);

  test('remoteModifiedTime があれば Drive の時刻どうしで比べる', () {
    // 端末の時計が 5 秒進んでいて、lastSyncedTime が Drive の更新より後に見える
    final f = KMetaSyncFile(
      driveFileId: 'x',
      lastSyncedTime: t0.add(const Duration(seconds: 5)),
      remoteModifiedTime: t0,
    );
    expect(f.isRemoteNewer(t0.add(const Duration(seconds: 2))), isTrue);
    expect(f.isRemoteNewer(t0), isFalse);
    expect(f.isRemoteNewer(t0.subtract(const Duration(seconds: 1))), isFalse);
  });

  test('古い帳簿（remoteModifiedTime 無し）は lastSyncedTime と比べる', () {
    final f = KMetaSyncFile(driveFileId: 'x', lastSyncedTime: t0);
    expect(f.isRemoteNewer(t0.add(const Duration(seconds: 1))), isTrue);
    expect(f.isRemoteNewer(t0), isFalse);
    expect(const KMetaSyncFile(driveFileId: 'x').isRemoteNewer(t0), isFalse);
  });

  test('JSON の往復で remoteModifiedTime が残り、UTC で書かれる', () {
    final local = DateTime(2026, 9, 24, 10, 0, 0);
    final f = KMetaSyncFile(driveFileId: 'x', lastSyncedTime: local, remoteModifiedTime: local);
    final json = f.toJson();
    expect(json['remoteModifiedTime'], endsWith('Z'));
    final back = KMetaSyncFile.fromJson(json);
    expect(back.remoteModifiedTime!.isAtSameMomentAs(local), isTrue);
    expect(KMetaSyncFile.fromJson({'driveFileId': 'y'}).remoteModifiedTime, isNull);
  });
}
