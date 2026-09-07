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
// Root Maps: GeoPackageノードクラス
// GeoPackageファイルに対応するレイヤツリーノード

import 'package:path/path.dart' as p;
import 'package:root_maps/utils/app_logger.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/node_types.dart';
import '../../i18n/strings.g.dart';
import '../../services/kmeta_service.dart';
import '../geopackage/geopackage_file.dart';
import '../kmeta.dart';
import 'folder_node.dart';
import 'layer_node.dart';
import 'layer_tree_node.dart';

/// GeoPackageファイルノード（GeoPackageFile参照型）
/// LayerTreeNodeの共通機能はoverrideせず、GeoPackageFile参照のみ追加
class GeoPackageNode extends LayerTreeNode {
  /// GeoPackageファイル管理クラスへの参照
  final GeoPackageFile geoPackageFile;

  /// コンストラクタ
  GeoPackageNode(
    this.geoPackageFile, {
    bool visible = true,
    LayerTreeNode? parent,
  }) : super(
         geoPackageFile.pathList.isNotEmpty ? geoPackageFile.pathList.last : '',
         visible: visible,
         parent: parent,
         nodeType: NodeType.geopackage,
       );
  
  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動

  @override
  Future<void> persistVisibility() async {
    final parentFolder = parent;
    if (parentFolder is! FolderNode) return;
    final parentPath = parentFolder.getAbsoluteFilePath();
    if (parentPath == null) return;
    await KMetaService.instance.setGeoPackageVisibility(
      parentPath,
      name,
      visible,
    );
    parentFolder.invalidateMetaCache();
  }

  /// このGeoPackage内のLayerNodeのみ生成（非同期化）
  @override
  Future<void> updateChildren() async {
    // DBから現在のレイヤ構造を取得
    final nodes = await LayerNode.loadNodes(this);

    // 現在のDBに存在するレイヤ名のセットを作成
    final currentLayerNames = nodes.map((n) => n.name).toSet();

    // 既存の子ノードで、DBに存在しないものを削除
    children.removeWhere((child) {
      final shouldRemove = !currentLayerNames.contains(child.name);
      if (shouldRemove) {
        child.parent = null;
      }
      return shouldRemove;
    });

    // 新しいレイヤノードを追加（既存ノードは再利用）
    for (final node in nodes) {
      addChildIfNotExists(node);
    }

    // KMetaの可視性設定をレイヤーに適用
    await _applyMetaVisibility();

    // View定義を読む。ツリーUIは同期的に描くので、ここで揃えておく。
    // View が定義されていないレイヤにも「既定」View が1枚できる。
    await Future.wait(
      children.whereType<LayerNode>().map((l) => l.loadViews()),
    );

    AppLogger.debug('[GeoPackageNode] ${children.length} layers in $name');
  }

  /// 親フォルダのKMetaを取得
  Future<KMeta?> _getParentMeta() async {
    final folderParent = parent;
    if (folderParent is FolderNode) {
      return folderParent.getMeta();
    }
    return null;
  }

  /// KMetaの可視性設定をレイヤーに適用（layerKey形式で照合）
  /// 親FolderNodeのキャッシュを無効化して最新の.kmeta.jsonを読む
  Future<void> _applyMetaVisibility() async {
    final folderParent = parent;
    if (folderParent is FolderNode) {
      folderParent.invalidateMetaCache();
    }
    final meta = await _getParentMeta();
    if (meta == null) return;

    for (final child in children) {
      if (child is LayerNode) {
        final layerVisible = meta.visibility.layers[child.layerKey];
        if (layerVisible != null) {
          child.visible = layerVisible;
        }
      }
    }
  }

  /// （サブクラスでoverride推奨）親ノード直下の自分型インスタンスリストを返す（非同期化）
  ///
  /// [entries] を渡すと列挙をやり直さない（[FolderNode.loadNodes] と同じ理由）。
  static Future<List<LayerTreeNode>> loadNodes(
    LayerTreeNode? parent, {
    List<KFileEntry>? entries,
  }) async {
    final nodes = <LayerTreeNode>[];
    if (parent is! FolderNode) return nodes;

    final absPath = parent.getAbsoluteFilePath();
    if (absPath == null) return nodes;

    final gpkgFiles = (entries ?? await fs.list(absPath))
        .where((e) => !e.isDirectory && e.path.endsWith('.gpkg'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    for (final entity in gpkgFiles) {
      final gpkgFile = GeoPackageFile(
        [entity.name],
        absolutePath: entity.path,
      );
      nodes.add(GeoPackageNode(gpkgFile, visible: true, parent: parent));
    }
    if (nodes.isNotEmpty) {
      AppLogger.debug(
        '[GeoPackageNode] loadNodes: ${nodes.length} files in ${parent.name}',
      );
    }
    return nodes;
  }

  /// リネーム処理
  /// 戻り値: リネーム後の新しいファイル名（拡張子付き）
  Future<String> rename(String newName, {required String projectRootDir}) async {
    try {
      await geoPackageFile.dispose();

      final currentPath = p.joinAll([projectRootDir, ...geoPackageFile.pathList]);
      
      if (!await fs.exists(currentPath)) {
        throw Exception(t.services.fileNotFound(path: currentPath));
      }

      final directory = p.dirname(currentPath);
      const extension = '.gpkg';
      // 拡張子が含まれていない場合は付与
      final newFileName = newName.endsWith(extension) ? newName : '$newName$extension';
      final newPath = p.join(directory, newFileName);

      if (await fs.exists(newPath)) {
        throw Exception(t.services.fileAlreadyExists(name: newFileName));
      }

      // リネーム実行
      await fs.rename(currentPath, newPath);
      
      // 注意: parent.updateChildren()は呼び出し元で行う
      // これにより、呼び出し元で展開状態の管理などを適切に行える
      
      return newFileName;
    } catch (e) {
      AppLogger.debug('[ERROR] GeoPackageNode.rename: $e');
      rethrow;
    }
  }

  /// GeoPackageファイルを含む削除処理（ファイル自体も削除）
  @override
  Future<void> dispose() async {
    AppLogger.debug('[DEBUG] GeoPackageNode.dispose: disposing $name');

    try {
      // ファイル自体を削除
      final success = await geoPackageFile.deleteFile();
      if (success) {
        AppLogger.debug('[DEBUG] GeoPackageNode.dispose: ファイル削除成功 - $name');
      } else {
        AppLogger.debug('[DEBUG] GeoPackageNode.dispose: ファイル削除失敗 - $name');
      }
    } catch (e) {
      AppLogger.debug('[ERROR] GeoPackageNode.dispose: ファイル削除エラー - $e');
    }

    // 基底クラスの処理（親子関係切断）
    await super.dispose();

    AppLogger.debug('[DEBUG] GeoPackageNode.dispose: dispose完了 - $name');
  }
}

