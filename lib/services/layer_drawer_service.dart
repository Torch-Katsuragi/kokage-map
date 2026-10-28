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
/// Root Maps: LayerDrawer 用ビジネスロジック Service
/// フォルダ・GeoPackage の作成/リネーム/Driveクローンを UI 非依存で提供
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../core/fs/safe_path.dart';
import '../i18n/strings.g.dart';
import '../models/geopackage/geopackage_file.dart';
import '../models/nodes/drive_folder_node.dart';
import '../models/nodes/drive_folder_set_node.dart';
import '../models/nodes/external_layer_node.dart';
import '../models/nodes/folder_node.dart';
import '../models/nodes/geopackage_node.dart';
import '../models/nodes/global_folder_node.dart';
import '../models/nodes/image_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/sys_node.dart';
import '../services/google_drive/index.dart';
import '../services/kmeta_service.dart';
import '../services/qgis/qgs_read_back.dart';
import '../utils/app_logger.dart';

class LayerDrawerService {
  const LayerDrawerService._();

  // ---------- フォルダ ----------

  /// ローカルフォルダを作成して親ノードに追加。同名が存在すると [StateError]
  ///
  /// ⚠ `dart:io` を直に使わないこと。web では `Directory` に触れた時点で
  /// `Unsupported operation: _Namespace` が飛ぶ（コンパイルは通る）。
  static Future<FolderNode> createLocalFolder(
    FolderNode parent,
    String name,
  ) async {
    final dir = parent.getAbsoluteFilePath();
    final path = p.join(dir ?? '', name);
    await _ensureAbsent(path, t.services.folderAlreadyExists);
    await fs.createDirectory(path);

    final child = switch (parent) {
      final GlobalFolderNode p => GlobalSubFolderNode(
        name,
        basePath: p.globalPath,
        visible: true,
        parent: parent,
      ),
      final GlobalSubFolderNode p => GlobalSubFolderNode(
        name,
        basePath: p.basePath,
        visible: true,
        parent: parent,
      ),
      _ => FolderNode(name, visible: true, parent: parent),
    };
    parent.addChild(child);
    return child;
  }

  /// Drive フォルダのクローン枠（ローカルフォルダ・`.sync/clone.pending`・`.qgs` 連携情報・`DriveFolderNode`）を
  /// 即座に作成して親ノードに追加する（Option A: 即時アタッチ＆バックグラウンド転送用）。
  static Future<({DriveFolderNode node, String localPath})?> prepareDriveCloneNode({
    required FolderNode parent,
    required String folderId,
    required String folderName,
    required String url,
    required bool isReadOnly,
  }) async {
    final parentDir = parent.getAbsoluteFilePath();
    if (parentDir == null) return null;

    final name = toLocalFolderName(folderName, fallback: folderId);
    final localPath = p.join(parentDir, name);
    await _ensureAbsent(localPath, t.services.folderAlreadyExists);

    await fs.createDirectory(localPath);
    await DriveTransferRegistry.instance.markClonePending(localPath);

    final saved = await KMetaService.instance.setDriveSync(
      localPath,
      driveId: folderId,
      driveFolderName: name,
      driveUrl: url,
      isReadOnly: isReadOnly,
    );
    if (!saved) {
      return null;
    }

    final node = DriveFolderNode(
      name,
      driveId: folderId,
      driveUrl: url,
      isReadOnly: isReadOnly,
      syncStatus: SyncStatus.syncing,
      visible: true,
      parent: parent,
    );
    parent.addChild(node);
    return (node: node, localPath: localPath);
  }

