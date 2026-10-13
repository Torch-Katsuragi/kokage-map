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
import '../../utils/geodesic.dart';

/// 測量の属性（survey_az など）の値を数にする。num と数として読める文字列のほかは 0
double surveyNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// survey_stn（器械点の GeoJSON Point）で点どうしをつなぐ道具
///
/// 器械点は座標の一致（約1mm以内）で引き当てる。TruPulse の道具・チェーン解決・後視補正が共有する。
class SurveyStation {
  // ~1mm squared — serialization rounding吸収閾値
  static const double _matchThresholdSq = 1e-16;

  /// survey_stn の値（GeoJSON Point の文字列か Map）を座標にする。読めなければ null
  static LatLng? parse(dynamic value) {
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

  /// 座標を survey_stn の値（GeoJSON Point の文字列）にする
  static String encode(LatLng p) => jsonEncode({
        'type': 'Point',
        'coordinates': [p.longitude, p.latitude],
      });

  /// [layer] の点のうち [coords] に一致する（約1mm以内）もの
  static PointFeatureNode? findAt(LatLng coords, LayerNode layer) {
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
    return (nearest != null && nearestDist < _matchThresholdSq) ? nearest : null;
  }

  /// [p] の器械点（survey_stn が指す点）。起点・器械点が見つからないときは null
  static PointFeatureNode? stationOf(PointFeatureNode p) {
    final coords = parse(p.turfFeature.properties?['survey_stn']);
    return coords == null ? null : findAt(coords, p.parent);
  }

  /// [target] を器械点にしている点（同じレイヤ）
  static List<PointFeatureNode> dependentsOf(PointFeatureNode target) {
    final layer = target.parent;
    return layer.children.whereType<PointFeatureNode>().where((p) {
      final coords = parse(p.turfFeature.properties?['survey_stn']);
      if (coords == null) return false;
      return findAt(coords, layer) == target;
    }).toList();
  }

  /// [start] から先のチェーン全体（幅優先、[start] は含まない）
  static List<PointFeatureNode> downstreamOf(PointFeatureNode start) {
    final result = <PointFeatureNode>[];
    final visited = <PointFeatureNode>{start};
    var frontier = [start];
    while (frontier.isNotEmpty) {
      final next = <PointFeatureNode>[];
      for (final p in frontier) {
        for (final dep in dependentsOf(p)) {
          if (visited.add(dep)) {
            result.add(dep);
            next.add(dep);
          }
        }
      }
      frontier = next;
    }
    return result;
  }

  /// [points] を緯度経度で [dLat], [dLon] だけ平行移動し、survey_stn も同じだけずらす
  ///
  /// [points] は動かす前に [downstreamOf] で集めておくこと（動かすと座標の一致で引けなくなる）。
  /// 器械点ごと平行移動するので、各測線の向きと長さは変わらない。
  static Future<void> translate(List<PointFeatureNode> points, double dLat, double dLon) async {
    for (final p in points) {
      await p.updateLocation(LatLng(p.point.latitude + dLat, p.point.longitude + dLon));
      final stn = parse(p.turfFeature.properties?['survey_stn']);
      if (stn != null) {
        await p.setAttributeValue(
          'survey_stn',
          encode(LatLng(stn.latitude + dLat, stn.longitude + dLon)),
        );
      }
    }
  }
}

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

  /// 総路線長（メートル）
  double get totalDistance {
    double total = 0;
    for (final p in points) {
      total += Geodesic.distance(p.stationPosition, p.position);
    }
    return total;
  }

  /// 閉合差（起点と終点の距離、メートル）
  double get closureError {
    if (points.isEmpty) return 0;
    return Geodesic.distance(origin.point, points.last.position);
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
        az: surveyNumber(props['survey_az']),
        hd: surveyNumber(props['survey_hd']),
        vd: surveyNumber(props['survey_vd']),
        sd: surveyNumber(props['survey_sd']),
        inc: surveyNumber(props['survey_inc']),
        stationPosition: stnCoords,
      ));

      current = next;
    }

    return TraverseChain(origin: root, points: points);
  }

  static bool _hasSurveyData(PointFeatureNode node) {
    final props = node.turfFeature.properties;
    if (props == null) return false;
    return props.containsKey('survey_az') && props.containsKey('survey_hd');
  }

  static LatLng? _parseStnCoords(dynamic value) => SurveyStation.parse(value);

  static PointFeatureNode? _findNearestPoint(LatLng coords, LayerNode layer) =>
      SurveyStation.findAt(coords, layer);
}
