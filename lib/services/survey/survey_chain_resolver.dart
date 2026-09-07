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
/// 測量チェーン解決サービス
///
/// survey_stn属性を辿ってポイントの測量順序を復元する。
/// TruPulseToolの測線オーバーレイと同じnearest-pointマッチングを使用。
library;

import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';

/// 測量チェーン内の1点を表すデータクラス
class TraversePoint {
  final PointFeatureNode node;
  final LatLng position;
  final double az;
  final double hd;
  final double vd;
  final double sd;
  final double inc;
  final LatLng stationPosition;

  const TraversePoint({
    required this.node,
    required this.position,
    required this.az,
    required this.hd,
    required this.vd,
    required this.sd,
    required this.inc,
    required this.stationPosition,
  });
}

/// 解決済み測量チェーン
class TraverseChain {
  /// チェーンの起点（Station原点、survey_*属性なし）
  final PointFeatureNode origin;

  /// 測量順に並んだポイント列（originは含まない）
  final List<TraversePoint> points;

  const TraverseChain({required this.origin, required this.points});

  /// 起点を含む全座標リスト
  List<LatLng> get allPositions => [
        origin.point,
        ...points.map((p) => p.position),
      ];

  /// 総路線長（メートル）
  double get totalDistance {
    const d = Distance(roundResult: false);
    double total = 0;
    for (final p in points) {
      total += d.as(LengthUnit.Meter, p.stationPosition, p.position);
    }
    return total;
  }

  /// 閉合差（起点と終点の距離、メートル）
  double get closureError {
    if (points.isEmpty) return 0;
    return const Distance(roundResult: false).as(
      LengthUnit.Meter,
      origin.point,
      points.last.position,
    );
  }

  /// 閉合比（1/N の N）。0除算時はdouble.infinity
  double get closureRatioN {
    final err = closureError;
    if (err < 1e-6) return double.infinity;
    return totalDistance / err;
  }

  bool get isEmpty => points.isEmpty;
  int get length => points.length;
}

/// survey_stnチェーンを辿ってTraverseChainを構築する
class SurveyChainResolver {
  // ~1mm squared — serialization rounding吸収閾値
  static const double _stnMatchThresholdSq = 1e-16;

  /// レイヤ内の測量チェーンをすべて解決する
  ///
  /// 複数の独立したチェーンが存在する場合、それぞれを返す。
  static List<TraverseChain> resolveAll(PointLayerNode layer) {
    final surveyPoints = <PointFeatureNode>[];
    final nonSurveyPoints = <PointFeatureNode>[];

    for (final child in layer.children) {
      if (child is! PointFeatureNode) continue;
      if (_hasSurveyData(child)) {
        surveyPoints.add(child);
      } else {
        nonSurveyPoints.add(child);
      }
    }

    if (surveyPoints.isEmpty) return [];

    // 各測量ポイントのstation参照をマッピング
    final stationOf = <PointFeatureNode, PointFeatureNode>{};
    final dependentsOf = <PointFeatureNode, List<PointFeatureNode>>{};

    for (final p in surveyPoints) {
      final stnCoords = _parseStnCoords(p.turfFeature.properties?['survey_stn']);
      if (stnCoords == null) continue;

      final stn = _findNearestPoint(stnCoords, layer);
      if (stn == null) continue;

      stationOf[p] = stn;
      dependentsOf.putIfAbsent(stn, () => []).add(p);
    }

    // ルートを特定: 測量ポイントのstationになっているが、自身はsurvey_stnを持たないポイント
    final referenced = stationOf.values.toSet();
    final roots = <PointFeatureNode>{};

    for (final stn in referenced) {
      if (!stationOf.containsKey(stn)) {
        roots.add(stn);
      }
    }

    // 各ルートからチェーンを構築
    final chains = <TraverseChain>[];
    final visited = <PointFeatureNode>{};

    for (final root in roots) {
      if (visited.contains(root)) continue;
      visited.add(root);

      final chain = _buildChain(root, dependentsOf, visited);
      if (chain.points.isNotEmpty) {
        chains.add(chain);
      }
    }

    return chains;
  }

  /// 単一のチェーンを構築（分岐がある場合は最長パスを選択）
  static TraverseChain _buildChain(
    PointFeatureNode root,
    Map<PointFeatureNode, List<PointFeatureNode>> dependentsOf,
    Set<PointFeatureNode> visited,
  ) {
    final points = <TraversePoint>[];
    var current = root;

    while (true) {
      final deps = dependentsOf[current];
      if (deps == null || deps.isEmpty) break;

      // timestamp順でソート（同一stationから複数射った場合）
      final unvisited = deps.where((d) => !visited.contains(d)).toList();
      if (unvisited.isEmpty) break;

      unvisited.sort((a, b) {
        final tA = a.turfFeature.properties?['survey_timestamp'] as String? ?? '';
        final tB = b.turfFeature.properties?['survey_timestamp'] as String? ?? '';
        return tA.compareTo(tB);
      });

      // 最も古い（最初に計測された）ものをチェーンに追加
      final next = unvisited.first;
      visited.add(next);

      final props = next.turfFeature.properties ?? {};
      final stnCoords = _parseStnCoords(props['survey_stn']);
      if (stnCoords == null) break;

      points.add(TraversePoint(
        node: next,
        position: next.point,
        az: _toDouble(props['survey_az']),
        hd: _toDouble(props['survey_hd']),
        vd: _toDouble(props['survey_vd']),
        sd: _toDouble(props['survey_sd']),
        inc: _toDouble(props['survey_inc']),
        stationPosition: stnCoords,
      ));

      current = next;
    }

    return TraverseChain(origin: root, points: points);
  }

  /// dynamic値（num or String）をdoubleに変換する
  static double _toDouble(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static bool _hasSurveyData(PointFeatureNode node) {
    final props = node.turfFeature.properties;
    if (props == null) return false;
    return props.containsKey('survey_az') && props.containsKey('survey_hd');
  }

  static LatLng? _parseStnCoords(dynamic value) {
    try {
      final map = value is String
          ? jsonDecode(value) as Map<String, dynamic>
          : value as Map;
      final c = map['coordinates'] as List;
      return LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
    } catch (_) {
      return null;
    }
  }

  static PointFeatureNode? _findNearestPoint(LatLng coords, LayerNode layer) {
    PointFeatureNode? nearest;
    double nearestDist = double.infinity;
    for (final child in layer.children) {
      if (child is! PointFeatureNode) continue;
      final dlat = child.point.latitude - coords.latitude;
      final dlon = child.point.longitude - coords.longitude;
      final d = dlat * dlat + dlon * dlon;
      if (d < nearestDist) {
        nearestDist = d;
        nearest = child;
      }
    }
    return (nearest != null && nearestDist < _stnMatchThresholdSq)
        ? nearest
        : null;
  }
}
