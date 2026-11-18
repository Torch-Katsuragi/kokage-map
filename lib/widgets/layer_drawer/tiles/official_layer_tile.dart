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

/// `System`（`sys`）内に並ぶ公式データレイヤの 1 行と、公式データ追加ボトムシート。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/official/official_data_catalog.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../models/nodes/layer_tree_node.dart';
import '../../../models/nodes/official_layer_node.dart';
import '../../../providers/selection_providers.dart';
import '../../../services/official/official_layer_service.dart';
import '../common_dialogs.dart';
import '../drawer_row.dart';

/// `System` の下に表示する公式データレイヤの行
class OfficialLayerTile extends ConsumerWidget {
  const OfficialLayerTile({
    super.key,
    required this.node,
    required this.rootNode,
  });

  final OfficialLayerNode node;
  final LayerTreeNode? rootNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dimmed = !node.isVisibleRecursive();
    final spec = node.spec;
    return DrawerRow(
      dimmed: dimmed,
      leading: Icon(
        spec.icon,
        size: 20,
        color: dimmed ? Colors.black26 : spec.accentColor,
      ),
      title: OfficialLayerNode.displayNameOf(spec),
      trailingInfo: t.officialLayer.badge,
      subtitle: Text(
        spec.minDisplayZoom >= 10
            ? '${t.officialLayer.zoomHint(zoom: spec.minDisplayZoom)} · ${spec.attribution}'
            : spec.attribution,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      eye: nodeVisibilityEye(ref, node),
      menu: () => [
        RowMenuItem(
          'remove',
          t.officialLayer.remove,
          icon: Icons.remove_circle_outline,
          danger: true,
        ),
      ],
      onMenu: (value) async {
        if (value == 'remove') {
          final name = OfficialLayerNode.displayNameOf(spec);
          // 選択中の擬似フィーチャがあれば外す
          ref.read(selectedFeaturesProvider.notifier).set(
            ref
                .read(selectedFeaturesProvider)
                .where((f) => f is! OfficialFeatureNode || f.spec.id != spec.id)
                .toList(),
          );
          await OfficialLayerService.instance.removeLayer(spec.id, root: rootNode);
          ref.refreshMap();
          ref.notify(t.officialLayer.removed(name: name));
        }
      },
    );
  }
}

/// `System`（`sys`）の中で「公式データを追加」ボトムシートを開く
Future<void> showAddOfficialLayerSheet(
  BuildContext context,
  WidgetRef ref, {
  required LayerTreeNode? rootNode,
}) async {
  final svc = OfficialLayerService.instance;
  await svc.ensureInitialized();
  if (!context.mounted) return;
  final enabled = svc.enabledIds.toSet();

  final picked = await showModalBottomSheet<OfficialLayerSpec>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              t.officialLayer.addTitle,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              t.officialLayer.addHint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          for (final spec in OfficialLayerSpec.catalog)
            ListTile(
              leading: Icon(
                spec.icon,
                color: enabled.contains(spec.id) ? Colors.grey : spec.accentColor,
              ),
              title: Text(OfficialLayerNode.displayNameOf(spec)),
              subtitle: Text(
                [
                  OfficialLayerNode.descriptionOf(spec),
                  '${t.officialLayer.sourceLabel}${spec.attribution}',
                ].join('\n'),
              ),
              isThreeLine: true,
              trailing: enabled.contains(spec.id)
                  ? Text(
                      t.officialLayer.alreadyAdded,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    )
                  : const Icon(Icons.add_circle_outline),
              enabled: !enabled.contains(spec.id),
              onTap: () => Navigator.of(sheetContext).pop(spec),
            ),
        ],
      ),
    ),
  );

  if (picked == null || !context.mounted) return;
  await svc.addLayer(picked.id, root: rootNode);
  ref.refreshMap();
  ref.notify(
    t.officialLayer.added(name: OfficialLayerNode.displayNameOf(picked)),
    level: NotificationLevel.success,
  );
}
