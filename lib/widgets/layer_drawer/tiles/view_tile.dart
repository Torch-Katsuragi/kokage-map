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
/// Root Maps: Viewタイル（レイヤの下の「見せ方」）
///
/// 並べ替えは**同一レイヤ内でのみ**許す。ドラッグではなくメニューの
/// 「上へ／下へ」にしてあるのは、レイヤをまたぐドラッグを物理的に不可能に
/// しておきたいから（dir構造の拘束が z順の根拠になっている）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/view_node.dart';
import '../../../presentation/node_presenter.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../screens/layer_style_settings_screen.dart';
import '../../../tutorial/practice_project.dart';
import '../../../tutorial/tutorial.dart';
import '../common_dialogs.dart';

/// Viewノード用 ListTile（可視切り替え・フィルタ編集・並べ替え）
class ViewTile extends ConsumerWidget {
  const ViewTile({super.key, required this.node});

  final ViewNode node;

  LayerNode get _layer => node.layerNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dimmed = !node.isVisibleRecursive();
    final guiding = ref.watch(tutorialProvider) != null;
    return ListTile(
      key: guiding && _layer.views.indexOf(node) == 0 && isPracticeLayer(_layer, PracticeProject.areaLayer)
          ? TutorialTargets.areaViewRow
          : null,
      dense: true,
      contentPadding: const EdgeInsets.only(left: 56, right: 8),
      leading: _VisibilityIcon(node: node),
      title: Text(
        node.name,
        style: TextStyle(
          fontSize: 13,
          color: dimmed ? Colors.grey : null,
        ),
      ),
      subtitle:
          node.hasFilter
              ? Text(
                node.filter!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: dimmed ? Colors.grey : Colors.teal.shade700,
                ),
              )
              : null,
      trailing: _buildMenu(context, ref),
    );
  }

  Widget _buildMenu(BuildContext context, WidgetRef ref) {
    final index = _layer.views.indexOf(node);
    // チュートリアルの案内先: 練習のエリアの最初の View の ⋮
    final guiding = ref.watch(tutorialProvider) != null;
    final menuKey = guiding && index == 0 && isPracticeLayer(_layer, PracticeProject.areaLayer)
        ? TutorialTargets.areaViewMenu
        : null;
    return PopupMenuButton<String>(
      key: menuKey,
      iconSize: 18,
      onSelected: (value) async {
        switch (value) {
          case 'rename':
            await _rename(context, ref);
          case 'style':
            await _openStyle(context, ref);
          case 'filter':
            await _editFilter(context, ref);
          case 'duplicate':
            await _duplicate(ref);
          case 'delete':
            await _delete(context, ref);
          case 'up':
            await _move(ref, -1);
          case 'down':
            await _move(ref, 1);
        }
      },
      itemBuilder:
          (context) => [
            PopupMenuItem(value: 'rename', child: Text(t.layerDrawer.view.rename)),
            PopupMenuItem(
              key: menuKey != null ? TutorialTargets.styleMenuItem : null,
              value: 'style',
              child: Text(t.layerDrawer.layer.style),
            ),
            PopupMenuItem(
              value: 'filter',
              child: Text(t.layerDrawer.view.editFilter),
            ),
            PopupMenuItem(
              value: 'duplicate',
              child: Text(t.layerDrawer.view.duplicate),
            ),
            if (index > 0)
              PopupMenuItem(value: 'up', child: Text(t.layerDrawer.view.moveUp)),
            if (index >= 0 && index < _layer.views.length - 1)
              PopupMenuItem(
                value: 'down',
                child: Text(t.layerDrawer.view.moveDown),
              ),
            PopupMenuItem(value: 'delete', child: Text(t.layerDrawer.view.delete)),
          ],
    );
  }

  // ---------- 操作 ----------

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final newName = await RenameDialog.show(
      context,
      title: t.layerDrawer.view.renameTitle,
      currentName: node.name,
      label: t.layerDrawer.view.viewName,
    );
    if (newName == null || newName.trim().isEmpty) return;
    final trimmed = newName.trim();
    if (trimmed == node.name) return;

    if (_layer.views.any((v) => v != node && v.name == trimmed)) {
      _notify(ref, t.layerDrawer.view.nameDuplicate, NotificationLevel.warning);
      return;
    }
    node.name = trimmed;
    await _persist(ref, reloadFeatures: false);
  }

  /// この View の見た目を編集する。
  ///
  /// レイヤ用の画面をそのまま使う（`targetView` を渡すと保存先だけ変わる）。
  Future<void> _openStyle(BuildContext context, WidgetRef ref) async {
    final folderPath = _layer.folderNode?.getAbsoluteFilePath();
    if (folderPath == null) {
      _notify(
        ref,
        t.layerDrawer.layer.couldNotDetermineFolder,
        NotificationLevel.error,
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => LayerStyleSettingsScreen(
              targetLayer: _layer,
              folderPath: folderPath,
              // 既定 View 1 枚だけのレイヤは View を書かない（＝スタイルはレイヤが持つ）ので、レイヤのスタイルとして開く
              targetView: _layer.views.length == 1 && node.isDefaultView ? null : node,
            ),
      ),
    );
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
  }

  Future<void> _editFilter(BuildContext context, WidgetRef ref) async {
    final result = await RenameDialog.show(
      context,
      title: t.layerDrawer.view.filterTitle,
      currentName: node.filter ?? '',
      label: t.layerDrawer.view.filterTitle,
      hint: t.layerDrawer.view.filterHint,
      helperText: t.layerDrawer.view.filterHelp,
      allowEmpty: true,
    );
    if (result == null) return;
    final trimmed = result.trim();
    node.filter = trimmed.isEmpty ? null : trimmed;
    // フィルタが変わると出すフィーチャが変わる → 読み直しが要る
    await _persist(ref, reloadFeatures: true);
  }

  Future<void> _duplicate(WidgetRef ref) async {
    final base = node.name;
    var name = '$base 2';
    var n = 2;
    while (_layer.views.any((v) => v.name == name)) {
      n++;
      name = '$base $n';
    }
    final copy = ViewNode(
      name: name,
      parent: _layer,
      filter: node.filter,
      style: node.style,
      visible: node.visible,
    );
    _layer.views.insert(_layer.views.indexOf(node) + 1, copy);
    await _persist(ref, reloadFeatures: false);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    if (_layer.views.length <= 1) {
      _notify(
        ref,
        t.layerDrawer.view.cannotDeleteLast,
        NotificationLevel.warning,
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(t.layerDrawer.view.delete),
            content: Text(
              t.layerDrawer.view.deleteConfirm(name: node.name),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(t.common.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(t.layerDrawer.view.delete),
              ),
            ],
          ),
    );
    if (ok != true) return;
    _layer.views.remove(node);
    await _persist(ref, reloadFeatures: true);
  }

  Future<void> _move(WidgetRef ref, int delta) async {
    final index = _layer.views.indexOf(node);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= _layer.views.length) return;
    _layer.views
      ..removeAt(index)
      ..insert(target, node);
    // z順はまだ描画に効かない（段4b）。並びだけ保存しておく。
    await _persist(ref, reloadFeatures: false);
  }

  Future<void> _persist(WidgetRef ref, {required bool reloadFeatures}) async {
    await _layer.persistViews();
    if (reloadFeatures) await _layer.updateChildren();
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
  }

  void _notify(WidgetRef ref, String title, NotificationLevel level) {
    ref.read(notificationCenterProvider.notifier).add(title: title, level: level);
  }
}

/// View の可視トグル。
///
/// [NodeVisibilityIcon] を使い回さないのは、View を切り替えたとき
/// **フィーチャの読み直しが要る**（WHERE句が変わる）ため。
class _VisibilityIcon extends ConsumerWidget {
  const _VisibilityIcon({required this.node});

  final ViewNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () async {
        node.visible = !node.visible;
        await node.persistVisibility();
        await node.layerNode.updateChildren();
        ref.read(featureRefreshTriggerProvider.notifier).trigger();
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            NodePresenter.getIcon(node),
            size: 18,
            color:
                node.isVisibleRecursive()
                    ? NodePresenter.getColor(node)
                    : Colors.grey,
          ),
          if (!node.visible)
            Transform.rotate(
              angle: -0.7,
              child: Container(width: 22, height: 3, color: Colors.grey),
            ),
        ],
      ),
    );
  }
}
