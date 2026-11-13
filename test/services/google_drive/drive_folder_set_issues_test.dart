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
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/fs/k_file_system.dart';
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/drive_folder_set_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/google_drive/auto_sync_service.dart';
import 'package:root_maps/services/google_drive/drive_dir_store.dart';
import 'package:root_maps/services/google_drive/drive_folder_local_lifecycle.dart';
import 'package:root_maps/services/google_drive/drive_folder_set_service.dart';
import 'package:root_maps/services/google_drive/drive_transfer_registry.dart';
import 'package:root_maps/services/google_drive/drive_tree_nodes.dart';
import 'package:root_maps/services/google_drive/folder_lookup.dart';
import 'package:root_maps/services/google_drive/google_drive_service.dart';
import 'package:root_maps/services/google_drive/sync_engine.dart';
import 'package:root_maps/services/google_drive/sync_progress.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
  })  : canEdit = true,
        mimeType = 'application/vnd.google-apps.folder';

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
  int downloadCount = 0;

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
    downloadCount++;
    final entry = entries[fileId];
    if (entry == null || entry.jsonContent == null) return null;
    return Uint8List.fromList(utf8.encode(entry.jsonContent!));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSyncEngine implements SyncEngine {
  final Future<void> Function(String driveId, String localPath)? onClone;

  _FakeSyncEngine({this.onClone});

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
    await onClone?.call(driveId, localPath);
    await KMetaService.instance.setDriveSync(
      localPath,
      driveId: driveId,
      driveFolderName: folderName,
      driveUrl: driveUrl,
      isReadOnly: isReadOnly,
      isFolderSet: false,
      lastSynced: DateTime(2026, 11, 12, 12),
    );
    await DriveTransferRegistry.instance.clearClonePending(localPath);
    return true;
  }

  @override
  Future<FolderSyncStatusDetail> checkSyncStatusDetail(
    String localPath, {
    bool useCache = false,
  }) async {
    return const FolderSyncStatusDetail(status: FolderSyncStatus.synced);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _createSamplePointGpkg(
  String gpkgPath, {
  String layerName = 'points',
  int pointCount = 2,
}) async {
  final gpkg = GeoPackageFile(
    [p.basename(gpkgPath)],
    absolutePath: gpkgPath,
  );
  await gpkg.addLayer(layerName, GeometryType.point);
  for (var i = 0; i < pointCount; i++) {
    await gpkg.addPoint(
      layerName,
      LatLng(33.9 + i * 0.001, 135.9 + i * 0.001),
      name: 'pt_$i',
    );
  }
  await gpkg.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String projRoot;
  late String sharedRoot;
  late _FakeGoogleDriveService fakeDrive;
  late _FakeSyncEngine fakeSync;
  late DriveFolderSetService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'auto_sync_enabled': false});
    KMetaService.instance.clearCache();
    DriveDirStore.instance.resetForTest();
    LocalSyncSeedIndex.instance.resetForTest();
    AutoSyncService.instance.detach();

    tempDir = await Directory.systemTemp.createTemp('folder_set_issues_test_');
    projRoot = p.join(tempDir.path, 'proj');
    sharedRoot = p.join(projRoot, '共有');
    await fs.createDirectory(sharedRoot);
    ProjectPathResolver.instance.setRootPathGetter(() => projRoot);

    fakeDrive = _FakeGoogleDriveService();
    fakeSync = _FakeSyncEngine();
    service = DriveFolderSetService(
      driveService: fakeDrive,
      syncEngine: fakeSync,
    );
  });

  tearDown(() async {
    AutoSyncService.instance.detach();
    KMetaService.instance.clearCache();
    DriveDirStore.instance.resetForTest();
    LocalSyncSeedIndex.instance.resetForTest();
    ProjectPathResolver.instance.setRootPathGetter(() => null);
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on Object catch (_) {}
    }
  });

  group('Issue #2: restore locally deleted child set even when parent MD5 is unchanged', () {
    test('forceFullReconcile restores deleted child set while background fast-path stays lightweight', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'parent_set_id',
            name: 'parent.json',
            md5Checksum: 'parent_md5_same',
            jsonContent: jsonEncode({
              'name': '親セット',
              'presets': ['child_a_id', 'child_b_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'child_a_id',
            name: 'child_a.json',
            md5Checksum: 'child_a_md5',
            jsonContent: jsonEncode({
              'name': '子セットA',
              'folders': ['folder_a_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'child_b_id',
            name: 'child_b.json',
            md5Checksum: 'child_b_md5',
            jsonContent: jsonEncode({
              'name': '子セットB',
              'folders': ['folder_b_id'],
            }),
          ),
        )
        ..register(_FakeDriveEntry.folder(id: 'folder_a_id', name: 'レイヤA'))
        ..register(_FakeDriveEntry.folder(id: 'folder_b_id', name: 'レイヤB'));

      final parentPath = p.join(sharedRoot, '親セット');
      final r1 = await service.reconcileSet(
        manifestFileId: 'parent_set_id',
        localSetPath: parentPath,
      );
      expect(r1.success, isTrue);

      final childAPath = p.join(parentPath, '子セットA');
      final childBPath = p.join(parentPath, '子セットB');
      expect(await fs.isDirectory(childAPath), isTrue);
      expect(await fs.isDirectory(childBPath), isTrue);

      // ツリー上で子セットAを削除（子セットBが残っているため existingByDriveId は空にならない）
      final sharedNode = FolderNode(
        '共有',
        pathResolver: DirectPathResolver(sharedRoot),
      );
      final parentNode = (await FolderNode.tryCreateDriveFolderNode(
        parentPath,
        '親セット',
        sharedNode,
      ))! as DriveFolderSetNode;
      sharedNode.addChild(parentNode);
      await DriveFolderSetService.reloadFolderSetNode(parentNode);

      final childANode = parentNode.children
          .whereType<DriveFolderSetNode>()
          .firstWhere((c) => c.manifestFileId == 'child_a_id');
      await deleteDriveFolderLocally(childANode);
      expect(await fs.exists(childAPath), isFalse);

      // バックグラウンド自動同期（forceFullReconcile: false）では親MD5未変更の高速経路を維持
      final downloadsBeforeBg = fakeDrive.downloadCount;
      final bgRes = await service.reconcileSet(
        manifestFileId: 'parent_set_id',
        localSetPath: parentPath,
        setNode: parentNode,
      );
      expect(bgRes.success, isTrue);
      expect(fakeDrive.downloadCount, downloadsBeforeBg);
      expect(await fs.exists(childAPath), isFalse);

      // 手動更新・リンク再受信（forceFullReconcile: true）では親MD5が同じでも子セットAが復元される
      final manualRes = await service.reconcileSet(
        manifestFileId: 'parent_set_id',
        localSetPath: parentPath,
        setNode: parentNode,
        forceFullReconcile: true,
      );
      expect(manualRes.success, isTrue);
      expect(manualRes.addedCount, greaterThanOrEqualTo(1));
      expect(await fs.isDirectory(childAPath), isTrue);
    });

    test('automatically exits fast-path even without forceFullReconcile when a recorded setMember is missing on disk', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'flat_set_id',
            name: 'flat.json',
            md5Checksum: 'flat_md5_same',
            jsonContent: jsonEncode({
              'name': 'フラットセット',
              'folders': ['member_1_id', 'member_2_id'],
            }),
          ),
        )
        ..register(_FakeDriveEntry.folder(id: 'member_1_id', name: 'メンバー1'))
        ..register(_FakeDriveEntry.folder(id: 'member_2_id', name: 'メンバー2'));

      final setPath = p.join(sharedRoot, 'フラットセット');
      await service.reconcileSet(
        manifestFileId: 'flat_set_id',
        localSetPath: setPath,
      );

      final member1Path =
          (await DriveDirStore.instance.findExistingPath('member_1_id'))!;
      await fs.delete(member1Path, recursive: true);
      await DriveDirStore.instance.unregister('member_1_id');

      final res = await service.reconcileSet(
        manifestFileId: 'flat_set_id',
        localSetPath: setPath,
      );
      expect(res.success, isTrue);
      expect(res.addedCount, 1);
      final restoredPath =
          await DriveDirStore.instance.findExistingPath('member_1_id');
      expect(restoredPath, isNotNull);
      expect(await fs.isDirectory(restoredPath!), isTrue);
    });
  });

  group('Issue #3: deleting standalone folder referenced by a set relocates physical data cleanly', () {
    test('relocates standalone folder to .kokage/drive_store and keeps set GeoPackage layers readable', () async {
      // 1. 先に `共有/単体フォルダX` を作成し、実データの .gpkg を置く
      final standalonePath = p.join(sharedRoot, '単体フォルダX');
      await fs.createDirectory(standalonePath);
      await _createSamplePointGpkg(
        p.join(standalonePath, 'survey.gpkg'),
        pointCount: 2,
      );
      await KMetaService.instance.setDriveSync(
        standalonePath,
        driveId: 'standalone_x_id',
        driveFolderName: '単体フォルダX',
        driveUrl: 'https://drive.google.com/drive/folders/standalone_x_id',
        isReadOnly: false,
        isFolderSet: false,
      );

      // 2. `共有/現場セット` が `standalone_x_id` を参照マウントする
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'site_set_id',
            name: 'site_set.json',
            md5Checksum: 'site_v1',
            jsonContent: jsonEncode({
              'name': '現場セット',
              'folders': ['standalone_x_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'standalone_x_id', name: '単体フォルダX'),
        );

      final setPath = p.join(sharedRoot, '現場セット');
      final r = await service.reconcileSet(
        manifestFileId: 'site_set_id',
        localSetPath: setPath,
      );
      expect(r.success, isTrue);

      // 3. ツリーを構築し、単体側とセット側の両方で .gpkg レイヤの地物を読み込んだ状態にする
      final rootNode = FolderNode(
        'Home',
        pathResolver: DirectPathResolver(projRoot),
      );
      final sharedNode = FolderNode(
        '共有',
        parent: rootNode,
        pathResolver: DirectPathResolver(sharedRoot),
      );
      rootNode.addChild(sharedNode);
      await sharedNode.updateChildren();

      final standaloneNode = sharedNode.children
          .whereType<DriveFolderNode>()
          .firstWhere((n) => n.driveId == 'standalone_x_id');
      final setNode = sharedNode.children
          .whereType<DriveFolderSetNode>()
          .firstWhere((n) => n.manifestFileId == 'site_set_id');

      await DriveFolderSetService.reloadFolderSetNode(setNode);
      await standaloneNode.updateChildren();
      for (final gpkg in standaloneNode.children.whereType<GeoPackageNode>()) {
        await gpkg.updateChildren();
        for (final layer in gpkg.children.whereType<LayerNode>()) {
          await layer.updateChildren();
          expect(layer.children.length, 2);
        }
      }

      final mountedBefore = setNode.children
          .whereType<DriveFolderNode>()
          .firstWhere((n) => n.driveId == 'standalone_x_id');
      for (final gpkg in mountedBefore.children.whereType<GeoPackageNode>()) {
        await gpkg.updateChildren();
        for (final layer in gpkg.children.whereType<LayerNode>()) {
          await layer.updateChildren();
          expect(layer.children.length, 2);
        }
      }

      // 4. 単体側の DriveFolderNode を削除する
      final outcome = await deleteDriveFolderLocally(standaloneNode);
      expect(outcome, DriveFolderDeleteOutcome.relocatedToStore);

      // 単体ディレクトリと単体ノードは消えていること
      expect(await fs.exists(standalonePath), isFalse);
      expect(
        sharedNode.children.whereType<DriveFolderNode>().where(
              (n) => n.driveId == 'standalone_x_id',
            ),
        isEmpty,
      );

      // 実体は `.kokage/drive_store` に退避され、セット側のメタデータとライブノードが新パスを指していること
      final relocatedPath =
          await DriveDirStore.instance.findExistingPath('standalone_x_id');
      expect(relocatedPath, isNotNull);
      expect(
        DriveDirStore.instance.isManagedStorePath(relocatedPath!),
        isTrue,
      );
      expect(
        await fs.exists(p.join(relocatedPath, 'survey.gpkg')),
        isTrue,
      );

      final updatedSetMeta = await KMetaService.instance.getRawMeta(setPath);
      expect(
        DriveTransferRegistry.normalizeKey(
          updatedSetMeta!.sync.setMembers.single.targetPath!,
        ),
        DriveTransferRegistry.normalizeKey(relocatedPath),
      );

      final mountedAfter = setNode.children
          .whereType<DriveFolderNode>()
          .firstWhere((n) => n.driveId == 'standalone_x_id');
      expect(
        DriveTransferRegistry.normalizeKey(mountedAfter.getAbsoluteFilePath()!),
        DriveTransferRegistry.normalizeKey(relocatedPath),
      );

      final mountedGpkg =
          mountedAfter.children.whereType<GeoPackageNode>().single;
      final mountedLayer = mountedGpkg.children.whereType<LayerNode>().single;
      await mountedLayer.updateChildren();
      expect(mountedLayer.children.length, 2);

      // ツリーを切り離して DB ハンドルを閉じておく
      await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(rootNode);
    });
  });

  group('Issue #4: AutoSyncService triggers feature loading for newly added child sets', () {
    test('handleTransferCompleted reloads non-empty existing folder set and invokes onFolderSetRefreshNeeded', () async {
      // 初期状態: 親セットにフォルダ1件が読み込み済み（existingSet.children.isNotEmpty）
      final setPath = p.join(sharedRoot, '自動同期セット');
      await fs.createDirectory(setPath);
      final folder1Store = await DriveDirStore.instance.allocateStorePath(
        driveId: 'f1_id',
        folderName: '初期フォルダ',
        contextPath: setPath,
      );
      await fs.createDirectory(folder1Store);
      await _createSamplePointGpkg(
        p.join(folder1Store, 'f1.gpkg'),
        pointCount: 1,
      );
      await KMetaService.instance.setDriveSync(
        folder1Store,
        driveId: 'f1_id',
        driveFolderName: '初期フォルダ',
        driveUrl: 'https://drive.google.com/drive/folders/f1_id',
        isReadOnly: true,
      );
      await KMetaService.instance.setDriveSync(
        setPath,
        driveId: 'autosync_set_json',
        driveFolderName: '自動同期セット',
        driveUrl: 'https://drive.google.com/file/d/autosync_set_json/view',
        isReadOnly: true,
        isFolderSet: true,
        setMembers: [
          KMetaFolderSetMember(
            driveId: 'f1_id',
            name: '初期フォルダ',
            driveUrl: 'https://drive.google.com/drive/folders/f1_id',
            isReadOnly: true,
            targetPath: folder1Store,
          ),
        ],
      );

      final rootNode = FolderNode(
        'Home',
        pathResolver: DirectPathResolver(projRoot),
      );
      final sharedNode = FolderNode(
        '共有',
        parent: rootNode,
        pathResolver: DirectPathResolver(sharedRoot),
      );
      rootNode.addChild(sharedNode);
      await sharedNode.updateChildren();
      final setNode = sharedNode.children.whereType<DriveFolderSetNode>().single;
      await DriveFolderSetService.reloadFolderSetNode(setNode);
      expect(setNode.children, isNotEmpty);

      var refreshCallbackCount = 0;
      await AutoSyncService.instance.start(
        root: rootNode,
        onFolderSetRefreshNeeded: (refreshedSet) async {
          refreshCallbackCount++;
          // MapInitializationMixin の updateFeatures 相当: 可視レイヤの未読フィーチャを読み込む
          for (final layer
              in refreshedSet.getVisibleLayerNodes().whereType<LayerNode>()) {
            if (!layer.featuresLoaded) {
              await layer.updateChildren();
            }
          }
        },
      );

      // バックグラウンド転送で新しい子セット（＋実体 .gpkg）が追加された状態を再現
      final childSetPath = p.join(setPath, '追加子セット');
      await fs.createDirectory(childSetPath);
      final folder2Store = await DriveDirStore.instance.allocateStorePath(
        driveId: 'f2_id',
        folderName: '追加レイヤフォルダ',
        contextPath: childSetPath,
      );
      await fs.createDirectory(folder2Store);
      await _createSamplePointGpkg(
        p.join(folder2Store, 'f2.gpkg'),
        pointCount: 3,
      );
      await KMetaService.instance.setDriveSync(
        folder2Store,
        driveId: 'f2_id',
        driveFolderName: '追加レイヤフォルダ',
        driveUrl: 'https://drive.google.com/drive/folders/f2_id',
        isReadOnly: true,
      );
      await KMetaService.instance.setDriveSync(
        childSetPath,
        driveId: 'child_added_json',
        driveFolderName: '追加子セット',
        driveUrl: 'https://drive.google.com/file/d/child_added_json/view',
        isReadOnly: true,
        isFolderSet: true,
        setMembers: [
          KMetaFolderSetMember(
            driveId: 'f2_id',
            name: '追加レイヤフォルダ',
            driveUrl: 'https://drive.google.com/drive/folders/f2_id',
            isReadOnly: true,
            targetPath: folder2Store,
          ),
        ],
      );

      // 転送完了イベントを発火し、リスナー完了を待つ
      DriveTransferRegistry.instance.beginTransfer(
        setPath,
        folderName: '自動同期セット',
      );
      DriveTransferRegistry.instance.endTransfer(
        setPath,
        driveId: 'autosync_set_json',
        folderName: '自動同期セット',
        success: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(refreshCallbackCount, 1);
      final addedChildSet = setNode.children
          .whereType<DriveFolderSetNode>()
          .firstWhere((c) => c.manifestFileId == 'child_added_json');
      final addedDriveFolder =
          addedChildSet.children.whereType<DriveFolderNode>().single;
      final addedGpkg =
          addedDriveFolder.children.whereType<GeoPackageNode>().single;
      final addedLayer = addedGpkg.children.whereType<LayerNode>().single;
      expect(addedLayer.featuresLoaded, isTrue);
      expect(addedLayer.children.length, 3);

      await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(rootNode);
    });
  });

  group('Issue #5: no orphaned .kokage/drive_store directories on child set deletion & orphan cleanup API', () {
    test('cleans up store directory even when deleting an unexpanded child set, while preserving entries referenced by sibling root sets', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'root_parent_json',
            name: 'root_parent.json',
            jsonContent: jsonEncode({
              'name': '親セット',
              'presets': ['sub_only_json', 'sub_shared_json'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'sub_only_json',
            name: 'sub_only.json',
            jsonContent: jsonEncode({
              'name': '単独子セット',
              'folders': ['only_folder_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'sub_shared_json',
            name: 'sub_shared.json',
            jsonContent: jsonEncode({
              'name': '共有子セット',
              'folders': ['cross_shared_folder_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'sibling_root_json',
            name: 'sibling_root.json',
            jsonContent: jsonEncode({
              'name': '別ルートセット',
              'folders': ['cross_shared_folder_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'only_folder_id', name: '単独データ'),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'cross_shared_folder_id', name: '共通データ'),
        );

      final parentSetPath = p.join(sharedRoot, '親セット');
      final siblingRootSetPath = p.join(sharedRoot, '別ルートセット');
      await service.reconcileSet(
        manifestFileId: 'root_parent_json',
        localSetPath: parentSetPath,
      );
      await service.reconcileSet(
        manifestFileId: 'sibling_root_json',
        localSetPath: siblingRootSetPath,
      );

      final onlyStorePath =
          (await DriveDirStore.instance.findExistingPath('only_folder_id'))!;
      final sharedStorePath = (await DriveDirStore.instance
          .findExistingPath('cross_shared_folder_id'))!;
      expect(await fs.isDirectory(onlyStorePath), isTrue);
      expect(await fs.isDirectory(sharedStorePath), isTrue);

      // 1. UI上で未展開（children が空）の子セットノードを削除しても、ディスクの KMeta を辿ってストア実体が消えること
      final unexpandedOnlyChildNode = DriveFolderSetNode(
        '単独子セット',
        manifestFileId: 'sub_only_json',
        manifestUrl: 'https://drive.google.com/file/d/sub_only_json/view',
        children: [], // 未展開状態を再現
      )..pathResolver = DirectPathResolver(p.join(parentSetPath, '単独子セット'));
      await deleteDriveFolderLocally(unexpandedOnlyChildNode);
      expect(await fs.exists(onlyStorePath), isFalse);
      expect(
        await DriveDirStore.instance.findExistingPath('only_folder_id'),
        isNull,
      );

      // 2. `共有/親セット/共有子セット` を削除した際、`共有/別ルートセット` が参照中なので実体が誤削除されないこと
      final unexpandedSharedChildNode = DriveFolderSetNode(
        '共有子セット',
        manifestFileId: 'sub_shared_json',
        manifestUrl: 'https://drive.google.com/file/d/sub_shared_json/view',
        children: [],
      )..pathResolver = DirectPathResolver(p.join(parentSetPath, '共有子セット'));
      await deleteDriveFolderLocally(unexpandedSharedChildNode);
      expect(await fs.isDirectory(sharedStorePath), isTrue);

      // 3. `共有/別ルートセット` も削除すると、どこからも参照されなくなったストア実体が削除されること
      final siblingRootNode = DriveFolderSetNode(
        '別ルートセット',
        manifestFileId: 'sibling_root_json',
        manifestUrl: 'https://drive.google.com/file/d/sibling_root_json/view',
        children: [],
      )..pathResolver = DirectPathResolver(siblingRootSetPath);
      await deleteDriveFolderLocally(siblingRootNode);
      expect(await fs.exists(sharedStorePath), isFalse);
    });

    test('scanOrphanedStoreEntries and pruneOrphanedStoreEntries remove only unreferenced store directories', () async {
      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'active_set_json',
            name: 'active.json',
            jsonContent: jsonEncode({
              'name': '稼働中セット',
              'folders': ['active_folder_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(id: 'active_folder_id', name: '稼働中データ'),
        );

      final activeSetPath = p.join(sharedRoot, '稼働中セット');
      await service.reconcileSet(
        manifestFileId: 'active_set_json',
        localSetPath: activeSetPath,
      );
      final activeStorePath =
          (await DriveDirStore.instance.findExistingPath('active_folder_id'))!;

      // 孤児エントリを手動で `.kokage/drive_store` に作成
      final orphanStorePath = await DriveDirStore.instance.allocateStorePath(
        driveId: 'orphan_folder_999',
        folderName: '孤児データ',
        contextPath: activeSetPath,
      );
      await fs.createDirectory(orphanStorePath);
      final orphanPayload = Uint8List.fromList(List<int>.filled(2048, 42));
      await fs.writeAsBytes(p.join(orphanStorePath, 'orphan.bin'), orphanPayload);

      final scanned = await DriveDirStore.instance.scanOrphanedStoreEntries();
      expect(scanned.length, 1);
      expect(scanned.single.driveId, 'orphan_folder_999');
      expect(scanned.single.sizeBytes, 2048);

      final pruned = await DriveDirStore.instance.pruneOrphanedStoreEntries();
      expect(pruned.deletedCount, 1);
      expect(pruned.freedBytes, 2048);
      expect(await fs.exists(orphanStorePath), isFalse);
      expect(await fs.isDirectory(activeStorePath), isTrue);
    });

    test('deleting a loaded DriveFolderSetNode preserves shared .gpkg files when another set still references the same store folder', () async {
      fakeSync = _FakeSyncEngine(
        onClone: (driveId, localPath) async {
          await _createSamplePointGpkg(
            p.join(localPath, 'shared_layer.gpkg'),
            pointCount: 4,
          );
        },
      );
      service = DriveFolderSetService(
        driveService: fakeDrive,
        syncEngine: fakeSync,
      );

      fakeDrive
        ..register(
          _FakeDriveEntry.json(
            id: 'set_1_json',
            name: 'set_1.json',
            jsonContent: jsonEncode({
              'name': 'セット1',
              'folders': ['shared_gpkg_folder_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.json(
            id: 'set_2_json',
            name: 'set_2.json',
            jsonContent: jsonEncode({
              'name': 'セット2',
              'folders': ['shared_gpkg_folder_id'],
            }),
          ),
        )
        ..register(
          _FakeDriveEntry.folder(
            id: 'shared_gpkg_folder_id',
            name: '共有GISフォルダ',
          ),
        );

      final set1Path = p.join(sharedRoot, 'セット1');
      final set2Path = p.join(sharedRoot, 'セット2');
      await service.reconcileSet(
        manifestFileId: 'set_1_json',
        localSetPath: set1Path,
      );
      await service.reconcileSet(
        manifestFileId: 'set_2_json',
        localSetPath: set2Path,
      );

      final rootNode = FolderNode(
        'Home',
        pathResolver: DirectPathResolver(projRoot),
      );
      final sharedNode = FolderNode(
        '共有',
        parent: rootNode,
        pathResolver: DirectPathResolver(sharedRoot),
      );
      rootNode.addChild(sharedNode);
      await sharedNode.updateChildren();

      final set1Node = sharedNode.children
          .whereType<DriveFolderSetNode>()
          .firstWhere((s) => s.manifestFileId == 'set_1_json');
      final set2Node = sharedNode.children
          .whereType<DriveFolderSetNode>()
          .firstWhere((s) => s.manifestFileId == 'set_2_json');
      await DriveFolderSetService.reloadFolderSetNode(set1Node);
      await DriveFolderSetService.reloadFolderSetNode(set2Node);

      // セット1側の GeoPackageNode + LayerNode をロードした状態でセット1を削除する
      final set1Layer = set1Node.children
          .whereType<DriveFolderNode>()
          .single
          .children
          .whereType<GeoPackageNode>()
          .single
          .children
          .whereType<LayerNode>()
          .single;
      await set1Layer.updateChildren();
      expect(set1Layer.children.length, 4);

      await deleteDriveFolderLocally(set1Node);

      // セット2が参照中のため shared_layer.gpkg が消されず、セット2側でそのまま全件読めること
      final storePath = (await DriveDirStore.instance
          .findExistingPath('shared_gpkg_folder_id'))!;
      expect(await fs.exists(p.join(storePath, 'shared_layer.gpkg')), isTrue);

      final set2Layer = set2Node.children
          .whereType<DriveFolderNode>()
          .single
          .children
          .whereType<GeoPackageNode>()
          .single
          .children
          .whereType<LayerNode>()
          .single;
      await set2Layer.updateChildren();
      expect(set2Layer.children.length, 4);

      await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(rootNode);
    });
  });
}
