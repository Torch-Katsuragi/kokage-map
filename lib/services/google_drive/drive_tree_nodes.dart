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
/// Drive連携ツリーノード（[DriveFolderNode] / [DriveFolderSetNode]）の走査・再読込ヘルパー
library;

import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../utils/app_logger.dart';
import '../qgis/qgs_read_back.dart';
import 'drive_transfer_registry.dart';

/// レイヤーツリー内の Drive 関連ノード走査・再読込ユーティリティ
class DriveTreeNodes {
  const DriveTreeNodes._();

  /// ツリー全体から [DriveFolderSetNode] を再帰収集する
  static List<DriveFolderSetNode> collectFolderSets(LayerTreeNode node) {
    final result = <DriveFolderSetNode>[];
    if (node is DriveFolderSetNode) result.add(node);
    for (final child in node.children) {
      result.addAll(collectFolderSets(child));
    }
    return result;
  }

  /// ツリー全体から [DriveFolderNode] を再帰収集する
  static List<DriveFolderNode> collectDriveFolders(LayerTreeNode node) {
    final result = <DriveFolderNode>[];
    if (node is DriveFolderNode) result.add(node);
    for (final child in node.children) {
      result.addAll(collectDriveFolders(child));
    }
    return result;
  }

  /// [node] 配下の子セットを含めた子孫 [DriveFolderNode] を列挙する（[DriveFolderNode] 内部へは潜らない）
  static Iterable<DriveFolderNode> collectDescendantDriveFolders(
    LayerTreeNode node,
  ) sync* {
    for (final child in node.children) {
      if (child is DriveFolderNode) {
        yield child;
      } else if (child is FolderNode) {
        yield* collectDescendantDriveFolders(child);
      }
    }
  }

  /// 指定ローカルパスに一致するツリー内の [DriveFolderNode] 一覧を返す（参照マウントによる複数ノード対応）
  static List<DriveFolderNode> findDriveFoldersByPath(
    LayerTreeNode root,
    String localPath,
  ) {
    final normTarget = DriveTransferRegistry.normalizeKey(localPath);
    return collectDriveFolders(root).where((n) {
      final path = n.getAbsoluteFilePath();
      return path != null &&
          DriveTransferRegistry.normalizeKey(path) == normTarget;
    }).toList();
  }

  /// 指定ローカルパスに一致するツリー内の [DriveFolderSetNode] を探す
  static DriveFolderSetNode? findFolderSetByPath(
    LayerTreeNode root,
    String localPath,
  ) {
    final normTarget = DriveTransferRegistry.normalizeKey(localPath);
    return collectFolderSets(root).where((n) {
      final path = n.getAbsoluteFilePath();
      return path != null &&
          DriveTransferRegistry.normalizeKey(path) == normTarget;
    }).firstOrNull;
  }

  /// [setNode] 配下の子ノードを再帰的に読み込み、子セット内も含めた全子孫 [DriveFolderNode] の `.qgs` を読み戻す
  static Future<void> reloadFolderSetNode(DriveFolderSetNode setNode) async {
    await _reloadSetSubtreeRecursive(setNode);
    for (final child in collectDescendantDriveFolders(setNode)) {
      try {
        final readBack = await const QgsReadBack().run(child);
        if (readBack != null) {
          await _reloadSetSubtreeRecursive(child);
        }
      } catch (e) {
        AppLogger.debug('[DriveFolderSet] 子フォルダ ${child.name} の .qgs 読み戻しエラー: $e');
      }
    }
  }

  /// ファイルや DB テーブルを物理削除せず、開いている GeoPackage 接続だけを閉じて [node] を親ツリーから切り離す。
  ///
  /// 共有フォルダセットの参照解除・単体フォルダのストア退避など、実体ディレクトリの削除可否を
  /// 参照カウントで後から判定する場面では、[LayerTreeNode.dispose]（物理削除を伴う）ではなく本メソッドを使う。
  static Future<void> detachSubtreeWithoutDeletingFiles(
    LayerTreeNode node,
  ) async {
    await _closeSubtreeConnectionsRecursive(node);
    node.parent?.removeChild(node);
  }

  /// [node] 自身は親に残したまま、配下の子ノードの接続を閉じて `children` を空にする（向き先パス差し替え前の解放用）
  static Future<void> closeAndClearChildrenWithoutDeletingFiles(
    LayerTreeNode node,
  ) async {
    for (final child in List.of(node.children)) {
      await _closeSubtreeConnectionsRecursive(child);
      node.removeChild(child);
    }
  }

  static Future<void> _closeSubtreeConnectionsRecursive(
    LayerTreeNode node,
  ) async {
    if (node is GeoPackageNode) {
      try {
        await node.geoPackageFile.dispose();
      } catch (e) {
        AppLogger.debug(
          '[DriveTreeNodes] GeoPackage 接続クローズ失敗 (${node.name}): $e',
        );
      }
    }
    for (final child in List.of(node.children)) {
      await _closeSubtreeConnectionsRecursive(child);
      child.parent = null;
    }
    node.children.clear();
  }

  /// 単一の [FolderNode]（参照マウントの向き先変更後など）配下を再帰的に再読込し、`.qgs` も読み戻す
  static Future<void> reloadFolderSubtree(FolderNode node) async {
    await _reloadSetSubtreeRecursive(node);
    try {
      final readBack = await const QgsReadBack().run(node);
      if (readBack != null) {
        await _reloadSetSubtreeRecursive(node);
      }
    } catch (e) {
      AppLogger.debug('[DriveFolderSet] フォルダ ${node.name} の .qgs 読み戻しエラー: $e');
    }
  }

  static Future<void> _reloadSetSubtreeRecursive(LayerTreeNode node) async {
    await node.updateChildren();
    for (final child in node.children) {
      if (node is DriveFolderSetNode &&
          node.syncStatus == SyncStatus.synced &&
          (child is DriveFolderSetNode || child is DriveFolderNode)) {
        if (child is DriveFolderSetNode &&
            child.syncStatus == SyncStatus.unknown) {
          child.syncStatus = SyncStatus.synced;
        } else if (child is DriveFolderNode &&
            child.syncStatus == SyncStatus.unknown) {
          child.syncStatus = SyncStatus.synced;
        }
      }
      if (child is FolderNode) {
        await _reloadSetSubtreeRecursive(child);
      } else if (child is GeoPackageNode) {
        await child.updateChildren();
        await child.reloadLoadedLayers();
      }
    }
  }
}
