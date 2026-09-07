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
// Root Maps: レイヤツリー共通ノード基底クラス
// FolderNode, GeoPackageGroup, Layerの共通実装

import 'package:flutter/material.dart';
import '../../core/fs/k_file_system.dart';
import '../../core/node_types.dart';
import '../../core/path_resolver.dart';

/// レイヤツリーのノード共通基底クラス
abstract class LayerTreeNode {
  /// ノード名（表示名）
  String name;

  /// 可視状態
  bool visible;

  /// ノード種別（型安全なenum）
  final NodeType nodeType;

  /// 親ノード（ルートはnull）
  LayerTreeNode? parent;

  /// 子ノードリスト（レイヤは空リスト）
  List<LayerTreeNode> children;

  /// パスリゾルバ（注入可能、未設定時は親から継承またはデフォルト使用）
  PathResolver? _pathResolver;

  // UI関連の責務（baseIcon, baseIconColor）はNodePresenterに移動
  // lib/presentation/node_presenter.dart を参照

  /// コンストラクタ
  /// [pathResolver] パスリゾルバ（省略時は親から継承またはProjectPathResolverを使用）
  LayerTreeNode(
    this.name, {
    this.visible = true,
    this.parent,
    List<LayerTreeNode>? children,
    required this.nodeType,
    PathResolver? pathResolver,
  }) : children = children ?? [],
       _pathResolver = pathResolver;

  /// パスリゾルバを取得
  /// 優先順位: 自身に設定 → 親から継承 → デフォルト（ProjectPathResolver）
  PathResolver get pathResolver {
    if (_pathResolver != null) return _pathResolver!;
    if (parent != null) return parent!.pathResolver;
    return ProjectPathResolver.instance;
  }

  /// パスリゾルバを設定
  set pathResolver(PathResolver resolver) {
    _pathResolver = resolver;
  }

  /// グローバルフォルダ関連ノードかどうか
  /// PathResolverがGlobalPathResolverの場合true
  bool get isGlobalNode => pathResolver.isGlobal;

  /// このノードまたは祖先がグローバルフォルダ内にあるか
  /// 祖先チェインにisGlobalNode=trueのノードがあればtrue
  bool get isInsideGlobalFolder {
    LayerTreeNode? current = this;
    while (current != null) {
      if (current.isGlobalNode) return true;
      current = current.parent;
    }
    return false;
  }

  /// 初期化フラグ（重複実行を防ぐ）
  bool _initialized = false;

  /// 明示的に子ノードを初期化（遅延初期化パターン）
  /// 通常はUIから初回アクセス時に呼び出される
  Future<void> ensureInitialized() async {
    if (_initialized) return; // 既に初期化済みなら何もしない
    _initialized = true;
    await updateChildren();
  }

  /// ノードのリソース解放・削除処理（サブクラスで必ずsuper.dispose()を呼ぶこと）
  @mustCallSuper
  Future<void> dispose() async {
    parent?.children.remove(this);
    parent = null;
  }

  /// ルートからのパスリスト（meta.json用途）
  List<String> getPathFromRoot() {
    final List<String> pathList = [];
    LayerTreeNode? current = this;
    while (current != null) {
      pathList.insert(0, current.name);
      current = current.parent;
    }
    // AppLogger.debug('getPathFromRoot result: $pathList'); // 最終結果のデバッグ出力
    return pathList;
  }

  /// ファイルシステム上の絶対パスリスト
  List<String> getAbsolutePathSegments() {
    final path = getPathFromRoot();
    return path.length > 1 ? path.sublist(1) : [];
  }

  /// 再帰的に子ノードをたどり、ノード構造を辞書形式で返す
  /// @return `Map<String, dynamic>` ノード構造を示す辞書
  Map<String, dynamic> toDict() {
    final Map<String, dynamic> dict = {
      'name': name,
      'type': nodeType.value,
      'visible': visible,
      'children': children.map((child) => child.toDict()).toList(),
    };
    return dict;
  }

  /// 指定typeの子ノードリストを返す
  List<LayerTreeNode> getChildrenByType(NodeType type) {
    return children.where((c) => c.nodeType == type).toList();
  }

  /// 可視状態のLayerNodeリストを再帰的に取得（高速化用）
  List<LayerTreeNode> getVisibleLayerNodes() {
    final result = <LayerTreeNode>[];
    _collectVisibleLayerNodes(result);
    return result;
  }

  /// 可視状態のLayerNodeを再帰的に収集（内部メソッド）
  void _collectVisibleLayerNodes(List<LayerTreeNode> result) {
    if (!isVisibleRecursive()) return;

    if (nodeType == NodeType.layer) {
      result.add(this);
    } else {
      for (final child in children) {
        child._collectVisibleLayerNodes(result);
      }
    }
  }

