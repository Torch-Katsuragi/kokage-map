// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// Drive 同期の無駄と、帳簿を失くした端末での上書き（2026-10-11）。
//
// - pull は変わっていないものを落とさない（帳簿の時刻・md5、帳簿が無ければ大きさと md5）
// - Drive で同じ中身が上げ直されただけなら「変更あり」と見ない
// - 帳簿が無く両方にあるものは、同じ中身なら何もせず同期済み、違えば 1 件の「両方にある」にまとめ、
//   更新日時が新しい側を既定にする（黙ってクラウドにしない）
// - 「端末を採用」で Drive の置き場所を見つけられなければ、ルート直下に上げない
// - Drive API の http クライアントを周期ごとに作り直さず、差し替えたら古いものを閉じる
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/sync_ledger.dart';
import 'package:root_maps/widgets/layer_drawer/sync_merge_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_google_drive.dart';

void main() {
  late Directory tmp;
  late FakeGoogleDrive drive;
  late SyncEngine engine;
  late String rootId;
  late String a;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('drive_sync_efficiency_');
    drive = FakeGoogleDrive();
    engine = SyncEngine(driveService: drive);
    rootId = drive.createRootFolder('proj');
    a = (await Directory(p.join(tmp.path, 'A')).create()).path;
    KMetaService.instance.clearCache();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    KMetaService.instance.clearCache();
    FakeDriveItem.withMd5 = true;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));
  Uint8List jpg(int n) => Uint8List.fromList([0xFF, 0xD8, n, 0xFF, 0xD9]);
  File local(String rel) => File(p.joinAll([a, ...rel.split('/')]));
  void put(String rel, int n) {
    final f = local(rel);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(jpg(n));
  }

  Future<List<MergeFileEntry>> photoEntries() async =>
      [for (final e in await engine.getMergeEntries(a)) if (e.relativePath.endsWith('.jpg')) e];

  /// 帳簿を失くす（アプリのデータを消した・入れ直した端末）。フォルダと `.qgs` のリンク情報は残る
  Future<void> loseLedger() async {
    await SyncLedger.instance.remove('drive:$rootId');
    KMetaService.instance.clearCache();
  }

  group('pull は変わっていないものを落とさない', () {
    test('Drive で 1 つ変わったら、それだけを落とす', () async {
      for (var i = 0; i < 10; i++) {
        put('p$i.jpg', i);
      }
      put('sub/q.jpg', 50);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      drive.touch(drive.fileAt(rootId, 'p3.jpg')!.id, jpg(33));
      await tick();
      drive.calls.clear();

      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.remoteChanges);
      final r = await engine.pullFolder(a, snapshot: d.snapshot);
      expect(r.success, isTrue, reason: r.errorMessage);
      // 以前は 12 ファイル（写真 11 + .qgs）を全部落としていた
      expect(drive.calls['downloadFile'], 1);
      expect(r.downloadedCount, 1);
      expect(r.skippedCount, greaterThanOrEqualTo(11));
      expect(local('p3.jpg').readAsBytesSync(), jpg(33));
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('手元を直したものは帳簿が合っていても落とし直す（pull は Drive に合わせる）', () async {
      put('x.jpg', 1);
      put('y.jpg', 2);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      put('x.jpg', 9);
      await tick();
      drive.calls.clear();
      final r = await engine.pull(rootId, a);
      expect(r.success, isTrue);
      expect(drive.calls['downloadFile'], 1);
      expect(local('x.jpg').readAsBytesSync(), jpg(1));
    });

    test('変わったものが無い pull は成功し、何も落とさない', () async {
      put('x.jpg', 1);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      drive.calls.clear();
      final r = await engine.pull(rootId, a);
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(drive.calls['downloadFile'], isNull);
      expect(r.changedLocal, isFalse, reason: 'ツリーを読み直さない');
    });

    test('Drive で同じ中身が上げ直されただけなら、変更と見ない', () async {
      put('x.jpg', 1);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      drive.touch(drive.fileAt(rootId, 'x.jpg')!.id, jpg(1)); // 時刻だけ進む
      await tick();
      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.synced);
    });

    test('md5 の無い Drive の応答では、時刻で判定する（以前どおり）', () async {
      put('x.jpg', 1);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      FakeDriveItem.withMd5 = false;
      drive.touch(drive.fileAt(rootId, 'x.jpg')!.id, jpg(1));
      await tick();
      expect((await engine.checkSyncStatusDetail(a)).remoteModifiedFiles, ['x.jpg']);
    });
  });

  group('帳簿を失くした端末（2026-10-11）', () {
    test('両方にあって中身が同じものは、何もせず同期済みにする', () async {
      put('x.jpg', 1);
      put('sub/y.jpg', 2);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      await loseLedger();
      drive.calls.clear();

      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.synced);
      expect(await photoEntries(), isEmpty);
      expect(drive.calls['downloadFile'], isNull);
      expect(drive.calls['uploadFileById'], isNull);
      // 帳簿に書けているので、次からは中身を読まずに判定できる
      expect((await KMetaService.instance.getMeta(a)).sync.files.keys, containsAll(['x.jpg', 'sub/y.jpg']));
    });

    test('Drive にだけ増えたものは取り込むが、両方にある同じ中身のものは落とさない', () async {
      put('x.jpg', 1);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      await loseLedger();
      await drive.uploadBytes(jpg(7), 'new.jpg', rootId);
      drive.calls.clear();

      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.remoteChanges);
      final r = await engine.pullFolder(a, snapshot: d.snapshot);
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(drive.calls['downloadFile'], 1);
      expect(local('new.jpg').readAsBytesSync(), jpg(7));
    });

    test('中身が違えば 1 件の「両方にある」にまとめ、端末が新しければ端末が既定', () async {
      put('x.jpg', 1);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      await loseLedger();
      put('x.jpg', 2); // 端末で直した（帳簿を失くす前の変更）
      await tick();

      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.conflict, reason: '自動同期は決めずに人に委ねる');
      final entries = await photoEntries();
      expect(entries, hasLength(1));
      final e = entries.single;
      expect((e.onBothWithoutLedger, e.isConflict, e.newerSide), (true, true, MergeChoice.local));

      // 既定（端末）で同期すると、Drive の同じファイルの版として上がる（2 つ目を作らない）
      final r = await engine.executeMerge(a, [MergeDecision(entry: e, choice: e.newerSide)]);
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(drive.allPaths(rootId).where((x) => x.endsWith('.jpg')), ['x.jpg']);
      expect(drive.fileAt(rootId, 'x.jpg')!.bytes, jpg(2));
      expect(local('x.jpg').readAsBytesSync(), jpg(2));
      expect((await engine.checkSyncStatusDetail(a)).status, FolderSyncStatus.synced);
    });

    test('クラウドのほうが新しければクラウドが既定', () async {
      put('x.jpg', 1);
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      await tick();
      await loseLedger();
      drive.touch(drive.fileAt(rootId, 'x.jpg')!.id, jpg(3));
      await tick();
      final e = (await photoEntries()).single;
      expect((e.onBothWithoutLedger, e.newerSide), (true, MergeChoice.remote));
    });

    test('一度も同期していない状態でも、中身の違うものがあれば取り込み（pull）にしない', () async {
      await drive.uploadBytes(jpg(1), 'x.jpg', rootId);
      await tick();
      put('x.jpg', 2);
      await KMetaService.instance.setDriveSync(a, driveId: rootId);
      final d = await engine.checkSyncStatusDetail(a);
      expect(d.status, FolderSyncStatus.conflict);
    });
  });

  group('同期ダイアログの既定（帳簿の無い「両方にある」）', () {
    final t0 = DateTime(2026, 10, 11, 9);
    MergeFileEntry both({required bool cloudNewer}) => MergeFileEntry(
          relativePath: 'data.gpkg',
          localChange: MergeChangeType.added,
          remoteChange: MergeChangeType.added,
          localModifiedTime: cloudNewer ? t0 : t0.add(const Duration(hours: 1)),
          remoteModifiedTime: cloudNewer ? t0.add(const Duration(hours: 1)) : t0,
          driveFileId: 'f1',
          onBothWithoutLedger: true,
        );

    Future<List<MergeDecision>?> open(WidgetTester tester, MergeFileEntry entry, SyncMode mode) async {
      List<MergeDecision>? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await SyncMergeDialog.show(context, folderName: 'proj', entries: [entry], mode: mode);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // どちらが新しいか確かめてほしい旨が、新しい側の名前つきで出る
      final side = entry.newerSide == MergeChoice.remote ? t.layerDrawer.folder.cloudLabel : t.layerDrawer.folder.localLabel;
      expect(find.text(t.layerDrawer.folder.onBothNoLedger(side: side)), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
      await tester.tap(find.text(t.layerDrawer.folder.syncExecute));
      await tester.pumpAndSettle();
      return result;
    }

    for (final mode in SyncMode.values) {
      testWidgets('端末が新しければ端末（$mode）', (tester) async {
        final r = await open(tester, both(cloudNewer: false), mode);
        expect(r!.single.choice, MergeChoice.local);
      });
      testWidgets('クラウドが新しければクラウド（$mode）', (tester) async {
        final r = await open(tester, both(cloudNewer: true), mode);
        expect(r!.single.choice, MergeChoice.remote);
      });
    }

    test('更新日時が分からなければ端末', () {
      const e = MergeFileEntry(
        relativePath: 'x.gpkg',
        localChange: MergeChangeType.added,
        remoteChange: MergeChangeType.added,
        onBothWithoutLedger: true,
      );
      expect(e.newerSide, MergeChoice.local);
    });
  });

  group('端末を採用で、Drive の置き場所を見つけられないとき', () {
    test('ルート直下に上げず、上げられなかったものとして返す', () async {
      expect((await engine.push(a, driveFolder: rootId)).success, isTrue);
      put('sub/new.jpg', 1);
      drive.failFolderNames.add('sub');
      final e = (await photoEntries()).single;
      expect(e.localChange, MergeChangeType.added);

      final r = await engine.executeMerge(a, [MergeDecision(entry: e, choice: MergeChoice.local)]);
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.failedUploads, ['sub/new.jpg']);
      expect(r.uploadedCount, 0);
      expect(drive.findByName(rootId, 'new.jpg'), isNull, reason: 'ルート直下に上げない');
      expect((await KMetaService.instance.getMeta(a)).sync.files.containsKey('sub/new.jpg'), isFalse);

      // 直れば次の同期で上がる
      drive.failFolderNames.clear();
      final again = (await photoEntries()).single;
      final r2 = await engine.executeMerge(a, [MergeDecision(entry: again, choice: MergeChoice.local)]);
      expect(r2.uploadedCount, 1);
      expect(r2.failedUploads, isEmpty);
      expect(drive.fileAt(rootId, 'sub/new.jpg'), isNotNull);
    });
  });

  group('Drive API の http クライアント', () {
    final service = GoogleDriveService();
    final prevGrace = GoogleDriveService.clientCloseGrace;
    setUp(() => GoogleDriveService.clientCloseGrace = Duration.zero);
    tearDown(() => GoogleDriveService.clientCloseGrace = prevGrace);

    test('同じトークンなら作り直さず、変わったら古いものを閉じる。サインアウトで閉じる', () async {
      final made = <_ClosableClient>[];
      http.Client make() => _ClosableClient()..also(made.add);

      expect(service.useTokenForTest('token-1', make), isTrue);
      // 自動同期の周期ごとに同じトークンが返ってくる
      for (var i = 0; i < 5; i++) {
        expect(service.useTokenForTest('token-1', make), isFalse);
      }
      expect(made, hasLength(1));
      expect(made.single.closed, isFalse);

      // トークンが変わった（約 1 時間で失効し、取り直した）
      expect(service.useTokenForTest('token-2', make), isTrue);
      expect(made, hasLength(2));
      expect(made[0].closed, isTrue);
      expect(made[1].closed, isFalse);
      expect(service.isDriveApiAvailable, isTrue);

      await service.signOut();
      expect(made[1].closed, isTrue);
      expect(service.isDriveApiAvailable, isFalse);
    });
  });
}

class _ClosableClient extends MockClient {
  _ClosableClient() : super((_) async => http.Response('{}', 200));
  bool closed = false;

  void also(void Function(_ClosableClient) f) => f(this);

  @override
  void close() {
    closed = true;
    super.close();
  }
}
