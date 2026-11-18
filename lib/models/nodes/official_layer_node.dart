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

/// `System`（`sys`）に追加される公式オープンデータのレイヤノードと擬似フィーチャノード。
///
/// プロジェクトの `.qgs`・Google Drive 同期の対象外とし、端末側で通信ストリーミングして重ねる。
library;

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../core/node_types.dart';
import '../../core/official/official_data_catalog.dart';
import '../../i18n/strings.g.dart';
import 'layer_tree_node.dart';

/// `System`（`sys`）の下に並ぶ公式データレイヤ（読み取り専用）
class OfficialLayerNode extends LayerTreeNode {
  OfficialLayerNode(
    this.spec, {
    super.visible = true,
    super.parent,
    this.onPersistVisibility,
  }) : super('official:${spec.id}', nodeType: NodeType.layer);

  final OfficialLayerSpec spec;
  final Future<void> Function(bool visible)? onPersistVisibility;

  @override
  String? getAbsoluteFilePath() => null;

  @override
  Future<void> persistVisibility() async {
    await onPersistVisibility?.call(visible);
  }

  /// カタログ ID に対応する i18n 表示名
  static String displayNameOf(OfficialLayerSpec spec) => switch (spec.id) {
        'rinya_forest_plan' => t.officialLayer.rinyaName,
        'gsj_seamless_geology' => t.officialLayer.gsjName,
        _ => spec.id,
      };

  /// カタログ ID に対応する i18n 説明文
  static String descriptionOf(OfficialLayerSpec spec) => switch (spec.id) {
        'rinya_forest_plan' => t.officialLayer.rinyaDesc,
        'gsj_seamless_geology' => t.officialLayer.gsjDesc,
        _ => spec.attribution,
      };
}

/// 公式データを地図上でタップしたときに選ばれる読み取り専用の擬似フィーチャ。
///
/// [CurrentLocationNode] と同じ扱い（`FeatureNode` を継承しないため編集・削除・消しゴム・投げ縄の対象にならない）。
/// [operator ==] を `(spec.id, hitId)` で定義しているため、同じ場所を続けてタップするとサイクル選択が機能する。
class OfficialFeatureNode extends LayerTreeNode {
  OfficialFeatureNode({
    required this.spec,
    required this.hitId,
    required this.title,
    required this.tapPoint,
    this.attributes = const {},
    this.geometry,
    this.lazyAttributesLoader,
    super.parent,
  }) : super(title, nodeType: NodeType.feature);

  final OfficialLayerSpec spec;
  final String hitId;
  final String title;
  final LatLng tapPoint;
  final Map<String, String> attributes;
  final geo.Geometry? geometry;

  /// 地質図 API などの非同期地点照会（詳細パネルを開いたときに取得）
  final Future<Map<String, String>?> Function()? lazyAttributesLoader;

  @override
  String? getAbsoluteFilePath() => null;

  /// シルエット表示や選択枠描画のための外環列（ポリゴン系のみ）
  List<List<LatLng>> get silhouetteParts {
    final g = geometry;
    if (g is geo.Polygon && g.rings.isNotEmpty) {
      return [_seriesToLatLng(g.rings.first)];
    }
    if (g is geo.MultiPolygon && g.ringArrays.isNotEmpty) {
      return [
        for (final rings in g.ringArrays)
          if (rings.isNotEmpty) _seriesToLatLng(rings.first),
      ];
    }
    return const [];
  }

  static List<LatLng> _seriesToLatLng(geo.PositionSeries s) => [
        for (var i = 0; i < s.positionCount; i++) LatLng(s.y(i), s.x(i)),
      ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfficialFeatureNode &&
          other.spec.id == spec.id &&
          other.hitId == hitId);

  @override
  int get hashCode => Object.hash(spec.id, hitId);
}
