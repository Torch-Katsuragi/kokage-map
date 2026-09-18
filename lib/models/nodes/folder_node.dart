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
// Root Maps: フォルダノードクラス
// ファイルシステムのフォルダに対応するレイヤツリーノード

import 'package:root_maps/utils/app_logger.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/node_types.dart';
import '../../services/google_drive/sync_base_store.dart';
import '../../services/kmeta_service.dart';
import '../kmeta.dart';
import 'drive_folder_node.dart';
import 'geopackage_node.dart';
import 'global_folder_node.dart';
import 'image_node.dart';
import 'layer_tree_node.dart';

/// フォルダノード
class FolderNode extends LayerTreeNode {
  /// マージ済みメタデータのキャッシュ
  KMeta? _cachedMeta;

  /// 展開状態（KMetaから取得、未設定時はtrue）
  bool _expanded = true;

  FolderNode(super.name, {super.visible, super.parent, super.children})
    : super(nodeType: NodeType.folder);

  /// 展開状態を取得
  @override
  bool get expanded => _expanded;

  /// 展開状態を設定（KMetaにも保存）
  set expanded(bool value) {
    _expanded = value;
    _saveExpandedState(value);
  }

  /// 展開状態をKMetaに保存
  Future<void> _saveExpandedState(bool value) async {
    final folderPath = getAbsoluteFilePath();
    if (folderPath == null) return;
    await KMetaService.instance.setExpanded(folderPath, value);
  }

  @override
  Future<void> persistVisibility() async {
    final parentFolder = parent;
    if (parentFolder is! FolderNode) return;
    final parentPath = parentFolder.getAbsoluteFilePath();
    if (parentPath == null) return;
    await KMetaService.instance.setFolderVisibility(parentPath, name, visible);
    parentFolder.invalidateMetaCache();
  }

  /// マージ済みメタデータを取得（キャッシュ対応）
  Future<KMeta> getMeta() async {
    if (_cachedMeta != null) return _cachedMeta!;
    final folderPath = getAbsoluteFilePath();
    if (folderPath == null) return KMeta.empty;
    _cachedMeta = await KMetaService.instance.getMeta(folderPath);
    return _cachedMeta!;
  }

  /// 生メタデータを取得（このフォルダのみ、継承なし）
  Future<KMeta?> getRawMeta() async {
    final folderPath = getAbsoluteFilePath();
    if (folderPath == null) return null;
    return KMetaService.instance.getRawMeta(folderPath);
  }

  /// メタデータキャッシュをクリア
  void invalidateMetaCache() {
    _cachedMeta = null;
    final folderPath = getAbsoluteFilePath();
    if (folderPath != null) {
      KMetaService.instance.invalidateCache(folderPath);
    }
  }
  
  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動

  /// このフォルダ直下のFolderNode, GeoPackageNode, ImageNodeのみ生成
  @override
  Future<void> updateChildren() async {
    // メタデータを読み込み（展開状態を復元）
    await loadMetaState();

    // ファイルシステムから現在の構造を取得。
    // 列挙は1回だけ行い、3つのローダーに配る（web はハンドル走査が高いため）
    final entries = await listOnce();
    final folderNodes = await FolderNode.loadNodes(this, entries: entries);
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
    // ただし、グローバル構造ノードはファイルシステム外に存在するため削除しない
    children.removeWhere((child) {
      if (child is GlobalFolderNode || child is GlobalSubFolderNode) {
        return false;
      }
      final shouldRemove = !allCurrentNames.contains(child.name);
      if (shouldRemove) {
        child.parent = null;
      }
      return shouldRemove;
    });

    // 新しいノードを追加（既存ノードは再利用）
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

  /// メタデータから状態を読み込み（サブクラスから呼び出し可能）
  Future<void> loadMetaState() async {
    invalidateMetaCache(); // キャッシュをクリアして最新を読み込み
    final meta = await getMeta();
    // 展開状態を復元
    _expanded = meta.layout.expanded ?? true;
  }

  /// メタデータの可視性設定を子ノードに適用（サブクラスから呼び出し可能）
  Future<void> applyMetaVisibility() async {
    final meta = await getMeta();
    final vis = meta.visibility;
    for (final child in children) {
      final bool? saved;
      if (child is GeoPackageNode) {
        saved = vis.geopackages[child.name];
      } else if (child is FolderNode) {
        saved = vis.folders[child.name];
      } else if (child is ImageNode) {
        saved = vis.images[child.name];
      } else {
        continue;
      }
      if (saved != null) child.visible = saved;
    }
  }

  /// このフォルダ直下のFolderNodeリストのみ返す（名前昇順でソート）
  /// .kmeta.jsonにDrive連携情報があればDriveFolderNodeとして作成
  ///
  /// [entries] を渡すと列挙をやり直さない。同じフォルダに対して
  /// FolderNode / GeoPackageNode / ImageNode の3つを続けて作るときに使う。
  static Future<List<LayerTreeNode>> loadNodes(
    LayerTreeNode? parent, {
    List<KFileEntry>? entries,
  }) async {
    final nodes = <LayerTreeNode>[];
    if (parent == null) return nodes;
    final absPath = parent.getAbsoluteFilePath();
    if (absPath == null) return nodes;

    final directories = (entries ?? await fs.list(absPath))
        .where((e) => e.isDirectory)
        .where((e) => e.name != SyncBaseStore.dirName) // 3-way マージの base 置き場は見せない
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in directories) {
      final folderPath = entity.path;
      final folderName = entity.name;

      // .kmeta.jsonをチェックしてDrive連携情報があるか確認
      final driveNode = await tryCreateDriveFolderNode(
        folderPath,
        folderName,
        parent,
      );

      if (driveNode != null) {
        nodes.add(driveNode);
      } else {
        nodes.add(
          FolderNode(
            folderName,
            visible: true,
            parent: parent,
            children: [],
          ),
        );
      }
    }
    return nodes;
  }

