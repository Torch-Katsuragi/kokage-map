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

import '../../core/fs/k_file_system.dart';
import '../../core/path_resolver.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/global_folder_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../kmeta_service.dart';
import 'auto_sync_service.dart';
import 'drive_dir_store.dart';
import 'drive_folder_set_storage.dart';
import 'drive_transfer_registry.dart';
import 'drive_tree_nodes.dart';

/// ローカル削除の実行結果
enum DriveFolderDeleteOutcome {
  /// ローカルから削除された
  deleted,

  /// 他セットから参照中のため、単体エントリのみ外して実体を `.kokage/drive_store` へ退避した
  relocatedToStore,
}

LayerTreeNode? _resolveTreeRoot(LayerTreeNode node) {
  LayerTreeNode cur = node;
  while (cur.parent != null) {
    cur = cur.parent!;
  }
  if (!identical(cur, node)) return cur;
  return AutoSyncService.instance.rootNode;
}

/// [node] の Drive 連携メタデータを解除し、ツリー上で通常の [FolderNode] / [GlobalSubFolderNode] に差し替える
Future<bool> unlinkDriveFolderNodeInTree(FolderNode node) async {
  final folderPath = node.getAbsoluteFilePath();
  if (folderPath == null) return false;

  final isSetNode = node is DriveFolderSetNode;
  final searchRoots = isSetNode
      ? await DriveDirStore.instance.resolveSearchRoots(folderPath)
      : const <String>[];
  final directSetMembers = isSetNode
      ? ((await KMetaService.instance.getRawMeta(folderPath))?.sync.setMembers ??
          const <KMetaFolderSetMember>[])
      : const <KMetaFolderSetMember>[];

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
      for (final child in List.of(node.children)) {
        final childPath = child.getAbsoluteFilePath();
        // セット解除時は外部パスを仮想マウントしていた子ノードを切り離し、物理サブディレクトリのみ引き継ぐ
        if (isSetNode &&
            (childPath == null ||
                !DriveTransferRegistry.isStrictDescendantPath(
                  childPath,
                  folderPath,
                ))) {
          await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(child);
          continue;
        }
        child.parent = replacement;
        replacement.children.add(child);
      }
      node.children.clear();
      parentNode.children[index] = replacement;
      node.parent = null;
    }
  }

  if (isSetNode) {
    for (final m in directSetMembers) {
      final targetPath = m.targetPath ??
          await DriveDirStore.instance.findExistingPath(
            m.driveId,
            searchRoots: searchRoots,
          );
      if (targetPath != null) {
        await DriveDirStore.instance.deletePhysicalIfUnreferenced(
          driveId: m.driveId,
          targetPath: targetPath,
          excludingSetPath: '',
          searchRoots: searchRoots,
        );
      }
    }
  }
  return true;
}

