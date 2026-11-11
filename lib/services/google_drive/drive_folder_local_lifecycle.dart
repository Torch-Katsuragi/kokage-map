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
/// Drive連携フォルダのローカル連携解除（unlink）および物理削除（単一実体共有対応）ライフサイクル
library;

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/global_folder_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../kmeta_service.dart';
import 'drive_dir_store.dart';
import 'drive_tree_nodes.dart';

/// [node] の Drive 連携メタデータを解除し、ツリー上で通常の [FolderNode] / [GlobalSubFolderNode] に差し替える
Future<bool> unlinkDriveFolderNodeInTree(FolderNode node) async {
  final folderPath = node.getAbsoluteFilePath();
  if (folderPath == null) return false;

  await KMetaService.instance.unlinkDrive(folderPath);

  final parentNode = node.parent;
  if (parentNode != null) {
    final index = parentNode.children.indexOf(node);
    if (index >= 0) {
      // Global の下なら Global のサブフォルダとして置き直す
      final globalBase = switch (parentNode) {
        GlobalFolderNode() => parentNode.globalPath,
        GlobalSubFolderNode() => parentNode.basePath,
        _ => null,
      };
      final LayerTreeNode replacement = globalBase != null
          ? GlobalSubFolderNode(
              node.name,
              basePath: globalBase,
              visible: node.visible,
              parent: parentNode,
              children: [],
            )
          : FolderNode(
              node.name,
              visible: node.visible,
              parent: parentNode,
              children: [],
            );
      for (final child in node.children) {
        child.parent = replacement;
        replacement.children.add(child);
      }
      node.children.clear();
      parentNode.children[index] = replacement;
      node.parent = null;
    }
  }
  return true;
}

/// Drive連携フォルダ・共有フォルダセットをローカルから安全に削除する。
///
/// - 親が [DriveFolderSetNode] の参照メンバーの場合: 親の `setMembers` から外し、他セットから未参照なら物理削除
/// - [DriveFolderSetNode] の場合: セット用ディレクトリを削除し、配下メンバーの実体を未参照チェック付きで掃除
/// - 単体の [DriveFolderNode] / [FolderNode] の場合: ディレクトリ削除と [DriveDirStore] 登録解除
Future<void> deleteDriveFolderLocally(FolderNode node) async {
  final folderPath = node.getAbsoluteFilePath();
  if (folderPath == null) return;

  final parentNode = node.parent;
  final parentSet = parentNode is DriveFolderSetNode ? parentNode : null;
  final parentSetPath = parentSet?.getAbsoluteFilePath();

  // DriveFolderSetNode を削除する場合、dispose 前に配下の参照メンバー一覧を控えておく
  final descendantFolders = node is DriveFolderSetNode
      ? DriveTreeNodes.collectDescendantDriveFolders(node).toList()
      : const <DriveFolderNode>[];

  await node.dispose();

  if (parentSet != null && parentSetPath != null && node is DriveFolderNode) {
    // 親セットの setMembers から除外
    final setMeta = await KMetaService.instance.getMeta(parentSetPath);
    final nextMembers = setMeta.sync.setMembers
        .where((m) => m.driveId != node.driveId)
        .toList();
    await KMetaService.instance.setDriveSync(
      parentSetPath,
      setMembers: nextMembers,
    );
    await DriveDirStore.instance.deletePhysicalIfUnreferenced(
      driveId: node.driveId,
      targetPath: folderPath,
      excludingSetPath: parentSetPath,
      searchRoots: [p.dirname(parentSetPath)],
    );
    return;
  }

  if (node is DriveFolderSetNode) {
    if (await fs.isDirectory(folderPath)) {
      await fs.delete(folderPath, recursive: true);
    }
    final searchRoot = p.dirname(folderPath);
    for (final childDrive in descendantFolders) {
      final childPath = childDrive.getAbsoluteFilePath();
      if (childPath != null) {
        await DriveDirStore.instance.deletePhysicalIfUnreferenced(
          driveId: childDrive.driveId,
          targetPath: childPath,
          excludingSetPath: folderPath,
          searchRoots: [searchRoot],
        );
      }
    }
    return;
  }

  if (await fs.isDirectory(folderPath)) {
    await fs.delete(folderPath, recursive: true);
  }
  if (node is DriveFolderNode) {
    await DriveDirStore.instance.unregister(
      node.driveId,
      ifPathMatches: folderPath,
    );
  }
}
