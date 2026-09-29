// dir の改名が Drive 越しに届いたときの追従（2026-09-29、設計の「未決の論点」）。
//
// 子 dir の `.qgs` は `<dir名>.qgs`（Drive 連携の根ではないので）。端末 A で dir を改名すると、
// 読んだ時点で印の `dirName` から `.qgs` も付け替わる。それが同期で B に届いたとき、
// B でも新しい dir に新しい名前の `.qgs` が 1 本だけあり、設定が残っていること。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/sync_ledger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_google_drive.dart';

void main() {
  late Directory tmp;
  late FakeGoogleDrive drive;
  late SyncEngine engine;
  late String rootId;
  late String a;
  late String b;
  final ledgers = <String, SyncLedgerEntry?>{};
  String? current;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('qgs_dir_rename_');
    drive = FakeGoogleDrive();
    engine = SyncEngine(driveService: drive);
    rootId = drive.createRootFolder('proj');
    a = (await Directory(p.join(tmp.path, 'A')).create()).path;
    b = p.join(tmp.path, 'B');
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

  Future<SyncResult> syncOnce(String local) async {
    await asDevice(local);
    final decisions = <MergeDecision>[];
    for (final e in await engine.getMergeEntries(local)) {
      if (e.isConflict) {
        decisions.add(MergeDecision(entry: e, choice: e.mergeable ? MergeChoice.merge : MergeChoice.local));
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

  List<String> qgsFiles(String dir) => Directory(dir).existsSync()
      ? (Directory(dir).listSync().map((e) => p.basename(e.path)).where((n) => n.endsWith('.qgs')).toList()..sort())
      : const [];

  // ⚠ いまは通らない（既存の不具合・要判断。TODO.md「dir の改名が自動同期で巻き戻る」）。
  // 改名すると帳簿のパスを新しい場所に付け替えるので「帳簿のパス ≠ Drive のパス」になるが、
  // push はそれをローカルの移動と見るのに、自動同期（getMergeEntries）はリモートの移動と見て
  // 「リモートを採用」で手元の改名を巻き戻す。.qgs に限らず写真・gpkg も同じ
  test('A で子 dir を改名 → 同期 → B にも新しい dir に <新しい名前>.qgs が 1 本だけ、設定は残る',
      skip: '既存の不具合: 自動同期がローカルの移動をリモートの移動と見て巻き戻す（TODO.md）', () async {
    // A: 子 dir sub に設定と写真を置いて上げる、B が落とす
    await asDevice(a);
    await Directory(p.join(a, 'sub')).create();
    File(p.join(a, 'sub', 'p.jpg')).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    await KMetaService.instance.setImageVisibility(p.join(a, 'sub'), 'p.jpg', false);
    expect(qgsFiles(p.join(a, 'sub')), ['sub.qgs']);
    expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
    await asDevice(b);
    expect((await engine.pull(rootId, b)).success, isTrue);
    expect(qgsFiles(p.join(b, 'sub')), ['sub.qgs']);
    await tick();

    // A: アプリで sub → sub2 に改名（LayerDrawerService.renameFolder と同じ: 実体の改名＋帳簿の付け替え）
    await asDevice(a);
    await Directory(p.join(a, 'sub')).rename(p.join(a, 'sub2'));
    await KMetaService.instance.renameSyncedFiles(a, 'sub', 'sub2');
    KMetaService.instance.clearCache();
    // 読んだ時点で .qgs も新しい名前へ（印の dirName が旧名）
    expect((await KMetaService.instance.getMeta(p.join(a, 'sub2'))).visibility.images['p.jpg'], isFalse);
    expect(qgsFiles(p.join(a, 'sub2')), ['sub2.qgs']);
    await tick();

    await syncOnce(a);
    await tick();
    await syncOnce(b);

    expect(Directory(p.join(b, 'sub')).existsSync() ? qgsFiles(p.join(b, 'sub')) : const <String>[], isEmpty,
        reason: '旧 dir に .qgs が残らない');
    expect(qgsFiles(p.join(b, 'sub2')), ['sub2.qgs']);
    KMetaService.instance.clearCache();
    expect((await KMetaService.instance.getMeta(p.join(b, 'sub2'))).visibility.images['p.jpg'], isFalse);
    expect(File(p.join(b, 'sub2', 'p.jpg')).existsSync(), isTrue);
  });
}
