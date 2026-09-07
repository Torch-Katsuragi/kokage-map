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
/// レイヤ描画設定画面
///
/// 点・線・ポリゴンの描画スタイルを宣言的に定義。
/// SettingsStoreでSharedPreferences/KMeta両対応の永続化を行い、
/// DataDrivenSettingsScreenでUI自動生成。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/settings_schema.dart';
import '../i18n/strings.g.dart';
import '../models/kmeta.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/view_node.dart';
import '../services/kmeta_service.dart';
import '../utils/app_logger.dart';
import '../widgets/settings_widgets.dart';

// ============================================================
// 設定定義
// ============================================================

// --- Point ---
final pointSizeDef = DoubleDef(
  key: 'layer_style_point_size',
  title: 'Size',
  defaultValue: 3.0,
  min: 1,
  max: 30,
  divisions: 26,
  formatter: (v) => '${v.toInt()} px',
  kmetaGetter: (k) => k.pointSize,
);
final pointColorDef = ColorDef(
  key: 'layer_style_point_color',
  title: 'Color',
  defaultArgb: 0xFFF44336,
  kmetaGetter: (k) => k.pointColor,
);

// --- Line ---
final lineWidthDef = DoubleDef(
  key: 'layer_style_line_width',
  title: 'Width',
  defaultValue: 3.0,
  min: 1,
  max: 10,
  divisions: 9,
  formatter: (v) => '${v.toInt()} px',
  kmetaGetter: (k) => k.lineWidth,
);
final lineColorDef = ColorDef(
  key: 'layer_style_line_color',
  title: 'Color',
  defaultArgb: 0xFF4CAF50,
  kmetaGetter: (k) => k.lineColor,
);
const lineVertexPointsEnabledDef = SwitchDef(
  key: 'layer_style_line_vertex_points_enabled',
  title: 'Draw Vertex Points',
  description: 'Overlay points at each vertex (color follows line)',
  defaultValue: false,
  icon: Icons.scatter_plot_outlined,
);
final lineVertexPointSizeFactorDef = DoubleDef(
  key: 'layer_style_line_vertex_point_size_factor',
  title: 'Vertex Point Size Factor',
  defaultValue: 2.0,
  min: 0.5,
  max: 6.0,
  divisions: 55,
  formatter: (v) => '${v.toStringAsFixed(1)}x',
);

// --- Polygon ---
final polygonBorderWidthDef = DoubleDef(
  key: 'layer_style_polygon_border_width',
  title: 'Border Width',
  defaultValue: 2.0,
  min: 0,
  max: 8,
  divisions: 16,
  formatter: (v) => '${v.toStringAsFixed(1)} px',
  kmetaGetter: (k) => k.polygonBorderWidth,
);
final polygonBorderColorDef = ColorDef(
  key: 'layer_style_polygon_border_color',
  title: 'Border Color',
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.polygonBorderColor,
);
final polygonFillColorDef = ColorDef(
  key: 'layer_style_polygon_fill_color',
  title: 'Fill Color',
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.polygonFillColor,
);
final polygonFillOpacityDef = DoubleDef(
  key: 'layer_style_polygon_fill_opacity',
  title: 'Fill Opacity',
  defaultValue: 0.1,
  min: 0.0,
  max: 1.0,
  divisions: 10,
  formatter: (v) => '${(v * 100).toInt()}%',
  kmetaGetter: (k) => k.polygonFillOpacity,
);
final polygonBorderOpacityDef = DoubleDef(
  key: 'layer_style_polygon_border_opacity',
  title: 'Border Opacity',
  defaultValue: 1.0,
  min: 0.0,
  max: 1.0,
  divisions: 10,
  formatter: (v) => '${(v * 100).toInt()}%',
  kmetaGetter: (k) => k.polygonBorderOpacity,
);
const polygonVertexPointsEnabledDef = SwitchDef(
  key: 'layer_style_polygon_vertex_points_enabled',
  title: 'Draw Vertex Points',
  description: 'Overlay points at each vertex (color follows border)',
  defaultValue: false,
  icon: Icons.scatter_plot_outlined,
);
final polygonVertexPointSizeFactorDef = DoubleDef(
  key: 'layer_style_polygon_vertex_point_size_factor',
  title: 'Vertex Point Size Factor',
  defaultValue: 2.0,
  min: 0.5,
  max: 6.0,
  divisions: 55,
  formatter: (v) => '${v.toStringAsFixed(1)}x',
);

