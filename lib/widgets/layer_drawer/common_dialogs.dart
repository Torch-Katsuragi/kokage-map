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
/// Root Maps: LayerDrawer 共通ダイアログヘルパー
/// 確認ダイアログ+操作+通知パターン / リネームダイアログ / 行の共通の操作（目・通知・地図の描き直し）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../providers/notification_providers.dart';
import '../../providers/selection_providers.dart';
import '../../providers/ui_state_providers.dart';
import 'drawer_row.dart';

/// 共通リネームダイアログ（バリデーション・Enter送信付き）
class RenameDialog {
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String currentName,
    String? label,
    String? hint,
    String submitLabel = '',
    String? helperText,
    bool allowEmpty = false,
  }) {
    final effectiveSubmitLabel = submitLabel.isEmpty ? t.layerDrawer.submitRename : submitLabel;
    final controller = TextEditingController(text: currentName);
    final formKey = GlobalKey<FormState>();

    return showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(title),
            content: Form(
              key: formKey,
              child: TextFormField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  helperText: helperText,
                  helperMaxLines: 3,
                ),
                // [allowEmpty] は「空 = 未設定」に意味がある入力用
                // （View のフィルタなど）。名前系は従来どおり空を弾く。
                validator:
                    (v) =>
                        (!allowEmpty && (v == null || v.trim().isEmpty))
                            ? t.common.nameCannotBeEmpty
                            : null,
                onFieldSubmitted: (_) {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.pop(context, controller.text.trim());
                  }
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.common.cancel),
              ),
              TextButton(
                onPressed: () {
                  if (formKey.currentState?.validate() ?? false) {
                    Navigator.pop(context, controller.text.trim());
                  }
                },
                child: Text(effectiveSubmitLabel),
              ),
            ],
          ),
    );
  }
}

/// 確かめるダイアログ。[confirmLabel] を押したら true（やめた・外を押したら false）
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required Widget content,
  required String confirmLabel,
  Color? confirmColor,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: Text(title),
          content: content,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style:
                  confirmColor != null
                      ? TextButton.styleFrom(foregroundColor: confirmColor)
                      : null,
              child: Text(confirmLabel),
            ),
          ],
        ),
  );
  return confirmed == true;
}

/// 確認ダイアログ → 操作実行 → 通知の共通パターン
/// [execute] が例外を投げた場合はエラー通知を表示して false を返す
Future<bool> confirmAndExecute(
  BuildContext context, {
  required String title,
  required Widget content,
  required Future<void> Function() execute,
  String? successMessage,
  String confirmLabel = '',
  Color? confirmColor,
  WidgetRef? ref,
}) async {
  final confirmed = await showConfirmDialog(
    context,
    title: title,
    content: content,
    confirmLabel: confirmLabel.isEmpty ? t.common.execute : confirmLabel,
    confirmColor: confirmColor,
  );
  if (!confirmed) return false;

  try {
    await execute();
    if (successMessage != null) ref?.notify(successMessage, level: NotificationLevel.success);
    return true;
  } catch (e) {
    ref?.notify(t.layerDrawer.errorPrefix(error: e.toString()), level: NotificationLevel.error);
    return false;
  }
}

/// レイヤ一覧の操作で共通に使う ref の小道具
extension DrawerRef on WidgetRef {
  /// 地図を描き直す（ノードを書き換えたあと）
  void refreshMap() => read(featureRefreshTriggerProvider.notifier).trigger();

  /// 通知センターに出す
  void notify(String title, {NotificationLevel level = NotificationLevel.info}) =>
      read(notificationCenterProvider.notifier).add(title: title, level: level);

  /// [layer] を選択から外し、その地物も選択から外す（消す前に）
  void deselectLayer(LayerNode layer) {
    if (read(selectedLayerNodeProvider) == layer) {
      read(selectedLayerNodeProvider.notifier).select(null);
    }
    read(selectedFeaturesProvider.notifier).set(
      read(selectedFeaturesProvider).where((f) => f is! FeatureNode || f.parent != layer).toList(),
    );
  }
}

/// ノードの表示/非表示の目。押すと切り替えて保存し、地図を描き直す（そのあと [onToggled]）
Widget nodeVisibilityEye(WidgetRef ref, LayerTreeNode node, {VoidCallback? onToggled}) {
  return VisibilityEye(
    visible: node.visible,
    effective: node.parent?.isVisibleRecursive() ?? true,
    onToggle: () {
      node.visible = !node.visible;
      node.persistVisibility();
      ref.refreshMap();
      onToggled?.call();
    },
  );
}
