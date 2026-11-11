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
/// 点・線・面・クラスタリング・選択状態のスタイル設定定義
library;

import 'package:flutter/material.dart';

import '../../core/settings_schema.dart';
import '../../i18n/strings.g.dart';
import '../../models/kmeta.dart';
import 'label_style_defs.dart';

/// 値の見せ方（px・%・倍率）
String formatStylePx(double v) => '${v.toInt()} px';
String formatStylePercent(double v) => '${(v * 100).toInt()}%';
String formatStyleTimes(double v) => '${v.toStringAsFixed(1)}x';

/// 不透明度（0〜100%、10% 刻み）の設定定義を生成する
DoubleDef createStyleOpacityDef({
  required String key,
  required String title,
  required double defaultValue,
  required double? Function(KMetaLayerStyle) kmetaGetter,
  bool Function(SettingsStore store)? visibleWhen,
}) =>
    DoubleDef(
      key: key,
      title: title,
      defaultValue: defaultValue,
      min: 0.0,
      max: 1.0,
      divisions: 10,
      formatter: formatStylePercent,
      kmetaGetter: kmetaGetter,
      visibleWhen: visibleWhen,
    );

/// 頂点に点を描くか（線・面）
SwitchDef _vertexPointsEnabledDef(String key, String description) => SwitchDef(
      key: key,
      title: t.styleScreen.drawVertexPoints,
      description: description,
      defaultValue: false,
      icon: Icons.scatter_plot_outlined,
    );

/// 頂点の点の大きさ（線の太さに対する倍率。線・面）
DoubleDef _vertexPointSizeFactorDef(String key, SwitchDef enabledDef) => DoubleDef(
      key: key,
      title: t.styleScreen.vertexPointSizeFactor,
      defaultValue: 2.0,
      min: 0.5,
      max: 6.0,
      divisions: 55,
      formatter: formatStyleTimes,
      visibleWhen: (s) => s.getBool(enabledDef),
    );

// --- Point ---
final pointSizeDef = DoubleDef(
  key: 'layer_style_point_size',
  title: t.styleScreen.size,
  defaultValue: 3.0,
  min: 1,
  max: 30,
  divisions: 26,
  formatter: formatStylePx,
  kmetaGetter: (k) => k.pointSize,
);
final pointColorDef = ColorDef(
  key: 'layer_style_point_color',
  title: t.styleScreen.color,
  defaultArgb: 0xFFF44336,
  kmetaGetter: (k) => k.pointColor,
);
final pointOpacityDef = createStyleOpacityDef(
  key: 'layer_style_point_opacity',
  title: t.styleScreen.pointOpacity,
  defaultValue: 1.0,
  kmetaGetter: (k) => k.pointOpacity,
);

// --- Line ---
final lineWidthDef = DoubleDef(
  key: 'layer_style_line_width',
  title: t.styleScreen.width,
  defaultValue: 3.0,
  min: 1,
  max: 10,
  divisions: 9,
  formatter: formatStylePx,
  kmetaGetter: (k) => k.lineWidth,
);
final lineColorDef = ColorDef(
  key: 'layer_style_line_color',
  title: t.styleScreen.color,
  defaultArgb: 0xFF4CAF50,
  kmetaGetter: (k) => k.lineColor,
);
final lineOpacityDef = createStyleOpacityDef(
  key: 'layer_style_line_opacity',
  title: t.styleScreen.lineOpacity,
  defaultValue: 1.0,
  kmetaGetter: (k) => k.lineOpacity,
);
final lineVertexPointsEnabledDef = _vertexPointsEnabledDef(
  'layer_style_line_vertex_points_enabled',
  t.styleScreen.drawVertexPointsLineDesc,
);
final lineVertexPointSizeFactorDef = _vertexPointSizeFactorDef(
  'layer_style_line_vertex_point_size_factor',
  lineVertexPointsEnabledDef,
);

