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
final pointShapeDef = StringDef(
  key: 'layer_style_point_shape',
  title: t.styleScreen.pointShape,
  defaultValue: 'circle',
  kmetaGetter: (k) => k.pointShape,
  options: [
    ('circle', t.styleScreen.pointShapeCircle),
    ('square', t.styleScreen.pointShapeSquare),
    ('diamond', t.styleScreen.pointShapeDiamond),
    ('triangle', t.styleScreen.pointShapeTriangle),
    ('star', t.styleScreen.pointShapeStar),
    ('cross', t.styleScreen.pointShapeCross),
    ('cross2', t.styleScreen.pointShapeX),
  ],
);
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
final pointOutlineEnabledDef = SwitchDef(
  key: 'layer_style_point_outline_enabled',
  title: t.styleScreen.pointOutline,
  defaultValue: true,
  kmetaGetter: (k) => k.pointOutlineEnabled,
);
final pointOutlineColorDef = ColorDef(
  key: 'layer_style_point_outline_color',
  title: t.styleScreen.pointOutlineColor,
  defaultArgb: 0xFFFFFFFF,
  kmetaGetter: (k) => k.pointOutlineColor,
  visibleWhen: (s) => s.getBool(pointOutlineEnabledDef),
);
final pointOutlineWidthDef = DoubleDef(
  key: 'layer_style_point_outline_width',
  title: t.styleScreen.pointOutlineWidth,
  defaultValue: 1.5,
  min: 0.5,
  max: 5.0,
  divisions: 9,
  formatter: (v) => '${v.toStringAsFixed(1)} px',
  kmetaGetter: (k) => k.pointOutlineWidth,
  visibleWhen: (s) => s.getBool(pointOutlineEnabledDef),
);

List<(String, String)> _lineDashOptions() => [
      ('solid', t.styleScreen.lineStyleSolid),
      ('dash', t.styleScreen.lineStyleDash),
      ('dot', t.styleScreen.lineStyleDot),
      ('dash_dot', t.styleScreen.lineStyleDashDot),
      ('dash_dot_dot', t.styleScreen.lineStyleDashDotDot),
    ];

