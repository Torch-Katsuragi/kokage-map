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
// Root Maps: Drive共有フォルダセット（JSONマニフェスト管理）ノードクラス
// Google Drive上のJSONファイルに記述されたDriveフォルダURLリストを追従管理するフォルダノード

import 'package:path/path.dart' as p;

import '../../core/node_types.dart';
import 'drive_folder_node.dart';
import 'folder_node.dart';
import 'global_folder_node.dart';
import 'layer_tree_node.dart';

/// Drive上のJSONマニフェストによって管理される共有フォルダセットノード
///
/// 自身はローカルの親フォルダ（例: `共有/<セット名>/`）に対応し、
/// 直下の子フォルダ群はそれぞれ個別の [DriveFolderNode] として構成される。
/// JSONマニフェストの更新に伴い、新規追加されたフォルダの自動クローンと、
/// リストから外れた（かつ未送信のローカル変更がない）フォルダの自動削除を行う。
class DriveFolderSetNode extends FolderNode {
  /// Drive上のJSONファイルID
  final String manifestFileId;

  /// 元のDrive共有URL
  final String manifestUrl;

  String get driveId => manifestFileId;
  String get driveUrl => manifestUrl;

  /// セット自体の同期状態
  SyncStatus syncStatus;

  /// 最終同期日時
  DateTime? lastSynced;

  /// Drive上のJSONファイルのMD5またはリビジョンID
  String? driveRevisionId;

  DriveFolderSetNode(
    super.name, {
    required this.manifestFileId,
    required this.manifestUrl,
    this.syncStatus = SyncStatus.unknown,
    this.lastSynced,
    this.driveRevisionId,
    super.visible,
    super.parent,
    super.children,
  });

  @override
  NodeType get nodeType => NodeType.folder;

  @override
  bool keepsChild(LayerTreeNode child) => false;

  /// グローバルフォルダ内の場合はグローバルパスから解決
  @override
  String? getAbsoluteFilePath() {
    final (global, segments) = segmentsBelowGlobalFolder(this);
    if (global != null) {
      return p.joinAll([global.globalPath, ...segments]);
    }
    return super.getAbsoluteFilePath();
  }
}
