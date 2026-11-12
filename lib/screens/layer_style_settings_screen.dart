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

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/settings_schema.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/geometry_type.dart';
import '../models/kmeta.dart';
import '../models/nodes/feature_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/view_node.dart';
import '../models/qgis_renderer.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/kmeta_service.dart';
import '../services/qgis/qgs_qml_service.dart';
import '../services/qgis/qgs_style_reader.dart';
import '../tutorial/tutorial.dart';
import '../utils/app_logger.dart';
import '../utils/attribute_columns.dart';
import '../utils/label_expression.dart';
import '../utils/label_template.dart';
import '../widgets/label_composer_dialog.dart';
import '../widgets/settings_widgets.dart';
import 'layer_style_settings/kmeta_style_sync.dart';
import 'layer_style_settings/label_style_defs.dart';
import 'layer_style_settings/style_preview_and_banners.dart';
import 'layer_style_settings/style_templates.dart';
import 'layer_style_settings/symbol_style_defs.dart';

export 'layer_style_settings/label_style_defs.dart'
    show
        labelColorDef,
        labelEnabledDef,
        labelFontSizeDef,
        labelHaloColorDef,
        labelOpacityDef,
        labelPropertyDef;
export 'layer_style_settings/symbol_style_defs.dart'
    show
        StyleSection,
        clusteringDisableZoomDef,
        clusteringEnabledDef,
        lineCasingColorDef,
        lineCasingEnabledDef,
        lineCasingWidthDef,
        lineColorDef,
        lineDashDef,
        lineOpacityDef,
        lineVertexPointSizeFactorDef,
        lineVertexPointsEnabledDef,
        lineWidthDef,
        pointColorDef,
        pointOpacityDef,
        pointOutlineColorDef,
        pointOutlineEnabledDef,
        pointOutlineWidthDef,
        pointShapeDef,
        pointSizeDef,
        polygonBorderCasingColorDef,
        polygonBorderCasingEnabledDef,
        polygonBorderCasingWidthDef,
        polygonBorderColorDef,
        polygonBorderDashDef,
        polygonBorderOpacityDef,
        polygonBorderWidthDef,
        polygonFillColorDef,
        polygonFillOpacityDef,
        polygonFillPatternDef,
        polygonPatternSpacingDef,
        polygonVertexPointSizeFactorDef,
        polygonVertexPointsEnabledDef,
        selectedColorDef,
        selectedMultiplierDef;

// ============================================================
// ストア（グローバルシングルトン）とラベル式タイル
// ============================================================

final labelExpressionTileDef = CustomDef(
  key: 'layer_style_label_expression_tile',
  title: t.styleScreen.labelExpression,
  builder: _buildLabelExpressionTile,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);