// --- Line ---
final lineDashDef = StringDef(
  key: 'layer_style_line_dash',
  title: t.styleScreen.lineStyle,
  defaultValue: 'solid',
  kmetaGetter: (k) => k.lineDash,
  options: _lineDashOptions(),
);
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
final lineCasingEnabledDef = SwitchDef(
  key: 'layer_style_line_casing_enabled',
  title: t.styleScreen.casing,
  description: t.styleScreen.casingDesc,
  defaultValue: false,
  kmetaGetter: (k) => k.lineCasingEnabled,
);
final lineCasingColorDef = ColorDef(
  key: 'layer_style_line_casing_color',
  title: t.styleScreen.casingColor,
  defaultArgb: 0xFFFFFFFF,
  kmetaGetter: (k) => k.lineCasingColor,
  visibleWhen: (s) => s.getBool(lineCasingEnabledDef),
);
final lineCasingWidthDef = DoubleDef(
  key: 'layer_style_line_casing_width',
  title: t.styleScreen.casingWidth,
  defaultValue: 2.0,
  min: 0.5,
  max: 8.0,
  divisions: 15,
  formatter: (v) => '${v.toStringAsFixed(1)} px',
  kmetaGetter: (k) => k.lineCasingWidth,
  visibleWhen: (s) => s.getBool(lineCasingEnabledDef),
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
final polygonFillPatternDef = StringDef(
  key: 'layer_style_polygon_fill_pattern',
  title: t.styleScreen.fillPattern,
  defaultValue: 'solid',
  kmetaGetter: (k) => k.polygonFillPattern,
  options: [
    ('solid', t.styleScreen.fillPatternSolid),
    ('slash', t.styleScreen.fillPatternSlash),
    ('backslash', t.styleScreen.fillPatternBackslash),
    ('cross', t.styleScreen.fillPatternCross),
    ('grid', t.styleScreen.fillPatternGrid),
    ('horizontal', t.styleScreen.fillPatternHorizontal),
    ('vertical', t.styleScreen.fillPatternVertical),
    ('dots', t.styleScreen.fillPatternDots),
    ('none', t.styleScreen.fillPatternNone),
  ],
);
final polygonFillColorDef = ColorDef(
  key: 'layer_style_polygon_fill_color',
  title: t.styleScreen.fillColor,
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.polygonFillColor,
  visibleWhen: (s) => s.getString(polygonFillPatternDef) != 'none',
);
final polygonFillOpacityDef = createStyleOpacityDef(
  key: 'layer_style_polygon_fill_opacity',
  title: t.styleScreen.fillOpacity,
  defaultValue: 0.1,
  kmetaGetter: (k) => k.polygonFillOpacity,
  visibleWhen: (s) => s.getString(polygonFillPatternDef) != 'none',
);
final polygonPatternSpacingDef = DoubleDef(
  key: 'layer_style_polygon_pattern_spacing',
  title: t.styleScreen.patternSpacing,
  defaultValue: 8.0,
  min: 4.0,
  max: 24.0,
  divisions: 20,
  formatter: formatStylePx,
  kmetaGetter: (k) => k.polygonPatternSpacing,
  visibleWhen: (s) {
    final pat = s.getString(polygonFillPatternDef);
    return pat != 'solid' && pat != 'none';
  },
);
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
final polygonBorderDashDef = StringDef(
  key: 'layer_style_polygon_border_dash',
  title: t.styleScreen.borderStyle,
  defaultValue: 'solid',
  kmetaGetter: (k) => k.polygonBorderDash,
  options: _lineDashOptions(),
  visibleWhen: (s) => s.getDouble(polygonBorderWidthDef) > 0,
);
final polygonBorderColorDef = ColorDef(
  key: 'layer_style_polygon_border_color',
  title: t.styleScreen.borderColor,
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.polygonBorderColor,
  visibleWhen: (s) => s.getDouble(polygonBorderWidthDef) > 0,
);
final polygonBorderOpacityDef = createStyleOpacityDef(
  key: 'layer_style_polygon_border_opacity',
  title: t.styleScreen.borderOpacity,
  defaultValue: 1.0,
  kmetaGetter: (k) => k.polygonBorderOpacity,
  visibleWhen: (s) => s.getDouble(polygonBorderWidthDef) > 0,
);
final polygonBorderCasingEnabledDef = SwitchDef(
  key: 'layer_style_polygon_border_casing_enabled',
  title: t.styleScreen.borderCasing,
  defaultValue: false,
  kmetaGetter: (k) => k.polygonBorderCasingEnabled,
  visibleWhen: (s) => s.getDouble(polygonBorderWidthDef) > 0,
);
final polygonBorderCasingColorDef = ColorDef(
  key: 'layer_style_polygon_border_casing_color',
  title: t.styleScreen.borderCasingColor,
  defaultArgb: 0xFFFFFFFF,
  kmetaGetter: (k) => k.polygonBorderCasingColor,
  visibleWhen: (s) =>
      s.getDouble(polygonBorderWidthDef) > 0 && s.getBool(polygonBorderCasingEnabledDef),
);
final polygonBorderCasingWidthDef = DoubleDef(
  key: 'layer_style_polygon_border_casing_width',
  title: t.styleScreen.borderCasingWidth,
  defaultValue: 2.0,
  min: 0.5,
  max: 6.0,
  divisions: 11,
  formatter: (v) => '${v.toStringAsFixed(1)} px',
  kmetaGetter: (k) => k.polygonBorderCasingWidth,
  visibleWhen: (s) =>
      s.getDouble(polygonBorderWidthDef) > 0 && s.getBool(polygonBorderCasingEnabledDef),
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
        items: [
          pointShapeDef,
          pointSizeDef,
          pointColorDef,
          pointOpacityDef,
          pointOutlineEnabledDef,
          pointOutlineColorDef,
          pointOutlineWidthDef,
        ],
      ),
      SettingSectionDef(
        id: StyleSection.line,
        title: t.styleScreen.line,
        icon: Icons.show_chart,
        initiallyExpanded: true,
        items: [
          lineDashDef,
          lineWidthDef,
          lineColorDef,
          lineOpacityDef,
          lineCasingEnabledDef,
          lineCasingColorDef,
          lineCasingWidthDef,
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
          polygonFillPatternDef,
          polygonFillColorDef,
          polygonFillOpacityDef,
          polygonPatternSpacingDef,
          polygonBorderWidthDef,
          polygonBorderDashDef,
          polygonBorderColorDef,
          polygonBorderOpacityDef,
          polygonBorderCasingEnabledDef,
          polygonBorderCasingColorDef,
          polygonBorderCasingWidthDef,
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
