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
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings_schema.dart';
import '../i18n/strings.g.dart';
import '../models/kmeta.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/view_node.dart';
import '../models/qgis_renderer.dart';
import '../providers/ui_state_providers.dart';
import '../services/kmeta_service.dart';
import '../tutorial/tutorial.dart';
import '../utils/app_logger.dart';
import '../utils/attribute_columns.dart';
import '../utils/label_expression.dart';
import '../utils/label_template.dart';
import '../widgets/label_composer_dialog.dart';
import '../widgets/qgis_renderer_legend.dart';
import '../widgets/settings_widgets.dart';

// ============================================================
// 設定定義
// ============================================================

// 値の見せ方
String _px(double v) => '${v.toInt()} px';
String _percent(double v) => '${(v * 100).toInt()}%';
String _times(double v) => '${v.toStringAsFixed(1)}x';

/// 不透明度（0〜100%、10% 刻み）
DoubleDef _opacityDef({
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
      formatter: _percent,
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
      formatter: _times,
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
  formatter: _px,
  kmetaGetter: (k) => k.pointSize,
);
final pointColorDef = ColorDef(
  key: 'layer_style_point_color',
  title: t.styleScreen.color,
  defaultArgb: 0xFFF44336,
  kmetaGetter: (k) => k.pointColor,
);
final pointOpacityDef = _opacityDef(
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
  formatter: _px,
  kmetaGetter: (k) => k.lineWidth,
);
final lineColorDef = ColorDef(
  key: 'layer_style_line_color',
  title: t.styleScreen.color,
  defaultArgb: 0xFF4CAF50,
  kmetaGetter: (k) => k.lineColor,
);
final lineOpacityDef = _opacityDef(
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
final polygonFillOpacityDef = _opacityDef(
  key: 'layer_style_polygon_fill_opacity',
  title: t.styleScreen.fillOpacity,
  defaultValue: 0.1,
  kmetaGetter: (k) => k.polygonFillOpacity,
);
final polygonBorderOpacityDef = _opacityDef(
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

// --- Label ---
final labelEnabledDef = SwitchDef(
  key: 'layer_style_label_enabled',
  title: t.styleScreen.showLabel,
  description: t.styleScreen.showLabelDesc,
  defaultValue: true,
  icon: Icons.text_fields,
  kmetaGetter: (k) => k.labelEnabled,
);

/// ラベルの中身（QGIS の式。`label_expression.dart`）。
/// 画面には出さず、[labelExpressionTileDef] が組み立てダイアログ経由で書き換える
final labelPropertyDef = StringDef(
  key: 'layer_style_label_property',
  title: t.styleScreen.labelExpression,
  defaultValue: 'name',
  kmetaGetter: (k) => k.labelProperty,
);
final labelExpressionTileDef = CustomDef(
  key: 'layer_style_label_expression_tile',
  title: t.styleScreen.labelExpression,
  builder: _buildLabelExpressionTile,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);
final labelFontSizeDef = DoubleDef(
  key: 'layer_style_label_font_size',
  title: t.styleScreen.fontSize,
  defaultValue: 12.0,
  min: 8,
  max: 24,
  divisions: 16,
  formatter: _px,
  kmetaGetter: (k) => k.labelFontSize,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);
final labelColorDef = ColorDef(
  key: 'layer_style_label_color',
  title: t.styleScreen.textColor,
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.labelColor,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);
final labelHaloColorDef = ColorDef(
  key: 'layer_style_label_halo_color',
  title: t.styleScreen.haloColor,
  defaultArgb: 0xFFFFFFFF,
  kmetaGetter: (k) => k.labelHaloColor,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);
final labelOpacityDef = _opacityDef(
  key: 'layer_style_label_opacity',
  title: t.styleScreen.labelOpacity,
  defaultValue: 1.0,
  kmetaGetter: (k) => k.labelOpacity,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
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
  formatter: _times,
);

// ============================================================
// ストア（グローバルシングルトン）
// ============================================================

/// 節のキー（表示名は翻訳で変わるので、絞り込みはこちらで）
abstract final class StyleSection {
  static const point = 'point';
  static const label = 'label';
  static const line = 'line';
  static const polygon = 'polygon';
  static const clustering = 'clustering';
  static const selection = 'selection';
}

final layerStyleSettings = SettingsStore([
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
  SettingSectionDef(
    id: StyleSection.label,
    title: t.styleScreen.label,
    icon: Icons.label_outline,
    collapsible: true,
    initiallyExpanded: true,
    items: [
      labelEnabledDef,
      labelExpressionTileDef,
      labelFontSizeDef,
      labelColorDef,
      labelHaloColorDef,
      labelOpacityDef,
    ],
  ),
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

// ============================================================
// ラベルの中身（組み立てダイアログへの入口）
// ============================================================

/// スタイル画面が「どのレイヤ／View を編集しているか」を、節の中の項目に伝える
class LabelEditorScope extends InheritedWidget {
  const LabelEditorScope({
    super.key,
    required this.layer,
    required this.view,
    required super.child,
  });

  final LayerNode? layer;
  final ViewNode? view;

  static LabelEditorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LabelEditorScope>();

  @override
  bool updateShouldNotify(LabelEditorScope old) => old.layer != layer || old.view != view;
}

Widget _buildLabelExpressionTile(BuildContext context, SettingsStore store, VoidCallback onChanged) {
  final tr = t.styleScreen;
  final expression = normalizeLabelExpression(store.getString(labelPropertyDef));
  final readable = expression == null || tryParseLabelExpression(expression) != null;
  final layer = LabelEditorScope.maybeOf(context)?.layer;

  Future<void> compose() async {
    List<String> columns = const [];
    Map<String, Object?>? sample;
    Map<String, double>? rates;
    if (layer != null) {
      columns = [
        ...(await layer.geoPackageFile.getColumnNames(layer.layerName, getAll: true))
            .where((c) => !isInternalColumn(c) && !isSystemColumn(c)),
        // 結合した表の列（森林簿の樹種など）もラベルに使える
        ...layer.joinedFieldNames,
      ];
      final rows = layer.children
          .whereType<FeatureNode>()
          .map((f) => layer.effectiveProperties(f.turfFeature.properties))
          .toList();
      sample = rows.firstOrNull;
      rates = rows.isEmpty ? null : columnFillRates(rows, columns);
    }
    if (!context.mounted) return;
    final result = await showLabelComposerDialog(
      context,
      columns: columns,
      initialTemplate: expression,
      initialEnabled: store.getBool(labelEnabledDef),
      sampleProps: sample,
      fillRates: rates,
    );
    if (result == null) return;
    await store.setString(labelPropertyDef, result.template);
    await store.setBool(labelEnabledDef, result.enabled);
    onChanged();
  }

  return ListTile(
    title: Text(tr.labelExpression),
    subtitle: Text(
      expression == null
          ? tr.labelExpressionEmpty
          : readable
              ? expression
              : '$expression\n${tr.labelExpressionInvalid}',
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        color: readable ? null : Theme.of(context).colorScheme.error,
      ),
    ),
    trailing: FilledButton.tonalIcon(
      onPressed: compose,
      icon: const Icon(Icons.edit_outlined, size: 18),
      label: Text(tr.compose),
    ),
    onTap: compose,
  );
}

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
  /// `views[layerKey][i].style` になる。View に無い項目はレイヤの値を見せ、
  /// 保存はレイヤと**違う項目だけ**（項目ごとの合成。`LayerNode.refreshStyleGroups` と同じ規則）
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

  /// View モードのときの、レイヤ側の解決済みスタイル（差分を取る基準）
  KMetaLayerStyle? _layerStyle;

  /// QGIS で単一シンボル以外に設定されたレイヤなら、その種類（[KMetaLayerStyle.qgisRenderer]）。
  /// このとき色・太さの節は出さない（変えても QGIS に届かず、見た目が食い違う）
  String? _qgisRenderer;

  /// [_qgisRenderer] の中身（凡例に出す。保存のときも消さずに持ち回る）
  QgisRenderer? _qgisRendererDef;

  /// レイヤ自体には描き分けが無く、配下の View から借りて表示しているか
  bool _rendererFromView = false;

  ProviderContainer? _container;

  @override
  void initState() {
    super.initState();
    // 組み立ての最中にプロバイダを変えられないので、描き終えてから
    WidgetsBinding.instance.addPostFrameCallback((_) => _tutorialReport(StyleScreenOpened(view: widget.isViewMode ? widget.targetView : null)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      _container = ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      _container = null;
    }
  }

  String get _title =>
      _isGlobalMode
          ? t.settingsWidget.layerDrawingTitle
          : t.settingsWidget.styleTitle(
            name:
                widget.isViewMode
                    ? '${widget.targetLayer!.layerName} / ${widget.targetView!.displayName}'
                    : widget.targetLayer!.layerName,
          );

  /// レイヤの型に合う節だけ出す（ラベルは点・線・面のどれにも出る）
  bool _sectionFilter(SettingSectionDef section) {
    if (_isGlobalMode) return true;
    final layer = widget.targetLayer;
    return switch (section.id) {
      StyleSection.point => layer is PointLayerNode,
      StyleSection.line => layer is LineLayerNode,
      StyleSection.polygon => layer is PolygonLayerNode,
      StyleSection.label => true,
      _ => false,
    };
  }

  /// QGIS 描き分けのレイヤでは、点・線・面の節のうち「濃さ（不透明度）」だけ編集できるようにする
  bool _itemFilter(SettingSectionDef section, SettingDef item) {
    if (_isGlobalMode || _qgisRenderer == null || section.id == StyleSection.label) return true;
    return identical(item, pointOpacityDef) ||
        identical(item, lineOpacityDef) ||
        identical(item, polygonFillOpacityDef) ||
        identical(item, polygonBorderOpacityDef);
  }

  /// KMeta初期化（個別レイヤーモード）
  Future<void> _onInit() async {
    if (widget.isViewMode) {
      final meta = await KMetaService.instance.getMeta(widget.folderPath!);
      _layerStyle = meta.getLayerStyle(widget.targetLayer!.layerKey);
      final viewStyle = widget.targetView!.style;
      _setQgisRenderer(
        viewStyle?.qgisRenderer ?? _layerStyle?.qgisRenderer,
        viewStyle?.qgisRenderer != null ? viewStyle?.qgisRendererDef : _layerStyle?.qgisRendererDef,
      );
      // View に指定が無い項目はレイヤの値を見せる
      final view = widget.targetView!.style;
      layerStyleSettings.loadOverlay(view == null ? _layerStyle : view.mergeWith(_layerStyle));
    } else if (widget.isLayerMode) {
      final meta = await KMetaService.instance.getMeta(widget.folderPath!);
      final style = meta.getLayerStyle(widget.targetLayer!.layerKey);
      final views = widget.targetLayer!.views;
      final fallbackViewStyle =
          views.where((v) => !v.isDefaultView && v.visible && v.style != null).firstOrNull?.style ??
          views.where((v) => !v.isDefaultView && v.style != null).firstOrNull?.style;
      final effective = style == null
          ? fallbackViewStyle
          : (fallbackViewStyle == null ? style : style.mergeWith(fallbackViewStyle));
      _layerStyle = effective;
      _rendererFromView = style?.qgisRenderer == null && fallbackViewStyle?.qgisRenderer != null;
      _setQgisRenderer(
        style?.qgisRenderer ?? fallbackViewStyle?.qgisRenderer,
        style?.qgisRenderer != null ? style?.qgisRendererDef : fallbackViewStyle?.qgisRendererDef,
      );
      layerStyleSettings.loadOverlay(effective);
    } else {
      layerStyleSettings.clearOverlay();
    }
  }

  void _setQgisRenderer(String? type, QgisRenderer? def) {
    if (type == _qgisRenderer && identical(def, _qgisRendererDef)) return;
    _qgisRenderer = type;
    _qgisRendererDef = def;
    if (mounted) setState(() {});
  }

  /// チュートリアルに知らせる（この画面は Consumer ではないので、上の ProviderScope から）
  void _tutorialReport(TutorialEvent e) {
    if (!mounted) return;
    ProviderScope.containerOf(context, listen: false).read(tutorialProvider.notifier).report(e);
  }

  void _notifyMapRefresh() {
    try {
      final c = _container ?? (mounted ? ProviderScope.containerOf(context, listen: false) : null);
      c?.read(featureRefreshTriggerProvider.notifier).trigger();
    } catch (_) {
      // ProviderScope が無い単体テスト環境では何もしない
    }
  }

  /// 値変更時のKMeta自動保存
  void _onValueChanged() {
    if (!widget.isLayerMode) {
      _notifyMapRefresh();
      return;
    }
    _saveToKMeta();
  }

  KMetaLayerStyle _styleFromStore() => KMetaLayerStyle(
        pointSize: layerStyleSettings.getDouble(pointSizeDef),
        pointColor: layerStyleSettings.getColor(pointColorDef),
        pointOpacity: layerStyleSettings.getDouble(pointOpacityDef),
        lineWidth: layerStyleSettings.getDouble(lineWidthDef),
        lineColor: layerStyleSettings.getColor(lineColorDef),
        lineOpacity: layerStyleSettings.getDouble(lineOpacityDef),
        polygonBorderWidth: layerStyleSettings.getDouble(polygonBorderWidthDef),
        polygonBorderColor: layerStyleSettings.getColor(polygonBorderColorDef),
        polygonFillColor: layerStyleSettings.getColor(polygonFillColorDef),
        polygonFillOpacity: layerStyleSettings.getDouble(polygonFillOpacityDef),
        polygonBorderOpacity: layerStyleSettings.getDouble(polygonBorderOpacityDef),
        labelEnabled: layerStyleSettings.getBool(labelEnabledDef),
        labelProperty: normalizeLabelExpression(layerStyleSettings.getString(labelPropertyDef)),
        labelFontSize: layerStyleSettings.getDouble(labelFontSizeDef),
        labelColor: layerStyleSettings.getColor(labelColorDef),
        labelHaloColor: layerStyleSettings.getColor(labelHaloColorDef),
        labelOpacity: layerStyleSettings.getDouble(labelOpacityDef),
        // QGIS 側の描き分けの印は、ラベルを変えても消さない
        qgisRenderer: (widget.isViewMode || _rendererFromView) ? null : _qgisRenderer,
        qgisRendererDef: (widget.isViewMode || _rendererFromView) ? null : _qgisRendererDef,
      );

  /// [full] のうち [base] と同じ項目を null にする（View はレイヤと違う項目だけ持つ）
  static KMetaLayerStyle _diff(KMetaLayerStyle full, KMetaLayerStyle? base) {
    if (base == null) return full;
    T? d<T>(T? a, T? b) => a == b ? null : a;
    return KMetaLayerStyle(
      pointSize: d(full.pointSize, base.pointSize),
      pointColor: d(full.pointColor, base.pointColor),
      pointOpacity: d(full.pointOpacity, base.pointOpacity),
      lineWidth: d(full.lineWidth, base.lineWidth),
      lineColor: d(full.lineColor, base.lineColor),
      lineOpacity: d(full.lineOpacity, base.lineOpacity),
      polygonBorderWidth: d(full.polygonBorderWidth, base.polygonBorderWidth),
      polygonBorderColor: d(full.polygonBorderColor, base.polygonBorderColor),
      polygonFillColor: d(full.polygonFillColor, base.polygonFillColor),
      polygonFillOpacity: d(full.polygonFillOpacity, base.polygonFillOpacity),
      polygonBorderOpacity: d(full.polygonBorderOpacity, base.polygonBorderOpacity),
      labelEnabled: d(full.labelEnabled, base.labelEnabled),
      labelProperty: d(full.labelProperty, base.labelProperty),
      labelFontSize: d(full.labelFontSize, base.labelFontSize),
      labelColor: d(full.labelColor, base.labelColor),
      labelHaloColor: d(full.labelHaloColor, base.labelHaloColor),
      labelOpacity: d(full.labelOpacity, base.labelOpacity),
    );
  }

  /// overlay値をKMetaに保存
  Future<void> _saveToKMeta() async {
    final style = _styleFromStore();
    if (widget.isViewMode) {
      var diff = _diff(style, _layerStyle);
      // View 自身が持っていた描き分けの印は残す
      final viewRenderer = widget.targetView!.style?.qgisRenderer;
      if (viewRenderer != null) {
        diff = diff.copyWith(qgisRenderer: viewRenderer, qgisRendererDef: widget.targetView!.style?.qgisRendererDef);
      }
      widget.targetView!.style = diff.isEmpty ? null : diff;
      await widget.targetLayer!.persistViews();
      widget.targetLayer!.folderNode?.invalidateMetaCache();
      await widget.targetLayer!.refreshStyleGroups();
      _notifyMapRefresh();
      AppLogger.debug('[LayerStyle] View設定を保存: ${widget.targetView!.viewKey}（差分 ${diff.isEmpty ? '無し' : 'あり'}）');
      _tutorialReport(StyleSaved(widget.targetLayer, view: widget.targetView));
      return;
    }

    final prev = _layerStyle;
    _layerStyle = style;
    await KMetaService.instance.setLayerStyle(
      widget.folderPath!,
      widget.targetLayer!.layerKey,
      style,
    );
    var viewsChanged = false;
    for (final v in widget.targetLayer!.views) {
      final vs = v.style;
      if (v.isDefaultView || vs == null) continue;
      final next = vs.copyWith(
        pointOpacity: style.pointOpacity != prev?.pointOpacity ? style.pointOpacity : vs.pointOpacity,
        lineOpacity: style.lineOpacity != prev?.lineOpacity ? style.lineOpacity : vs.lineOpacity,
        polygonFillOpacity:
            style.polygonFillOpacity != prev?.polygonFillOpacity ? style.polygonFillOpacity : vs.polygonFillOpacity,
        polygonBorderOpacity:
            style.polygonBorderOpacity != prev?.polygonBorderOpacity
                ? style.polygonBorderOpacity
                : vs.polygonBorderOpacity,
        labelOpacity: style.labelOpacity != prev?.labelOpacity ? style.labelOpacity : vs.labelOpacity,
      );
      if (next != vs) {
        v.style = next;
        viewsChanged = true;
      }
    }
    if (viewsChanged) {
      await widget.targetLayer!.persistViews();
    }
    widget.targetLayer!.folderNode?.invalidateMetaCache();
    widget.targetLayer!.invalidateKmetaStyleCache();
    // スタイルを変えたら「どのフィーチャがどのグループか」も取り直す
    await widget.targetLayer!.refreshStyleGroups();
    _notifyMapRefresh();
    AppLogger.debug(
      '[LayerStyle] レイヤー固有設定を保存: ${widget.targetLayer!.layerKey}',
    );
    _tutorialReport(StyleSaved(widget.targetLayer));
  }

  /// リセット処理（View なら「レイヤに従う」に戻す）
  Future<void> _resetSettings() async {
    final confirm = await showSettingsConfirmDialog(
      context,
      title: widget.isViewMode ? t.styleScreen.followLayer : t.settingsWidget.resetSettings,
      message: widget.isViewMode
          ? t.styleScreen.followLayerConfirm
          : _isGlobalMode
              ? t.settingsWidget.resetAllConfirm
              : t.settingsWidget.resetLayerConfirm,
      confirmLabel: t.common.reset,
    );
    if (!confirm) return;

    if (widget.isViewMode) {
      widget.targetView!.style = null;
      await widget.targetLayer!.persistViews();
      widget.targetLayer!.folderNode?.invalidateMetaCache();
      await widget.targetLayer!.refreshStyleGroups();
      layerStyleSettings.loadOverlay(_layerStyle);
      _notifyMapRefresh();
      AppLogger.debug('[LayerStyle] View をレイヤに従わせた: ${widget.targetView!.viewKey}');
      return;
    }
    if (_isGlobalMode) {
      await layerStyleSettings.resetAll();
      _notifyMapRefresh();
    } else {
      // KMetaからレイヤー固有スタイルを削除
      final rawMeta =
          await KMetaService.instance.getRawMeta(widget.folderPath!) ??
          KMeta.empty;
      final updatedLayers = Map<String, KMetaLayerStyle>.from(
        rawMeta.styles.layers,
      );
      updatedLayers.remove(widget.targetLayer!.layerKey);
      // QGIS 側の描き分けの印は残す（戻しても `.qgs` のレンダラは QGIS のまま）
      if (_qgisRenderer != null && !_rendererFromView) {
        updatedLayers[widget.targetLayer!.layerKey] =
            KMetaLayerStyle(qgisRenderer: _qgisRenderer, qgisRendererDef: _qgisRendererDef);
      }
      final updatedStyles = KMetaStyles(
        defaultStyle: rawMeta.styles.defaultStyle,
        layers: updatedLayers,
      );
      await KMetaService.instance.saveMeta(
        widget.folderPath!,
        rawMeta.copyWith(styles: updatedStyles),
      );
      widget.targetLayer!.invalidateKmetaStyleCache();
      await widget.targetLayer!.refreshStyleGroups();
      // overlayをグローバル値にリセット
      layerStyleSettings.loadOverlay(null);
      _notifyMapRefresh();
    }
    AppLogger.debug('[LayerStyle] 設定をリセットしました');
  }

  @override
  void dispose() {
    if (widget.isLayerMode) {
      layerStyleSettings.clearOverlay();
      _notifyMapRefresh();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LabelEditorScope(
      layer: widget.targetLayer,
      view: widget.targetView,
      child: DataDrivenSettingsScreen(
        title: _title,
        store: layerStyleSettings,
        isEmbedded: widget.isEmbedded,
        onInit: _onInit,
        onReset: _resetSettings,
        onValueChanged: _onValueChanged,
        sectionFilter: _sectionFilter,
        itemFilter: _itemFilter,
        customSections: (store) => [
          if (_qgisRenderer != null)
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(t.styleScreen.qgisStyle(kind: _qgisRendererLabel(_qgisRenderer!))),
              subtitle: Text(t.styleScreen.qgisStyleHint),
            ),
          if (_qgisRendererDef != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: QgisRendererLegend(renderer: _qgisRendererDef!),
            ),
          if (widget.isViewMode)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                t.styleScreen.followingLayer,
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
            ),
          _buildPreviewSection(store),
        ],
      ),
    );
  }

  static String _qgisRendererLabel(String type) => switch (type) {
        'categorizedSymbol' => t.styleScreen.qgisRendererCategorized,
        'graduatedSymbol' => t.styleScreen.qgisRendererGraduated,
        'RuleRenderer' => t.styleScreen.qgisRendererRule,
        _ => type,
      };

  /// プレビューセクション
  Widget _buildPreviewSection(SettingsStore store) {
    final layer = widget.targetLayer;
    return SettingsSection(
      title: t.styleScreen.preview,
      icon: Icons.preview,
      iconColor: Colors.purple,
      collapsible: true,
      initiallyExpanded: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 120,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'assets/user_guide/gsi_preview.png',
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                  ),
                  CustomPaint(
                    painter: _StylePreviewPainter(
                      showPoint: _isGlobalMode || layer is PointLayerNode,
                      showLine: _isGlobalMode || layer is LineLayerNode,
                      showPolygon: _isGlobalMode || layer is PolygonLayerNode,
                      pointColor: store.getColor(pointColorDef),
                      pointOpacity: store.getDouble(pointOpacityDef),
                      pointSize: store.getDouble(pointSizeDef),
                      lineColor: store.getColor(lineColorDef),
                      lineOpacity: store.getDouble(lineOpacityDef),
                      lineWidth: store.getDouble(lineWidthDef),
                      polygonBorderColor: store.getColor(polygonBorderColorDef),
                      polygonBorderWidth: store.getDouble(polygonBorderWidthDef),
                      polygonFillColor: store.getColor(polygonFillColorDef),
                      polygonFillOpacity: store.getDouble(polygonFillOpacityDef),
                      polygonBorderOpacity: store.getDouble(polygonBorderOpacityDef),
                      labelEnabled: store.getBool(labelEnabledDef),
                      labelFontSize: store.getDouble(labelFontSizeDef),
                      labelColor: store.getColor(labelColorDef),
                      labelHaloColor: store.getColor(labelHaloColorDef),
                      labelOpacity: store.getDouble(labelOpacityDef),
                    ),
                  ),
                ],
              ),
            ),
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
  final bool showPoint;
  final bool showLine;
  final bool showPolygon;
  final Color pointColor;
  final double pointOpacity;
  final double pointSize;
  final Color lineColor;
  final double lineOpacity;
  final double lineWidth;
  final Color polygonBorderColor;
  final double polygonBorderWidth;
  final Color polygonFillColor;
  final double polygonFillOpacity;
  final double polygonBorderOpacity;
  final bool labelEnabled;
  final double labelFontSize;
  final Color labelColor;
  final Color labelHaloColor;
  final double labelOpacity;

  _StylePreviewPainter({
    this.showPoint = true,
    this.showLine = true,
    this.showPolygon = true,
    required this.pointColor,
    required this.pointOpacity,
    required this.pointSize,
    required this.lineColor,
    required this.lineOpacity,
    required this.lineWidth,
    required this.polygonBorderColor,
    required this.polygonBorderWidth,
    required this.polygonFillColor,
    required this.polygonFillOpacity,
    required this.polygonBorderOpacity,
    required this.labelEnabled,
    required this.labelFontSize,
    required this.labelColor,
    required this.labelHaloColor,
    required this.labelOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final allThree = showPoint && showLine && showPolygon;
    final polyCx = allThree ? size.width * 0.75 : size.width * 0.5;
    final polyCy = size.height * 0.5;

    // ポリゴン（六角形）
    if (showPolygon) {
      final polygonPath = Path();
      final rx = allThree ? 35.0 : 64.0;
      final ry = allThree ? 35.0 : 42.0;
      for (int i = 0; i < 6; i++) {
        final angle = (i * 60 - 90) * math.pi / 180;
        final x = polyCx + rx * math.cos(angle);
        final y = polyCy + ry * math.sin(angle);
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
    }

    // ライン
    if (showLine) {
      final linePath = Path();
      if (allThree) {
        linePath
          ..moveTo(size.width * 0.35, size.height * 0.7)
          ..quadraticBezierTo(
            size.width * 0.5,
            size.height * 0.2,
            size.width * 0.65,
            size.height * 0.5,
          );
      } else {
        linePath
          ..moveTo(size.width * 0.12, size.height * 0.75)
          ..cubicTo(
            size.width * 0.38,
            size.height * 0.15,
            size.width * 0.62,
            size.height * 0.85,
            size.width * 0.88,
            size.height * 0.25,
          );
      }
      canvas.drawPath(
        linePath,
        Paint()
          ..color = lineColor.withValues(alpha: lineOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    // ポイント
    if (showPoint) {
      final pointPaint = Paint()
        ..color = pointColor.withValues(alpha: pointOpacity)
        ..style = PaintingStyle.fill;
      if (allThree) {
        canvas.drawCircle(
          Offset(size.width * 0.15, size.height * 0.5),
          pointSize / 2,
          pointPaint,
        );
      } else {
        for (final pos in [
          Offset(size.width * 0.25, size.height * 0.62),
          Offset(size.width * 0.50, size.height * 0.45),
          Offset(size.width * 0.75, size.height * 0.55),
        ]) {
          canvas.drawCircle(pos, pointSize / 2, pointPaint);
        }
      }
    }

    // ラベル
    if (labelEnabled && labelOpacity > 0) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'ABC',
          style: TextStyle(
            fontSize: labelFontSize,
            color: labelColor.withValues(alpha: labelOpacity),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelCx = allThree ? polyCx : size.width * 0.5;
      final labelCy = allThree ? polyCy : size.height * 0.5;
      final origin = Offset(labelCx - tp.width / 2, labelCy - tp.height / 2);
      final box = Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(3)),
        Paint()..color = labelHaloColor.withValues(alpha: 0.85 * labelOpacity),
      );
      tp.paint(canvas, origin);
    }
  }

  @override
  bool shouldRepaint(covariant _StylePreviewPainter old) =>
      old.showPoint != showPoint ||
      old.showLine != showLine ||
      old.showPolygon != showPolygon ||
      old.pointColor != pointColor ||
      old.pointOpacity != pointOpacity ||
      old.pointSize != pointSize ||
      old.lineColor != lineColor ||
      old.lineOpacity != lineOpacity ||
      old.lineWidth != lineWidth ||
      old.polygonBorderColor != polygonBorderColor ||
      old.polygonBorderWidth != polygonBorderWidth ||
      old.polygonFillColor != polygonFillColor ||
      old.polygonFillOpacity != polygonFillOpacity ||
      old.polygonBorderOpacity != polygonBorderOpacity ||
      old.labelEnabled != labelEnabled ||
      old.labelFontSize != labelFontSize ||
      old.labelColor != labelColor ||
      old.labelHaloColor != labelHaloColor ||
      old.labelOpacity != labelOpacity;
}