  /// 展開状態（デフォルトはtrue）
  bool get expanded => true;

  /// ファイル構造を参照して自分のchildrenを更新する（非同期化）
  /// サブクラスで必ずoverrideすること
  Future<void> updateChildren() async {}

  /// 子ノードを追加。childrenTypeに合致しない場合は警告を出してスキップ
  void addChild(LayerTreeNode child) {
    children.add(child);
    child.parent = this;
  }

  /// 子ノードを削除
  void removeChild(LayerTreeNode child) {
    children.remove(child);
    child.parent = null;
  }

  /// 同名・同型の子ノードが存在しない場合のみ追加
  /// 既存ノードがある場合はそのノードを返し、ない場合は新規追加して返す
  LayerTreeNode addChildIfNotExists(LayerTreeNode newChild) {
    final existing = getChild(newChild.name, type: newChild.nodeType);
    if (existing != null) {
      if (existing.runtimeType != newChild.runtimeType) {
        // 型が変わった場合（例: ImageNode -> OverlayImageNode）は入れ替える
        final index = children.indexOf(existing);
        if (index != -1) {
          children[index] = newChild;
          newChild.parent = this;
          existing.parent = null;
          return newChild;
        }
      }
      // 既存ノードを返す（重複を避ける）
      return existing;
    }
    // 新規追加
    addChild(newChild);
    return newChild;
  }

  bool isVisibleRecursive() {
    if (!visible) {
      return false;
    } else {
      if (parent == null) {
        return true;
      } else {
        return parent!.isVisibleRecursive();
      }
    }
  }

  /// 自分自身を含むツリー構造を再帰的に辞書(Map)として出力
  /// 例: {"ノード名": {"nodeType": "folder", "children": [...], "visible": true}}
  Map<String, dynamic> toMap() {
    return {
      name: {
        'nodeType': nodeType.value,
        'children': children.map((c) => c.toMap()).toList(),
        'visible': visible,
      },
    };
  }

  /// 子ノード名と（必要なら）nodeTypeで該当ノードを取得。なければnull
  /// @param name 子ノード名
  /// @param type ノード種別（省略可）
  /// @return LayerTreeNode? 一致する子ノード、なければnull
  LayerTreeNode? getChild(String name, {NodeType? type}) {
    for (final child in children) {
      if (child.name == name && (type == null || child.nodeType == type)) {
        return child;
      }
    }
    return null;
  }

  /// パスリスト（このノードからのノード名リスト）を受け取り、該当する子孫ノードへの参照を返す
  /// 例: ["root", "folderA", "layer1"]
  /// 見つからなければnullを返す
  LayerTreeNode? getNodeByPath(List<String> pathList) {
    if (pathList.isEmpty) return null;
    if (pathList[0] != name) return null;
    if (pathList.length == 1) return this;
    for (final type in NodeType.values) {
      final next = getChild(pathList[1], type: type);
      if (next != null) {
        return next.getNodeByPath(pathList.sublist(1));
      }
      return null;
    }
    return null;
  }

  /// ノードの絶対パス（ファイルシステム上のパス）を取得
  /// PathResolverを使用してパスを解決
  String? getAbsoluteFilePath() {
    return pathResolver.resolvePath(getAbsolutePathSegments());
  }

  /// 可視状態をkmetaに永続化（サブクラスでオーバーライド）
  Future<void> persistVisibility() async {}

  /// 自分の直下を1回だけ列挙する。パスを解決できなければ空。
  ///
  /// > [!NOTE] なぜこれがあるか
  /// > `updateChildren()` は同じフォルダに対して FolderNode / GeoPackageNode /
  /// > ImageNode の3種を作る。素直に書くと `fs.list()` が3回走る。
  /// > native なら syscall 3回で済むが、**web は File System Access API の
  /// > ハンドル走査が3回**になり、フォルダが大きいほど効く。
  /// > 1回列挙して各ローダーの `entries` に配ること。
  Future<List<KFileEntry>> listOnce() async {
    final absPath = getAbsoluteFilePath();
    if (absPath == null) return const [];
    return fs.list(absPath);
  }

  /// （サブクラスでoverride推奨）親ノード直下の自分型インスタンスリストを返す（非同期化）
  static Future<List<LayerTreeNode>> loadNodes(LayerTreeNode? parent) async {
    // 基底クラスでは空のリストを返す
    // 各サブクラス（FolderNode、GeoPackageNode、LayerNode）で具体的な実装をする
    return <LayerTreeNode>[];
  }
}
