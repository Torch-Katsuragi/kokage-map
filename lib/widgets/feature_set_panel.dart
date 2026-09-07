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
// こかげマップ: 複数フィーチャを選択しているときの情報カード
//
// 点・線・面・写真が混ざっていてもよい。件数と、種類ごとの集計
// （点の重心・線の合計距離・面の合計面積）を出し、まとめて削除できる。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/image_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../providers/notification_providers.dart';
import '../providers/selection_providers.dart';
import '../utils/feature_calc_utils.dart';
import 'info_panel_card.dart';
import 'long_press_delete_button.dart';

/// 選択集合の集計。UI から切り離してあるのでテストできる
class FeatureSetSummary {
  FeatureSetSummary(List<LayerTreeNode> nodes)
      : points = nodes.whereType<PointFeatureNode>().toList(),
        lines = nodes.whereType<LineFeatureNode>().toList(),
        polygons = nodes.whereType<PolygonFeatureNode>().toList(),
        photos = nodes.whereType<ImageNode>().toList(),
        total = nodes.length;

  final List<PointFeatureNode> points;
  final List<LineFeatureNode> lines;
  final List<PolygonFeatureNode> polygons;
  final List<ImageNode> photos;
  final int total;

  /// 点の重心（点が無ければ null）
  LatLng? get pointsCentroid => points.isEmpty
      ? null
      : GeometryCalc.calcPointsCentroid([for (final p in points) p.point]);

  /// 線の合計距離 [m]
  double get totalLength => lines.fold(0, (s, l) => s + l.length);

  /// 面の合計面積 [m²]
  double get totalArea => polygons.fold(0, (s, p) => s + p.area);

  /// 所属レイヤごとの件数（表示順は出現順）
  Map<String, int> get countByLayer {
    final m = <String, int>{};
    for (final f in [...points, ...lines, ...polygons]) {
      m.update(f.parent.name, (v) => v + 1, ifAbsent: () => 1);
    }
    return m;
  }

  static String formatLength(double meters) => meters >= 10000
      ? '${(meters / 1000).toStringAsFixed(2)} km'
      : '${meters.toStringAsFixed(1)} m';

  static String formatArea(double m2) => m2 >= 10000
      ? '${(m2 / 10000).toStringAsFixed(3)} ha'
      : '${m2.toStringAsFixed(1)} m²';
}

class FeatureSetPanel extends ConsumerWidget {
  const FeatureSetPanel({super.key, required this.features});

  final List<LayerTreeNode> features;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = FeatureSetSummary(features);
    final tr = t.featureSet;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: Text(value)),
            ],
          ),
        );

    final centroid = s.pointsCentroid;
    return InfoPanelCard(
      title: tr.title(n: s.total),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        tooltip: tr.clearSelection,
        onPressed: () => ref.read(selectedFeaturesProvider.notifier).clear(),
      ),
      children: [
        if (s.points.isNotEmpty) row(tr.points, '${s.points.length}'),
        if (s.lines.isNotEmpty)
          row(
            tr.lines,
            '${s.lines.length}（${FeatureSetSummary.formatLength(s.totalLength)}）',
          ),
        if (s.polygons.isNotEmpty)
          row(
            tr.polygons,
            '${s.polygons.length}（${FeatureSetSummary.formatArea(s.totalArea)}）',
          ),
        if (s.photos.isNotEmpty) row(tr.photos, '${s.photos.length}'),
        if (centroid != null)
          row(
            tr.centroid,
            '${centroid.latitude.toStringAsFixed(6)}, ${centroid.longitude.toStringAsFixed(6)}',
          ),
        if (s.countByLayer.length > 1) ...[
          const SizedBox(height: 4),
          for (final e in s.countByLayer.entries) row(e.key, '${e.value}'),
        ],
        const SizedBox(height: 12),
        LongPressDeleteButton(
          label: tr.deleteAll(n: s.total),
          onDelete: () => _deleteAll(ref, s.total),
        ),
      ],
    );
  }

  Future<void> _deleteAll(WidgetRef ref, int count) async {
    final notifier = ref.read(notificationCenterProvider.notifier);
    await ref.read(selectedFeaturesProvider.notifier).disposeSelectedFeatures();
    notifier.add(
      title: t.featureSet.deleted(n: count),
      level: NotificationLevel.success,
    );
  }
}
