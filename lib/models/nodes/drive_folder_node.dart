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
import '../../services/global_folder_locator.dart';
import '../../services/google_drive/sync_base_store.dart';
import 'folder_node.dart';
import 'global_folder_node.dart';
import 'layer_tree_node.dart';

/// グローバルフォルダ内のノードのパスを解決するヘルパー
/// 親チェインにGlobalFolderNodeがあればそこからパスを構築、なければnull
String? _resolveGlobalPath(LayerTreeNode node) {
  final (global, segments) = segmentsBelowGlobalFolder(node);
  return global == null ? null : p.joinAll([global.globalPath, ...segments]);
}

/// Drive 連携フォルダ直下のサブフォルダ（[root] の同期情報を共有する）
List<LayerTreeNode> _driveSubFolders(
  FolderNode parent,
  DriveFolderNode root,
  List<KFileEntry> entries,
) {
  final directories = entries
      .where((e) => e.isDirectory && e.name != SyncBaseStore.dirName) // 3-way マージの base 置き場は見せない
      // アプリ用の `.kokage`（読み取り専用レイヤのキャッシュなど）は見せない。連携 dir がプロジェクトルートのとき直下にできる
      .where((e) => e.name != GlobalFolderLocator.systemDirName)
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return [
    for (final entity in directories)
      DriveSubFolderNode(
        entity.name,
        rootDriveNode: root,
        visible: true,
        parent: parent,
        children: [],
      ),
  ];
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

  /// グローバルフォルダ内の場合はグローバルパスから解決
  @override
  String? getAbsoluteFilePath() =>
      _resolveGlobalPath(this) ?? super.getAbsoluteFilePath();

  /// サブフォルダもDriveSubFolderNodeとして作成（同じdriveIdを共有）
  @override
  Future<List<LayerTreeNode>> loadFolderNodes(List<KFileEntry> entries) async =>
      _driveSubFolders(this, this, entries);
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

  /// 読み取り専用か
  bool get isReadOnly => rootDriveNode.isReadOnly;

  /// グローバルフォルダ内の場合はグローバルパスから解決
  @override
  String? getAbsoluteFilePath() =>
      _resolveGlobalPath(this) ?? super.getAbsoluteFilePath();

  @override
  Future<List<LayerTreeNode>> loadFolderNodes(List<KFileEntry> entries) async =>
      _driveSubFolders(this, rootDriveNode, entries);
}
