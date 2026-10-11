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
// こかげマップ: 地点への誘導の札（距離・方位・矢印・高低差・やめるボタン）
//
// 案内している間だけ地図の上に出る。値は GPS の更新（[guidanceProvider]）と端末の向きで変わる。
// 高低差は標高タイル（3D 地形と同じ。キャッシュにあればオフラインで引ける）で、目標と今の位置の両方を引く。
// GPS の高度は楕円体高でジオイドの分ずれるので使わない

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/geopackage/vertex_z.dart';
import '../../../providers/guidance_providers.dart';
import '../../../providers/party_providers.dart';
import '../../../utils/navigation_math.dart';

class GuidanceOverlay extends ConsumerStatefulWidget {
  const GuidanceOverlay({super.key, required this.heading, required this.mapBearing});

  /// 端末の向き（コンパス。度）
  final ValueListenable<double?> heading;

  /// 地図の回転（度）。向きも進行方向も無いときは矢印を地図の上基準にする
  final ValueListenable<double> mapBearing;

  @override
  ConsumerState<GuidanceOverlay> createState() => _GuidanceOverlayState();
}

class _GuidanceOverlayState extends ConsumerState<GuidanceOverlay> {
  /// 標高を引き直すまでに動く距離（m）
  static const _elevationResampleMeters = 5.0;

  LatLng? _targetElevAt;
  double? _targetElev;
  LatLng? _hereElevAt;
  double? _hereElev;
  bool _sampling = false;

  /// 目標と今の位置の標高を（変わったときだけ）引く
  void _sampleElevation(GuidanceState s) {
    final lookup = VertexZ.elevationLookup;
    final target = s.target?.point;
    final here = s.here;
    if (lookup == null || target == null || _sampling) return;
    final needTarget = target != _targetElevAt;
    final needHere = here != null &&
        (_hereElevAt == null || NavigationMath.distanceMeters(_hereElevAt!, here) >= _elevationResampleMeters);
    if (!needTarget && !needHere) return;
    _sampling = true;
    final points = [
      if (needTarget) (target.longitude, target.latitude),
      if (needHere) (here.longitude, here.latitude),
    ];
    unawaited(lookup(points).then((v) {
      if (!mounted) return;
      setState(() {
        var i = 0;
        if (needTarget) {
          _targetElevAt = target;
          _targetElev = v[i++];
        }
        if (needHere) {
          _hereElevAt = here;
          _hereElev = v[i];
        }
      });
    }).catchError((Object _) {
      // 引けなければ「不明」のまま
    }).whenComplete(() => _sampling = false));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(guidanceProvider);
    // メンバーへ向かっているときは、その人の最新の位置に付いて動く（届かなくなったら最後の位置のまま）
    ref.listen(partySessionProvider, (_, session) {
      final uid = ref.read(guidanceProvider).target?.peerUid;
      if (uid == null) return;
      final p = session.peers[uid];
      if (p != null) ref.read(guidanceProvider.notifier).moveTarget(LatLng(p.latitude, p.longitude));
    });
    // 着いたら震わせる（通知は guidanceProvider が通知センターへ）
    ref.listen(guidanceProvider.select((g) => g.arrived), (prev, arrived) {
      if (arrived && prev == false) HapticFeedback.heavyImpact();
    });
    final target = s.target;
    if (target == null) return const SizedBox.shrink();
    _sampleElevation(s);

    final distance = s.distance;
    final bearing = s.bearing;
    return Material(
      color: Colors.white,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (bearing != null)
              ValueListenableBuilder<double?>(
                valueListenable: widget.heading,
                builder: (_, heading, _) => ValueListenableBuilder<double>(
                  valueListenable: widget.mapBearing,
                  builder: (_, mapBearing, _) => _arrow(bearing, heading, s.courseDeg, mapBearing),
                ),
              ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    target.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (distance == null || bearing == null)
                    Text(t.guidance.waitingPosition, style: const TextStyle(fontSize: 14))
                  else ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(formatDistance(distance), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 6),
                        if (s.accuracy != null)
                          Text(
                            t.guidance.accuracy(value: s.accuracy!.toStringAsFixed(0)),
                            style: const TextStyle(fontSize: 11, color: Colors.black54),
                          ),
                        if (s.arrived) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(8)),
                            child: Text(t.guidance.arrivedBadge, style: const TextStyle(fontSize: 11, color: Colors.white)),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      t.guidance.bearing(
                        deg: bearing.round() % 360,
                        dir: t.guidance.octants[NavigationMath.octant(bearing)],
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(_elevationText(), style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: t.guidance.stop,
              icon: const Icon(Icons.close),
              onPressed: () => ref.read(guidanceProvider.notifier).stop(),
            ),
          ],
        ),
      ),
    );
  }

  /// 目標への矢印。端末の向きがあればそれ、無ければ進行方向、どちらも無ければ地図の上を基準にする
  Widget _arrow(double bearing, double? heading, double? course, double mapBearing) {
    final (facing, basis) = heading != null
        ? (heading, t.guidance.basisHeading)
        : course != null
            ? (course, t.guidance.basisCourse)
            : (mapBearing, t.guidance.basisMap);
    final rel = NavigationMath.relativeDeg(bearing, facing);
    return Tooltip(
      message: basis,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: Colors.pink.shade50, shape: BoxShape.circle),
            child: Transform.rotate(
              angle: rel * math.pi / 180,
              child: Icon(Icons.navigation, size: 34, color: Colors.pink.shade700),
            ),
          ),
          const SizedBox(height: 2),
          Icon(
            heading != null ? Icons.explore : (course != null ? Icons.directions_walk : Icons.map_outlined),
            size: 12,
            color: Colors.black45,
          ),
        ],
      ),
    );
  }

  String _elevationText() {
    final a = _hereElev, b = _targetElev;
    if (a == null || b == null) return t.guidance.elevationUnknown;
    final d = b - a;
    if (d.abs() < 1) return t.guidance.elevationLevel;
    final m = d.abs().round().toString();
    return d > 0 ? t.guidance.elevationUp(m: m) : t.guidance.elevationDown(m: m);
  }
}

/// 距離の表示: 10 m 未満は 0.1 m、1 km 未満は 1 m、それ以上は 0.01 km
String formatDistance(double meters) {
  if (meters < 10) return '${meters.toStringAsFixed(1)} m';
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(2)} km';
}