  /// Drive の共有フォルダセット（JSON）のローカル枠を作成して親ノードに追加する
  static Future<({DriveFolderSetNode node, String localPath})?> prepareDriveFolderSetNode({
    required FolderNode parent,
    required String jsonDriveId,
    required String setName,
    required String url,
  }) async {
    final parentDir = parent.getAbsoluteFilePath();
    if (parentDir == null) return null;

    final name = toLocalFolderName(setName, fallback: jsonDriveId);
    final localPath = p.join(parentDir, name);
    await _ensureAbsent(localPath, t.services.folderAlreadyExists);

    await fs.createDirectory(localPath);
    await DriveTransferRegistry.instance.markClonePending(localPath);

    final saved = await KMetaService.instance.setDriveSync(
      localPath,
      driveId: jsonDriveId,
      driveFolderName: name,
      driveUrl: url,
      isReadOnly: true,
      isFolderSet: true,
    );
    if (!saved) {
      return null;
    }

    final node = DriveFolderSetNode(
      name,
      manifestFileId: jsonDriveId,
      manifestUrl: url,
      syncStatus: SyncStatus.syncing,
      visible: true,
      parent: parent,
    );
    parent.addChild(node);
    return (node: node, localPath: localPath);
  }

  /// バックグラウンド等の Pull が完了した既存 [DriveFolderNode] の中身を再帰読込し、`.qgs` を読み戻す
  static Future<QgsReadBackResult?> finalizeClonedNode(DriveFolderNode node) async {
    await _reloadRecursive(node);
    QgsReadBackResult? readBack;
    try {
      readBack = await const QgsReadBack().run(node);
      if (readBack != null) await _reloadRecursive(node);
    } on Object catch (e) {
      AppLogger.debug('[LayerDrawer] クローンした ${node.name} の読み戻しに失敗: $e');
    }
    return readBack;
  }

  /// Drive フォルダをクローンして追加。失敗時は null。
  ///
  /// 届いた `.qgs` が QGIS で保存されたものなら読み戻し、その結果を [readBack] に返す（通知は呼び手）
  static Future<({DriveFolderNode node, QgsReadBackResult? readBack})?> cloneDriveFolder({
    required FolderNode parent,
    required String folderId,
    required String folderName,
    required String url,
    required bool isReadOnly,
  }) async {
    final parentDir = parent.getAbsoluteFilePath();
    if (parentDir == null) return null;

    // Drive の名前は `/` や `..` を含められる。手元のフォルダ名 1 段にしてから使う
    final name = toLocalFolderName(folderName, fallback: folderId);
    final localPath = p.join(parentDir, name);
    await _ensureAbsent(localPath, t.services.folderAlreadyExists);

    final success = await SyncEngine().cloneFromDrive(
      driveId: folderId,
      localPath: localPath,
      folderName: name,
      driveUrl: url,
      isReadOnly: isReadOnly,
    );
    if (!success) return null;

    return attachClonedFolder(
      parent: parent,
      name: name,
      folderId: folderId,
      url: url,
      isReadOnly: isReadOnly,
    );
  }

  /// クローンし終えた dir（[parent] の下の [name]）をツリーに足し、`.qgs` を読み戻す。
  ///
  /// 読み戻しは地図を開いたときにしか走らなかったので、QGIS で作ったフォルダをクローンしても
  /// View・凡例・背景地図が入らず、地図を開き直すまで素のレイヤのままだった（2026-10-12）。
  /// その間は `.qgs` を書かない（QgsProjectBuilder が読み戻すまで断る）ので、ここで取り込んで印を付ける
  @visibleForTesting
  static Future<({DriveFolderNode node, QgsReadBackResult? readBack})> attachClonedFolder({
    required FolderNode parent,
    required String name,
    required String folderId,
    required String url,
    required bool isReadOnly,
  }) async {
    final node = DriveFolderNode(
      name,
      driveId: folderId,
      driveUrl: url,
      isReadOnly: isReadOnly,
      visible: true,
      parent: parent,
    );
    parent.addChild(node);
    await _reloadRecursive(node);

    QgsReadBackResult? readBack;
    try {
      readBack = await const QgsReadBack().run(node);
      // 取り込んだ View・可視性でノードを作り直す
      if (readBack != null) await _reloadRecursive(node);
    } on Object catch (e) {
      AppLogger.debug('[LayerDrawer] クローンした ${node.name} の読み戻しに失敗: $e');
    }
    return (node: node, readBack: readBack);
  }

  // ---------- GeoPackage ----------