  /// .kmeta.jsonからDrive連携情報を読み込み、DriveFolderNodeを作成
  /// GlobalFolderNodeのローダーからも利用されるためパッケージ可視
  static Future<LayerTreeNode?> tryCreateDriveFolderNode(
    String folderPath,
    String folderName,
    LayerTreeNode parent,
  ) async {
    try {
      final meta = await KMetaService.instance.getRawMeta(folderPath);
      if (meta == null || !meta.sync.isLinked) {
        return null;
      }
      
      final driveId = meta.sync.driveId;
      if (driveId == null) return null;
      
      AppLogger.debug('[FolderNode] Drive連携フォルダを検出: $folderName (driveId: $driveId)');
      return createDriveFolderNodeFromMeta(folderName, meta, parent);
    } catch (e) {
      AppLogger.debug('[FolderNode] Drive連携チェックエラー: $e');
      return null;
    }
  }

  /// メタデータからDriveFolderNodeを作成
  static LayerTreeNode? createDriveFolderNodeFromMeta(
    String folderName,
    KMeta meta,
    LayerTreeNode parent,
  ) {
    final driveId = meta.sync.driveId;
    if (driveId == null) return null;
    
    final driveUrl = meta.sync.driveUrl ?? '';
    final isReadOnly = meta.sync.isReadOnly ?? false;
    
    return DriveFolderNode(
      folderName,
      driveId: driveId,
      driveUrl: driveUrl,
      isReadOnly: isReadOnly,
      lastSynced: meta.sync.lastSynced,
      visible: true,
      parent: parent,
      children: [],
    );
  }

  /// プロジェクトルート用のノードを作成
  /// .kmeta.jsonにDrive連携情報があればDriveFolderNodeを返す
  static Future<LayerTreeNode> createRootNode(String projectDir) async {
    try {
      final meta = await KMetaService.instance.getRawMeta(projectDir);
      if (meta != null && meta.sync.isLinked) {
        final driveId = meta.sync.driveId;
        if (driveId != null) {
          AppLogger.debug(
            '[FolderNode] ルートがDrive連携: driveId=$driveId',
          );
          return DriveFolderNode(
            'Home',
            driveId: driveId,
            driveUrl: meta.sync.driveUrl ?? '',
            isReadOnly: meta.sync.isReadOnly ?? false,
            lastSynced: meta.sync.lastSynced,
            driveRevisionId: meta.sync.driveRevisionId,
            visible: true,
          );
        }
      }
    } catch (e) {
      AppLogger.debug('[FolderNode] ルートDrive連携チェックエラー: $e');
    }
    return FolderNode('Home', visible: true);
  }

  @override
  Future<void> dispose() async {
    for (final child in children) {
      await child.dispose();
    }
    children.clear();
    await super.dispose();
  }

  // 2026-08-25: createIn() を削除した。
  // どこからも呼ばれていない（フォルダ作成は LayerDrawerService.createLocalFolder
  // が担当）うえ、同期のファイルI/O（existsSync/createSync）を持っていて
  // web に持ち込めなかった。必要になったら `fs` 経由の非同期版として足すこと。
}

