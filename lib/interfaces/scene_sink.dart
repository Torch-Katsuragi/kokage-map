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
import '../models/nodes/overlay_image_node.dart';
import '../screens/map_page/feature_geojson_cache.dart';

/// 地図ページがシーンへ書く口
abstract interface class SceneSink {
  /// View 固有スタイルの束を差し替える。変わったら true。
  /// ⚠ フィーチャを組み立てる**前**に呼ぶ（`k-style` を載せるかどうかの判断がこれを見る）
  bool setStyleGroups(List<MapStyleGroup> groups);

  /// フィーチャを組み直して描画系に知らせる。[selectionOnly] なら選択ソースだけ組み直す（通常ソースは前のまま）
  void pushFeatures(FeatureGeoJsonInput input, {required bool selectionOnly});

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

  /// シーンが変わるたびに増える
  ValueListenable<int> get revision;
}
