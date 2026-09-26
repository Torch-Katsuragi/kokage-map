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
// Root Maps: 「System」（sys）ノード
// プロジェクトに属さない、端末側の層をまとめる仮想フォルダ。
// 仕様は [[docs/features/layer-management#System（sys）]]

import '../kmeta.dart';
import 'folder_node.dart';
import 'global_folder_node.dart';
import 'layer_tree_node.dart';

/// 「System」（sys）
///
/// - ツリーのルート直下に 1 つだけ置く。**実体ディレクトリは無い**
/// - 子は `global`（[GlobalFolderNode]）だけ。将来 `view`（端末の写真など読み取り専用）が入る
/// - プロジェクトの Drive 同期・`.qgs` の対象外。リネーム・削除・ドラッグ・Drive 連携もしない
///
/// > [!NOTE] FolderNode を継承している理由
/// > 可視性の連鎖・ツリーの再帰更新・読み戻しの再帰など「フォルダとして辿る」処理を
/// > そのまま通すため。パスを持たない（[getAbsoluteFilePath] が null）ので、
/// > 追加・移動・Drive 連携の入口は「パスが解決できない」で自然に閉じる。
///
/// > [!IMPORTANT] 表示の可視性はプロジェクトルートの `.kmeta.json` に置く
/// > sys 自身は `folders['<sys>']`、global は**従来どおり** `folders['Global']`。
/// > global がルート直下にあった頃の保存値をそのまま引き継ぐため（鍵を変えない）。
class SysNode extends FolderNode {
  /// ノード名（＝ルートの `.kmeta.json` での可視性の鍵）。
  ///
  /// ⚠ ファイル名に使えない `<` `>` を含めてある。プロジェクト直下に同名の実フォルダが
  /// あると `addChildIfNotExists` が名前で取り違えるため。表示名は
  /// `NodePresenter.getDisplayName` が i18n で出す。
  static const String nodeName = '<sys>';

  SysNode({super.visible, super.parent, super.children}) : super(nodeName);

  /// 可視性を読み書きする先（プロジェクトルート）。無ければ null
  FolderNode? get _host => parent is FolderNode ? parent as FolderNode : null;

  /// 実体ディレクトリは無い
  @override
  String? getAbsoluteFilePath() => null;

  /// 子（global）の可視性はプロジェクトルートの `.kmeta.json` に書く
  @override
  String? get visibilityMetaPath => _host?.getAbsoluteFilePath();

  /// 子の可視性を読むのもプロジェクトルートの `.kmeta.json`
  @override
  Future<KMeta> getMeta() async => await _host?.getMeta() ?? KMeta.empty;

  /// sys 自身のメタは無い（ルートのメタを返すと Drive 連携などを取り違える）
  @override
  Future<KMeta?> getRawMeta() async => null;

  @override
  void invalidateMetaCache() {
    super.invalidateMetaCache();
    _host?.invalidateMetaCache();
  }

  /// 子はファイルシステムから作らない（home_screen が差し込む）。可視性だけ当て直す
  @override
  Future<void> updateChildren() async {
    invalidateMetaCache();
    await applyMetaVisibility();
  }

  /// 配下のグローバルフォルダ（無ければ null。web では作らない）
  GlobalFolderNode? get globalFolder =>
      children.whereType<GlobalFolderNode>().firstOrNull;

  /// [root] 直下の sys を返す。無ければ作って先頭に差し込む
  static SysNode ensureIn(LayerTreeNode root) {
    final existing = root.children.whereType<SysNode>().firstOrNull;
    if (existing != null) return existing;
    final sys = SysNode(parent: root, children: []);
    root.children.insert(0, sys);
    return sys;
  }

  /// [root] の sys の下にグローバルフォルダを置く（sys が無ければ作る）。
  ///
  /// ルート直下に旧配置のグローバルフォルダが残っていれば外す。
  static SysNode attachGlobalFolder(LayerTreeNode root, GlobalFolderNode global) {
    root.children.removeWhere((c) {
      if (c is! GlobalFolderNode) return false;
      c.parent = null;
      return true;
    });
    return ensureIn(root)..setGlobalFolder(global);
  }

  /// sys の下のグローバルフォルダを [global] に差し替える
  void setGlobalFolder(GlobalFolderNode global) {
    children.removeWhere((c) {
      if (c is! GlobalFolderNode) return false;
      c.parent = null;
      return true;
    });
    global.parent = this;
    children.insert(0, global);
  }
}
