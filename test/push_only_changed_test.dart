// フォルダの push は、前回の同期から変わったファイルだけを上げる。
// 以前は 1 つ変わると全部を上げ直し、変わっていない gpkg の Drive 側の更新時刻も進めていた
// （他の端末が毎回「Drive で変更あり」と見る。2026-09-24、本物の Drive で見つけた）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_google_drive.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('push_changed_');
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
  });
  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('変わったファイルだけを上げ、変わっていないファイルの Drive 側は触らない', () async {
    final drive = FakeGoogleDrive();
    final engine = SyncEngine(driveService: drive);
    final rootId = drive.createRootFolder('proj');
    final dir = tmp.path;
    await File(p.join(dir, 'x.qgs')).writeAsString('<x/>');
    await File(p.join(dir, 'y.qgs')).writeAsString('<y/>');

    expect((await engine.push(dir, driveFolder: rootId)).success, isTrue);
    final y = drive.findByName(rootId, 'y.qgs')!;
    final yTime = y.modifiedTime;
    drive.calls.clear();

    await Future<void>.delayed(const Duration(milliseconds: 50));
    await File(p.join(dir, 'x.qgs')).writeAsString('<x changed="1"/>');
    final r = await engine.push(dir, driveFolder: rootId);
    expect(r.success, isTrue, reason: r.errorMessage);

    expect(drive.calls['uploadFileById'], 1, reason: 'x.qgs だけ');
    expect(String.fromCharCodes(drive.findByName(rootId, 'x.qgs')!.bytes), '<x changed="1"/>');
    expect(drive.findByName(rootId, 'y.qgs')!.modifiedTime, yTime, reason: 'y.qgs は上げ直さない');

    // 次の同期でも y.qgs は変わっていない扱いのまま（記録が引き継がれている）
    drive.calls.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await File(p.join(dir, 'x.qgs')).writeAsString('<x changed="2"/>');
    expect((await engine.push(dir, driveFolder: rootId)).success, isTrue);
    expect(drive.calls['uploadFileById'], 1);
  });
}