/// Drive連携フォルダ・共有フォルダセット・通常フォルダをローカルから安全に削除する。
///
/// - 親が [DriveFolderSetNode] の参照メンバーの場合: 親の `setMembers` から外し、他セットから未参照なら物理削除
/// - 単体の [DriveFolderNode] が他セットから参照マウント中の場合: 実体を `.kokage/drive_store` へ退避し、セット側のマウントを維持
/// - [DriveFolderSetNode] / [FolderNode] の場合: ディスク上の `KMetaSync.setMembers` も含めて配下メンバーを収集し、未参照実体を掃除
Future<DriveFolderDeleteOutcome> deleteDriveFolderLocally(
  FolderNode node,
) async {
  final folderPath = node.getAbsoluteFilePath();
  if (folderPath == null) return DriveFolderDeleteOutcome.deleted;

  final parentNode = node.parent;
  final parentSet = parentNode is DriveFolderSetNode ? parentNode : null;
  final parentSetPath = parentSet?.getAbsoluteFilePath();
  final treeRoot = _resolveTreeRoot(node);
  final searchRoots =
      await DriveDirStore.instance.resolveSearchRoots(folderPath);

  // 1. フォルダセット内のメンバーフォルダ削除
  if (parentSet != null && parentSetPath != null && node is DriveFolderNode) {
    await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(node);
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
      searchRoots: searchRoots,
    );
    return DriveFolderDeleteOutcome.deleted;
  }

  // 2. 単体の DriveFolderNode 削除（他セットから参照中ならストアへ退避）
  if (node is DriveFolderNode) {
    final referencingSets = await DriveDirStore.instance.findReferencingSets(
      node.driveId,
      searchRoots: searchRoots,
    );
    if (referencingSets.isNotEmpty &&
        !DriveDirStore.instance.isManagedStorePath(folderPath)) {
      await _relocateReferencedDriveFolder(
        deletingNode: node,
        driveId: node.driveId,
        sourcePath: folderPath,
        treeRoot: treeRoot,
        searchRoots: searchRoots,
      );
      return DriveFolderDeleteOutcome.relocatedToStore;
    }

    await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(node);
    if (await fs.isDirectory(folderPath)) {
      await fs.delete(folderPath, recursive: true);
    }
    KMetaService.instance.invalidateCache(folderPath);
    await DriveDirStore.instance.unregister(
      node.driveId,
      ifPathMatches: folderPath,
    );
    return DriveFolderDeleteOutcome.deleted;
  }

  // 3. DriveFolderSetNode または通常の FolderNode 削除
  // ノード未展開時でも取りこぼさないよう、ディスク上の KMeta とメモリ上のノード双方から対象メンバーを収集する
  final memberTargets = <String, ({String driveId, String targetPath})>{};
  void recordTarget(String driveId, String? targetPath) {
    if (driveId.isEmpty || targetPath == null || targetPath.isEmpty) return;
    final key = '$driveId::${DriveTransferRegistry.normalizeKey(targetPath)}';
    memberTargets[key] = (driveId: driveId, targetPath: targetPath);
  }

  final diskMembers = await FolderSetStorage.collectSubSetMembersFromDisk(
    folderPath,
    searchRoots: searchRoots,
  );
  for (final m in diskMembers) {
    recordTarget(m.driveId, m.targetPath);
  }
  for (final childDrive in DriveTreeNodes.collectDescendantDriveFolders(node)) {
    recordTarget(childDrive.driveId, childDrive.getAbsoluteFilePath());
  }

  await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(node);

  // 物理的に folderPath 内部にある DriveFolder が外部セットから参照されている場合は、フォルダ削除前にストアへ退避する
  for (final entry in memberTargets.values.toList()) {
    if (!DriveTransferRegistry.isStrictDescendantPath(
      entry.targetPath,
      folderPath,
    )) {
      continue;
    }
    final referencedOutside =
        await DriveDirStore.instance.isReferencedByOtherSets(
      entry.driveId,
      excludingSetPath: folderPath,
      searchRoots: searchRoots,
    );
    if (referencedOutside && await fs.isDirectory(entry.targetPath)) {
      await _relocateReferencedDriveFolder(
        deletingNode: null,
        driveId: entry.driveId,
        sourcePath: entry.targetPath,
        treeRoot: treeRoot,
        searchRoots: searchRoots,
      );
    }
  }

  if (await fs.isDirectory(folderPath)) {
    await fs.delete(folderPath, recursive: true);
  }
  KMetaService.instance.invalidateCache(folderPath);

  for (final entry in memberTargets.values) {
    await DriveDirStore.instance.deletePhysicalIfUnreferenced(
      driveId: entry.driveId,
      targetPath: entry.targetPath,
      excludingSetPath: folderPath,
      searchRoots: searchRoots,
    );
  }
  return DriveFolderDeleteOutcome.deleted;
}

Future<void> _relocateReferencedDriveFolder({
  required DriveFolderNode? deletingNode,
  required String driveId,
  required String sourcePath,
  required LayerTreeNode? treeRoot,
  required List<String> searchRoots,
}) async {
  final mountedPeers = treeRoot != null
      ? DriveTreeNodes.collectDriveFolders(treeRoot)
          .where((n) => !identical(n, deletingNode) && n.driveId == driveId)
          .toList()
      : const <DriveFolderNode>[];

  // 移動前に開いている .gpkg 接続と旧パスを握る GeoPackageNode を（物理削除せずに）すべて解放する
  for (final peer in mountedPeers) {
    await DriveTreeNodes.closeAndClearChildrenWithoutDeletingFiles(peer);
  }
  if (deletingNode != null) {
    await DriveTreeNodes.detachSubtreeWithoutDeletingFiles(deletingNode);
  }

  final storePath = await DriveDirStore.instance.relocateFolderToStore(
    driveId: driveId,
    sourcePath: sourcePath,
    searchRoots: searchRoots,
  );

  for (final peer in mountedPeers) {
    peer.pathResolver = DirectPathResolver(storePath, isGlobal: peer.isGlobalNode);
    peer.invalidateMetaCache();
    await DriveTreeNodes.reloadFolderSubtree(peer);
  }
}
