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
/// Root Maps: LayerDrawer用タイトルバーウィジェット
library;

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/global_folder_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../presentation/node_presenter.dart';

enum AddAction { folder, geoPackage, photo }

/// 濃グレーのタイトルパネル（currentNodeの名前を表示＋右側に統合追加ボタン）
/// Drive連携フォルダ配下ではクラウドカラー背景＋同期UIを表示
class LayerDrawerTitleBar extends StatelessWidget {
  final String title;
  final LayerTreeNode currentNode;
  final void Function(AddAction action)? onAdd;
  final void Function()? onBack;

  /// Drive同期関連（null なら非表示）
  final SyncStatus? syncStatus;
  final void Function(String action)? onCloudAction;
  final bool isReadOnly;

  const LayerDrawerTitleBar({
    super.key,
    required this.title,
    required this.currentNode,
    this.onAdd,
    this.onBack,
    this.syncStatus,
    this.onCloudAction,
    this.isReadOnly = false,
  });

  bool get _isUnderDriveFolder {
    LayerTreeNode? node = currentNode;
    while (node != null) {
      if (node is DriveFolderNode) return true;
      if (node is GlobalFolderNode) return false;
      node = node.parent;
    }
    return false;
  }

  (String, Color) get _syncLabel => switch (syncStatus) {
        SyncStatus.synced => (t.layerDrawer.titleBar.syncedLabel, Colors.greenAccent),
        SyncStatus.localChanges => (t.layerDrawer.titleBar.localChangesLabel, Colors.orangeAccent),
        SyncStatus.remoteChanges => (t.layerDrawer.titleBar.remoteChangesLabel, Colors.lightBlueAccent),
        SyncStatus.conflict => (t.layerDrawer.titleBar.conflictLabel, Colors.redAccent),
        SyncStatus.syncing => (t.layerDrawer.titleBar.syncingLabel, Colors.lightBlueAccent),
        SyncStatus.error => (t.layerDrawer.titleBar.errorLabel, Colors.redAccent),
        SyncStatus.unknown => (t.layerDrawer.titleBar.driveLinkedLabel, Colors.white70),
        null => ('', Colors.white70),
      };

  static const _buttonDecoration = BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );

  @override
  Widget build(BuildContext context) {
    final isDrive = _isUnderDriveFolder;
    final bgColor = isDrive ? cloudColor : const Color(0xFF424242);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      color: bgColor,
      child: Row(
        children: [
          if (onBack != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton(
                icon: const Icon(
                  Icons.arrow_back_ios_new,
                  color: Colors.white,
                  size: 20,
                ),
                tooltip: t.layerDrawer.titleBar.goUp,
                onPressed: onBack,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ),
          Expanded(child: _buildTitle(isDrive)),
          if (currentNode is DriveFolderNode && onCloudAction != null)
            _buildCloudButton(),
          if (currentNode is FolderNode && onAdd != null) ...[
            if (currentNode is DriveFolderNode && onCloudAction != null)
              const SizedBox(width: 8),
            _buildAddButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildTitle(bool isDrive) {
    final showSyncLabel = currentNode is DriveFolderNode && syncStatus != null;
    if (!showSyncLabel) {
      return Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        overflow: TextOverflow.ellipsis,
      );
    }
    final (label, _) = _syncLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black87)),
      ],
    );
  }

  Widget _buildCloudButton() {
    final iconData = switch (syncStatus) {
      SyncStatus.syncing => Icons.cloud_sync,
      SyncStatus.error => Icons.cloud_off,
      _ => Icons.cloud,
    };

    return PopupMenuButton<String>(
      tooltip: t.layerDrawer.titleBar.driveSync,
      onSelected: onCloudAction,
      offset: const Offset(0, 40),
      child: Container(
        width: 34,
        height: 34,
        decoration: _buttonDecoration,
        child: Icon(iconData, color: Colors.black, size: 20),
      ),
      itemBuilder: (_) => [
        if (!isReadOnly)
          PopupMenuItem(
            value: 'upload',
            child: Row(children: [
              const Icon(Icons.cloud_upload, color: Colors.orange),
              const SizedBox(width: 12),
              Text(t.layerDrawer.folder.upload),
            ]),
          ),
        PopupMenuItem(
          value: 'download',
          child: Row(children: [
            const Icon(Icons.cloud_download, color: Colors.green),
            const SizedBox(width: 12),
            Text(t.layerDrawer.folder.download),
          ]),
        ),
        PopupMenuItem(
          value: 'refresh',
          child: Row(children: [
            const Icon(Icons.refresh, color: Colors.blue),
            const SizedBox(width: 12),
            Text(t.layerDrawer.folder.refreshStatus),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'unlink',
          child: Row(children: [
            const Icon(Icons.link_off, color: Colors.red),
            const SizedBox(width: 12),
            Text(t.layerDrawer.folder.unlinkDrive),
          ]),
        ),
      ],
    );
  }

  Widget _buildAddButton() {
    return PopupMenuButton<AddAction>(
      tooltip: 'Add',
      onSelected: onAdd,
      offset: const Offset(0, 40),
      child: Container(
        width: 34,
        height: 34,
        decoration: _buttonDecoration,
        child: const Icon(Icons.add, color: Colors.black, size: 22),
      ),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: AddAction.folder,
          child: Row(children: [
            const Icon(Icons.folder, color: Colors.amber),
            const SizedBox(width: 12),
            Text(t.layerDrawer.titleBar.addFolder),
          ]),
        ),
        PopupMenuItem(
          value: AddAction.geoPackage,
          child: Row(children: [
            const Icon(Icons.storage, color: Color(0xFF90A4AE)),
            const SizedBox(width: 12),
            Text(t.layerDrawer.titleBar.addGeoPackage),
          ]),
        ),
        PopupMenuItem(
          value: AddAction.photo,
          child: Row(children: [
            const Icon(Icons.photo_library, color: Colors.blue),
            const SizedBox(width: 12),
            Text(t.layerDrawer.titleBar.addPhotos),
          ]),
        ),
      ],
    );
  }
}
