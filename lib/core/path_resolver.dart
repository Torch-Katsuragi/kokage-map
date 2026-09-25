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
// Root Maps: パス解決のためのインターフェースと実装
// Strategy Patternを使用して、プロジェクトフォルダとグローバルフォルダのパス解決を統一

import 'package:path/path.dart' as p;

/// パス解決のためのインターフェース
/// 
/// ノードのパス解決戦略を抽象化し、以下を実現：
/// - プロジェクトフォルダとグローバルフォルダの統一的な扱い
/// - GlobalConfigへの直接依存を排除
/// - テスト容易性の向上（モック可能）
abstract class PathResolver {
  /// ルートパス（基準となるディレクトリパス）
  String? get rootPath;
  
  /// パスセグメントから絶対パスを構築
  /// [segments] ルートからの相対パスセグメント（例: ["folder1", "file.gpkg"]）
  /// 戻り値: 絶対パス（ルートパスがnullの場合はnull）
  String? resolvePath(List<String> segments);
  
  /// このリゾルバがグローバルフォルダ用かどうか
  bool get isGlobal;

  // 2026-08-25: pathExists() / ensureDirectoryExists() を削除した。
  // どこからも呼ばれておらず、かつ同期のファイルI/O（existsSync/createSync）を
  // 持っていたため web に持ち込めない。必要になったら `fs`（KFileSystem）経由の
  // 非同期版として足すこと。
}

/// プロジェクトフォルダ用のパスリゾルバ
/// GlobalConfig.projectRootDirを基準にパスを解決
class ProjectPathResolver extends PathResolver {
  static final ProjectPathResolver _instance = ProjectPathResolver._();
  static ProjectPathResolver get instance => _instance;
  
  ProjectPathResolver._();
  
  String? Function()? _rootPathGetter;
  
  void setRootPathGetter(String? Function() getter) {
    _rootPathGetter = getter;
  }
  
  factory ProjectPathResolver({String? customRootPath}) {
    if (customRootPath != null) {
      return _CustomProjectPathResolver(customRootPath);
    }
    return _instance;
  }
  
  @override
  String? get rootPath => _rootPathGetter?.call();
  
  @override
  String? resolvePath(List<String> segments) {
    final root = rootPath;
    if (root == null) return null;
    if (segments.isEmpty) return root;
    return p.joinAll([root, ...segments]);
  }
  
  @override
  bool get isGlobal => false;
}

/// カスタムルートパスを持つプロジェクトパスリゾルバ（テスト用）
class _CustomProjectPathResolver extends ProjectPathResolver {
  final String _customRootPath;
  
  _CustomProjectPathResolver(this._customRootPath) : super._();
  
  @override
  String? get rootPath => _customRootPath;
}

/// グローバルフォルダ用のパスリゾルバ
/// GlobalConfig.globalFolderPathを基準にパスを解決
class GlobalPathResolver extends PathResolver {
  static final GlobalPathResolver _instance = GlobalPathResolver._();
  static GlobalPathResolver get instance => _instance;
  
  GlobalPathResolver._();
  
  String? Function()? _rootPathGetter;
  
  void setRootPathGetter(String? Function() getter) {
    _rootPathGetter = getter;
  }
  
  factory GlobalPathResolver({String? customRootPath}) {
    if (customRootPath != null) {
      return _CustomGlobalPathResolver(customRootPath);
    }
    return _instance;
  }
  
  @override
  String? get rootPath => _rootPathGetter?.call();
  
  @override
  String? resolvePath(List<String> segments) {
    final root = rootPath;
    if (root == null) return null;
    if (segments.isEmpty) return root;
    // segments はグローバルフォルダ（リゾルバの起点）からの相対。
    // 起点の名前は LayerTreeNode.getAbsolutePathSegments が落としてある
    return p.joinAll([root, ...segments]);
  }
  
  @override
  bool get isGlobal => true;
}

/// カスタムルートパスを持つグローバルパスリゾルバ（テスト用）
class _CustomGlobalPathResolver extends GlobalPathResolver {
  final String _customRootPath;
  
  _CustomGlobalPathResolver(this._customRootPath) : super._();
  
  @override
  String? get rootPath => _customRootPath;
}

/// パスリゾルバのファクトリ
/// ノードの種類に応じて適切なリゾルバを提供
class PathResolverFactory {
  PathResolverFactory._();
  
  /// プロジェクト用のリゾルバを取得
  static PathResolver get project => ProjectPathResolver.instance;
  
  /// グローバル用のリゾルバを取得
  static PathResolver get global => GlobalPathResolver.instance;
  
  /// isGlobalフラグに基づいてリゾルバを取得
  static PathResolver forGlobal(bool isGlobal) {
    return isGlobal ? global : project;
  }
}