final layerStyleSettings = createLayerStyleSettingsStore(
  labelExpressionTileDef: labelExpressionTileDef,
);

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
        // 結合した表の列（台帳の種別など）もラベルに使える
        ...layer.joinedFieldNames,
      ];
      final rows = layer.children
          .whereType<FeatureNode>()
          .map((f) => layer.effectiveProperties(f.properties))
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
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _tutorialReport(StyleScreenOpened(view: widget.isViewMode ? widget.targetView : null)),
    );
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

  String get _title => _isGlobalMode
      ? t.settingsWidget.layerDrawingTitle
      : t.settingsWidget.styleTitle(
          name: widget.isViewMode
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
    if (!widget.isLayerMode) {
      layerStyleSettings.clearOverlay();
      return;
    }
    final loaded = await loadLayerOrViewStyleState(
      folderPath: widget.folderPath!,
      targetLayer: widget.targetLayer!,
      targetView: widget.isViewMode ? widget.targetView : null,
    );
    _layerStyle = loaded.layerStyle;
    _rendererFromView = loaded.rendererFromView;
    _setQgisRenderer(loaded.qgisRenderer, loaded.qgisRendererDef);
    layerStyleSettings.loadOverlay(loaded.overlayForStore);
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

  /// overlay値をKMetaに保存
  Future<void> _saveToKMeta() async {
    final existing = widget.isViewMode ? widget.targetView?.style : _layerStyle;
    final style = buildStyleFromStore(
      layerStyleSettings,
      omitLayerQgisRenderer: widget.isViewMode || _rendererFromView,
      qgisRenderer: _qgisRenderer,
      qgisRendererDef: _qgisRendererDef,
      existingStyle: existing,
    );
    if (widget.isViewMode) {
      await saveViewStyleToKMeta(
        targetLayer: widget.targetLayer!,
        targetView: widget.targetView!,
        currentStyle: style,
        baseLayerStyle: _layerStyle,
      );
      _notifyMapRefresh();
      _tutorialReport(StyleSaved(widget.targetLayer, view: widget.targetView));
      return;
    }

    final prev = _layerStyle;
    _layerStyle = style;
    await saveLayerStyleToKMeta(
      folderPath: widget.folderPath!,
      targetLayer: widget.targetLayer!,
      style: style,
      previousLayerStyle: prev,
    );
    _notifyMapRefresh();
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
      await resetViewStyleToFollowLayer(
        store: layerStyleSettings,
        targetLayer: widget.targetLayer!,
        targetView: widget.targetView!,
        layerStyle: _layerStyle,
      );
      _notifyMapRefresh();
      return;
    }
    if (_isGlobalMode) {
      await layerStyleSettings.resetAll();
      _notifyMapRefresh();
    } else {
      await resetLayerStyleInKMeta(
        store: layerStyleSettings,
        folderPath: widget.folderPath!,
        targetLayer: widget.targetLayer!,
        qgisRenderer: _qgisRenderer,
        qgisRendererDef: _qgisRendererDef,
        rendererFromView: _rendererFromView,
      );
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

  void _notify(String title, NotificationLevel level) {
    try {
      final c = _container ?? (mounted ? ProviderScope.containerOf(context, listen: false) : null);
      c?.read(notificationCenterProvider.notifier).add(title: title, level: level);
    } catch (_) {
      // ProviderScope が無い単体テスト環境では何もしない
    }
  }

  GeometryType? _targetGeometryType() {
    final layer = widget.targetLayer;
    if (layer is PointLayerNode) return GeometryType.point;
    if (layer is LineLayerNode) return GeometryType.linestring;
    if (layer is PolygonLayerNode) return GeometryType.polygon;
    return null;
  }

  String _geometryLabel(GeometryType type) => switch (type) {
        GeometryType.point => t.styleScreen.point,
        GeometryType.linestring => t.styleScreen.line,
        GeometryType.polygon => t.styleScreen.polygon,
      };

  String? _currentPointSvgContent() {
    final effective = widget.isViewMode
        ? (widget.targetView?.style?.mergeWith(_layerStyle) ?? _layerStyle)
        : _layerStyle;
    return effective?.symbolLayers?.markers.lastOrNull?.svgContent;
  }

  bool _hasCustomSymbolLayers() {
    final effective = widget.isViewMode
        ? (widget.targetView?.style?.mergeWith(_layerStyle) ?? _layerStyle)
        : _layerStyle;
    return effective?.symbolLayers != null;
  }

  Future<void> _applyTemplate(StyleTemplate template) async {
    await template.applyToStore(layerStyleSettings);
    // QML 等から読み込んだ複合シンボル（SVG マーカー等）が残っていると優先描画されるため外す
    if (widget.isViewMode) {
      if (widget.targetView?.style?.symbolLayers != null) {
        widget.targetView!.style = widget.targetView!.style!.copyWith(clearSymbolLayers: true);
      }
    } else if (_layerStyle?.symbolLayers != null) {
      _layerStyle = _layerStyle!.copyWith(clearSymbolLayers: true);
    }
    if (mounted) setState(() {});
    _onValueChanged();
  }

  Future<void> _importQmlFile() async {
    final layer = widget.targetLayer;
    final folderPath = widget.folderPath;
    if (layer == null || folderPath == null) return;

    final List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['qml'],
      );
    } on Object catch (e) {
      AppLogger.error('[LayerStyle] QML ファイル選択失敗: $e');
      _notify(t.common.errorOccurred(error: '$e'), NotificationLevel.error);
      return;
    }
    if (picked.isEmpty) return;

    final file = picked.first;
    final String xmlText;
    Map<String, String> localSvgs = const {};
    try {
      final bytes = await file.readAsBytes();
      xmlText = utf8.decode(bytes, allowMalformed: true);
      if (file.path != null) {
        final doc = XmlDocument.parse(xmlText);
        localSvgs = await QgsStyleReader.preloadLocalSvgFiles(
          doc,
          baseDir: p.dirname(file.path!),
          rootDir: folderPath,
        );
      }
    } on Object {
      _notify(t.styleScreen.qmlInvalid, NotificationLevel.error);
      return;
    }

    final result = QgsQmlService.importQml(
      xmlText,
      expectedGeometryType: _targetGeometryType(),
      svgFileReader: localSvgs.isEmpty ? null : (raw) => localSvgs[raw],
    );

    switch (result) {
      case QmlImportInvalid():
        _notify(t.styleScreen.qmlInvalid, NotificationLevel.error);
      case QmlImportGeometryMismatch(:final expected, :final actual):
        _notify(
          t.styleScreen.qmlGeometryMismatch(
            actual: _geometryLabel(actual),
            expected: _geometryLabel(expected),
          ),
          NotificationLevel.warning,
        );
      case QmlImportSuccess(:final style):
        if (widget.isViewMode) {
          widget.targetView!.style = style;
          await layer.persistViews();
          layer.folderNode?.invalidateMetaCache();
          await layer.refreshStyleGroups();
        } else {
          await KMetaService.instance.setLayerStyle(
            folderPath,
            layer.layerKey,
            style,
          );
          layer.folderNode?.invalidateMetaCache();
          layer.invalidateKmetaStyleCache();
          await layer.refreshStyleGroups();
        }
        await _onInit();
        if (mounted) setState(() {});
        _notifyMapRefresh();
        _tutorialReport(StyleSaved(layer, view: widget.isViewMode ? widget.targetView : null));
        _notify(t.styleScreen.qmlImported(name: file.name), NotificationLevel.success);
    }
  }

  Future<void> _exportQmlFile() async {
    final layer = widget.targetLayer;
    final geomType = _targetGeometryType();
    if (layer == null || geomType == null) return;

    final existingEffective = widget.isViewMode
        ? (widget.targetView?.style?.mergeWith(_layerStyle) ?? _layerStyle)
        : _layerStyle;
    final current = buildStyleFromStore(
      layerStyleSettings,
      omitLayerQgisRenderer: false,
      qgisRenderer: _qgisRenderer,
      qgisRendererDef: _qgisRendererDef,
      existingStyle: existingEffective,
    );
    final existingMapLayer = await QgsQmlService.findExistingMapLayerInFolder(
      folderPath: widget.folderPath,
      layer: layer,
      view: widget.targetView,
    );
    final bytes = QgsQmlService.exportQmlBytes(
      style: current,
      geometryType: geomType,
      existingMapLayer: existingMapLayer,
    );
    final rawBase = widget.isViewMode
        ? '${layer.layerName}_${widget.targetView!.displayName}'
        : layer.layerName;
    final safeBase = rawBase.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final fileName = '${safeBase.isEmpty ? 'style' : safeBase}.qml';

    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: t.styleScreen.qmlExport,
        fileName: fileName,
        bytes: bytes,
      );
      if (saved == null) return;
      _notify(t.styleScreen.qmlExported(name: fileName), NotificationLevel.success);
    } on Object catch (e) {
      AppLogger.error('[LayerStyle] QML 書き出し失敗: $e');
      _notify(t.common.errorOccurred(error: '$e'), NotificationLevel.error);
    }
  }

  Widget _buildQmlMenuButton() => PopupMenuButton<_QmlMenuAction>(
        icon: const Icon(Icons.import_export),
        tooltip: t.styleScreen.qmlMenuTooltip,
        onSelected: (action) => switch (action) {
          _QmlMenuAction.importQml => _importQmlFile(),
          _QmlMenuAction.exportQml => _exportQmlFile(),
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _QmlMenuAction.importQml,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.file_open_outlined),
              title: Text(t.styleScreen.qmlImport),
            ),
          ),
          PopupMenuItem(
            value: _QmlMenuAction.exportQml,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.save_alt_outlined),
              title: Text(t.styleScreen.qmlExport),
            ),
          ),
        ],
      );

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
        extraActions: [
          if (widget.isLayerMode && _targetGeometryType() != null) _buildQmlMenuButton(),
        ],
        customSections: (store) => buildStyleHeaderAndPreviewSections(
          store: store,
          isGlobalMode: _isGlobalMode,
          isViewMode: widget.isViewMode,
          targetLayer: widget.targetLayer,
          qgisRenderer: _qgisRenderer,
          qgisRendererDef: _qgisRendererDef,
          pointSvgContent: _currentPointSvgContent(),
          targetGeometryType: _targetGeometryType(),
          hasCustomSymbolLayers: _hasCustomSymbolLayers(),
          onSelectTemplate: _applyTemplate,
        ),
      ),
    );
  }
}

enum _QmlMenuAction { importQml, exportQml }
