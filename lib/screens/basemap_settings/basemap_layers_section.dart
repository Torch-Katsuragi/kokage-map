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
/// 背景地図レイヤの重ね合わせリスト・不透明度・合成モード操作セクション
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../i18n/strings.g.dart';
import '../../models/basemap_layer.dart';
import '../../models/basemap_provider.dart';
import '../../services/basemap_service.dart';
import '../../tutorial/tutorial.dart';
import '../../widgets/basemap_preview.dart';
import '../../widgets/settings_widgets.dart';

/// 合成モードの表示ラベルを返す
String basemapBlendLabel(BaseMapBlend b) => switch (b) {
      BaseMapBlend.normal => t.basemap.layers.blendModes.normal,
      BaseMapBlend.multiply => t.basemap.layers.blendModes.multiply,
      BaseMapBlend.screen => t.basemap.layers.blendModes.screen,
      BaseMapBlend.overlay => t.basemap.layers.blendModes.overlay,
      BaseMapBlend.darken => t.basemap.layers.blendModes.darken,
      BaseMapBlend.lighten => t.basemap.layers.blendModes.lighten,
      BaseMapBlend.softLight => t.basemap.layers.blendModes.softLight,
      BaseMapBlend.hardLight => t.basemap.layers.blendModes.hardLight,
      BaseMapBlend.difference => t.basemap.layers.blendModes.difference,
    };

/// レイヤセクション（イメージはお絵描きソフトのレイヤ。順番・可視・透明度・合成モード）。
/// サービスは下から上に持つが、ここでは上（手前）から並べる。
class BasemapLayersSection extends StatelessWidget {
  const BasemapLayersSection({
    super.key,
    required this.service,
    required this.mapCenter,
    required this.previewZoom,
    required this.onReorderLayer,
    required this.onUpdateLayer,
    required this.onRemoveLayer,
    required this.onAddLayerPressed,
  });

  final BaseMapService service;
  final LatLng mapCenter;
  final int previewZoom;
  final Future<void> Function(int oldIndexFromBottom, int newIndexFromBottom) onReorderLayer;
  final Future<void> Function(BaseMapLayer previous, BaseMapLayer updated) onUpdateLayer;
  final Future<void> Function(String providerId) onRemoveLayer;
  final VoidCallback onAddLayerPressed;

  @override
  Widget build(BuildContext context) {
    final layers = service.layers.reversed.toList();

    return SettingsSection(
      title: t.basemap.layers.title,
      trailing: Text(
        t.basemap.layers.summary(count: layers.length.toString()),
        style: const TextStyle(fontSize: 14, color: Colors.grey),
      ),
      children: [
        // プレビュー（地図の中心のタイル 1 枚をいまの設定で合成）と説明
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BaseMapPreview(service: service, center: mapCenter, zoom: previewZoom),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.basemap.layers.preview(zoom: previewZoom.toString()),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    Text(t.basemap.layers.hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: layers.length,
          onReorderItem: (oldIndex, newIndex) async {
            // 上から数えた番号 → サービス（下から）の番号
            final n = service.layers.length;
            await onReorderLayer(n - 1 - oldIndex, n - 1 - newIndex);
          },
          itemBuilder: (context, i) {
            final layer = layers[i];
            final provider = layer.provider!;
            return BasemapLayerRow(
              key: ValueKey(layer.providerId),
              index: i,
              layer: layer,
              provider: provider,
              isBottom: i == layers.length - 1,
              webBlocked: service.webFetchFailed(layer.providerId),
              blendLabel: basemapBlendLabel,
              onChanged: (updated) => onUpdateLayer(layer, updated),
              onRemove: layers.length > 1 ? () => onRemoveLayer(layer.providerId) : null,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: TutorialTargets.basemapAddButton,
              onPressed: onAddLayerPressed,
              icon: const Icon(Icons.add),
              label: Text(t.basemap.layers.add),
            ),
          ),
        ),
      ],
    );
  }
}

/// レイヤ 1 行: 持ち手・目・名前・合成モード・外す、下に不透明度
class BasemapLayerRow extends StatelessWidget {
  const BasemapLayerRow({
    super.key,
    required this.index,
    required this.layer,
    required this.provider,
    required this.isBottom,
    this.webBlocked = false,
    required this.blendLabel,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final BaseMapLayer layer;
  final BaseMapProvider provider;

  /// 一番下の層（合成モードは効かない）
  final bool isBottom;

  /// web でタイルが取れていない利用者の地図（CORS の見込み）
  final bool webBlocked;
  final String Function(BaseMapBlend) blendLabel;
  final ValueChanged<BaseMapLayer> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final on = layer.visible;
    final dim = on ? null : Colors.grey;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
      child: Column(
        children: [
          // 持ち手・目・名前・外す
          Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle, color: Colors.grey),
                ),
              ),
              IconButton(
                icon: Icon(on ? Icons.visibility : Icons.visibility_off, color: on ? Colors.blue : Colors.grey),
                tooltip: on ? t.basemap.layers.hide : t.basemap.layers.show,
                onPressed: () => onChanged(layer.copyWith(visible: !on)),
              ),
              Icon(provider.icon, color: dim ?? Colors.blue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  provider.name,
                  style: TextStyle(fontSize: 14, color: dim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.grey,
                tooltip: t.basemap.layers.remove,
                onPressed: onRemove,
              ),
            ],
          ),
          if (webBlocked)
            Padding(
              padding: const EdgeInsets.only(left: 48, right: 8),
              child: Text(t.basemap.custom.webBlocked, style: TextStyle(fontSize: 12, color: Colors.red[700])),
            ),
          // 合成モード・不透明度
          Row(
            children: [
              const SizedBox(width: 48),
              DropdownButton<BaseMapBlend>(
                value: layer.blend,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: TextStyle(
                  fontSize: 12,
                  color: isBottom ? Colors.grey : Theme.of(context).textTheme.bodyMedium?.color,
                ),
                items: [
                  for (final b in BaseMapBlend.values) DropdownMenuItem(value: b, child: Text(blendLabel(b))),
                ],
                onChanged: isBottom ? null : (b) => b == null ? null : onChanged(layer.copyWith(blend: b)),
              ),
              Expanded(
                child: Slider(
                  key: layer.providerId == reliefProviderId ? TutorialTargets.reliefOpacity : null,
                  value: layer.opacity.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${layer.opacity}%',
                  onChanged: (v) => onChanged(layer.copyWith(opacity: v.round())),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${layer.opacity}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: dim ?? Colors.blue),
                ),
              ),
            ],
          ),
          const Divider(height: 4),
        ],
      ),
    );
  }
}
