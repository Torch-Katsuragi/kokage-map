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
import '../../../providers/notification_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../screens/layer_style_settings_screen.dart';
import '../../../tutorial/practice_project.dart';
import '../../../tutorial/tutorial.dart';
import '../common_dialogs.dart';
import '../drawer_row.dart';
import 'layer_swatch.dart';

/// Viewノード用 ListTile（可視切り替え・フィルタ編集・並べ替え）
class ViewTile extends ConsumerWidget {
  const ViewTile({super.key, required this.node, this.depth = 2});

  final ViewNode node;
  final int depth;

  LayerNode get _layer => node.layerNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dimmed = !node.isVisibleRecursive();
    final guiding = _guiding(ref);
    final index = _layer.views.indexOf(node);
    Widget row = DrawerRow(
      depth: depth,
      height: 40,
      dimmed: dimmed,
      leading: LayerSwatch(layer: _layer, view: node, dimmed: dimmed),
      title: node.displayName,
      titleStyle: const TextStyle(fontSize: 14),
      subtitle: node.hasFilter
          ? Text(
              node.filter!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: dimmed ? Colors.grey : Colors.teal.shade700),
            )
          : null,
      eye: KeyedSubtree(
        key: guiding ? TutorialTargets.newViewEye : null,
        child: VisibilityEye(
          visible: node.visible,
          effective: _layer.isVisibleRecursive(),
          onToggle: () async {
            node.visible = !node.visible;
            await node.persistVisibility();
            await node.layerNode.updateChildren();
            ref.read(featureRefreshTriggerProvider.notifier).trigger();
            ref.read(tutorialProvider.notifier).report(ViewVisibilityToggled(node));
          },
        ),
      ),
      menu: () => [
        RowMenuItem('rename', t.layerDrawer.view.rename, icon: Icons.edit),
        RowMenuItem('style', t.layerDrawer.layer.style, icon: Icons.palette, key: guiding ? TutorialTargets.viewStyleMenuItem : null),
        RowMenuItem('filter', t.layerDrawer.view.editFilter, icon: Icons.filter_alt),
        RowMenuItem('duplicate', t.layerDrawer.view.duplicate, icon: Icons.copy),
        if (index > 0) RowMenuItem('up', t.layerDrawer.view.moveUp, icon: Icons.arrow_upward),
        if (index >= 0 && index < _layer.views.length - 1) RowMenuItem('down', t.layerDrawer.view.moveDown, icon: Icons.arrow_downward),
        RowMenuItem('delete', t.layerDrawer.view.delete, icon: Icons.delete_outline, danger: true, dividerBefore: true),
      ],
      onMenu: (value) async {
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
    );
    if (guiding) row = KeyedSubtree(key: TutorialTargets.newViewMenu, child: row);
    return row;
  }

  /// チュートリアルの案内先: 練習のエリアに足した View（いちばん上の、既定でない View）
  bool _guiding(WidgetRef ref) =>
      ref.watch(tutorialProvider) != null &&
      !node.isDefaultView &&
      _layer.views.indexOf(node) == 0 &&
      isPracticeLayer(_layer, PracticeProject.areaLayer);

  // ---------- 操作 ----------

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final newName = await RenameDialog.show(
      context,
      title: t.layerDrawer.view.renameTitle,
      currentName: node.displayName,
      label: t.layerDrawer.view.viewName,
    );
    if (newName == null || newName.trim().isEmpty) return;
    var trimmed = newName.trim();
    if (trimmed == node.displayName) return;
    // レイヤと同じ名前にしたフィルタ無しの View は既定 View として持つ（QGIS からの読み戻しと同じ扱い）
    if (trimmed == _layer.layerName && !node.hasFilter) trimmed = kDefaultViewName;

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
              // 既定 View の見え方はレイヤのスタイルそのもの（既定 View にはスタイルを持たせない）
              targetView: node.isDefaultView ? null : node,
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
    final base = node.displayName;
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
              t.layerDrawer.view.deleteConfirm(name: node.displayName),
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
