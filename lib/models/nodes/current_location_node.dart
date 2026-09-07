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
// こかげマップ: 現在位置マーカーを表す擬似フィーチャ
//
// 現在位置は GeoPackage に無いが、タップして情報を見る操作はフィーチャと同じにしたい。
// そこで選択の仕組み（`selectedFeaturesProvider` → 情報カード）にこのノードを載せる。
// フィーチャと同じ場所に同じカードが出るので、選択は自然に排他になる。
//
// ⚠ 範囲選択（投げ縄）・複数選択・消しゴムの対象には**しない**。消せないし、
//   集合の集計にも入れない。`SelectTool` のタップ候補にだけ混ざる。

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../../core/node_types.dart';
import 'layer_tree_node.dart';

class CurrentLocationNode extends LayerTreeNode {
  CurrentLocationNode({
    required this.locationOf,
    required this.gpsInfoOf,
    required this.headingNotifier,
  }) : super('current-location', nodeType: NodeType.feature);

  /// 地図側の最新値を毎回読む（ノードに値を写す手間を省く）
  final LatLng? Function() locationOf;
  final Map<String, dynamic>? Function() gpsInfoOf;
  final ValueListenable<double?> headingNotifier;

  LatLng? get location => locationOf();
  Map<String, dynamic>? get gpsInfo => gpsInfoOf();

  // dispose は基底のまま（parent が無いので何も起きない＝消せない）。
  // 範囲選択・複数選択から除外しているので、まとめて削除に紛れることもない
}
