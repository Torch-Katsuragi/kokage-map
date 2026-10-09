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
// 読み取り専用レイヤ（shp・GeoJSON など）の編集の門番と、gpkg への変換・複製の UI
// 設計は docs/technical/external-formats.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:path/path.dart' as p;

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/external_layer_node.dart';
import '../models/nodes/folder_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/sys_node.dart';
import '../presentation/node_presenter.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/external/external_layer_converter.dart';
import '../services/layer_drawer_service.dart';
import '../utils/app_logger.dart';
import 'layer_drawer/drawer_row.dart';

/// [node]（レイヤ・View・地物・gpkg）を含む読み取り専用レイヤ。無ければ null
ExternalLayerNode? readOnlyLayerOf(LayerTreeNode? node) =>
    node is ExternalLayerNode ? node : node?.ancestorOf<ExternalLayerNode>();

/// [node] が読み取り専用レイヤの中なら「gpkg に変換して編集」つきで通知して true（呼び手は編集をやめる）。
///
/// [onChanged] は変換・複製でツリーが変わったあとに呼ぶ（地図とツリーの描き直し）
bool refuseReadOnlyEdit(NotificationCenter center, LayerTreeNode? node, {VoidCallback? onChanged}) {
  final external = readOnlyLayerOf(node);
  if (external == null) return false;
  center.add(
    title: t.externalLayer.readOnly(name: external.name),
    detail: t.externalLayer.readOnlyDetail,
    level: NotificationLevel.warning,
    actionLabel: t.externalLayer.convertAction,
    onAction: () => convertExternalLayer(center, external, onChanged: onChanged),
  );
  return true;
}

/// [refuseReadOnlyEdit] の ref 版（`ref.read` を渡す。WidgetRef でも Ref でもよい）。変換したら地図を描き直す
bool refuseReadOnlyEditBy(T Function<T>(ProviderListenable<T> provider) read, LayerTreeNode? node) =>
    refuseReadOnlyEdit(
      read(notificationCenterProvider.notifier),
      node,
      onChanged: () => read(featureRefreshTriggerProvider.notifier).trigger(),
    );

/// 変換の確認ダイアログ（何を消すかを見せる）。やめたら false
Future<bool> confirmConvertExternalLayer(BuildContext context, ExternalLayerNode node) async {
  final files = (await node.sourceFiles()).map(p.basename).join('、');
  final target = await ExternalLayerConverter.uniqueGpkgPath(
    p.dirname(node.sourcePath),
    p.basenameWithoutExtension(node.sourcePath),
  );
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.externalLayer.convertTitle),
      content: Text(t.externalLayer.convertConfirm(name: node.name, target: p.basename(target), files: files)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.externalLayer.convertTitle)),
      ],
    ),
  );
  return ok ?? false;
}

/// [node] を gpkg に変換し、結果を通知する。置き換えられない場所なら「自分のフォルダに gpkg として複製」を勧める
Future<void> convertExternalLayer(
  NotificationCenter center,
  ExternalLayerNode node, {
  VoidCallback? onChanged,
  BuildContext? context,
}) async {
  try {
    final result = await ExternalLayerConverter.convert(node);
    switch (result.outcome) {
      case ExternalConvertOutcome.converted:
        center.add(
          title: t.externalLayer.converted(name: node.name, target: p.basename(result.gpkgPath!)),
          level: NotificationLevel.success,
        );
        if (result.leftovers.isNotEmpty) {
          center.add(
            title: t.externalLayer.leftovers(files: result.leftovers.map(p.basename).join('、')),
            level: NotificationLevel.warning,
          );
        }
        onChanged?.call();
      case ExternalConvertOutcome.readOnlyFolder || ExternalConvertOutcome.deleteFailed:
        center.add(
          title: result.outcome == ExternalConvertOutcome.readOnlyFolder
              ? t.externalLayer.readOnlyFolder
              : t.externalLayer.deleteFailed,
          level: NotificationLevel.warning,
          actionLabel: t.externalLayer.copyAction,
          onAction: () async {
            final ctx = context;
            await copyExternalLayer(center, node, context: ctx != null && ctx.mounted ? ctx : null, onChanged: onChanged);
          },
        );
      case ExternalConvertOutcome.copied:
        onChanged?.call();
    }
  } on ExternalConvertVerifyException catch (e) {
    AppLogger.debug('[ExternalLayer] 変換をやめた: $e');
    center.add(title: t.externalLayer.verifyFailed, detail: e.detail, level: NotificationLevel.error);
  } catch (e) {
    AppLogger.debug('[ExternalLayer] 変換に失敗: $e');
    center.add(title: t.externalLayer.convertFailed(error: e.toString()), level: NotificationLevel.error);
  }
}

/// 複製先にできるフォルダ（読み取り専用の Drive フォルダと「System」以外）
bool _isWritableFolder(LayerTreeNode n) =>
    n is FolderNode && n is! SysNode && !(LayerDrawerService.findDriveRoot(n)?.isReadOnly ?? false);

/// [node] を自分のフォルダへ gpkg として複製する（元は残す）。
/// [context] があれば複製先を選ばせ、無ければプロジェクトのルートへ
Future<void> copyExternalLayer(
  NotificationCenter center,
  ExternalLayerNode node, {
  BuildContext? context,
  VoidCallback? onChanged,
}) async {
  LayerTreeNode root = node;
  while (root.parent != null) {
    root = root.parent!;
  }
  FolderNode? target;
  if (context != null && context.mounted) {
    target = await _pickWritableFolder(context, node, root);
    if (target == null) return; // やめた
  } else if (_isWritableFolder(root)) {
    target = root as FolderNode;
  }
  if (target == null) {
    center.add(title: t.externalLayer.noWritableFolder, level: NotificationLevel.warning);
    return;
  }
  try {
    final result = await ExternalLayerConverter.copyAsGeoPackage(node, target);
    center.add(
      title: t.externalLayer.copied(name: node.name, target: p.basename(result.gpkgPath!)),
      level: NotificationLevel.success,
    );
    onChanged?.call();
  } on ExternalConvertVerifyException catch (e) {
    center.add(title: t.externalLayer.verifyFailed, detail: e.detail, level: NotificationLevel.error);
  } catch (e) {
    center.add(title: t.externalLayer.convertFailed(error: e.toString()), level: NotificationLevel.error);
  }
}

Future<FolderNode?> _pickWritableFolder(BuildContext context, ExternalLayerNode node, LayerTreeNode root) {
  final targets = <(FolderNode, int)>[];
  void walk(LayerTreeNode n, int depth) {
    if (n is SysNode) return;
    if (n is FolderNode) {
      if (_isWritableFolder(n)) targets.add((n, depth));
      for (final c in n.children) {
        walk(c, depth + 1);
      }
    }
  }

  walk(root, 0);
  return showDialog<FolderNode>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.externalLayer.copyTitle(name: node.name)),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: 360,
        height: 420,
        child: targets.isEmpty
            ? Center(child: Text(t.externalLayer.noWritableFolder))
            : ListView(
                children: [
                  for (final (n, depth) in targets)
                    DrawerRow(
                      depth: depth,
                      height: 44,
                      leading: Icon(NodePresenter.getIcon(n), size: 20, color: NodePresenter.getColor(n)),
                      title: NodePresenter.getDisplayName(n),
                      onTap: () => Navigator.pop(context, n),
                    ),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel))],
    ),
  );
}
