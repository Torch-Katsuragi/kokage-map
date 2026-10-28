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
/// Root Maps: Drive同期関連ミックスイン
/// DriveSyncOperationsへの薄いラッパー
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/nodes/drive_folder_node.dart';
import '../../models/nodes/drive_folder_set_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../services/google_drive/drive_sync_operations.dart';
import '../../widgets/layer_drawer/sync_merge_dialog.dart';
import 'layer_drawer.dart';

mixin LayerDrawerDriveSync on ConsumerState<LayerDrawer> {
  void triggerMapRefresh();

  DriveSyncOperations? _syncOps;

  DriveSyncOperations get syncOps => _syncOps ??= DriveSyncOperations(
        ref: ref,
        onStateChanged: () => setState(() {}),
        onMapRefresh: triggerMapRefresh,
      );

  Future<void> refreshSyncStatus(DriveFolderNode node) =>
      syncOps.refreshSyncStatus(node);

  Future<void> openSyncMergeDialog(
    BuildContext context,
    DriveFolderNode node, {
    required SyncMode mode,
  }) =>
      syncOps.openSyncMergeDialog(context, node, mode: mode);

  Future<void> syncFolderSet(
    BuildContext context,
    DriveFolderSetNode node,
  ) =>
      syncOps.syncFolderSet(context, node);

  Future<void> unlinkDriveFolder(
          BuildContext context, FolderNode node) =>
      syncOps.unlinkDriveFolder(context, node);

  Future<void> deleteDriveFolder(
          BuildContext context, FolderNode node) =>
      syncOps.deleteDriveFolder(context, node);
}
