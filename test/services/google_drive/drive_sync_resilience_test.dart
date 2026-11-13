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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/services/google_drive/auto_sync_service.dart';
import 'package:root_maps/services/google_drive/drive_api_client.dart';
import 'package:root_maps/services/google_drive/drive_tree_cache.dart';
import 'package:root_maps/services/google_drive/folder_lookup.dart';
import 'package:root_maps/services/google_drive/network_error.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/google_drive/sync_file_operations.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_google_drive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FakeGoogleDrive fakeDrive;
  late SyncEngine engine;
  late Duration savedRetryDelay;

  Uint8List bytesOf(int seed, [int length = 8]) =>
      Uint8List.fromList(List<int>.generate(length, (i) => (seed + i) & 0xFF));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('drive_sync_resilience_');
    ProjectPathResolver.instance.setRootPathGetter(() => tmp.path);
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    DriveTreeCache.instance.clear();
    DriveTreeCache.clock = DateTime.now;
    savedRetryDelay = DriveApiClient.transientRetryDelay;
    DriveApiClient.transientRetryDelay = Duration.zero;
    fakeDrive = FakeGoogleDrive();
    engine = SyncEngine(driveService: fakeDrive);
  });

  tearDown(() async {
    DriveApiClient.transientRetryDelay = savedRetryDelay;
    DriveTreeCache.clock = DateTime.now;
    DriveTreeCache.instance.clear();
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('1. 大量サブフォルダのバッチ一覧取得と同時実行数制限', () {
    test('200超のサブフォルダを40件単位で束ね、同時リクエスト数を上限以下に抑えて走査する', () async {
      final rootId = fakeDrive.createRootFolder('archive');
      for (var g = 0; g < 6; g++) {
        final groupFolder = await fakeDrive.getOrCreateSubFolder(
          rootId,
          'area_$g',
        );
        for (var s = 0; s < 35; s++) {
          final sub = await fakeDrive.getOrCreateSubFolder(
            groupFolder!.id!,
            'plot_${g}_$s',
          );
          if (s % 10 == 0) {
            await fakeDrive.uploadBytes(
              bytesOf(g * 100 + s),
              'photo_${g}_$s.jpg',
              sub!.id!,
            );
          }
        }
      }
      // ルート1 + 第1階層6 + 第2階層210 = 計217フォルダ、写真24枚
      fakeDrive.calls.clear();
      fakeDrive.maxConcurrentListCalls = 0;
      fakeDrive.listDelay = const Duration(milliseconds: 5);

      final localDir = p.join(tmp.path, 'archive');
      final result = await engine.pull(rootId, localDir);

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.downloadedCount, 24);
      expect(
        fakeDrive.maxConcurrentListCalls,
        lessThanOrEqualTo(SyncFileOperations.maxListConcurrency),
      );

      final totalListRequests =
          (fakeDrive.calls['listFiles'] ?? 0) +
          (fakeDrive.calls['listFilesForParents'] ?? 0);
      // 従来は 217 回の listFiles だったが、バッチ化により 1(root) + 1(6件) + 6(210件÷40) = 8 回で完了する
      expect(totalListRequests, lessThanOrEqualTo(10));
    });
  });

  group('2. レート制限バックオフ・権限エラー識別・401自動トークン再取得', () {
    drive.DetailedApiRequestError apiError(
      int status, {
      String? reason,
      String message = 'API error',
    }) {
      return drive.DetailedApiRequestError(
        status,
        reason != null ? '$message ($reason)' : message,
      );
    }

    test('429 / 403 userRateLimitExceeded / 503 はリトライし、403 権限不足は即座に失敗させる', () async {
      var attempts429 = 0;
      final v1 = await DriveApiClient.retryTransient(() async {
        attempts429++;
        if (attempts429 < 3) {
          throw apiError(429, reason: 'rateLimitExceeded');
        }
        return 'ok-429';
      });
      expect(v1, 'ok-429');
      expect(attempts429, 3);

      var attemptsUserLimit = 0;
      final v2 = await DriveApiClient.retryTransient(() async {
        attemptsUserLimit++;
        if (attemptsUserLimit < 2) {
          throw apiError(
            403,
            reason: 'userRateLimitExceeded',
            message: 'User Rate Limit Exceeded',
          );
        }
        return 'ok-403-rate';
      });
      expect(v2, 'ok-403-rate');
      expect(attemptsUserLimit, 2);

      var attempts503 = 0;
      final v3 = await DriveApiClient.retryTransient(() async {
        attempts503++;
        if (attempts503 < 2) {
          throw apiError(503, message: 'Backend Error');
        }
        return 'ok-503';
      });
      expect(v3, 'ok-503');
      expect(attempts503, 2);

      // 本当の権限エラーはリトライせず、FolderLookup でも forbidden になる
      var attemptsPerm = 0;
      final permErr = apiError(
        403,
        reason: 'insufficientFilePermissions',
        message: 'Insufficient Permission',
      );
      expect(isRateLimitOrServerError(permErr), isFalse);
      await expectLater(
        () => DriveApiClient.retryTransient(() async {
          attemptsPerm++;
          throw permErr;
        }),
        throwsA(same(permErr)),
      );
      expect(attemptsPerm, 1);
      expect(classifyFolderLookupError(permErr), FolderLookupFailure.forbidden);

      // 403 レート制限は共有権限エラー（forbidden）と誤認させない
      final rateErr = apiError(403, reason: 'userRateLimitExceeded');
      expect(classifyFolderLookupError(rateErr), FolderLookupFailure.other);
    });

    test('HTTP 401 応答を受けたとき onUnauthorized でクライアントを更新して自動再試行する', () async {
      var currentBearer = 'expired_token';
      var refreshCalls = 0;

      drive.DriveApi buildMockApi(String token) {
        final mockHttp = MockClient((request) async {
          if (token == 'expired_token') {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 401,
                  'message': 'Invalid Credentials',
                },
              }),
              401,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'files': [
                {
                  'id': 'file_1',
                  'name': 'survey.gpkg',
                  'mimeType': 'application/geopackage+sqlite3',
                  'parents': ['folder_root_12345'],
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        return drive.DriveApi(mockHttp);
      }

      var activeApi = buildMockApi(currentBearer);
      final client = DriveApiClient(
        () => activeApi,
        onUnauthorized: () async {
          refreshCalls++;
          currentBearer = 'fresh_token';
          activeApi = buildMockApi(currentBearer);
          return true;
        },
      );

      final files = await client.listFiles('folder_root_12345');
      expect(refreshCalls, 1);
      expect(files.single.name, 'survey.gpkg');
    });
  });

  group('3. アプリ版数更新時の .qgs 無駄書き抑止', () {
    test('saveUserFull と <app> のバージョン表記だけが異なる場合は .qgs を書き直さない', () async {
      final dirPath = p.join(tmp.path, 'version_test');
      await Directory(dirPath).create(recursive: true);
      final folder = FolderNode('version_test', children: []);
      final root = FolderNode('root', children: [folder]);
      folder.parent = root;

      final firstWrite = await const QgsProjectBuilder().writeTo(folder);
      expect(firstWrite, isNotNull);
      final qgsFile = File(firstWrite!.path);
      final originalXml = await qgsFile.readAsString();

      // 旧バージョン（0.15.2+36）で保存された状態を模擬
      final olderVersionXml = originalXml
          .replaceAll(
            RegExp('saveUserFull="kokage-map[^"]*"'),
            'saveUserFull="kokage-map 0.15.2+36"',
          )
          .replaceAllMapped(
            RegExp('(<app[^>]*>)kokage-map[^<]*(</app>)'),
            (m) => '${m[1]}kokage-map 0.15.2+36${m[2]}',
          );
      expect(olderVersionXml, contains('saveUserFull="kokage-map 0.15.2+36"'));
      expect(olderVersionXml, contains('>kokage-map 0.15.2+36</app>'));
      await qgsFile.writeAsString(olderVersionXml, flush: true);
      final oldMtime = DateTime(2026, 11, 1, 9, 0, 0);
      await qgsFile.setLastModified(oldMtime);

      await const QgsProjectBuilder().writeTo(folder);

      expect(await qgsFile.lastModified(), oldMtime);
      expect(await qgsFile.readAsString(), olderVersionXml);
    });
  });

  group('4. 読み取り専用フォルダ（isReadOnly / capabilities.canEdit=false）の保護', () {
    test('読み取り専用フォルダでローカルの .qgs 等が変わっても Push せず synced にし、競合時はリモート側を取り込む', () async {
      final roDriveId = fakeDrive.createRootFolder(
        'shared_ref',
        ownedByMe: false,
        canEdit: false,
      );
      await fakeDrive.uploadBytes(bytesOf(10), 'layer.jpg', roDriveId);

      final localPath = p.join(tmp.path, 'shared_ref');
      expect(
        await engine.cloneFromDrive(
          driveId: roDriveId,
          localPath: localPath,
          folderName: 'shared_ref',
          driveUrl: 'https://drive.google.com/drive/folders/$roDriveId',
          isReadOnly: true,
          showOsNotification: false,
        ),
        isTrue,
      );

      final root = FolderNode('root', children: []);
      final node = DriveFolderNode(
        'shared_ref',
        driveId: roDriveId,
        driveUrl: '',
        isReadOnly: true,
        parent: root,
        children: [],
      );
      root.children.add(node);

      // 1) ローカル側だけ変更された状態 → Push せず synced になる
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File(p.join(localPath, 'local_edit.jpg')).writeAsBytesSync(bytesOf(99));
      fakeDrive.calls.clear();

      await AutoSyncService.instance.syncFolderForTest(engine, node);
      expect(node.syncStatus, SyncStatus.synced);
      expect(fakeDrive.calls['uploadBytes'], isNull);
      expect(fakeDrive.calls['uploadFile'], isNull);
      expect(fakeDrive.calls['uploadFileById'], isNull);

      // 2) リモート側でも同じファイル更新＋新規追加が起きた場合 → 衝突停止せずリモートを採用して synced になる
      await Future<void>.delayed(const Duration(milliseconds: 20));
      File(p.join(localPath, 'layer.jpg')).writeAsBytesSync(bytesOf(77));
      fakeDrive.touch(fakeDrive.fileAt(roDriveId, 'layer.jpg')!.id, bytesOf(55));
      await fakeDrive.uploadBytes(bytesOf(88), 'added_remote.jpg', roDriveId);
      fakeDrive.calls.clear();

      await AutoSyncService.instance.syncFolderForTest(engine, node);
      expect(node.syncStatus, SyncStatus.synced);
      expect(fakeDrive.calls['uploadBytes'], isNull);
      expect(fakeDrive.calls['uploadFile'], isNull);
      expect(fakeDrive.calls['uploadFileById'], isNull);
      expect(
        File(p.join(localPath, 'layer.jpg')).readAsBytesSync(),
        bytesOf(55),
      );
      expect(
        File(p.join(localPath, 'added_remote.jpg')).readAsBytesSync(),
        bytesOf(88),
      );
    });

    test('isReadOnly フラグが false でも Drive 側の canEdit が false なら Push を試みない', () async {
      final viewerOnlyId = fakeDrive.createRootFolder(
        'viewer_only',
        ownedByMe: false,
        canEdit: false,
      );
      await fakeDrive.uploadBytes(bytesOf(1), 'map.jpg', viewerOnlyId);

      final localPath = p.join(tmp.path, 'viewer_only');
      await engine.cloneFromDrive(
        driveId: viewerOnlyId,
        localPath: localPath,
        folderName: 'viewer_only',
        driveUrl: '',
        isReadOnly: false,
        showOsNotification: false,
      );

      final root = FolderNode('root', children: []);
      final node = DriveFolderNode(
        'viewer_only',
        driveId: viewerOnlyId,
        driveUrl: '',
        isReadOnly: false,
        parent: root,
        children: [],
      );
      root.children.add(node);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      File(p.join(localPath, 'map.jpg')).writeAsBytesSync(bytesOf(2));
      fakeDrive.calls.clear();

      await AutoSyncService.instance.syncFolderForTest(engine, node);
      expect(node.syncStatus, SyncStatus.synced);
      expect(fakeDrive.calls['uploadFileById'], isNull);
    });
  });

  group('5. Changes API 差分キャッシュと共有フォルダの取りこぼし防止', () {
    test('所有フォルダは無変更周期で listFiles を 0 回にし、変更時のみ該当フォルダを再走査する', () async {
      final ownA = fakeDrive.createRootFolder('own_a', ownedByMe: true);
      final ownB = fakeDrive.createRootFolder('own_b', ownedByMe: true);
      await fakeDrive.uploadBytes(bytesOf(1), 'a.jpg', ownA);
      await fakeDrive.uploadBytes(bytesOf(2), 'b.jpg', ownB);

      final pathA = p.join(tmp.path, 'own_a');
      final pathB = p.join(tmp.path, 'own_b');
      await engine.cloneFromDrive(
        driveId: ownA,
        localPath: pathA,
        folderName: 'own_a',
        driveUrl: '',
        isReadOnly: false,
        showOsNotification: false,
      );
      await engine.cloneFromDrive(
        driveId: ownB,
        localPath: pathB,
        folderName: 'own_b',
        driveUrl: '',
        isReadOnly: false,
        showOsNotification: false,
      );

      final root = FolderNode('root', children: []);
      final nodeA = DriveFolderNode(
        'own_a',
        driveId: ownA,
        driveUrl: '',
        parent: root,
        children: [],
      );
      final nodeB = DriveFolderNode(
        'own_b',
        driveId: ownB,
        driveUrl: '',
        parent: root,
        children: [],
      );
      root.children.addAll([nodeA, nodeB]);

      // 第1周期: 初回 clone 直後のローカル .qgs を Drive へ Push
      await AutoSyncService.instance.syncAllFoldersForTest(
        root: root,
        engine: engine,
        driveService: fakeDrive,
      );
      expect(nodeA.syncStatus, SyncStatus.synced);
      expect(nodeB.syncStatus, SyncStatus.synced);

      // 第2周期: Push 後の最新状態をキャッシュへ格納（転送なし）
      await AutoSyncService.instance.syncAllFoldersForTest(
        root: root,
        engine: engine,
        driveService: fakeDrive,
      );
      expect(nodeA.syncStatus, SyncStatus.synced);
      expect(nodeB.syncStatus, SyncStatus.synced);

      // 第3周期: Drive 変更なし → listChanges 1 回のみ、listFiles / getFolderInfo は 0 回
      fakeDrive.calls.clear();
      await AutoSyncService.instance.syncAllFoldersForTest(
        root: root,
        engine: engine,
        driveService: fakeDrive,
      );
      expect(fakeDrive.calls['listChanges'], 1);
      expect(fakeDrive.calls['listFiles'], isNull);
      expect(fakeDrive.calls['getFolderInfo'], isNull);

      // 第4周期: own_b のみ Drive 側で更新 → own_b だけ再走査・ダウンロードされ、own_a はキャッシュ維持
      await Future<void>.delayed(const Duration(milliseconds: 20));
      fakeDrive.touch(fakeDrive.fileAt(ownB, 'b.jpg')!.id, bytesOf(99));
      fakeDrive.calls.clear();

      await AutoSyncService.instance.syncAllFoldersForTest(
        root: root,
        engine: engine,
        driveService: fakeDrive,
      );
      expect(fakeDrive.calls['listChanges'], 1);
      expect(fakeDrive.calls['listFiles'], 1);
      expect(File(p.join(pathB, 'b.jpg')).readAsBytesSync(), bytesOf(99));
    });

    test('小規模な他人所有共有フォルダは Changes API に出ない追加ファイルも毎周期確実に検出する', () async {
      final sharedSmall = fakeDrive.createRootFolder(
        'shared_active',
        ownedByMe: false,
        canEdit: true,
      );
      await fakeDrive.uploadBytes(bytesOf(1), 'init.jpg', sharedSmall);

      final localPath = p.join(tmp.path, 'shared_active');
      await engine.cloneFromDrive(
        driveId: sharedSmall,
        localPath: localPath,
        folderName: 'shared_active',
        driveUrl: '',
        isReadOnly: false,
        showOsNotification: false,
      );

      final root = FolderNode('root', children: []);
      final node = DriveFolderNode(
        'shared_active',
        driveId: sharedSmall,
        driveUrl: '',
        parent: root,
        children: [],
      );
      root.children.add(node);

      await AutoSyncService.instance.syncAllFoldersForTest(
        root: root,
        engine: engine,
        driveService: fakeDrive,
      );

      // リンク共有フォルダに別ユーザーが新規ファイルを上げ、Changes API に載らなかったケースを模擬
      await fakeDrive.uploadBytes(
        bytesOf(42),
        'coworker_new.jpg',
        sharedSmall,
        emitChangeEvent: false,
      );

      await AutoSyncService.instance.syncAllFoldersForTest(
        root: root,
        engine: engine,
        driveService: fakeDrive,
      );
      expect(node.syncStatus, SyncStatus.synced);
      expect(
        File(p.join(localPath, 'coworker_new.jpg')).readAsBytesSync(),
        bytesOf(42),
      );
    });
  });

  group('6. 2パス・サイズ順スマートスケジューリング', () {
    test('先頭に大容量フォルダがあっても、同期済みフォルダの確定と軽量フォルダの同期を先に完了させる', () async {
      final heavyId = fakeDrive.createRootFolder('01_heavy', ownedByMe: true);
      final syncedId = fakeDrive.createRootFolder('02_synced', ownedByMe: true);
      final lightId = fakeDrive.createRootFolder('03_light', ownedByMe: true);

      await fakeDrive.uploadBytes(bytesOf(1), 'stay.jpg', syncedId);
      final pathHeavy = p.join(tmp.path, '01_heavy');
      final pathSynced = p.join(tmp.path, '02_synced');
      final pathLight = p.join(tmp.path, '03_light');

      for (final item in [
        (id: heavyId, path: pathHeavy, name: '01_heavy'),
        (id: syncedId, path: pathSynced, name: '02_synced'),
        (id: lightId, path: pathLight, name: '03_light'),
      ]) {
        await engine.cloneFromDrive(
          driveId: item.id,
          localPath: item.path,
          folderName: item.name,
          driveUrl: '',
          isReadOnly: false,
          showOsNotification: false,
        );
      }

      // 先頭の大容量フォルダに 200KB、末尾の軽量フォルダに 16B の新規ファイルを追加
      final heavyFile = await fakeDrive.uploadBytes(
        bytesOf(5, 200 * 1024),
        'big_archive.jpg',
        heavyId,
      );
      final lightFile = await fakeDrive.uploadBytes(
        bytesOf(9, 16),
        'small_field.jpg',
        lightId,
      );

      final root = FolderNode('root', children: []);
      final heavyNode = DriveFolderNode(
        '01_heavy',
        driveId: heavyId,
        driveUrl: '',
        parent: root,
        children: [],
      )..syncStatus = SyncStatus.error;
      final syncedNode = DriveFolderNode(
        '02_synced',
        driveId: syncedId,
        driveUrl: '',
        parent: root,
        children: [],
      )..syncStatus = SyncStatus.error;
      final lightNode = DriveFolderNode(
        '03_light',
        driveId: lightId,
        driveUrl: '',
        parent: root,
        children: [],
      )..syncStatus = SyncStatus.error;
      root.children.addAll([heavyNode, syncedNode, lightNode]);

      var syncedBeforeFirstDownload = false;
      fakeDrive.downloadedOrder.clear();
      AutoSyncService.instance.onSyncStatusChanged = () {
        if (fakeDrive.downloadedOrder.isEmpty &&
            syncedNode.syncStatus == SyncStatus.synced) {
          syncedBeforeFirstDownload = true;
        }
      };

      try {
        await AutoSyncService.instance.syncAllFoldersForTest(
          root: root,
          engine: engine,
          driveService: fakeDrive,
        );
      } finally {
        AutoSyncService.instance.onSyncStatusChanged = null;
      }

      expect(syncedBeforeFirstDownload, isTrue);
      expect(heavyNode.syncStatus, SyncStatus.synced);
      expect(syncedNode.syncStatus, SyncStatus.synced);
      expect(lightNode.syncStatus, SyncStatus.synced);
      expect(
        fakeDrive.downloadedOrder,
        [lightFile!.id, heavyFile!.id],
      );
    });
  });
}