  /// 空の GeoPackage を作成して親ノードに追加。作成失敗時は null
  static Future<GeoPackageNode?> createGeoPackage(
    FolderNode parent,
    String name,
  ) async {
    final dir = parent.getAbsoluteFilePath();
    final fileName = name.endsWith('.gpkg') ? name : '$name.gpkg';
    final path = p.join(dir ?? '', fileName);
    await _ensureAbsent(path, t.services.gpkgAlreadyExists);

    final gpkgFile = GeoPackageFile([fileName], absolutePath: path);
    final node = GeoPackageNode(gpkgFile, visible: true, parent: parent);
    parent.addChild(node);

    if (!await gpkgFile.createEmptyDatabase()) {
      parent.removeChild(node);
      return null;
    }
    return node;
  }

  /// GeoPackage をリネーム。新しいファイル名を返す
  static Future<String> renameGeoPackage(
    GeoPackageNode node,
    String newName, {
    required String projectRootDir,
  }) async {
    final oldPath = node.getAbsoluteFilePath();
    final oldName = node.name;
    // 値の関係の参照先は gpkg（読み取り専用レイヤなら元のファイル）の絶対パス。読み取り専用レイヤは中のレイヤ名も変わる
    final oldSource = gpkgSourcePath(node);
    final oldLayers = [for (final l in node.children.whereType<LayerNode>()) l.layerName];
    final newFileName = await node.rename(
      newName,
      projectRootDir: projectRootDir,
    );
    if (oldPath != null) {
      await notifySyncedPathChange(
        node,
        oldPath,
        p.join(p.dirname(oldPath), newFileName),
      );
    }
    // フォルダ設定の鍵（可視性・スタイル・View・属性フォーム・写真の列・結合）を新しい名前へ移す。
    // 移さないと改名で描き分けや結合が外れる
    final folder = node.parent;
    final folderPath = folder is FolderNode ? folder.getAbsoluteFilePath() : null;
    if (folder is FolderNode && folderPath != null && oldName != newFileName) {
      await KMetaService.instance.renameGeoPackageKeys(folderPath, oldName: oldName, newName: newFileName);
      folder.invalidateMetaCache();
    }
    if (oldSource != null && oldName != newFileName) {
      final oldStem = p.basenameWithoutExtension(oldSource);
      final newStem = p.basenameWithoutExtension(newFileName);
      await retargetValueRelations(
        node,
        oldGpkgPath: oldSource,
        newGpkgPath: p.join(p.dirname(oldSource), newFileName),
        layerNames: node is ExternalLayerNode
            ? {
                for (final l in oldLayers)
                  if (l == oldStem || l.startsWith('${oldStem}_')) l: '$newStem${l.substring(oldStem.length)}',
              }
            : const {},
      );
    }
    await node.parent?.updateChildren();
    return newFileName;
  }

  // ---------- レイヤ ----------

  /// gpkg の中のレイヤを改名し、フォルダ設定の鍵（`<gpkg>/<レイヤ>[/…]`）も新しい名前へ移す
  static Future<void> renameLayer(LayerNode node, String newName) async {
    final gpkgNode = node.geoPackageNode;
    final gpkgName = gpkgNode.name;
    final oldName = node.layerName;
    final folder = node.folderNode;
    await node.geoPackageFile.renameLayer(oldName, newName);
    final folderPath = folder?.getAbsoluteFilePath();
    if (folder != null && folderPath != null) {
      await KMetaService.instance.renameGeoPackageKeys(
        folderPath,
        oldName: gpkgName,
        newName: gpkgName,
        layerNames: {oldName: newName},
      );
      folder.invalidateMetaCache();
    }
    final source = gpkgSourcePath(gpkgNode);
    if (source != null && oldName != newName) {
      await retargetValueRelations(gpkgNode, oldGpkgPath: source, newGpkgPath: source, layerNames: {oldName: newName});
    }
    await gpkgNode.updateChildren();
  }

  /// 値の関係（ValueRelation）の参照先として見る gpkg の絶対パス（読み取り専用レイヤは元のファイル）
  static String? gpkgSourcePath(GeoPackageNode node) =>
      node is ExternalLayerNode ? node.sourcePath : node.geoPackageFile.getAbsolutePath();

