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
/// フォルダの「ファイルを追加」とドラッグ＆ドロップ（どちらも同じ [_addFiles] を通る）
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/folder_node.dart';
import '../../presentation/node_presenter.dart';
import '../../providers/notification_providers.dart';
import '../../services/folder_file_adder.dart';
import '../../services/layer_drawer_service.dart';
import '../../utils/app_logger.dart';
import 'common_dialogs.dart';

/// [folder] にファイルを足してよいか（読み取り専用の Drive 共有の中には足さない）
bool canAddFilesTo(FolderNode folder) =>
    folder.getAbsoluteFilePath() != null && !(LayerDrawerService.findDriveRoot(folder)?.isReadOnly ?? false);

/// ファイルを選ばせて [folder] に写す（何でも・いくつでも）
Future<void> pickAndAddFiles(WidgetRef ref, FolderNode folder) async {
  if (!_checkWritable(ref, folder)) return;
  final List<PlatformFile> picked;
  try {
    picked = await FilePicker.pickFiles();
  } on Object catch (e) {
    AppLogger.error('[AddFiles] ファイル選択に失敗: $e');
    ref.notify(t.common.errorOccurred(error: '$e'), level: NotificationLevel.error);
    return;
  }
  if (picked.isEmpty) return;
  await _addFiles(ref, folder, [for (final f in picked) (name: f.name, read: f.readAsBytes)]);
}

/// 落とされたファイルを [folder] に写す（web のドラッグ＆ドロップ）。フォルダごと落とされたものは見ない
Future<void> addDroppedFiles(WidgetRef ref, FolderNode folder, List<DropItem> dropped) async {
  final files = dropped.where((f) => f is! DropItemDirectory).toList();
  if (files.isEmpty || !_checkWritable(ref, folder)) return;
  await _addFiles(ref, folder, [for (final f in files) (name: f.name, read: f.readAsBytes)]);
}

bool _checkWritable(WidgetRef ref, FolderNode folder) {
  if (canAddFilesTo(folder)) return true;
  ref.notify(t.layerDrawer.folder.filesAddReadOnly(folder: NodePresenter.getDisplayName(folder)),
      level: NotificationLevel.warning);
  return false;
}

Future<void> _addFiles(WidgetRef ref, FolderNode folder, List<IncomingFile> files) async {
  final dir = folder.getAbsoluteFilePath();
  if (dir == null) return;
  final notifier = ref.read(notificationCenterProvider.notifier);
  final folderName = NodePresenter.getDisplayName(folder);

  final missing = FolderFileAdder.shpMissingSidecars(files.map((f) => f.name));
  final AddFilesResult result;
  try {
    result = await FolderFileAdder.addTo(dir, files);
  } on Object catch (e) {
    AppLogger.error('[AddFiles] $dir への追加に失敗: $e');
    notifier.add(title: t.layerDrawer.folder.filesAddFailed(count: files.length), detail: '$e', level: NotificationLevel.error);
    return;
  }

  if (result.added.isNotEmpty) {
    try {
      await folder.updateChildren();
    } on Object catch (e) {
      AppLogger.error('[AddFiles] フォルダの読み直しに失敗: $e');
    }
    ref.refreshMap();
    notifier.add(
      title: t.layerDrawer.folder.filesAdded(folder: folderName, count: result.added.length),
      detail: result.added.join('\n'),
      level: NotificationLevel.success,
    );
  }
  if (result.failed.isNotEmpty) {
    for (final f in result.failed) {
      AppLogger.error('[AddFiles] ${f.name}: ${f.error}');
    }
    notifier.add(
      title: t.layerDrawer.folder.filesAddFailed(count: result.failed.length),
      detail: [for (final f in result.failed) '${f.name}: ${f.error}'].join('\n'),
      level: NotificationLevel.error,
    );
  }
  if (missing.isNotEmpty) {
    notifier.add(
      title: t.layerDrawer.folder.shpMissingSidecars(names: missing.join(', ')),
      detail: t.layerDrawer.folder.shpMissingSidecarsDetail,
      level: NotificationLevel.warning,
    );
  }
}
