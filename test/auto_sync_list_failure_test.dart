// 自動同期で Drive の一覧が取れない（名前解決の失敗など）とき、フォルダを「同期済み」にしない（2026-10-12）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/services/google_drive/auto_sync_service.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_google_drive.dart';

void main() {
  late Directory tmp;
  late FakeGoogleDrive drive;
  late SyncEngine engine;
  late String rootId;
  late String a;
  late DriveFolderNode node;

  Uint8List jpg(int n) => Uint8List.fromList([0xFF, 0xD8, n, 0xFF, 0xD9]);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('auto_sync_fail_');
    ProjectPathResolver.instance.setRootPathGetter(() => tmp.path);
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    drive = FakeGoogleDrive();
    engine = SyncEngine(driveService: drive);
    rootId = drive.createRootFolder('proj');
    a = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    File(p.join(a, 'x.jpg')).writeAsBytesSync(jpg(1));
    expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
    final root = FolderNode('root', children: []);
    node = DriveFolderNode('proj', driveId: rootId, driveUrl: '', parent: root, children: []);
    root.children.add(node);
    expect(node.getAbsoluteFilePath(), a);
  });
  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('一覧が取れなければエラー、手元の変更は残る', () async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    File(p.join(a, 'x.jpg')).writeAsBytesSync(jpg(2));
    drive.failListFor.add(rootId);

    await AutoSyncService.instance.syncFolderForTest(engine, node);
    expect(node.syncStatus, SyncStatus.error);
    expect(drive.fileAt(rootId, 'x.jpg')!.bytes, jpg(1));

    drive.failListFor.clear();
    expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.localChanges);
  });
}
