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

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;
import 'package:root_maps/core/fs/k_file_system.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/drive_folder_set_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/services/google_drive/drive_dir_store.dart';
import 'package:root_maps/services/google_drive/drive_folder_set_service.dart';
import 'package:root_maps/services/google_drive/drive_transfer_registry.dart';
import 'package:root_maps/services/google_drive/folder_lookup.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/google_drive/sync_progress.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDriveEntry {
  final String id;
  final String name;
  final String mimeType;
  String? md5Checksum;
  final bool canEdit;
  String? jsonContent;

  _FakeDriveEntry.folder({
    required this.id,
    required this.name,
    this.canEdit = true,
  }) : mimeType = 'application/vnd.google-apps.folder';

  _FakeDriveEntry.json({
    required this.id,
    required this.name,
    required String this.jsonContent,
    this.md5Checksum = 'md5_v1',
  })  : canEdit = false,
        mimeType = 'application/json';

  drive.File toDriveFile() => drive.File(
        id: id,
        name: name,
        mimeType: mimeType,
        md5Checksum: md5Checksum,
        capabilities: drive.FileCapabilities(canEdit: canEdit),
      );
}

class _FakeGoogleDriveService implements GoogleDriveService {
  final Map<String, _FakeDriveEntry> entries = {};

  void register(_FakeDriveEntry entry) {
    entries[entry.id] = entry;
  }

  @override
  Future<drive.File?> getFolderInfo(String folderId) async {
    return entries[folderId]?.toDriveFile();
  }

  @override
  Future<FolderLookup> lookupFolder(String folderId) async {
    final file = entries[folderId]?.toDriveFile();
    if (file == null) {
      return const FolderLookup.failed(
        FolderLookupFailure.notFound,
        'not found',
      );
    }
    return FolderLookup.found(file);
  }

