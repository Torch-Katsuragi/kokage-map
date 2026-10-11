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
// 情報パネルの「ここへ案内」ボタン。点はその点、線はいちばん近い所、面は中心かいちばん近い頂点を選ぶ

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/nodes/feature_node.dart';
import '../providers/guidance_providers.dart';
import '../providers/notification_providers.dart';
import '../utils/feature_calc_utils.dart';
import '../utils/navigation_math.dart';

/// 面の行き先の選び方
enum _PolygonAnchor { centroid, nearestVertex }

class GuideHereButton extends ConsumerWidget {
  /// 点・線・面の地物
  const GuideHereButton.feature({super.key, required FeatureNode this.feature, required this.label}) : point = null;

  /// 位置だけ（位置付きの写真など）
  const GuideHereButton.point({super.key, required LatLng this.point, required this.label}) : feature = null;

  final FeatureNode? feature;
  final LatLng? point;

  /// 案内の見出しに出す名前
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ElevatedButton.styleFrom(
      backgroundColor: Colors.pink.shade50,
      foregroundColor: Colors.pink.shade700,
      elevation: 0,
      padding: const EdgeInsets.symmetric(vertical: 8),
    );
    const icon = Icon(Icons.near_me, size: 16);
    final f = feature;
    if (f is PolygonFeatureNode) {
      // 面は「中心」か「いちばん近い頂点」（素図の境界点・プロットの中心）
      return SizedBox(
        width: double.infinity,
        child: PopupMenuButton<_PolygonAnchor>(
          tooltip: t.guidance.action,
          onSelected: (a) => _startPolygon(ref, f, a),
          itemBuilder: (_) => [
            PopupMenuItem(value: _PolygonAnchor.centroid, child: Text(t.guidance.toCentroid)),
            PopupMenuItem(value: _PolygonAnchor.nearestVertex, child: Text(t.guidance.toNearestVertex)),
          ],
          child: IgnorePointer(
            child: ElevatedButton.icon(onPressed: () {}, icon: icon, label: Text(t.guidance.action), style: style),
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _startSimple(ref),
        icon: icon,
        label: Text(t.guidance.action),
        style: style,
      ),
    );
  }

  void _start(WidgetRef ref, LatLng p) =>
      ref.read(guidanceProvider.notifier).start(GuidanceTarget(point: p, label: label));

  void _startSimple(WidgetRef ref) {
    final p = point;
    if (p != null) return _start(ref, p);
    final f = feature;
    final here = ref.read(guidanceProvider.notifier).lastPosition;
    if (f is PointFeatureNode) {
      _start(ref, f.point);
    } else if (f is LineFeatureNode) {
      final line = f.line;
      if (line.isEmpty) return;
      // 線はいちばん近い所へ。位置が無ければ線の中ほど
      _start(ref, (here == null ? null : NavigationMath.nearestPointOnLine(here, line)) ?? GeometryCalc.calcLineCentroid(line));
    } else if (f != null) {
      _start(ref, f.centroid);
    }
  }

  void _startPolygon(WidgetRef ref, PolygonFeatureNode f, _PolygonAnchor anchor) {
    final rings = f.polygon;
    if (rings.isEmpty || rings.first.isEmpty) return;
    final outer = rings.first;
    if (anchor == _PolygonAnchor.centroid) {
      final c = NavigationMath.polygonCentroid(outer);
      if (c != null) _start(ref, c);
      return;
    }
    final here = ref.read(guidanceProvider.notifier).lastPosition;
    if (here == null) {
      ref.read(notificationCenterProvider.notifier).add(title: t.guidance.noPosition, level: NotificationLevel.warning);
      return;
    }
    final v = NavigationMath.nearestVertex(here, [for (final r in rings) ...r]);
    if (v != null) _start(ref, v);
  }
}