// --- Polygon ---
final polygonBorderWidthDef = DoubleDef(
  key: 'layer_style_polygon_border_width',
  title: t.styleScreen.borderWidth,
  defaultValue: 2.0,
  min: 0,
  max: 8,
  divisions: 16,
  formatter: (v) => '${v.toStringAsFixed(1)} px',
  kmetaGetter: (k) => k.polygonBorderWidth,
);
final polygonBorderColorDef = ColorDef(
  key: 'layer_style_polygon_border_color',
  title: t.styleScreen.borderColor,
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.polygonBorderColor,
  visibleWhen: (s) => s.getDouble(polygonBorderWidthDef) > 0,
);
final polygonFillColorDef = ColorDef(
  key: 'layer_style_polygon_fill_color',
  title: t.styleScreen.fillColor,
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.polygonFillColor,
);
final polygonFillOpacityDef = createStyleOpacityDef(
  key: 'layer_style_polygon_fill_opacity',
  title: t.styleScreen.fillOpacity,
  defaultValue: 0.1,
  kmetaGetter: (k) => k.polygonFillOpacity,
);
final polygonBorderOpacityDef = createStyleOpacityDef(
  key: 'layer_style_polygon_border_opacity',
  title: t.styleScreen.borderOpacity,
  defaultValue: 1.0,
  kmetaGetter: (k) => k.polygonBorderOpacity,
  visibleWhen: (s) => s.getDouble(polygonBorderWidthDef) > 0,
);
final polygonVertexPointsEnabledDef = _vertexPointsEnabledDef(
  'layer_style_polygon_vertex_points_enabled',
  t.styleScreen.drawVertexPointsPolygonDesc,
);
final polygonVertexPointSizeFactorDef = _vertexPointSizeFactorDef(
  'layer_style_polygon_vertex_point_size_factor',
  polygonVertexPointsEnabledDef,
);

// --- Clustering (グローバル専用) ---
final clusteringEnabledDef = SwitchDef(
  key: 'layer_style_clustering_enabled',
  title: t.styleScreen.enableClustering,
  description: t.styleScreen.enableClusteringDesc,
  defaultValue: true,
  icon: Icons.workspaces_outlined,
);
final clusteringDisableZoomDef = IntDef(
  key: 'layer_style_clustering_disable_zoom',
  title: t.styleScreen.disableAtZoom,
  defaultValue: 18,
  min: 14,
  max: 20,
  formatter: (v) => t.styleScreen.zoomN(n: v),
  visibleWhen: (s) => s.getBool(clusteringEnabledDef),
);

// --- Selection (グローバル専用) ---
final selectedColorDef = ColorDef(
  key: 'layer_style_selected_color',
  title: t.styleScreen.color,
  defaultArgb: 0xFFE91E63,
);
final selectedMultiplierDef = DoubleDef(
  key: 'layer_style_selected_multiplier',
  title: t.styleScreen.sizeMultiplier,
  defaultValue: 1.5,
  min: 1.0,
  max: 3.0,
  divisions: 20,
  formatter: formatStyleTimes,
);

/// 節のキー（表示名は翻訳で変わるので、絞り込みはこちらで）
abstract final class StyleSection {
  static const point = 'point';
  static const label = 'label';
  static const line = 'line';
  static const polygon = 'polygon';
  static const clustering = 'clustering';
  static const selection = 'selection';
}

/// レイヤ描画スタイルの全セクションを持つ [SettingsStore] を構築する
SettingsStore createLayerStyleSettingsStore({
  required CustomDef labelExpressionTileDef,
}) =>
    SettingsStore([
      SettingSectionDef(
        id: StyleSection.point,
        title: t.styleScreen.point,
        icon: Icons.place,
        initiallyExpanded: true,
        items: [pointSizeDef, pointColorDef, pointOpacityDef],
      ),
      SettingSectionDef(
        id: StyleSection.line,
        title: t.styleScreen.line,
        icon: Icons.show_chart,
        initiallyExpanded: true,
        items: [
          lineWidthDef,
          lineColorDef,
          lineOpacityDef,
          lineVertexPointsEnabledDef,
          lineVertexPointSizeFactorDef,
        ],
      ),
      SettingSectionDef(
        id: StyleSection.polygon,
        title: t.styleScreen.polygon,
        icon: Icons.crop_square,
        initiallyExpanded: true,
        items: [
          polygonBorderWidthDef,
          polygonBorderColorDef,
          polygonBorderOpacityDef,
          polygonFillColorDef,
          polygonFillOpacityDef,
          polygonVertexPointsEnabledDef,
          polygonVertexPointSizeFactorDef,
        ],
      ),
      buildLabelStyleSectionDef(labelExpressionTileDef),
      SettingSectionDef(
        id: StyleSection.clustering,
        title: t.styleScreen.clustering,
        icon: Icons.workspaces_outlined,
        iconColor: Colors.blue,
        collapsible: true,
        initiallyExpanded: false,
        globalOnly: true,
        items: [clusteringEnabledDef, clusteringDisableZoomDef],
      ),
      SettingSectionDef(
        id: StyleSection.selection,
        title: t.styleScreen.selection,
        icon: Icons.highlight_alt,
        collapsible: true,
        initiallyExpanded: false,
        globalOnly: true,
        items: [selectedColorDef, selectedMultiplierDef],
      ),
    ]);