// --- Label ---
final labelEnabledDef = SwitchDef(
  key: 'layer_style_label_enabled',
  title: 'Show Label',
  description: 'Display property value next to point markers',
  defaultValue: true,
  icon: Icons.text_fields,
  kmetaGetter: (k) => k.labelEnabled,
);
final labelPropertyDef = StringDef(
  key: 'layer_style_label_property',
  title: 'Property',
  defaultValue: 'name',
  kmetaGetter: (k) => k.labelProperty,
);
final labelFontSizeDef = DoubleDef(
  key: 'layer_style_label_font_size',
  title: 'Font Size',
  defaultValue: 12.0,
  min: 8,
  max: 24,
  divisions: 16,
  formatter: (v) => '${v.toInt()} px',
  kmetaGetter: (k) => k.labelFontSize,
);
final labelColorDef = ColorDef(
  key: 'layer_style_label_color',
  title: 'Text Color',
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.labelColor,
);
final labelHaloColorDef = ColorDef(
  key: 'layer_style_label_halo_color',
  title: 'Halo Color',
  defaultArgb: 0xFFFFFFFF,
  kmetaGetter: (k) => k.labelHaloColor,
);
final labelOpacityDef = DoubleDef(
  key: 'layer_style_label_opacity',
  title: 'Opacity',
  defaultValue: 1.0,
  min: 0.0,
  max: 1.0,
  divisions: 10,
  formatter: (v) => '${(v * 100).toInt()}%',
  kmetaGetter: (k) => k.labelOpacity,
);

// --- Clustering (グローバル専用) ---
const clusteringEnabledDef = SwitchDef(
  key: 'layer_style_clustering_enabled',
  title: 'Enable Clustering',
  description: 'Nearby markers are grouped into clusters',
  defaultValue: true,
  icon: Icons.workspaces_outlined,
);
final clusteringRadiusDef = IntDef(
  key: 'layer_style_clustering_radius',
  title: 'Cluster Radius',
  defaultValue: 12,
  min: 1,
  max: 150,
  formatter: (v) => '$v px',
);
final clusteringDisableZoomDef = IntDef(
  key: 'layer_style_clustering_disable_zoom',
  title: 'Disable at Zoom',
  defaultValue: 18,
  min: 14,
  max: 20,
  formatter: (v) => 'Zoom $v',
);

// --- Selection (グローバル専用) ---
const selectedColorDef = ColorDef(
  key: 'layer_style_selected_color',
  title: 'Color',
  defaultArgb: 0xFFE91E63,
);
final selectedMultiplierDef = DoubleDef(
  key: 'layer_style_selected_multiplier',
  title: 'Size Multiplier',
  defaultValue: 1.5,
  min: 1.0,
  max: 3.0,
  divisions: 20,
  formatter: (v) => '${v.toStringAsFixed(1)}x',
);

// ============================================================
// ストア（グローバルシングルトン）
// ============================================================

