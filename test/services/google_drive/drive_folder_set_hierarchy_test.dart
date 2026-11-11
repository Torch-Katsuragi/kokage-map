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
import 'package:path/path.dart' as p;
import 'package:root_maps/core/fs/k_file_system.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/services/google_drive/drive_dir_store.dart';
import 'package:root_maps/services/google_drive/drive_folder_set_hierarchy.dart';
import 'package:root_maps/services/google_drive/drive_folder_set_service.dart';
import 'package:root_maps/services/google_drive/drive_transfer_registry.dart';
import 'package:root_maps/services/google_drive/folder_lookup.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/google_drive/sync_progress.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubGoogleDriveService implements GoogleDriveService {
  final Map<String, ({drive.File meta, String? content})> entries = {};

  void putJson(String id, String name, Map<String, Object?> body, {String md5 = 'm1'}) {
    entries[id] = (
      meta: drive.File(
        id: id,
        name: name,
        mimeType: 'application/json',
        md5Checksum: md5,
        capabilities: drive.FileCapabilities(canEdit: false),
      ),
      content: jsonEncode(body),
    );
  }

  void putFolder(String id, String name) {
    entries[id] = (
      meta: drive.File(
        id: id,
        name: name,
        mimeType: 'application/vnd.google-apps.folder',
        capabilities: drive.FileCapabilities(canEdit: true),
      ),
      content: null,
    );
  }

  @override
  Future<FolderLookup> lookupFolder(String folderId) async {
    final e = entries[folderId];
    if (e == null) {
      return const FolderLookup.failed(FolderLookupFailure.notFound, '404');
    }
    return FolderLookup.found(e.meta);
  }

  @override
  Future<Uint8List?> downloadBytes(
    String fileId, {
    void Function(int chunkBytes)? onChunk,
  }) async {
    final content = entries[fileId]?.content;
    return content == null ? null : Uint8List.fromList(utf8.encode(content));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSyncEngine implements SyncEngine {
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
    await fs.createDirectory(localPath);
    await KMetaService.instance.setDriveSync(
      localPath,
      driveId: driveId,
      driveFolderName: folderName,
      driveUrl: driveUrl,
      isReadOnly: isReadOnly,
      isFolderSet: false,
      lastSynced: DateTime(2026, 11, 11, 9),
    );
    await DriveTransferRegistry.instance.clearClonePending(localPath);
    return true;
  }

  @override
  Future<FolderSyncStatusDetail> checkSyncStatusDetail(String localPath) async =>
      const FolderSyncStatusDetail(status: FolderSyncStatus.synced);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DriveFolderSetManifest.parse edge cases & aliases', () {
    test('supports title, children, items, id, and isReadOnly aliases and ignores blank strings', () {
      const jsonStr = '''
      {
        "title": "  演習セットA  ",
        "children": [
          "   ",
          {"id": "1ChildSetIdAbCdEfGhIjKlMnOp", "isReadOnly": true}
        ],
        "items": [
          {"driveUrl": "https://drive.google.com/drive/folders/2FolderIdBcDeFgHiJkLmNoPqRs"}
        ]
      }
      ''';

      final manifest = DriveFolderSetManifest.parse(jsonStr);
      expect(manifest.name, '演習セットA');
      expect(manifest.invalidEntryCount, 0);
      expect(manifest.items.length, 2);
      expect(manifest.items[0].driveId, '1ChildSetIdAbCdEfGhIjKlMnOp');
      expect(manifest.items[0].readOnly, isTrue);
      expect(
        manifest.items[0].driveUrl,
        'https://drive.google.com/drive/folders/1ChildSetIdAbCdEfGhIjKlMnOp',
      );
      expect(manifest.items[1].driveId, '2FolderIdBcDeFgHiJkLmNoPqRs');
      expect(manifest.items[1].readOnly, isFalse);
    });

    test('throws FormatException on invalid root or missing/non-array folder keys', () {
      expect(
        () => DriveFolderSetManifest.parse('"just a string"'),
        throwsFormatException,
      );
      expect(
        () => DriveFolderSetManifest.parse('{"name": "no arrays"}'),
        throwsFormatException,
      );
      expect(
        () => DriveFolderSetManifest.parse('{"presets": "not_a_list"}'),
        throwsFormatException,
      );
      expect(
        () => DriveFolderSetManifest.parse('{"folders": 123}'),
        throwsFormatException,
      );
    });
  });

  group('FolderSetHierarchy pure guards', () {
    test('enforces kFolderSetMaxTotalItems cap across shared context', () {
      final items = List.generate(
        kFolderSetMaxTotalItems + 5,
        (i) {
          final id = 'folder_item_id_${i.toString().padLeft(4, '0')}';
          return DriveFolderSetItem(
            driveId: id,
            driveUrl: 'https://drive.google.com/drive/folders/$id',
          );
        },
      );
      final manifest = DriveFolderSetManifest(items: items);
      final ctx = FolderSetReconcileContext(
        rootSetPath: '/tmp/root_set',
        searchRoots: const ['/tmp'],
      );

      final filtered = FolderSetHierarchy.filterManifestItems(manifest, ctx);
      expect(filtered.desiredItems.length, kFolderSetMaxTotalItems);
      expect(filtered.skippedCycleOrDuplicateItems.length, 5);
      expect(
        filtered.skippedCycleOrDuplicateItems.first,
        'folder_item_id_0100',
      );
    });

    test('shouldAllowDeletion blocks deletion on invalid entries or empty-JSON wipe', () {
      const emptyClean = DriveFolderSetManifest(items: []);
      expect(
        FolderSetHierarchy.shouldAllowDeletion(
          manifest: emptyClean,
          hasExistingEntries: true,
        ),
        isFalse,
      );
      expect(
        FolderSetHierarchy.shouldAllowDeletion(
          manifest: emptyClean,
          hasExistingEntries: false,
        ),
        isTrue,
      );

      const nonEmptyWithInvalid = DriveFolderSetManifest(
        items: [
          DriveFolderSetItem(
            driveId: 'valid_folder_id_12345',
            driveUrl: 'https://drive.google.com/drive/folders/valid_folder_id_12345',
          ),
        ],
        invalidEntryCount: 1,
      );
      expect(
        FolderSetHierarchy.shouldAllowDeletion(
          manifest: nonEmptyWithInvalid,
          hasExistingEntries: true,
        ),
        isFalse,
      );
    });
  });

  group('FolderSetHierarchy.buildInitialState & accidental-wipe protection', () {
    late Directory tempDir;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      KMetaService.instance.clearCache();
      DriveDirStore.instance.resetForTest();
      LocalSyncSeedIndex.instance.resetForTest();
      tempDir = Directory.systemTemp.createTempSync('folder_set_hierarchy_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('restores ancestor depth, readOnly, and sibling driveIds when invoked on a child set', () async {
      final rootSetPath = p.join(tempDir.path, '共有', 'ルートセット');
      final midSetPath = p.join(rootSetPath, '中間ROセット');
      final targetChildPath = p.join(midSetPath, '対象子セット');
      final siblingSetPath = p.join(rootSetPath, '兄弟セット');
      await fs.createDirectory(targetChildPath);
      await fs.createDirectory(siblingSetPath);

      await KMetaService.instance.setDriveSync(
        rootSetPath,
        driveId: 'root_manifest_id_001',
        isFolderSet: true,
        isReadOnly: false,
        setMembers: const [
          KMetaFolderSetMember(
            driveId: 'root_member_folder_01',
            name: 'ルート直下フォルダ',
            driveUrl: 'https://drive.google.com/drive/folders/root_member_folder_01',
          ),
        ],
      );
      await KMetaService.instance.setDriveSync(
        midSetPath,
        driveId: 'mid_manifest_id_002',
        isFolderSet: true,
        isReadOnly: true,
      );
      await KMetaService.instance.setDriveSync(
        targetChildPath,
        driveId: 'target_child_id_003',
        isFolderSet: true,
        isReadOnly: false,
        setMembers: const [
          KMetaFolderSetMember(
            driveId: 'target_own_folder_99',
            name: '自身の既存フォルダ',
            driveUrl: 'https://drive.google.com/drive/folders/target_own_folder_99',
          ),
        ],
      );
      await KMetaService.instance.setDriveSync(
        siblingSetPath,
        driveId: 'sibling_set_id_004',
        isFolderSet: true,
        setMembers: const [
          KMetaFolderSetMember(
            driveId: 'sibling_folder_id_05',
            name: '兄弟のフォルダ',
            driveUrl: 'https://drive.google.com/drive/folders/sibling_folder_id_05',
          ),
        ],
      );

      final init = await FolderSetHierarchy.buildInitialState(
        localSetPath: targetChildPath,
        setNode: null,
        forceReadOnly: false,
      );

      expect(init.depth, 2);
      expect(init.forceReadOnly, isTrue);
      expect(
        DriveTransferRegistry.sameNormalizedPath(init.rootSetPath, rootSetPath),
        isTrue,
      );
      // 祖先セットおよび兄弟セット配下の driveId は visitedIds に入り、対象子セット自身のメンバーは除外される
      expect(
        init.visitedIds,
        containsAll(<String>[
          'root_manifest_id_001',
          'mid_manifest_id_002',
          'root_member_folder_01',
          'sibling_set_id_004',
          'sibling_folder_id_05',
        ]),
      );
      expect(init.visitedIds, isNot(contains('target_own_folder_99')));
    });

    test('reconcileSet preserves existing folders when manifest unexpectedly becomes empty array', () async {
      final driveStub = _StubGoogleDriveService()
        ..putJson('set_json_id_001', '現場.json', {
          'name': '現場',
          'folders': ['folder_keep_001'],
        })
        ..putFolder('folder_keep_001', '消えてはいけない図面');
      final service = DriveFolderSetService(
        driveService: driveStub,
        syncEngine: _StubSyncEngine(),
      );

      final localSetPath = p.join(tempDir.path, '共有', '現場');
      final first = await service.reconcileSet(
        manifestFileId: 'set_json_id_001',
        localSetPath: localSetPath,
      );
      expect(first.success, isTrue);
      expect(first.addedCount, 1);

      final physicalPath =
          await DriveDirStore.instance.findExistingPath('folder_keep_001');
      expect(physicalPath, isNotNull);

      // JSON が誤って空配列になったケース
      driveStub.putJson(
        'set_json_id_001',
        '現場.json',
        {'name': '現場', 'folders': <String>[]},
        md5: 'm2',
      );
      final second = await service.reconcileSet(
        manifestFileId: 'set_json_id_001',
        localSetPath: localSetPath,
      );
      expect(second.success, isTrue);
      expect(second.removedCount, 0);
      expect(await fs.exists(physicalPath!), isTrue);
    });
  });
}
