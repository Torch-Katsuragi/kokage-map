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
import 'package:flutter/foundation.dart';

import '../../interfaces/scene_sink.dart';
import '../../models/map_style_group.dart';
import '../../models/nodes/overlay_image_node.dart';
import 'feature_geojson_cache.dart';

/// 地図ページのシーン（[SceneSink] と [MapScene] の実装）。所有は地図ページ
class MapSceneStore implements SceneSink, MapScene {
  MapSceneStore({required this.overlayImagesOf});

  /// オーバーレイ画像の正は地図ページのフィーチャキャッシュ（選択ツールも読む）なので、ここは覗くだけ
  final List<OverlayImageNode> Function() overlayImagesOf;

  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  @override
  final FeatureGeoJsonCache features = FeatureGeoJsonCache();

  List<MapStyleGroup> _styleGroups = const [];

  @override
  List<MapStyleGroup> get styleGroups => _styleGroups;

  @override
  List<OverlayImageNode> get overlayImages => overlayImagesOf();

  @override
  ValueListenable<int> get revision => _revision;

  @override
  bool setStyleGroups(List<MapStyleGroup> groups) {
    if (styleGroupsEqual(_styleGroups, groups)) return false;
    _styleGroups = List.unmodifiable(groups);
    return true;
  }

  @override
  void pushFeatures(FeatureGeoJsonInput input, {required bool selectionOnly}) {
    if (selectionOnly) {
      features.rebuildSelection(input);
    } else {
      features.rebuildAll(input);
    }
    invalidate();
  }

  @override
  void invalidate() => _revision.value++;
}