  /// gpkg・レイヤを改名したとき、プロジェクトのどのフォルダの属性フォームでも、値の関係（ValueRelation）の参照先を新しい名前へ付け替える。
  /// 参照先は「フォームを持つフォルダからの gpkg の相対パス＋レイヤ名」なので、ほかのフォルダのフォームも見る
  static Future<void> retargetValueRelations(
    LayerTreeNode from, {
    required String oldGpkgPath,
    required String newGpkgPath,
    Map<String, String> layerNames = const {},
  }) async {
    var root = from;
    for (var up = root.parent; up != null; up = up.parent) {
      root = up;
    }
    final folders = <FolderNode>[];
    void walk(LayerTreeNode n) {
      if (n is FolderNode) folders.add(n);
      if (n is GeoPackageNode) return;
      n.children.forEach(walk);
    }

    walk(root);
    for (final folder in folders) {
      final folderPath = folder.getAbsoluteFilePath();
      if (folderPath == null) continue;
      try {
        final changed = await KMetaService.instance.retargetValueRelations(
          folderPath,
          oldGpkgPath: oldGpkgPath,
          newGpkgPath: newGpkgPath,
          layerNames: layerNames,
        );
        if (changed) folder.invalidateMetaCache();
      } on Object catch (e) {
        AppLogger.debug('[LayerDrawerService] 値の関係の参照先を付け替えられない: $folderPath - $e');
      }
    }
  }

  /// レイヤを消し（gpkg の表ごと）、フォルダ設定からそのレイヤの鍵を落とす
  static Future<void> deleteLayer(LayerNode node) async {
    final folder = node.folderNode;
    final folderPath = folder?.getAbsoluteFilePath();
    final layerKey = node.layerKey;
    await node.dispose();
    if (folder != null && folderPath != null) {
      await KMetaService.instance.forgetLayer(folderPath, layerKey);
      folder.invalidateMetaCache();
    }
  }

  // ---------- 写真 ----------

  /// 写真をリネーム
  static Future<void> renamePhoto(ImageNode node, String newName) async {
    final oldPath = node.filePath;
    await node.rename(newName);
    final ext = p.extension(oldPath);
    final newFileName = newName.endsWith(ext) ? newName : '$newName$ext';
    await notifySyncedPathChange(
      node,
      oldPath,
      p.join(p.dirname(oldPath), newFileName),
    );
    await node.parent?.updateChildren();
  }

  // ---------- ヘルパー ----------

  /// 既にあれば [message] の [StateError]
  static Future<void> _ensureAbsent(String path, String message) async {
    if (await fs.exists(path)) throw StateError(message);
  }

  /// DriveFolderNodeの祖先を探す
  static DriveFolderNode? findDriveRoot(LayerTreeNode? node) {
    LayerTreeNode? current = node;
    while (current != null) {
      if (current is DriveFolderNode) return current;
      // 端末側（sys・global）はプロジェクトの Drive 連携の外。global 配下の連携dirは上で拾える
      if (current is GlobalFolderNode || current is SysNode) return null;
      current = current.parent;
    }
    return null;
  }

  /// ローカルリネーム/移動時にsyncedFilesのパスを更新
  static Future<void> notifySyncedPathChange(
    LayerTreeNode node,
    String oldAbsPath,
    String newAbsPath,
  ) async {
    final driveRoot = findDriveRoot(node);
    if (driveRoot == null) return;
    final rootPath = driveRoot.getAbsoluteFilePath();
    if (rootPath == null) return;

    final oldRel = p.relative(oldAbsPath, from: rootPath).replaceAll('\\', '/');
    final newRel = p.relative(newAbsPath, from: rootPath).replaceAll('\\', '/');
    if (oldRel == newRel) return;

    await KMetaService.instance.renameSyncedFiles(rootPath, oldRel, newRel);
  }

  static Future<void> _reloadRecursive(LayerTreeNode node) async {
    await node.updateChildren();
    for (final child in node.children) {
      if (child is FolderNode) {
        await _reloadRecursive(child);
      } else if (child is GeoPackageNode) {
        await child.updateChildren();
      }
    }
  }
}
