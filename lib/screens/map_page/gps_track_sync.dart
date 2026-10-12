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
// こかげマップ: GPS 軌跡の統合（20 秒ごと）を地図に映す
//
// 統合のたびに全地物を集め直し（`updateFeatures`）、3D の下地を焼き直していた（2026-10-12、Pixel 9 で置いたまま
// 20 秒ごとに 6 枚）。今日の 1 本だけを差し替え、軌跡のレイヤが見えているときだけその 1 本を地図に流す
import 'package:latlong2/latlong.dart';
import 'package:turf/turf.dart' as turf;

import '../../converters/turf_converter.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';

/// 統合のあと地図をどう直したか
enum TrackSyncResult {
  /// 今日の 1 本を差し替え、その 1 本だけ地図に流した
  rows,

  /// 今日の 1 本を差し替えたが、レイヤが見えていないので地図は触らない
  hidden,

  /// 差し替えられず（新しい区間など）レイヤを読み直し、全件を組み直した
  reloaded,

  /// 何もしない（レイヤが無い・見えていなくて読み込んでもいない）
  none,
}

/// 軌跡のレイヤが地図に出ているか（レイヤと親が可視で、View を全部消灯していない）
bool isTrackLayerShown(LayerNode layer) => layer.isVisibleRecursive() && layer.hasVisibleView;

/// 統合で書いた今日の 1 本 [line]（フィーチャ [featureId]）を地図に映す。
///
/// - レイヤが見えていれば、差し替えた 1 本だけ [refreshRows] で流す（全件の組み直し・全体の焼き直しをしない）
/// - 見えていなければ地図は触らない（差し替えは済ませるので、点けたときに今の形で出る）
/// - 差し替えられないとき（今日の区間がまだ地図に無い）はレイヤを読み直し、見えていれば [refreshAll]
Future<TrackSyncResult> syncConsolidatedTrack({
  required LayerNode? layer,
  required int? featureId,
  required List<LatLng>? line,
  required void Function(Set<FeatureNode> changed) refreshRows,
  required Future<void> Function() refreshAll,
}) async {
  if (layer == null) return TrackSyncResult.none;
  final shown = isTrackLayerShown(layer);
  final node = patchTrackFeature(layer, featureId, line);
  if (node != null) {
    if (!shown) return TrackSyncResult.hidden;
    refreshRows({node});
    return TrackSyncResult.rows;
  }
  // 読み込んでいない見えないレイヤは、点けたときに読まれる
  if (!shown && !layer.featuresLoaded) return TrackSyncResult.none;
  await layer.updateChildren();
  if (!shown) return TrackSyncResult.hidden;
  await refreshAll();
  return TrackSyncResult.reloaded;
}

/// 今日の 1 本を書いた座標で差し替える。差し替えた地物を返す（できなければ null）
FeatureNode? patchTrackFeature(LayerNode layer, int? featureId, List<LatLng>? line) {
  if (featureId == null || line == null || line.length < 2 || !layer.featuresLoaded) return null;
  final old = layer.getFeatureById(featureId);
  if (old == null) return null; // 新しい区間（まだ地図に無い）
  FeatureNode? node;
  for (final c in layer.children) {
    if (c is FeatureNode && c.rowId == featureId) {
      node = c;
      break;
    }
  }
  if (node == null) return null;
  final geom = old.geometry is turf.MultiLineString
      ? TurfConverter.createMultiLineString([line])
      : TurfConverter.createLineString(line);
  layer.addFeatureToMap(featureId, turf.Feature(id: old.id, geometry: geom, properties: old.properties));
  return node;
}