final layerStyleSettings = SettingsStore([
  SettingSectionDef(
    title: 'Point Style',
    icon: Icons.place,
    items: [pointSizeDef, pointColorDef],
  ),
  SettingSectionDef(
    title: 'Label Style',
    icon: Icons.label_outline,
    collapsible: true,
    initiallyExpanded: false,
    items: [
      labelEnabledDef,
      labelPropertyDef,
      labelFontSizeDef,
      labelColorDef,
      labelHaloColorDef,
      labelOpacityDef,
    ],
  ),
  SettingSectionDef(
    title: 'Line Style',
    icon: Icons.show_chart,
    items: [
      lineWidthDef,
      lineColorDef,
      lineVertexPointsEnabledDef,
      lineVertexPointSizeFactorDef,
    ],
  ),
  SettingSectionDef(
    title: 'Polygon Style',
    icon: Icons.crop_square,
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
  SettingSectionDef(
    title: 'Marker Clustering',
    icon: Icons.workspaces_outlined,
    iconColor: Colors.blue,
    collapsible: true,
    initiallyExpanded: false,
    globalOnly: true,
    items: [clusteringEnabledDef, clusteringDisableZoomDef],
  ),
  SettingSectionDef(
    title: 'Selection Highlight',
    icon: Icons.highlight_alt,
    collapsible: true,
    initiallyExpanded: false,
    globalOnly: true,
    items: [selectedColorDef, selectedMultiplierDef],
  ),
]);

// ============================================================
// 画面
// ============================================================

class LayerStyleSettingsScreen extends StatefulWidget {
  final bool isEmbedded;
  final LayerNode? targetLayer;
  final String? folderPath;

  /// View 単位でスタイルを編集するときに渡す。
  ///
  /// 渡すと保存先が `styles.layers[layerKey]` ではなく
  /// `views[layerKey][i].style` になる。それ以外の見た目は同じ。
  final ViewNode? targetView;

  const LayerStyleSettingsScreen({
    super.key,
    this.isEmbedded = false,
    this.targetLayer,
    this.folderPath,
    this.targetView,
  });

  bool get isLayerMode => targetLayer != null && folderPath != null;

  /// View のスタイルを編集しているか
  bool get isViewMode => isLayerMode && targetView != null;

  @override
  State<LayerStyleSettingsScreen> createState() =>
      _LayerStyleSettingsScreenState();
}

class _LayerStyleSettingsScreenState extends State<LayerStyleSettingsScreen> {
  bool get _isGlobalMode => !widget.isLayerMode;

  String get _title =>
      _isGlobalMode
          ? t.settingsWidget.layerDrawingTitle
          : t.settingsWidget.styleTitle(
            name:
                widget.isViewMode
                    ? '${widget.targetLayer!.layerName} / ${widget.targetView!.name}'
                    : widget.targetLayer!.layerName,
          );

  /// レイヤータイプに応じてセクションをフィルタ
  bool _sectionFilter(SettingSectionDef section) {
    if (_isGlobalMode) return true;
    final layer = widget.targetLayer;
    return switch (section.title) {
      'Point Style' || 'Label Style' => layer is PointLayerNode,
      'Line Style' => layer is LineLayerNode,
      'Polygon Style' => layer is PolygonLayerNode,
      _ => false,
    };
  }

  /// KMeta初期化（個別レイヤーモード）
  Future<void> _onInit() async {
    if (widget.isViewMode) {
      // View に指定が無ければレイヤのスタイルを初期値として見せる
      final meta = await KMetaService.instance.getMeta(
        widget.folderPath!,
      );
      layerStyleSettings.loadOverlay(
        widget.targetView!.style ??
            meta.getLayerStyle(widget.targetLayer!.layerKey),
      );
    } else if (widget.isLayerMode) {
      final meta = await KMetaService.instance.getMeta(
        widget.folderPath!,
      );
      final layerStyle = meta.getLayerStyle(widget.targetLayer!.layerKey);
      layerStyleSettings.loadOverlay(layerStyle);
    } else {
      layerStyleSettings.clearOverlay();
    }
  }

  /// 値変更時のKMeta自動保存
  void _onValueChanged() {
    if (!widget.isLayerMode) return;
    _saveToKMeta();
  }

  /// overlay値をKMetaに保存
  Future<void> _saveToKMeta() async {
    final style = KMetaLayerStyle(
      pointSize: layerStyleSettings.getDouble(pointSizeDef),
      pointColor: layerStyleSettings.getColor(pointColorDef),
      lineWidth: layerStyleSettings.getDouble(lineWidthDef),
      lineColor: layerStyleSettings.getColor(lineColorDef),
      polygonBorderWidth: layerStyleSettings.getDouble(polygonBorderWidthDef),
      polygonBorderColor: layerStyleSettings.getColor(polygonBorderColorDef),
      polygonFillColor: layerStyleSettings.getColor(polygonFillColorDef),
      polygonFillOpacity: layerStyleSettings.getDouble(polygonFillOpacityDef),
      polygonBorderOpacity: layerStyleSettings.getDouble(
        polygonBorderOpacityDef,
      ),
      labelEnabled: layerStyleSettings.getBool(labelEnabledDef),
      labelProperty: layerStyleSettings.getString(labelPropertyDef),
      labelFontSize: layerStyleSettings.getDouble(labelFontSizeDef),
      labelColor: layerStyleSettings.getColor(labelColorDef),
      labelHaloColor: layerStyleSettings.getColor(labelHaloColorDef),
      labelOpacity: layerStyleSettings.getDouble(labelOpacityDef),
    );
    if (widget.isViewMode) {
      widget.targetView!.style = style;
      await widget.targetLayer!.persistViews();
      widget.targetLayer!.folderNode?.invalidateMetaCache();
      await widget.targetLayer!.refreshStyleGroups();
      AppLogger.debug('[LayerStyle] View設定を保存: ${widget.targetView!.viewKey}');
      return;
    }

    await KMetaService.instance.setLayerStyle(
      widget.folderPath!,
      widget.targetLayer!.layerKey,
      style,
    );
    widget.targetLayer!.folderNode?.invalidateMetaCache();
    widget.targetLayer!.invalidateKmetaStyleCache();
    // スタイルを変えたら「どのフィーチャがどのグループか」も取り直す
    await widget.targetLayer!.refreshStyleGroups();
    AppLogger.debug(
      '[LayerStyle] レイヤー固有設定を保存: ${widget.targetLayer!.layerKey}',
    );
  }

  /// リセット処理
  Future<void> _resetSettings() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.settingsWidget.resetSettings),
        content: Text(
          _isGlobalMode
              ? t.settingsWidget.resetAllConfirm
              : t.settingsWidget.resetLayerConfirm,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.common.reset),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    if (_isGlobalMode) {
      await layerStyleSettings.resetAll();
    } else {
      // KMetaからレイヤー固有スタイルを削除
      final rawMeta =
          await KMetaService.instance.getRawMeta(widget.folderPath!) ??
          KMeta.empty;
      final updatedLayers = Map<String, KMetaLayerStyle>.from(
        rawMeta.styles.layers,
      );
      updatedLayers.remove(widget.targetLayer!.layerKey);
      final updatedStyles = KMetaStyles(
        defaultStyle: rawMeta.styles.defaultStyle,
        layers: updatedLayers,
      );
      await KMetaService.instance.saveMeta(
        widget.folderPath!,
        rawMeta.copyWith(styles: updatedStyles),
      );
      widget.targetLayer!.invalidateKmetaStyleCache();
      // overlayをグローバル値にリセット
      layerStyleSettings.loadOverlay(null);
    }
    AppLogger.debug('[LayerStyle] 設定をリセットしました');
  }

  @override
  void dispose() {
    if (widget.isLayerMode) layerStyleSettings.clearOverlay();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DataDrivenSettingsScreen(
      title: _title,
      store: layerStyleSettings,
      isEmbedded: widget.isEmbedded,
      onInit: _onInit,
      onReset: _resetSettings,
      onValueChanged: _onValueChanged,
      sectionFilter: _sectionFilter,
      customSections: (store) => [_buildPreviewSection(store)],
    );
  }

  /// プレビューセクション
  Widget _buildPreviewSection(SettingsStore store) {
    return SettingsSection(
      title: 'Preview',
      icon: Icons.preview,
      iconColor: Colors.purple,
      collapsible: true,
      initiallyExpanded: true,
      children: [
        SizedBox(
          height: 100,
          child: CustomPaint(
            painter: _StylePreviewPainter(
              pointColor: store.getColor(pointColorDef),
              pointSize: store.getDouble(pointSizeDef),
              lineColor: store.getColor(lineColorDef),
              lineWidth: store.getDouble(lineWidthDef),
              polygonBorderColor: store.getColor(polygonBorderColorDef),
              polygonBorderWidth: store.getDouble(polygonBorderWidthDef),
              polygonFillColor: store.getColor(polygonFillColorDef),
              polygonFillOpacity: store.getDouble(polygonFillOpacityDef),
              polygonBorderOpacity: store.getDouble(polygonBorderOpacityDef),
            ),
            size: const Size(double.infinity, 100),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// スタイルプレビューPainter
// ============================================================

class _StylePreviewPainter extends CustomPainter {
  final Color pointColor;
  final double pointSize;
  final Color lineColor;
  final double lineWidth;
  final Color polygonBorderColor;
  final double polygonBorderWidth;
  final Color polygonFillColor;
  final double polygonFillOpacity;
  final double polygonBorderOpacity;

  _StylePreviewPainter({
    required this.pointColor,
    required this.pointSize,
    required this.lineColor,
    required this.lineWidth,
    required this.polygonBorderColor,
    required this.polygonBorderWidth,
    required this.polygonFillColor,
    required this.polygonFillOpacity,
    required this.polygonBorderOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ポリゴン（六角形）
    final polygonPath = Path();
    final cx = size.width * 0.75;
    final cy = size.height * 0.5;
    const r = 35.0;
    for (int i = 0; i < 6; i++) {
      final angle = (i * 60 - 90) * math.pi / 180;
      final x = cx + r * math.cos(angle);
      final y = cy + r * math.sin(angle);
      if (i == 0) {
        polygonPath.moveTo(x, y);
      } else {
        polygonPath.lineTo(x, y);
      }
    }
    polygonPath.close();
    canvas.drawPath(
      polygonPath,
      Paint()
        ..color = polygonFillColor.withValues(alpha: polygonFillOpacity)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      polygonPath,
      Paint()
        ..color = polygonBorderColor.withValues(alpha: polygonBorderOpacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = polygonBorderWidth,
    );

    // ライン
    final linePath = Path()
      ..moveTo(size.width * 0.35, size.height * 0.7)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height * 0.2,
        size.width * 0.65,
        size.height * 0.5,
      );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = lineWidth
        ..strokeCap = StrokeCap.round,
    );

    // ポイント
    canvas.drawCircle(
      Offset(size.width * 0.15, size.height * 0.5),
      pointSize / 2,
      Paint()
        ..color = pointColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _StylePreviewPainter oldDelegate) => true;
}
