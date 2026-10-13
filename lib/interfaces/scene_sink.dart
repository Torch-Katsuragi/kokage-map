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
/// シーン投入の窓口（seam ②）。設計は `docs/technical/scene-model.md`
///
/// - [SceneSink]: 地図ページが書く口（フィーチャ・View 固有スタイル・「描き直して」の合図）
/// - [MapScene]: 描画系（`TerrainMapLayer`）が読む口。[revision] が増えたら組み直す
///
/// 描画系は差分を受け取らず、合図が来たら [MapScene] から読み直す（いまの 3D の作りに合わせた形）。
/// 実装は `MapSceneStore`。
library;

import 'package:flutter/foundation.dart';

import '../models/map_style_group.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_tree_node.dart';
import '../models/nodes/overlay_image_node.dart';
import '../screens/map_page/feature_geojson_cache.dart';

/// 地図ページがシーンへ書く口
abstract interface class SceneSink {
  /// View 固有スタイルの束を差し替える。変わったら true。
  /// ⚠ フィーチャを組み立てる**前**に呼ぶ（`k-style` を載せるかどうかの判断がこれを見る）
  bool setStyleGroups(List<MapStyleGroup> groups);

  /// フィーチャを組み直して描画系に知らせる。[selectionOnly] なら選択ソースだけ組み直す（通常ソースは前のまま）
  void pushFeatures(FeatureGeoJsonInput input, {required bool selectionOnly});

  /// [changed] の地物だけ組み直して描画系に知らせる（ほかの地物の一覧は前回と同じ前提）。
  /// 差分で組めなければ全件を組み直す（GPS 軌跡の統合で今日の 1 本が伸びたときなど）
  void pushFeatureChanges(FeatureGeoJsonInput input, Set<FeatureNode> changed);

  /// 描く順（レイヤ一覧の並び。[ranks] は段で、大きいほど手前）を差し替える。変わったら true。
  /// ⚠ フィーチャを組み立てる**前**に呼ぶ（面の段は組み立てのときに引く）
  bool setDrawOrder(Map<LayerTreeNode, int> ranks);

  /// 中身は変えずに描画系に組み直させる（GPS 軌跡・オーバーレイ画像の変形・編集の終わりなど、
  /// 描画系が別の経路で読むものが変わったとき）
  void invalidate();
}

/// 描画系がシーンを読む口
abstract interface class MapScene {
  /// 地図に流す GeoJSON（通常 / 選択）
  FeatureGeoJsonCache get features;

  /// View 固有スタイル（解決済み。フィーチャの `k-style` と突き合わせる）
  List<MapStyleGroup> get styleGroups;

  /// オーバーレイ画像（GeoTIFF・写真）
  List<OverlayImageNode> get overlayImages;

  /// レイヤ（・オーバーレイ画像）の描く順の段。大きいほど手前。知らないものは -1（いちばん下）
  int drawRankOf(LayerTreeNode node);

  /// 描く順が変わるたびに増える（焼き込み済みのテクスチャを一度だけ焼き直す合図）
  int get drawOrderRevision;

  /// シーンが変わるたびに増える
  ValueListenable<int> get revision;
}
