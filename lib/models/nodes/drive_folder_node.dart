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
// Root Maps: Drive連携フォルダノードクラス
// Google Driveと同期するフォルダを表すレイヤツリーノード

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/node_types.dart';
import '../../services/google_drive/sync_base_store.dart';
import '../../services/kmeta_service.dart';
import '../../utils/app_logger.dart';
import 'folder_node.dart';
import 'geopackage_node.dart';
import 'global_folder_node.dart';
import 'image_node.dart';
import 'layer_tree_node.dart';

/// グローバルフォルダ内のノードのパスを解決するヘルパー
/// 親チェインにGlobalFolderNodeがあればそこからパスを構築、なければnull
String? _resolveGlobalPath(LayerTreeNode node) {
  LayerTreeNode? ancestor = node.parent;
  while (ancestor != null) {
    if (ancestor is GlobalFolderNode) {
      final segments = <String>[];
      LayerTreeNode? current = node;
      while (current != null && current is! GlobalFolderNode) {
        segments.insert(0, current.name);
        current = current.parent;
      }
      return p.joinAll([ancestor.globalPath, ...segments]);
    }
    ancestor = ancestor.parent;
  }
  return null;
}

/// 同期状態
enum SyncStatus {
  /// 同期済み（変更なし）
  synced,
  /// ローカルに変更あり（↑ Push可能）
  localChanges,
  /// Driveに変更あり（↓ Pull可能）
  remoteChanges,
  /// 競合あり（両方に変更）
  conflict,
  /// 同期中
  syncing,
  /// エラー
  error,
  /// 未確認（初期状態）
  unknown,
}

/// Drive連携フォルダノード
class DriveFolderNode extends FolderNode {
  /// DriveフォルダID
  final String driveId;

  /// 元のDrive URL
  final String driveUrl;

  /// 読み取り専用か
  final bool isReadOnly;

  /// 同期状態
  SyncStatus syncStatus;

  /// 最終同期日時
  DateTime? lastSynced;

  /// DriveのリビジョンID（差分検出用）
  String? driveRevisionId;

  DriveFolderNode(
    super.name, {
    required this.driveId,
    required this.driveUrl,
    this.isReadOnly = false,
    this.syncStatus = SyncStatus.unknown,
    this.lastSynced,
    this.driveRevisionId,
    super.visible,
    super.parent,
    super.children,
  });

  @override
  NodeType get nodeType => NodeType.folder;

  /// Drive連携フォルダかどうか
  bool get isDriveLinked => true;

  /// グローバルフォルダ内の場合はグローバルパスから解決
  @override
  String? getAbsoluteFilePath() =>
      _resolveGlobalPath(this) ?? super.getAbsoluteFilePath();

  /// このフォルダ直下の子ノードを更新
  @override
  Future<void> updateChildren() async {
    // メタデータを読み込み
    await loadMetaState();

    // ファイルシステムから現在の構造を取得（列挙は1回だけ。FolderNodeと同じ理由）
    final entries = await listOnce();
    final folderNodes = await _loadDriveFolderNodes(this, entries);
    final gpkgNodes = await GeoPackageNode.loadNodes(this, entries: entries);
    final photoNodes = await ImageNode.loadNodes(this, entries: entries);

    // 現在のファイルシステムに存在するノード名のセットを作成
    final currentFolderNames = folderNodes.map((n) => n.name).toSet();
    final currentGpkgNames = gpkgNodes.map((n) => n.name).toSet();
    final currentPhotoNames = photoNodes.map((n) => n.name).toSet();
    final allCurrentNames = {
      ...currentFolderNames,
      ...currentGpkgNames,
      ...currentPhotoNames,
    };

    // 既存の子ノードで、ファイルシステムに存在しないものを削除
    children.removeWhere((child) {
      if (child is GlobalFolderNode || child is GlobalSubFolderNode) return false;
      final shouldRemove = !allCurrentNames.contains(child.name);
      if (shouldRemove) {
        AppLogger.debug(
          '[DriveFolderNode] removing ${child.name} (no longer exists)',
        );
        child.parent = null;
      }
      return shouldRemove;
    });

    // 新しいノードを追加
    for (final node in folderNodes) {
      addChildIfNotExists(node);
    }
    for (final node in gpkgNodes) {
      addChildIfNotExists(node);
    }
    for (final node in photoNodes) {
      addChildIfNotExists(node);
    }

    // KMetaの可視性設定を子ノードに適用
    await applyMetaVisibility();
  }

