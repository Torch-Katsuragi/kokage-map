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

import 'package:path/path.dart' as p;

import '../core/fs/k_file_system.dart';
import '../i18n/strings.g.dart';
import '../models/geopackage/geopackage_file.dart';
import '../models/nodes/drive_folder_node.dart';
import '../models/nodes/folder_node.dart';
import '../models/nodes/geopackage_node.dart';
import '../models/nodes/global_folder_node.dart';
import '../models/nodes/image_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/sys_node.dart';
import '../services/google_drive/index.dart';
import '../services/kmeta_service.dart';

class LayerDrawerService {
  const LayerDrawerService._();

  // ---------- フォルダ ----------

  /// ローカルフォルダを作成して親ノードに追加。同名が存在すると [StateError]
  ///
  /// ⚠ `dart:io` を直に使わないこと。web では `Directory` に触れた時点で
  /// `Unsupported operation: _Namespace` が飛ぶ（コンパイルは通る）。
  static Future<FolderNode> createLocalFolder(FolderNode parent, String name) async {
    final dir = parent.getAbsoluteFilePath();
    final path = p.join(dir ?? '', name);
    if (await fs.exists(path)) {
      throw StateError(t.services.folderAlreadyExists);
    }
    await fs.createDirectory(path);

    final child = switch (parent) {
      final GlobalFolderNode p => GlobalSubFolderNode(name, basePath: p.globalPath, visible: true, parent: parent),
      final GlobalSubFolderNode p => GlobalSubFolderNode(name, basePath: p.basePath, visible: true, parent: parent),
      _ => FolderNode(name, visible: true, parent: parent),
    };
    parent.addChild(child);
    return child;
  }

  /// Drive フォルダをクローンして追加。失敗時は null
  static Future<DriveFolderNode?> cloneDriveFolder({
    required FolderNode parent,
    required String folderId,
    required String folderName,
    required String url,
    required bool isReadOnly,
  }) async {
    final parentDir = parent.getAbsoluteFilePath();
    if (parentDir == null) return null;

    final localPath = p.join(parentDir, folderName);
    if (await fs.exists(localPath)) {
      throw StateError(t.services.folderAlreadyExists);
    }

    final success = await SyncEngine().cloneFromDrive(
      driveId: folderId,
      localPath: localPath,
      folderName: folderName,
      driveUrl: url,
      isReadOnly: isReadOnly,
    );
    if (!success) return null;

    final node = DriveFolderNode(
      folderName,
      driveId: folderId,
      driveUrl: url,
      isReadOnly: isReadOnly,
      visible: true,
      parent: parent,
    );
    parent.addChild(node);
    await _reloadRecursive(node);
    return node;
  }

  // ---------- GeoPackage ----------

  /// 空の GeoPackage を作成して親ノードに追加。作成失敗時は null
  static Future<GeoPackageNode?> createGeoPackage(FolderNode parent, String name) async {
    final dir = parent.getAbsoluteFilePath();
    final fileName = name.endsWith('.gpkg') ? name : '$name.gpkg';
    final path = p.join(dir ?? '', fileName);

    if (await fs.exists(path)) {
      throw StateError(t.services.gpkgAlreadyExists);
    }

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
    final newFileName = await node.rename(newName, projectRootDir: projectRootDir);
    if (oldPath != null) {
      final newPath = p.join(p.dirname(oldPath), newFileName);
      await notifySyncedPathChange(node, oldPath, newPath);
    }
    if (node.parent != null) await node.parent!.updateChildren();
    return newFileName;
  }

  // ---------- 写真 ----------

  /// 写真をリネーム
  static Future<void> renamePhoto(ImageNode node, String newName) async {
    final oldPath = node.filePath;
    await node.rename(newName);
    final ext = p.extension(oldPath);
    final newFileName = newName.endsWith(ext) ? newName : '$newName$ext';
    final newPath = p.join(p.dirname(oldPath), newFileName);
    await notifySyncedPathChange(node, oldPath, newPath);
    if (node.parent != null) await node.parent!.updateChildren();
  }

  // ---------- ヘルパー ----------

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
