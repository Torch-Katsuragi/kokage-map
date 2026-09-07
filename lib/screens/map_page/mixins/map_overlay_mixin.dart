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
// こかげマップ: オーバーレイ画像（GeoTIFF 等）を MapLibre の ImageSource として同期する

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre/maplibre.dart' as ml;

import '../../../models/nodes/overlay_image_node.dart';
import '../../../utils/geo_converter.dart';
import '../map_page_state_base.dart';

mixin MapOverlayMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  ml.LngLatQuad _quadOf(OverlayImageNode node) {
    final c = node.cornerCoordinates;
    return ml.LngLatQuad(
      topLeft: c[0].toGeographic(),
      topRight: c[1].toGeographic(),
      bottomRight: c[2].toGeographic(),
      bottomLeft: c[3].toGeographic(),
    );
  }

  /// 変形中のオーバーレイの四隅を差し替える。
  /// setState は呼ばない（ハンドルマーカーは transformNotifier 経由で局所 rebuild）
  @override
  void updateOverlayTransform(OverlayImageNode node) {
    if (!sourceManager.isInitialized) return;
    sourceManager.updateOverlayCoordinates(
      node.overlaySourceId,
      _quadOf(node),
      imageUrl: node.imageUrl,
      layerId: node.overlayLayerId,
    );
  }

  /// 可視なオーバーレイと MapLibre 側のソースを突き合わせ、増減ぶんだけ足し引きする
  void syncOverlayImages() {
    if (!sourceManager.isInitialized) return;

    final currentIds = {for (final n in overlayImageNodes) n.overlaySourceId};

    for (final id in activeOverlaySourceIds.difference(currentIds)) {
      sourceManager.removeOverlayImage(
        id,
        id.replaceFirst('overlay-src-', 'overlay-lyr-'),
      );
    }

    final toAdd = currentIds.difference(activeOverlaySourceIds);
    for (final node in overlayImageNodes) {
      if (!toAdd.contains(node.overlaySourceId)) continue;
      sourceManager.addOverlayImage(
        sourceId: node.overlaySourceId,
        layerId: node.overlayLayerId,
        imageUrl: node.imageUrl,
        coordinates: _quadOf(node),
      );
    }

    activeOverlaySourceIds = currentIds;
  }
}