  /// Drive連携フォルダ内のサブフォルダをロード
  /// サブフォルダもDriveFolderNodeとして作成（同じdriveIdを共有）
  static Future<List<LayerTreeNode>> _loadDriveFolderNodes(
    DriveFolderNode parent,
    List<KFileEntry> entries,
  ) async {
    final nodes = <LayerTreeNode>[];

    final directories = entries
        .where((e) => e.isDirectory && e.name != SyncBaseStore.dirName) // 3-way マージの base 置き場は見せない
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in directories) {
      // サブフォルダはDriveSubFolderNodeとして作成
      nodes.add(
        DriveSubFolderNode(
          entity.name,
          rootDriveNode: parent,
          visible: true,
          parent: parent,
          children: [],
        ),
      );
    }
    return nodes;
  }

  /// KMetaから同期情報を読み込み
  Future<void> loadSyncInfo() async {
    final folderPath = getAbsoluteFilePath();
    if (folderPath == null) return;

    final meta = await KMetaService.instance.getMeta(folderPath);
    if (meta.sync.lastSynced != null) {
      lastSynced = meta.sync.lastSynced;
    }
    if (meta.sync.driveRevisionId != null) {
      driveRevisionId = meta.sync.driveRevisionId;
    }
  }

  /// 同期情報をKMetaに保存
  Future<void> saveSyncInfo() async {
    final folderPath = getAbsoluteFilePath();
    if (folderPath == null) return;

    await KMetaService.instance.setDriveSync(
      folderPath,
      driveId: driveId,
      lastSynced: lastSynced,
      driveRevisionId: driveRevisionId,
    );
  }
}

/// Drive連携フォルダ内のサブフォルダノード
class DriveSubFolderNode extends FolderNode {
  /// ルートのDriveFolderNode（同期情報を持つ）
  final DriveFolderNode rootDriveNode;

  DriveSubFolderNode(
    super.name, {
    required this.rootDriveNode,
    super.visible,
    super.parent,
    super.children,
  });

  /// Drive連携フォルダかどうか
  bool get isDriveLinked => true;

  /// 読み取り専用か
  bool get isReadOnly => rootDriveNode.isReadOnly;

  /// グローバルフォルダ内の場合はグローバルパスから解決
  @override
  String? getAbsoluteFilePath() =>
      _resolveGlobalPath(this) ?? super.getAbsoluteFilePath();

  @override
  Future<void> updateChildren() async {
    await loadMetaState();

    final entries = await listOnce();
    final folderNodes = await _loadSubFolderNodes(this, entries);
    final gpkgNodes = await GeoPackageNode.loadNodes(this, entries: entries);
    final photoNodes = await ImageNode.loadNodes(this, entries: entries);

    final currentFolderNames = folderNodes.map((n) => n.name).toSet();
    final currentGpkgNames = gpkgNodes.map((n) => n.name).toSet();
    final currentPhotoNames = photoNodes.map((n) => n.name).toSet();
    final allCurrentNames = {
      ...currentFolderNames,
      ...currentGpkgNames,
      ...currentPhotoNames,
    };

    children.removeWhere((child) {
      if (child is GlobalFolderNode || child is GlobalSubFolderNode) return false;
      final shouldRemove = !allCurrentNames.contains(child.name);
      if (shouldRemove) {
        child.parent = null;
      }
      return shouldRemove;
    });

    for (final node in folderNodes) {
      addChildIfNotExists(node);
    }
    for (final node in gpkgNodes) {
      addChildIfNotExists(node);
    }
    for (final node in photoNodes) {
      addChildIfNotExists(node);
    }

    await applyMetaVisibility();
  }

  static Future<List<LayerTreeNode>> _loadSubFolderNodes(
    DriveSubFolderNode parent,
    List<KFileEntry> entries,
  ) async {
    final nodes = <LayerTreeNode>[];

    final directories = entries
        .where((e) => e.isDirectory && e.name != SyncBaseStore.dirName) // 3-way マージの base 置き場は見せない
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in directories) {
      nodes.add(
        DriveSubFolderNode(
          entity.name,
          rootDriveNode: parent.rootDriveNode,
          visible: true,
          parent: parent,
          children: [],
        ),
      );
    }
    return nodes;
  }
}
