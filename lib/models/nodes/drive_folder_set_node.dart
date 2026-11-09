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

import '../../core/fs/k_file_system.dart';
import '../../core/node_types.dart';
import '../../core/path_resolver.dart';
import '../../services/google_drive/drive_dir_store.dart';
import '../../services/google_drive/drive_transfer_registry.dart';
import '../../services/kmeta_service.dart';
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

  /// 親セットから読み取り専用（`readOnly: true`）として指定されているか。
  /// true の場合、このセット配下の子フォルダ・孫セットもすべて読み取り専用になる。
  bool isReadOnly;

  DriveFolderSetNode(
    super.name, {
    required this.manifestFileId,
    required this.manifestUrl,
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

  /// 直下の物理サブフォルダ（子セットや旧構成フォルダ）に加え、
  /// フォルダ設定（`KMetaSync.setMembers`）に記録された参照メンバーを
  /// [DriveDirStore] 経由の [DirectPathResolver] でマウントして返す。
  @override
  Future<List<LayerTreeNode>> loadFolderNodes(List<KFileEntry> entries) async {
    final nodes = await super.loadFolderNodes(entries);
    final setPath = getAbsoluteFilePath();
    final meta = await getMeta();
    final members = meta.sync.setMembers;
    if (members.isEmpty) return nodes;

    final existingDriveIds = <String>{
      for (final n in nodes)
        if (n is DriveFolderNode)
          n.driveId
        else if (n is DriveFolderSetNode)
          n.manifestFileId,
    };
    final existingNames = <String>{for (final n in nodes) n.name};
    final searchRoots = <String>[
      if (setPath != null) p.dirname(setPath),
    ];

    for (final member in members) {
      if (member.driveId.isEmpty || existingDriveIds.contains(member.driveId)) {
        continue;
      }
      String? targetPath = member.targetPath;
      if (targetPath == null || !await fs.isDirectory(targetPath)) {
        targetPath = await DriveDirStore.instance.findExistingPath(
          member.driveId,
          searchRoots: searchRoots,
        );
      } else {
        await DriveDirStore.instance.register(member.driveId, targetPath);
      }
      if (targetPath == null || !await fs.isDirectory(targetPath)) {
        continue;
      }

      final targetMeta = await KMetaService.instance.getRawMeta(targetPath);
      final effectiveRo = isReadOnly ||
          member.isReadOnly ||
          (targetMeta?.sync.isReadOnly ?? false);

      var displayName =
          member.name.isNotEmpty ? member.name : p.basename(targetPath);
      if (existingNames.contains(displayName)) {
        var suffix = 2;
        while (existingNames.contains('$displayName $suffix')) {
          suffix++;
        }
        displayName = '$displayName $suffix';
      }
      existingNames.add(displayName);
      existingDriveIds.add(member.driveId);

      final node = DriveFolderNode(
        displayName,
        driveId: member.driveId,
        driveUrl: member.driveUrl.isNotEmpty
            ? member.driveUrl
            : (targetMeta?.sync.driveUrl ?? ''),
        isReadOnly: effectiveRo,
        lastSynced: targetMeta?.sync.lastSynced,
        driveRevisionId: targetMeta?.sync.driveRevisionId,
        visible: true,
        parent: this,
        children: [],
        pathResolver: DirectPathResolver(
          targetPath,
          isGlobal: isGlobalNode,
        ),
      );
      if (DriveTransferRegistry.instance.isBusy(targetPath)) {
        node.syncStatus = SyncStatus.syncing;
      } else if (await DriveTransferRegistry.instance.hasClonePending(targetPath)) {
        node.syncStatus = SyncStatus.remoteChanges;
      }
      nodes.add(node);
    }

    nodes.sort((a, b) => a.name.compareTo(b.name));
    return nodes;
  }
}
