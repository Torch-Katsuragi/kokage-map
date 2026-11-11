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
/// 背景地図レイヤ追加ボトムシートと独自タイル（XYZ / WMS URL）追加・削除操作
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/basemap_layer.dart';
import '../../models/basemap_provider.dart';
import '../../services/basemap_service.dart';
import '../../tutorial/tutorial.dart';
import '../../widgets/custom_basemap_dialog.dart';
import '../../widgets/settings_widgets.dart';

/// 追加シートの「URL から追加」の印（シートはプロバイダを返すので、その中の目印として使う）
final _addFromUrlSentinel = BaseMapProvider.custom(
  name: '',
  urlTemplate: 'https://add-from-url.invalid/{z}/{x}/{y}',
);

/// 追加する地図を選ぶボトムシートを表示し、選ばれたレイヤまたは独自タイル URL を追加する
Future<void> showAddBasemapLayerSheet(
  BuildContext context, {
  required BaseMapService service,
  required Map<String, int> cacheStats,
  required LatLng center,
  required int previewZoom,
  required Future<void> Function(Future<void> Function() edit) editLayers,
  required Future<void> Function() onCacheChanged,
  required void Function(String title, NotificationLevel level) notify,
  required void Function(String addedProviderId) onBuiltInOrExistingLayerAdded,
}) async {
  final have = {for (final l in service.layers) l.providerId};
  final picked = await showModalBottomSheet<BaseMapProvider>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(t.basemap.layers.addTitle, style: Theme.of(sheetContext).textTheme.titleMedium),
          ),
          for (final p in BaseMapProvider.allProviders)
            ListTile(
              key: p.id == reliefProviderId ? TutorialTargets.reliefOption : null,
              leading: Icon(p.icon, color: have.contains(p.id) ? Colors.grey : Colors.blue),
              title: Text(p.name),
              subtitle: Text([
                p.description,
                if ((cacheStats[p.cacheId] ?? 0) > 0) t.basemap.cacheCount(count: cacheStats[p.cacheId].toString()),
              ].join('\n')),
              trailing: p.isCustom
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: t.basemap.custom.delete,
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        if (!context.mounted) return;
                        await deleteCustomBasemapProvider(
                          context,
                          provider: p,
                          service: service,
                          editLayers: editLayers,
                          onCacheChanged: onCacheChanged,
                        );
                      },
                    )
                  : have.contains(p.id)
                      ? Text(t.basemap.layers.alreadyAdded, style: const TextStyle(color: Colors.grey))
                      : null,
              enabled: !have.contains(p.id),
              onTap: () => Navigator.of(sheetContext).pop(p),
            ),
          // 任意の XYZ / WMS の URL（自治体の公開タイル・県の CS 立体図など）
          ListTile(
            leading: const Icon(Icons.add_link, color: Colors.blue),
            title: Text(t.basemap.custom.addEntry),
            onTap: () => Navigator.of(sheetContext).pop(_addFromUrlSentinel),
          ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  if (identical(picked, _addFromUrlSentinel)) {
    await promptAddCustomBasemap(
      context,
      service: service,
      center: center,
      previewZoom: previewZoom,
      editLayers: editLayers,
      notify: notify,
    );
    return;
  }
  // 等高線のように「重ねる前提」の地図は乗算で足す（白地に線だけなので、通常でもほぼ同じ）
  await editLayers(
    () => service.addLayer(
      picked.id,
      blend: picked.type == BaseMapType.generated ? BaseMapBlend.multiply : BaseMapBlend.normal,
    ),
  );
  onBuiltInOrExistingLayerAdded(picked.id);
}

/// 利用者の独自タイル（XYZ / WMS URL）を足すダイアログを表示し、追加したら一番上のレイヤに重ねる
Future<void> promptAddCustomBasemap(
  BuildContext context, {
  required BaseMapService service,
  required LatLng center,
  required int previewZoom,
  required Future<void> Function(Future<void> Function() edit) editLayers,
  required void Function(String title, NotificationLevel level) notify,
}) async {
  final added = await showCustomBaseMapDialog(
    context,
    service: service,
    center: center,
    zoom: previewZoom,
  );
  if (added == null) return;
  await editLayers(() => service.addLayer(added.id));
  notify(t.basemap.custom.added(name: added.name), NotificationLevel.success);
}

/// 利用者の独自タイルを消す（レイヤからも外し、キャッシュも消す）
Future<void> deleteCustomBasemapProvider(
  BuildContext context, {
  required BaseMapProvider provider,
  required BaseMapService service,
  required Future<void> Function(Future<void> Function() edit) editLayers,
  required Future<void> Function() onCacheChanged,
}) async {
  final ok = await showSettingsConfirmDialog(
    context,
    title: t.basemap.custom.delete,
    message: t.basemap.custom.deleteConfirm(name: provider.name),
    confirmLabel: t.common.delete,
    confirmStyle: TextButton.styleFrom(foregroundColor: Colors.red),
  );
  if (!ok) return;
  // 最後の 1 枚なら既定の地図を先に足す（背景地図が 0 枚にならないように）
  if (service.layers.length == 1 && service.layers.single.providerId == provider.id) {
    await service.addLayer(BaseMapProvider.defaultProvider.id);
  }
  await editLayers(() => service.removeCustomProvider(provider.id));
  await onCacheChanged();
}