  @override
  Future<Uint8List?> downloadBytes(
    String fileId, {
    void Function(int chunkBytes)? onChunk,
  }) async {
    final entry = entries[fileId];
    if (entry == null || entry.jsonContent == null) return null;
    return Uint8List.fromList(utf8.encode(entry.jsonContent!));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClonedCall {
  final String driveId;
  final String localPath;
  final String folderName;
  final bool isReadOnly;

  const _ClonedCall({
    required this.driveId,
    required this.localPath,
    required this.folderName,
    required this.isReadOnly,
  });
}

class _FakeSyncEngine implements SyncEngine {
  final List<_ClonedCall> clonedCalls = [];
  final Map<String, FolderSyncStatusDetail> statusByNormalizedPath = {};

  void setStatus(String localPath, FolderSyncStatusDetail detail) {
    statusByNormalizedPath[DriveTransferRegistry.normalizeKey(localPath)] =
        detail;
  }

  @override
  Future<bool> cloneFromDrive({
    required String driveId,
    required String localPath,
    required String folderName,
    required String driveUrl,
    required bool isReadOnly,
    drive.File? preloadedFolderInfo,
    void Function(SyncProgress progress)? onProgress,
    bool showOsNotification = true,
  }) async {
    clonedCalls.add(
      _ClonedCall(
        driveId: driveId,
        localPath: localPath,
        folderName: folderName,
        isReadOnly: isReadOnly,
      ),
    );
    await fs.createDirectory(localPath);
    await KMetaService.instance.setDriveSync(
      localPath,
      driveId: driveId,
      driveFolderName: folderName,
      driveUrl: driveUrl,
      isReadOnly: isReadOnly,
      isFolderSet: false,
      lastSynced: DateTime(2026, 11, 4, 12),
    );
    await DriveTransferRegistry.instance.clearClonePending(localPath);
    return true;
  }

  @override
  Future<FolderSyncStatusDetail> checkSyncStatusDetail(String localPath, {bool useCache = false}) async {
    final key = DriveTransferRegistry.normalizeKey(localPath);
    return statusByNormalizedPath[key] ??
        const FolderSyncStatusDetail(status: FolderSyncStatus.synced);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DriveFolderSetManifest.parse', () {
    test('parses object format with name and folders array', () {
      const jsonStr = '''
      {
        "name": "現在の現場地図",
        "folders": [
          "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
          {
            "url": "https://drive.google.com/drive/folders/2BcDeFgHiJkLmNoPqRsTuVwXyZ",
            "readOnly": true
          },
          {
            "driveId": "3CdEfGhIjKlMnOpQrStUvWxYzA",
            "readOnly": false
          }
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.name, '現在の現場地図');
      expect(manifest.items.length, 3);

      expect(manifest.items[0].driveId, '1AbCdEfGhIjKlMnOpQrStUvWxYz');
      expect(manifest.items[0].readOnly, isFalse);

      expect(manifest.items[1].driveId, '2BcDeFgHiJkLmNoPqRsTuVwXyZ');
      expect(manifest.items[1].readOnly, isTrue);

      expect(manifest.items[2].driveId, '3CdEfGhIjKlMnOpQrStUvWxYzA');
      expect(manifest.items[2].readOnly, isFalse);
    });

    test('parses combined presets and folders arrays and preset/folder entry keys', () {
      const jsonStr = '''
      {
        "name": "広域統合プリセット",
        "presets": [
          "https://drive.google.com/file/d/1ChildPresetJsonIdAbCdEfGhIj/view?usp=sharing",
          {
            "preset": "https://drive.google.com/file/d/2ChildPresetJsonIdBcDeFgHiJk/view",
            "readOnly": true
          }
        ],
        "folders": [
          {
            "folder": "https://drive.google.com/drive/folders/3FolderIdCdEfGhIjKlMnOpQrSt"
          }
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.name, '広域統合プリセット');
      expect(manifest.invalidEntryCount, 0);
      expect(manifest.items.length, 3);
      expect(manifest.items[0].driveId, '1ChildPresetJsonIdAbCdEfGhIj');
      expect(manifest.items[0].readOnly, isFalse);
      expect(manifest.items[1].driveId, '2ChildPresetJsonIdBcDeFgHiJk');
      expect(manifest.items[1].readOnly, isTrue);
      expect(manifest.items[2].driveId, '3FolderIdCdEfGhIjKlMnOpQrSt');
      expect(manifest.items[2].readOnly, isFalse);
    });

    test('parses top-level array format and uses fallbackName', () {
      const jsonStr = '''
      [
        "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
        "https://kokage-map.sleeptree.jp/open?drive=2BcDeFgHiJkLmNoPqRsTuVwXyZ"
      ]
      ''';

      final manifest = DriveFolderSetManifest.parse(
        jsonStr,
        fallbackName: 'site_maps.json',
      );
      expect(manifest.name, 'site_maps');
      expect(manifest.items.length, 2);
      expect(manifest.items[0].driveId, '1AbCdEfGhIjKlMnOpQrStUvWxYz');
      expect(manifest.items[1].driveId, '2BcDeFgHiJkLmNoPqRsTuVwXyZ');
    });

    test('deduplicates duplicate folder IDs', () {
      const jsonStr = '''
      {
        "folders": [
          "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
          "1AbCdEfGhIjKlMnOpQrStUvWxYz"
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.items.length, 1);
      expect(manifest.invalidEntryCount, 0);
    });

    test('counts invalid entries in invalidEntryCount to prevent accidental deletion', () {
      const jsonStr = '''
      {
        "folders": [
          "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz",
          "not-a-valid-url-or-id!!",
          {"wrongKey": "https://drive.google.com/drive/folders/2BcDeFgHiJkLmNoPqRsTuVwXyZ"}
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.items.length, 1);
      expect(manifest.invalidEntryCount, 2);
    });
  });

  group('GoogleDriveService.extractFolderIdFromUrl', () {
    test('extracts ID from Google Drive file URL (/file/d/<id>/view)', () {
      const url =
          'https://drive.google.com/file/d/1JsonFileIdAbCdEfGhIjKlMnOp/view?usp=sharing';
      expect(
        GoogleDriveService.extractFolderIdFromUrl(url),
        '1JsonFileIdAbCdEfGhIjKlMnOp',
      );
    });
  });

  group('FolderNode / DriveFolderSetNode persistence', () {
    late Directory tempDir;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('folder_set_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('creates DriveFolderSetNode when isFolderSet is saved in KMetaSync (including nested child sets)', () async {
      final rootSetPath = p.join(tempDir.path, '現在の現場地図');
      await fs.createDirectory(rootSetPath);
      await KMetaService.instance.setDriveSync(
        rootSetPath,
        driveId: 'json_file_id_123',
        driveFolderName: '現在の現場地図',
        driveUrl: 'https://drive.google.com/file/d/json_file_id_123/view',
        isReadOnly: true, // v0.14.0 互換: ルートセットは true で保存されていても強制ROにはしない
        isFolderSet: true,
        lastSynced: DateTime(2026, 10, 28, 12),
        driveRevisionId: 'md5_abc',
      );
      KMetaService.instance.invalidateCache(rootSetPath);

      final parent = FolderNode('共有');
      final node = await FolderNode.tryCreateDriveFolderNode(
        rootSetPath,
        '現在の現場地図',
        parent,
      );
      expect(node, isA<DriveFolderSetNode>());
      final rootSetNode = node! as DriveFolderSetNode;
      expect(rootSetNode.driveId, 'json_file_id_123');
      expect(rootSetNode.manifestFileId, 'json_file_id_123');
      expect(rootSetNode.isReadOnly, isFalse);

      // 親セット配下の子セットは KMetaSync.isReadOnly を引き継ぐ
      final childSetPath = p.join(rootSetPath, '子プリセット');
      await fs.createDirectory(childSetPath);
      await KMetaService.instance.setDriveSync(
        childSetPath,
        driveId: 'child_json_id_456',
        driveFolderName: '子プリセット',
        driveUrl: 'https://drive.google.com/file/d/child_json_id_456/view',
        isReadOnly: true,
        isFolderSet: true,
        lastSynced: DateTime(2026, 11, 4, 12),
        driveRevisionId: 'md5_def',
      );
      KMetaService.instance.invalidateCache(childSetPath);

      final childNode = await FolderNode.tryCreateDriveFolderNode(
        childSetPath,
        '子プリセット',
        rootSetNode,
      );
      expect(childNode, isA<DriveFolderSetNode>());
      final childSetNode = childNode! as DriveFolderSetNode;
      expect(childSetNode.manifestFileId, 'child_json_id_456');
      expect(childSetNode.isReadOnly, isTrue);
    });
  });

  group('DriveFolderSetService.reconcileSet (nested presets & safety guards)', () {
    late Directory tempDir;
    late _FakeGoogleDriveService fakeDrive;
    late _FakeSyncEngine fakeSync;
    late DriveFolderSetService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      KMetaService.instance.clearCache();
      DriveDirStore.instance.resetForTest();
      LocalSyncSeedIndex.instance.resetForTest();
      tempDir = Directory.systemTemp.createTempSync('nested_folder_set_test_');
      fakeDrive = _FakeGoogleDriveService();
      fakeSync = _FakeSyncEngine();
      service = DriveFolderSetService(
        driveService: fakeDrive,
        syncEngine: fakeSync,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('recursively expands nested JSON presets and Drive folders into tree structure', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'root_json_id_111111',
            name: '全体プリセット.json',
            jsonContent: jsonEncode({
              'name': '全体プリセット',
              'presets': [
                'https://drive.google.com/file/d/child_json_id_222222/view',
              ],
              'folders': [
                'https://drive.google.com/drive/folders/root_folder_id_333333',
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'child_json_id_222222',
            name: 'エリアA.json',
            jsonContent: jsonEncode({
              'name': 'エリアA',
              'folders': [
                'https://drive.google.com/drive/folders/area_a_folder_111111',
                'https://drive.google.com/drive/folders/area_a_folder_222222',
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(
            id: 'root_folder_id_333333',
            name: '共通ベースマップ',
          ),
        )
        ..register(
          _FakeDriveEntry.folder(
            id: 'area_a_folder_111111',
            name: 'Aエリア_調査図',
          ),
        )
        ..register(
          _FakeDriveEntry.folder(
            id: 'area_a_folder_222222',
            name: 'A工区_写真',
          ),
        );

      final rootSetPath = p.join(tempDir.path, '全体プリセット');
      final result = await service.reconcileSet(
        manifestFileId: 'root_json_id_111111',
        localSetPath: rootSetPath,
      );

      expect(result.success, isTrue);
      expect(result.addedCount, 3);
      expect(result.removedCount, 0);
      expect(result.failedItems, isEmpty);
      expect(result.skippedCycleOrDuplicateItems, isEmpty);

      // ディレクトリ階層とメタデータの検証
      final childSetPath = p.join(rootSetPath, 'エリアA');
      final rootFolderPath = (await DriveDirStore.instance
          .findExistingPath('root_folder_id_333333'))!;
      final childFolder1Path = (await DriveDirStore.instance
          .findExistingPath('area_a_folder_111111'))!;
      final childFolder2Path = (await DriveDirStore.instance
          .findExistingPath('area_a_folder_222222'))!;

      expect(await fs.exists(childSetPath), isTrue);
      expect(await fs.exists(rootFolderPath), isTrue);
      expect(await fs.exists(childFolder1Path), isTrue);
      expect(await fs.exists(childFolder2Path), isTrue);

      final childSetMeta = await KMetaService.instance.getMeta(childSetPath);
      expect(childSetMeta.sync.isFolderSet, isTrue);
      expect(childSetMeta.sync.driveId, 'child_json_id_222222');
      expect(
        childSetMeta.sync.setMembers.map((m) => m.driveId),
        equals(['area_a_folder_111111', 'area_a_folder_222222']),
      );

      final childFolderMeta = await KMetaService.instance.getMeta(childFolder1Path);
      expect(childFolderMeta.sync.isFolderSet, isFalse);
      expect(childFolderMeta.sync.driveId, 'area_a_folder_111111');
    });

    test('prevents direct and mutual cycles (A.json -> B.json -> A.json)', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'set_a_id_1111111111',
            name: 'set_a.json',
            jsonContent: jsonEncode({
              'name': 'セットA',
              'presets': [
                'set_b_id_2222222222',
                'set_a_id_1111111111', // 自己参照
              ],
              'folders': ['folder_a_id_1111111'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'set_b_id_2222222222',
            name: 'set_b.json',
            jsonContent: jsonEncode({
              'name': 'セットB',
              'presets': [
                'set_a_id_1111111111', // 相互参照ループ
              ],
              'folders': ['folder_b_id_2222222'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'folder_a_id_1111111', name: 'フォルダA'),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'folder_b_id_2222222', name: 'フォルダB'),
        );

      final rootSetPath = p.join(tempDir.path, 'セットA');
      final result = await service.reconcileSet(
        manifestFileId: 'set_a_id_1111111111',
        localSetPath: rootSetPath,
      );

      expect(result.success, isTrue);
      expect(result.addedCount, 2);
      expect(
        result.skippedCycleOrDuplicateItems,
        contains('set_a_id_1111111111'),
      );
      expect(fakeSync.clonedCalls.length, 2);
    });

    test('deduplicates diamond references across sibling child presets (First-Win)', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'root_diamond_id_111',
            name: 'root.json',
            jsonContent: jsonEncode({
              'name': 'ルート',
              'presets': [
                'branch_b_id_2222222',
                'branch_c_id_3333333',
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'branch_b_id_2222222',
            name: 'branch_b.json',
            jsonContent: jsonEncode({
              'name': '枝B',
              'folders': ['shared_folder_id_999'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'branch_c_id_3333333',
            name: 'branch_c.json',
            jsonContent: jsonEncode({
              'name': '枝C',
              'folders': [
                'shared_folder_id_999', // 枝Bと同じフォルダを参照
                'unique_c_folder_888',
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'shared_folder_id_999', name: '共通図面'),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'unique_c_folder_888', name: 'C専用図面'),
        );

      final rootSetPath = p.join(tempDir.path, 'ルート');
      final result = await service.reconcileSet(
        manifestFileId: 'root_diamond_id_111',
        localSetPath: rootSetPath,
      );

      expect(result.success, isTrue);
      expect(result.addedCount, 2);
      expect(
        result.skippedCycleOrDuplicateItems,
        equals(['shared_folder_id_999']),
      );

      // 共通図面は先に評価された「枝B」の setMembers にのみ登録され、「枝C」には重複登録されない
      final branchBMeta = await KMetaService.instance.getMeta(
        p.join(rootSetPath, '枝B'),
      );
      final branchCMeta = await KMetaService.instance.getMeta(
        p.join(rootSetPath, '枝C'),
      );
      expect(
        branchBMeta.sync.setMembers.map((m) => m.driveId),
        equals(['shared_folder_id_999']),
      );
      expect(
        branchCMeta.sync.setMembers.map((m) => m.driveId),
        equals(['unique_c_folder_888']),
      );
      expect(
        await DriveDirStore.instance.findExistingPath('shared_folder_id_999'),
        isNotNull,
      );
      expect(
        await DriveDirStore.instance.findExistingPath('unique_c_folder_888'),
        isNotNull,
      );
    });

    test('propagates readOnly monotonically from parent preset to child preset folders', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'parent_ro_json_1111',
            name: 'parent.json',
            jsonContent: jsonEncode({
              'name': '親セット',
              'presets': [
                {
                  'preset': 'child_rw_json_22222',
                  'readOnly': true, // 親が子セットを読み取り専用として指定
                },
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'child_rw_json_22222',
            name: 'child.json',
            jsonContent: jsonEncode({
              'name': '子セット',
              'folders': [
                {
                  'folder': 'editable_folder_333',
                  'readOnly': false, // 子セット内では readOnly: false
                },
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(
            id: 'editable_folder_333',
            name: '編集可能だったフォルダ',
            canEdit: true,
          ),
        );

      final rootSetPath = p.join(tempDir.path, '親セット');
      final result = await service.reconcileSet(
        manifestFileId: 'parent_ro_json_1111',
        localSetPath: rootSetPath,
      );

      expect(result.success, isTrue);
      expect(fakeSync.clonedCalls.length, 1);
      // 親セットの readOnly: true が強制継承されること
      expect(fakeSync.clonedCalls.single.isReadOnly, isTrue);

      final childSetMeta = await KMetaService.instance.getMeta(
        p.join(rootSetPath, '子セット'),
      );
      expect(childSetMeta.sync.isReadOnly, isTrue);
    });

    test('protects child preset from deletion when a descendant folder has local changes', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'root_del_json_11111',
            name: 'root.json',
            md5Checksum: 'md5_v1',
            jsonContent: jsonEncode({
              'name': '現場ルート',
              'presets': ['child_del_json_2222'],
              'folders': ['keep_folder_id_3333'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'child_del_json_2222',
            name: 'child.json',
            md5Checksum: 'md5_child_v1',
            jsonContent: jsonEncode({
              'name': '削除予定の子セット',
              'folders': ['dirty_folder_id_444'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'keep_folder_id_3333', name: '残すフォルダ'),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'dirty_folder_id_444', name: '未送信フォルダ'),
        );

      final rootSetPath = p.join(tempDir.path, '現場ルート');
      final firstResult = await service.reconcileSet(
        manifestFileId: 'root_del_json_11111',
        localSetPath: rootSetPath,
      );
      expect(firstResult.success, isTrue);
      expect(firstResult.addedCount, 2);

      final childSetPath = p.join(rootSetPath, '削除予定の子セット');
      final dirtyFolderPath = (await DriveDirStore.instance
          .findExistingPath('dirty_folder_id_444'))!;
      expect(await fs.exists(dirtyFolderPath), isTrue);

      // 子セット内のフォルダに未送信のローカル変更がある状態をセット
      fakeSync.setStatus(
        dirtyFolderPath,
        const FolderSyncStatusDetail(
          status: FolderSyncStatus.localChanges,
          localModified: 1,
        ),
      );

      // 親JSONから子セットを除外して更新
      fakeDrive.entries['root_del_json_11111']!
        ..md5Checksum = 'md5_v2'
        ..jsonContent = jsonEncode({
          'name': '現場ルート',
          'folders': ['keep_folder_id_3333'],
        });

      final secondResult = await service.reconcileSet(
        manifestFileId: 'root_del_json_11111',
        localSetPath: rootSetPath,
      );

      expect(secondResult.success, isTrue);
      expect(secondResult.removedCount, 0);
      expect(secondResult.keptWithLocalChanges, contains('未送信フォルダ'));
      expect(await fs.exists(childSetPath), isTrue);

      // 未送信変更が解消（同期済み）された後は安全に子セットごと削除されること
      fakeSync.setStatus(
        dirtyFolderPath,
        const FolderSyncStatusDetail(status: FolderSyncStatus.synced),
      );
      fakeDrive.entries['root_del_json_11111']!.md5Checksum = 'md5_v3';

      final thirdResult = await service.reconcileSet(
        manifestFileId: 'root_del_json_11111',
        localSetPath: rootSetPath,
      );

      expect(thirdResult.success, isTrue);
      expect(thirdResult.removedCount, 1);
      expect(thirdResult.keptWithLocalChanges, isEmpty);
      expect(await fs.exists(childSetPath), isFalse);
      expect(await fs.exists(dirtyFolderPath), isFalse);
    });

    test('reconciles child preset when child MD5 changes even if parent MD5 is unchanged', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'parent_md5_json_111',
            name: 'parent.json',
            md5Checksum: 'parent_md5_fixed',
            jsonContent: jsonEncode({
              'name': '親プリセット',
              'presets': ['child_md5_json_2222'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'child_md5_json_2222',
            name: 'child.json',
            md5Checksum: 'child_md5_v1',
            jsonContent: jsonEncode({
              'name': '子プリセット',
              'folders': ['folder_initial_1111'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'folder_initial_1111', name: '初期フォルダ'),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'folder_added_222222', name: '追加フォルダ'),
        );

      final rootSetPath = p.join(tempDir.path, '親プリセット');
      final r1 = await service.reconcileSet(
        manifestFileId: 'parent_md5_json_111',
        localSetPath: rootSetPath,
      );
      expect(r1.success, isTrue);
      expect(r1.addedCount, 1);

      // 親JSONのMD5はそのまま、子JSONだけDrive上で更新されてフォルダが追加されたケース
      fakeDrive.entries['child_md5_json_2222']!
        ..md5Checksum = 'child_md5_v2'
        ..jsonContent = jsonEncode({
          'name': '子プリセット',
          'folders': [
            'folder_initial_1111',
            'folder_added_222222',
          ],
        });

      final r2 = await service.reconcileSet(
        manifestFileId: 'parent_md5_json_111',
        localSetPath: rootSetPath,
      );
      expect(r2.success, isTrue);
      expect(r2.addedCount, 1);
      final addedFolderPath = await DriveDirStore.instance
          .findExistingPath('folder_added_222222');
      expect(addedFolderPath, isNotNull);
      expect(await fs.exists(addedFolderPath!), isTrue);
    });

    test('enforces kMaxSetDepth guard when nesting exceeds limit', () async {
      // set_0 -> set_1 -> ... -> set_6 (深さ6、上限 kMaxSetDepth = 5 を超える)
      for (var i = 0; i <= 6; i++) {
        final id = 'depth_set_id_00000$i';
        final nextId = 'depth_set_id_00000${i + 1}';
        fakeDrive.register(
          _FakeDriveEntry.json(
            id: id,
            name: 'set_$i.json',
            jsonContent: jsonEncode({
              'name': '階層$i',
              'presets': i < 6 ? [nextId] : <String>[],
            }),
          ),
        );
      }

      final rootSetPath = p.join(tempDir.path, '階層0');
      final result = await service.reconcileSet(
        manifestFileId: 'depth_set_id_000000',
        localSetPath: rootSetPath,
      );

      expect(result.success, isTrue);
      expect(
        result.skippedCycleOrDuplicateItems,
        contains('set_6.json'),
      );
    });

    test('shares single physical directory in DriveDirStore across multiple presets and preserves it while referenced', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'preset_1_json_id',
            name: 'preset_1.json',
            md5Checksum: 'p1_v1',
            jsonContent: jsonEncode({
              'name': 'プリセット1',
              'folders': [
                'shared_gis_id_11111',
                'only_p1_id_22222222',
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'preset_2_json_id',
            name: 'preset_2.json',
            md5Checksum: 'p2_v1',
            jsonContent: jsonEncode({
              'name': 'プリセット2',
              'folders': [
                'shared_gis_id_11111', // プリセット1と同じDriveフォルダを参照
                'only_p2_id_33333333',
              ],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'shared_gis_id_11111', name: '共通境界ポリゴン'),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'only_p1_id_22222222', name: '1専用レイヤ'),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'only_p2_id_33333333', name: '2専用レイヤ'),
        );

      final sharedRoot = p.join(tempDir.path, '共有');
      await fs.createDirectory(sharedRoot);
      final preset1Path = p.join(sharedRoot, 'プリセット1');
      final preset2Path = p.join(sharedRoot, 'プリセット2');

      final r1 = await service.reconcileSet(
        manifestFileId: 'preset_1_json_id',
        localSetPath: preset1Path,
      );
      expect(r1.success, isTrue);
      expect(r1.addedCount, 2);

      // プリセット2を同期した際、shared_gis_id_11111 は既に実体が存在するため再クローンされないこと
      final r2 = await service.reconcileSet(
        manifestFileId: 'preset_2_json_id',
        localSetPath: preset2Path,
      );
      expect(r2.success, isTrue);
      expect(
        fakeSync.clonedCalls.where((c) => c.driveId == 'shared_gis_id_11111').length,
        1,
      );

      final sharedPhysicalPath = (await DriveDirStore.instance
          .findExistingPath('shared_gis_id_11111'))!;
      expect(await fs.exists(sharedPhysicalPath), isTrue);

      // DriveFolderSetNode として読み込んだ際、両方のプリセットが同じ実体パスを参照渡しでマウントすること
      final sharedParent = FolderNode(
        '共有',
        pathResolver: DirectPathResolver(sharedRoot),
      );
      final node1 = (await FolderNode.tryCreateDriveFolderNode(
        preset1Path,
        'プリセット1',
        sharedParent,
      ))! as DriveFolderSetNode;
      final node2 = (await FolderNode.tryCreateDriveFolderNode(
        preset2Path,
        'プリセット2',
        sharedParent,
      ))! as DriveFolderSetNode;
      final nodes1 = await node1.loadFolderNodes(await fs.list(preset1Path));
      final nodes2 = await node2.loadFolderNodes(await fs.list(preset2Path));

      final mounted1 = nodes1
          .whereType<DriveFolderNode>()
          .firstWhere((n) => n.driveId == 'shared_gis_id_11111');
      final mounted2 = nodes2
          .whereType<DriveFolderNode>()
          .firstWhere((n) => n.driveId == 'shared_gis_id_11111');
      expect(
        DriveTransferRegistry.normalizeKey(mounted1.getAbsoluteFilePath()!),
        DriveTransferRegistry.normalizeKey(sharedPhysicalPath),
      );
      expect(
        DriveTransferRegistry.normalizeKey(mounted2.getAbsoluteFilePath()!),
        DriveTransferRegistry.normalizeKey(sharedPhysicalPath),
      );

      // プリセット1から shared_gis_id_11111 を外しても、プリセット2が参照しているため実体は削除されないこと
      fakeDrive.entries['preset_1_json_id']!
        ..md5Checksum = 'p1_v2'
        ..jsonContent = jsonEncode({
          'name': 'プリセット1',
          'folders': ['only_p1_id_22222222'],
        });
      final r1Removed = await service.reconcileSet(
        manifestFileId: 'preset_1_json_id',
        localSetPath: preset1Path,
      );
      expect(r1Removed.success, isTrue);
      expect(r1Removed.removedCount, 1);
      expect(await fs.exists(sharedPhysicalPath), isTrue);

      // プリセット2からも外れた時点で、どこからも参照されなくなった実体が削除されること
      fakeDrive.entries['preset_2_json_id']!
        ..md5Checksum = 'p2_v2'
        ..jsonContent = jsonEncode({
          'name': 'プリセット2',
          'folders': ['only_p2_id_33333333'],
        });
      final r2Removed = await service.reconcileSet(
        manifestFileId: 'preset_2_json_id',
        localSetPath: preset2Path,
      );
      expect(r2Removed.success, isTrue);
      expect(r2Removed.removedCount, 1);
      expect(await fs.exists(sharedPhysicalPath), isFalse);
    });

    test('LocalSyncSeedIndex seeds verified local files by MD5+size and rejects locally modified files', () async {
      final existingFolder = p.join(tempDir.path, '共有', '親フォルダ');
      await fs.createDirectory(existingFolder);

      final cleanBytes = Uint8List.fromList(utf8.encode('clean gpkg content 12345'));
      final cleanMd5 = md5.convert(cleanBytes).toString();
      final cleanPath = p.join(existingFolder, 'clean.gpkg');
      await fs.writeAsBytes(cleanPath, cleanBytes);

      final dirtyOriginalBytes = Uint8List.fromList(utf8.encode('original content 12345'));
      final dirtyOriginalMd5 = md5.convert(dirtyOriginalBytes).toString();
      final dirtyPath = p.join(existingFolder, 'dirty.gpkg');
      // ローカルで同じバイト長の別内容に書き換えられたケース
      final dirtyModifiedBytes = Uint8List.fromList(utf8.encode('modified content 99999'));
      await fs.writeAsBytes(dirtyPath, dirtyModifiedBytes);

      await KMetaService.instance.setDriveSync(
        existingFolder,
        driveId: 'parent_folder_drive_id',
        driveFolderName: '親フォルダ',
        lastSynced: DateTime(2026, 11, 5, 10),
        files: {
          'clean.gpkg': KMetaSyncFile(
            driveFileId: 'file_clean',
            lastSyncedTime: DateTime(2026, 11, 5, 10),
            remoteMd5: cleanMd5,
          ),
          'dirty.gpkg': KMetaSyncFile(
            driveFileId: 'file_dirty',
            lastSyncedTime: DateTime(2026, 11, 5, 10),
            remoteMd5: dirtyOriginalMd5,
          ),
        },
      );

      await LocalSyncSeedIndex.instance.refreshFromLedgers();

      final targetCleanPath = p.join(tempDir.path, 'target', 'clean_seeded.gpkg');
      final seededClean = await LocalSyncSeedIndex.instance.trySeedToFile(
        driveFileId: 'file_clean',
        remoteMd5: cleanMd5,
        remoteSize: cleanBytes.length,
        targetFilePath: targetCleanPath,
      );
      expect(seededClean, isTrue);
      expect(await fs.readAsBytes(targetCleanPath), equals(cleanBytes));

      final targetDirtyPath = p.join(tempDir.path, 'target', 'dirty_seeded.gpkg');
      final seededDirty = await LocalSyncSeedIndex.instance.trySeedToFile(
        driveFileId: 'file_dirty',
        remoteMd5: dirtyOriginalMd5,
        remoteSize: dirtyOriginalBytes.length,
        targetFilePath: targetDirtyPath,
      );
      expect(seededDirty, isFalse);
      expect(await fs.exists(targetDirtyPath), isFalse);
    });
  });
}
