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
/// レイヤ・View の行の左端: 地図で描いている色の見本（点は丸、線は線、面は塗りと枠）
library;

import 'package:flutter/material.dart';

import '../../../models/kmeta.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/view_node.dart';
import '../../../screens/layer_style_settings_screen.dart'
    show layerStyleSettings, pointColorDef, lineColorDef, polygonFillColorDef, polygonFillOpacityDef, polygonBorderColorDef, polygonBorderOpacityDef;

class LayerSwatch extends StatelessWidget {
  const LayerSwatch({super.key, required this.layer, this.view, this.dimmed = false});
  final LayerNode layer;
  final ViewNode? view;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    // 描画と同じ合成: View の指定が無い項目はレイヤの値、その下にアプリ全体の設定
    final layerStyle = layer.kmetaStyleIfLoaded;
    final KMetaLayerStyle? style = view?.style == null ? layerStyle : view!.style!.mergeWith(layerStyle);
    final s = layerStyleSettings;
    Color c(Color v) => dimmed ? Colors.black26 : v;
    switch (layer) {
      case PointLayerNode():
        return Container(width: 12, height: 12, decoration: BoxDecoration(color: c(s.resolveColor(pointColorDef, style)), shape: BoxShape.circle));
      case LineLayerNode():
        return Container(width: 18, height: 4, decoration: BoxDecoration(color: c(s.resolveColor(lineColorDef, style)), borderRadius: BorderRadius.circular(2)));
      case PolygonLayerNode():
        final fill = s.resolveColor(polygonFillColorDef, style).withValues(alpha: s.resolveDouble(polygonFillOpacityDef, style));
        final border = s.resolveColor(polygonBorderColorDef, style).withValues(alpha: s.resolveDouble(polygonBorderOpacityDef, style).clamp(0.3, 1.0));
        return Container(
          width: 16,
          height: 14,
          decoration: BoxDecoration(color: dimmed ? null : fill, border: Border.all(color: c(border), width: 2), borderRadius: BorderRadius.circular(2)),
        );
      default:
        return Icon(Icons.layers, size: 18, color: c(Colors.blue));
    }
  }
}
