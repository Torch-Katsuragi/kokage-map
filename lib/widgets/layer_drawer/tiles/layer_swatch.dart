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
/// レイヤ・View の行の左端: レイヤは種類のアイコン（点・線・面）、View は筆と色見本のアイコン。どちらも地図で描いている色で塗る
library;

import 'package:flutter/material.dart';

import '../../../models/kmeta.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/view_node.dart';
import '../../../presentation/node_presenter.dart';
import '../../../screens/layer_style_settings_screen.dart'
    show layerStyleSettings, pointColorDef, lineColorDef, polygonFillColorDef, polygonFillOpacityDef, polygonBorderColorDef;

class LayerSwatch extends StatelessWidget {
  const LayerSwatch({super.key, required this.layer, this.view, this.dimmed = false, this.legend = false});
  final LayerNode layer;
  final ViewNode? view;
  final bool dimmed;

  /// 行の下に QGIS の描き分けの凡例を出すか（出すなら View のアイコンは色を付けない）
  final bool legend;

  @override
  Widget build(BuildContext context) {
    // 描画と同じ合成: View の指定が無い項目はレイヤの値、その下にアプリ全体の設定
    final layerStyle = layer.kmetaStyleIfLoaded;
    final KMetaLayerStyle? style = view?.style == null ? layerStyle : view!.style!.mergeWith(layerStyle);
    final s = layerStyleSettings;
    Color c(Color v) => dimmed ? Colors.black26 : v;
    // 種類のアイコン（点・線・面）を地図で描いている色で塗る。形だけの見本だと種類が分かりにくかった（2026-10-11）
    final Color color = switch (layer) {
      PointLayerNode() => s.resolveColor(pointColorDef, style),
      LineLayerNode() => s.resolveColor(lineColorDef, style),
      // 面は枠の色（林班のように塗りが薄く枠が本体のことが多い）。塗りが濃ければ塗りの色
      PolygonLayerNode() => s.resolveDouble(polygonFillOpacityDef, style) >= 0.5
          ? s.resolveColor(polygonFillColorDef, style)
          : s.resolveColor(polygonBorderColorDef, style),
      _ => Colors.blue,
    };
    // View は「同じデータの見せ方」なので種類のアイコンでなく筆と色見本のアイコン。レイヤが何本もあるように見えた（2026-10-13）。
    // QGIS の描き分けなら色は行の下の凡例で見えるので、アイコンは色を付けない。単色の View だけ描いている色を付ける
    if (view != null) {
      final neutral = Theme.of(context).colorScheme.onSurfaceVariant;
      return Icon(Icons.style_outlined, size: 20, color: c(legend ? neutral : color.withValues(alpha: 1)));
    }
    return Icon(NodePresenter.getIcon(layer), size: 20, color: c(color.withValues(alpha: 1)));
  }
}
