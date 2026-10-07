// 同期エンジンの判定と反映を、偽の Drive で一通り押さえる（2026-10-07、リファクタリングの前に足した）。
//
// - 同期状態（checkSyncStatusDetail）とマージの一覧（getMergeEntries）が、追加・変更・削除・移動を
//   それぞれどう数えるか
// - マージの実行（executeMerge）で「端末を採用」「クラウドを採用」が何を上げ下げ・削除するか
// - push が Drive にだけあるものを消し、pull が手元にだけあるものを消すこと
//
// 写真（.jpg）だけで組む（gpkg の行単位マージは geodiff_sync_roundtrip_test が受け持つ）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('drive_sync_engine_');
    drive = FakeGoogleDrive();
    engine = SyncEngine(driveService: drive);
    rootId = drive.createRootFolder('proj');
    a = (await Directory(p.join(tmp.path, 'A')).create()).path;
    KMetaService.instance.clearCache();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));

  Uint8List jpg(int n) => Uint8List.fromList([0xFF, 0xD8, n, 0xFF, 0xD9]);

  void put(String rel, int n) {
    final f = File(p.joinAll([a, ...rel.split('/')]));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(jpg(n));
  }

  File local(String rel) => File(p.joinAll([a, ...rel.split('/')]));

  List<String> drivePhotos() => drive.allPaths(rootId).where((x) => x.endsWith('.jpg')).toList();

  Future<Map<String, MergeFileEntry>> mergeEntries() async => {
        for (final e in await engine.getMergeEntries(a))
          if (e.relativePath.endsWith('.jpg')) e.relativePath: e,
      };

  /// keep / mod / del / sub/moved を上げた状態
  Future<void> shared() async {
    put('keep.jpg', 1);
    put('mod.jpg', 2);
    put('del.jpg', 3);
    put('sub/moved.jpg', 4);
    final r = await engine.push(a, driveFolder: rootId);
    expect(r.success, isTrue, reason: r.errorMessage);
    await tick();
  }

  /// この端末で: mod を直し、del を消し、new を足す
  Future<void> changeLocally() async {
    put('mod.jpg', 20);
    local('del.jpg').deleteSync();
    put('new.jpg', 5);
    await tick();
  }

  /// 別の端末が Drive で: keep を直し、del を消し、r を足し、sub/moved を other/ へ動かし、空の empty/ を作る
  Future<void> changeRemotely() async {
    drive.touch(drive.fileAt(rootId, 'keep.jpg')!.id, jpg(10));
    drive.fileAt(rootId, 'del.jpg')!.trashed = true;
    await drive.uploadBytes(jpg(6), 'r.jpg', rootId);
    final other = await drive.getOrCreateSubFolder(rootId, 'other');
    await drive.moveFile(drive.fileAt(rootId, 'sub/moved.jpg')!.id, newParentId: other!.id!);
    await drive.getOrCreateSubFolder(rootId, 'empty');
    await tick();
  }

  group('同期状態', () {
    test('上げた直後は synced', () async {
      await shared();
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('連携していなければ notLinked', () async {
      put('x.jpg', 1);
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.notLinked);
    });

    test('連携しただけで一度も同期していなければ remoteChanges', () async {
      put('x.jpg', 1);
      await KMetaService.instance.setDriveSync(a, driveId: rootId);
      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.remoteChanges);
      expect(d.localAddedFiles, contains('x.jpg'));
    });

    test('この端末の追加・変更・削除', () async {
      await shared();
      await changeLocally();
      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.localChanges);
      expect(d.localAddedFiles, ['new.jpg']);
      expect(d.localModifiedFiles, ['mod.jpg']);
      expect(d.localDeletedFiles, ['del.jpg']);
      expect(d.hasRemoteChanges, isFalse);
    });

    test('Drive の追加・変更・削除・移動と、手元に無いフォルダ', () async {
      await shared();
      await changeRemotely();
      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.remoteChanges);
      expect(d.remoteModifiedFiles, ['keep.jpg']);
      expect(d.remoteDeletedFiles, ['del.jpg']);
      expect(d.remoteAddedFiles..sort(), ['empty/', 'other/', 'r.jpg']);
      expect(d.remoteMoved, 1);
      expect(d.remoteMovedFiles.single.movedFrom, 'sub/moved.jpg');
      expect(d.remoteMovedFiles.single.movedTo, 'other/moved.jpg');
      expect(d.remoteMovedFiles.single.type, FileChangeType.moved);
      expect(d.hasLocalChanges, isFalse);
    });

    test('Drive で動かして直したものは movedAndModified', () async {
      await shared();
      final f = drive.fileAt(rootId, 'sub/moved.jpg')!;
      await drive.moveFile(f.id, newParentId: rootId);
      drive.touch(f.id, jpg(40));
      await tick();
      final d = await engine.checkSyncStatusDetail(a);
      expect(d.remoteMovedFiles.single.type, FileChangeType.movedAndModified);
    });

    test('両方で変わっていれば conflict', () async {
      await shared();
      await changeLocally();
      await changeRemotely();
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.conflict);
    });

    test('この端末で改名したものは、この端末の変更', () async {
      await shared();
      local('keep.jpg').renameSync(local('kept.jpg').path);
      await KMetaService.instance.renameSyncedFiles(a, 'keep.jpg', 'kept.jpg');
      await tick();
      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.localChanges);
      expect(d.localModifiedFiles, ['kept.jpg']);
      expect(d.remoteMoved, 0);
    });
  });

  group('マージの一覧', () {
    test('この端末の変更', () async {
      await shared();
      await changeLocally();
      final e = await mergeEntries();
      expect(e.keys.toSet(), {'mod.jpg', 'del.jpg', 'new.jpg'});
      expect((e['mod.jpg']!.localChange, e['mod.jpg']!.remoteChange), (MergeChangeType.modified, MergeChangeType.none));
      expect((e['del.jpg']!.localChange, e['del.jpg']!.remoteChange), (MergeChangeType.deleted, MergeChangeType.none));
      expect((e['new.jpg']!.localChange, e['new.jpg']!.remoteChange), (MergeChangeType.added, MergeChangeType.none));
      expect(e['new.jpg']!.driveFileId, isNull);
      expect(e['mod.jpg']!.driveFileId, drive.fileAt(rootId, 'mod.jpg')!.id);
    });

    test('Drive の変更', () async {
      await shared();
      await changeRemotely();
      final e = await mergeEntries();
      expect(e.keys.toSet(), {'keep.jpg', 'del.jpg', 'r.jpg', 'sub/moved.jpg'});
      expect((e['keep.jpg']!.localChange, e['keep.jpg']!.remoteChange), (MergeChangeType.none, MergeChangeType.modified));
      expect((e['del.jpg']!.localChange, e['del.jpg']!.remoteChange), (MergeChangeType.none, MergeChangeType.deleted));
      expect((e['r.jpg']!.localChange, e['r.jpg']!.remoteChange), (MergeChangeType.none, MergeChangeType.added));
      final moved = e['sub/moved.jpg']!;
      expect((moved.localChange, moved.remoteChange), (MergeChangeType.none, MergeChangeType.moved));
      expect((moved.moveInfo!.movedFrom, moved.moveInfo!.movedTo), ('sub/moved.jpg', 'other/moved.jpg'));
    });

    test('両方で同じファイルを直したら衝突（写真は行単位で合わせられない）', () async {
      await shared();
      put('keep.jpg', 11);
      drive.touch(drive.fileAt(rootId, 'keep.jpg')!.id, jpg(12));
      await tick();
      final e = (await mergeEntries())['keep.jpg']!;
      expect(e.isConflict, isTrue);
      expect(e.mergeable, isFalse);
    });

    test('この端末で改名したものは、この端末の移動', () async {
      await shared();
      local('keep.jpg').renameSync(local('kept.jpg').path);
      await KMetaService.instance.renameSyncedFiles(a, 'keep.jpg', 'kept.jpg');
      await tick();
      final e = (await mergeEntries())['kept.jpg']!;
      expect((e.localChange, e.remoteChange), (MergeChangeType.moved, MergeChangeType.none));
      expect((e.moveInfo!.movedFrom, e.moveInfo!.movedTo), ('keep.jpg', 'kept.jpg'));
    });
  });

  group('マージの実行', () {
    Future<SyncResult> mergeAll(MergeChoice choice) async {
      final entries = await engine.getMergeEntries(a);
      final r = await engine.executeMerge(a, [for (final e in entries) MergeDecision(entry: e, choice: choice)]);
      expect(r.success, isTrue, reason: r.errorMessage);
      return r;
    }

    test('この端末の変更を、端末を採用で上げる', () async {
      await shared();
      await changeLocally();
      final r = await mergeAll(MergeChoice.local);
      expect((r.uploadedCount, r.deletedCount), (2, 1));
      expect(drivePhotos(), ['keep.jpg', 'mod.jpg', 'new.jpg', 'sub/moved.jpg']);
      expect(drive.fileAt(rootId, 'mod.jpg')!.bytes, jpg(20));
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('この端末の変更を、クラウドを採用で取り消す', () async {
      await shared();
      await changeLocally();
      final r = await mergeAll(MergeChoice.remote);
      expect((r.downloadedCount, r.deletedCount), (2, 1));
      expect(local('mod.jpg').readAsBytesSync(), jpg(2));
      expect(local('del.jpg').readAsBytesSync(), jpg(3));
      expect(local('new.jpg').existsSync(), isFalse);
      expect(drivePhotos(), ['del.jpg', 'keep.jpg', 'mod.jpg', 'sub/moved.jpg']);
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('Drive の変更を、クラウドを採用で取り込む（空のフォルダも作り、手元の空フォルダは消す）', () async {
      await shared();
      await changeRemotely();
      final r = await mergeAll(MergeChoice.remote);
      expect((r.downloadedCount, r.deletedCount, r.movedCount), (2, 1, 1));
      expect(local('keep.jpg').readAsBytesSync(), jpg(10));
      expect(local('del.jpg').existsSync(), isFalse);
      expect(local('r.jpg').readAsBytesSync(), jpg(6));
      expect(local('other/moved.jpg').existsSync(), isTrue);
      expect(local('sub/moved.jpg').existsSync(), isFalse);
      expect(Directory(p.join(a, 'empty')).existsSync(), isTrue);
      expect(Directory(p.join(a, 'sub')).existsSync(), isTrue, reason: 'Drive にはまだ sub/ がある');
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('マージのあと、Drive に無い手元の空フォルダは消す（.sync は残す）', () async {
      await shared();
      await Directory(p.join(a, 'emptylocal', 'deeper')).create(recursive: true);
      await Directory(p.join(a, '.sync', 'tmp')).create(recursive: true);
      put('new.jpg', 5);
      await tick();
      await mergeAll(MergeChoice.local);
      expect(Directory(p.join(a, 'emptylocal')).existsSync(), isFalse);
      expect(Directory(p.join(a, '.sync', 'tmp')).existsSync(), isTrue);
      expect(Directory(p.join(a, 'sub')).existsSync(), isTrue);
    });

    test('Drive の変更を、端末を採用で元に戻す', () async {
      await shared();
      await changeRemotely();
      final r = await mergeAll(MergeChoice.local);
      expect((r.uploadedCount, r.deletedCount), (2, 1));
      expect(drive.fileAt(rootId, 'keep.jpg')!.bytes, jpg(1));
      expect(drive.fileAt(rootId, 'del.jpg')!.bytes, jpg(3), reason: '消されたものを上げ直す');
      expect(drive.fileAt(rootId, 'r.jpg'), isNull, reason: 'Drive にだけ足されたものは消す');
      expect(drive.fileAt(rootId, 'sub/moved.jpg'), isNotNull, reason: '元の場所に戻す');
      expect(local('r.jpg').existsSync(), isFalse);
    });

    test('衝突は選んだ側が残る', () async {
      await shared();
      put('keep.jpg', 11);
      drive.touch(drive.fileAt(rootId, 'keep.jpg')!.id, jpg(12));
      await tick();
      await mergeAll(MergeChoice.local);
      expect(drive.fileAt(rootId, 'keep.jpg')!.bytes, jpg(11));

      put('keep.jpg', 13);
      drive.touch(drive.fileAt(rootId, 'keep.jpg')!.id, jpg(14));
      await tick();
      await mergeAll(MergeChoice.remote);
      expect(local('keep.jpg').readAsBytesSync(), jpg(14));
    });

    test('新しいサブフォルダへの追加は、Drive にもそのフォルダを作って上げる', () async {
      await shared();
      put('deep/er/x.jpg', 7);
      await tick();
      await mergeAll(MergeChoice.local);
      expect(drive.fileAt(rootId, 'deep/er/x.jpg')!.bytes, jpg(7));
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });
  });

  group('push / pull', () {
    test('push は手元に無いものを Drive から消し、改名を Drive にも写す', () async {
      await shared();
      await drive.uploadBytes(jpg(6), 'stray.jpg', rootId); // Drive にだけある
      local('del.jpg').deleteSync();
      local('keep.jpg').renameSync(local('kept.jpg').path);
      await KMetaService.instance.renameSyncedFiles(a, 'keep.jpg', 'kept.jpg');
      put('mod.jpg', 20);
      await tick();
      final r = await engine.push(a, driveFolder: rootId);
      expect(r.success, isTrue, reason: r.errorMessage);
      expect((r.uploadedCount, r.deletedCount), (1, 2));
      expect(drivePhotos(), ['kept.jpg', 'mod.jpg', 'sub/moved.jpg']);
      expect(drive.fileAt(rootId, 'kept.jpg')!.bytes, jpg(1), reason: '上げ直さずに改名');
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('上げるものが無い push（改名と削除だけ）も成功し、帳簿を書く', () async {
      await shared();
      local('del.jpg').deleteSync();
      local('keep.jpg').renameSync(local('kept.jpg').path);
      await KMetaService.instance.renameSyncedFiles(a, 'keep.jpg', 'kept.jpg');
      await tick();
      final r = await engine.push(a, driveFolder: rootId);
      expect(r.success, isTrue, reason: r.errorMessage);
      expect((r.uploadedCount, r.deletedCount), (0, 1));
      expect(drivePhotos(), ['kept.jpg', 'mod.jpg', 'sub/moved.jpg']);
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('pull は全部落とし、Drive に無いものと空のフォルダを手元から消す', () async {
      await shared();
      put('stray.jpg', 9);
      await Directory(p.join(a, 'emptylocal')).create();
      await changeRemotely();
      final r = await engine.pull(rootId, a);
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(local('stray.jpg').existsSync(), isFalse);
      expect(local('del.jpg').existsSync(), isFalse);
      expect(local('keep.jpg').readAsBytesSync(), jpg(10));
      expect(local('other/moved.jpg').existsSync(), isTrue);
      expect(Directory(p.join(a, 'emptylocal')).existsSync(), isFalse);
      expect(Directory(p.join(a, 'empty')).existsSync(), isTrue);
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });
  });
}
