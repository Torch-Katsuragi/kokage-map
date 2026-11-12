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
/// KMeta スタイルの読み込み・保存・View 差分計算・「レイヤに従う」リセット処理
library;

import '../../core/settings_schema.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/view_node.dart';
import '../../models/qgis_renderer.dart';
import '../../services/kmeta_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/label_template.dart';
import 'label_style_defs.dart';
import 'symbol_style_defs.dart';

/// KMeta 初期化時に解決されたレイヤ／View スタイル状態
class LoadedStyleOverlayState {
  const LoadedStyleOverlayState({
    required this.layerStyle,
    required this.overlayForStore,
    required this.qgisRenderer,
    required this.qgisRendererDef,
    required this.rendererFromView,
  });

  final KMetaLayerStyle? layerStyle;
  final KMetaLayerStyle? overlayForStore;
  final String? qgisRenderer;
  final QgisRenderer? qgisRendererDef;
  final bool rendererFromView;
}

/// レイヤモードまたは View モードの KMeta スタイル状態を読み込む
Future<LoadedStyleOverlayState> loadLayerOrViewStyleState({
  required String folderPath,
  required LayerNode targetLayer,
  required ViewNode? targetView,
}) async {
  final meta = await KMetaService.instance.getMeta(folderPath);
  if (targetView != null) {
    final layerStyle = meta.getLayerStyle(targetLayer.layerKey);
    final viewStyle = targetView.style;
    // View に指定が無い項目はレイヤの値を見せる
    final overlay = viewStyle == null ? layerStyle : viewStyle.mergeWith(layerStyle);
    return LoadedStyleOverlayState(
      layerStyle: layerStyle,
      overlayForStore: overlay,
      qgisRenderer: viewStyle?.qgisRenderer ?? layerStyle?.qgisRenderer,
      qgisRendererDef: viewStyle?.qgisRenderer != null ? viewStyle?.qgisRendererDef : layerStyle?.qgisRendererDef,
      rendererFromView: false,
    );
  }

  final style = meta.getLayerStyle(targetLayer.layerKey);
  final views = targetLayer.views;
  final fallbackViewStyle =
      views.where((v) => !v.isDefaultView && v.visible && v.style != null).firstOrNull?.style ??
      views.where((v) => !v.isDefaultView && v.style != null).firstOrNull?.style;
  final effective = style == null
      ? fallbackViewStyle
      : (fallbackViewStyle == null ? style : style.mergeWith(fallbackViewStyle));
  final rendererFromView = style?.qgisRenderer == null && fallbackViewStyle?.qgisRenderer != null;

  return LoadedStyleOverlayState(
    layerStyle: effective,
    overlayForStore: effective,
    qgisRenderer: style?.qgisRenderer ?? fallbackViewStyle?.qgisRenderer,
    qgisRendererDef: style?.qgisRenderer != null ? style?.qgisRendererDef : fallbackViewStyle?.qgisRendererDef,
    rendererFromView: rendererFromView,
  );
}

/// [store] の現在値から [KMetaLayerStyle] を組み立てる。
///
/// 新規追加プロパティ（形状・破線・縁取り・ハッチング）は既定値から変えたとき（または
/// [existingStyle] に既に設定があるとき）だけ書き込み、普段の JSON と `.qgs` を簡潔に保つ。
/// QGIS 由来の縮尺制限・背景枠・データ定義プロパティは [existingStyle] から引き継ぐ。
KMetaLayerStyle buildStyleFromStore(
  SettingsStore store, {
  required bool omitLayerQgisRenderer,
  required String? qgisRenderer,
  required QgisRenderer? qgisRendererDef,
  KMetaLayerStyle? existingStyle,
}) {
  final pointSize = store.getDouble(pointSizeDef);
  final pointColor = store.getColor(pointColorDef);
  final pointOpacity = store.getDouble(pointOpacityDef);
  final rawPointShape = store.getString(pointShapeDef);
  final pointShape = (rawPointShape != 'circle' || existingStyle?.pointShape != null) ? rawPointShape : null;
  final rawPointOutlineOn = store.getBool(pointOutlineEnabledDef);
  final pointOutlineEnabled =
      (!rawPointOutlineOn || existingStyle?.pointOutlineEnabled != null) ? rawPointOutlineOn : null;
  final rawPointOutlineCol = store.getColor(pointOutlineColorDef);
  final pointOutlineColor =
      (rawPointOutlineCol.toARGB32() != 0xFFFFFFFF || existingStyle?.pointOutlineColor != null)
          ? rawPointOutlineCol
          : null;
  final rawPointOutlineW = store.getDouble(pointOutlineWidthDef);
  final pointOutlineWidth =
      (rawPointOutlineW != 1.5 || existingStyle?.pointOutlineWidth != null) ? rawPointOutlineW : null;

  final lineWidth = store.getDouble(lineWidthDef);
  final lineColor = store.getColor(lineColorDef);
  final lineOpacity = store.getDouble(lineOpacityDef);
  final rawLineDash = store.getString(lineDashDef);
  final lineDash = (rawLineDash != 'solid' || existingStyle?.lineDash != null) ? rawLineDash : null;
  final rawLineCasingOn = store.getBool(lineCasingEnabledDef);
  final lineCasingEnabled =
      (rawLineCasingOn || existingStyle?.lineCasingEnabled != null) ? rawLineCasingOn : null;
  final rawLineCasingCol = store.getColor(lineCasingColorDef);
  final lineCasingColor =
      (rawLineCasingOn || existingStyle?.lineCasingColor != null) ? rawLineCasingCol : null;
  final rawLineCasingW = store.getDouble(lineCasingWidthDef);
  final lineCasingWidth =
      (rawLineCasingOn || existingStyle?.lineCasingWidth != null) ? rawLineCasingW : null;

  final polygonBorderWidth = store.getDouble(polygonBorderWidthDef);
  final polygonBorderColor = store.getColor(polygonBorderColorDef);
  final polygonFillColor = store.getColor(polygonFillColorDef);
  final polygonFillOpacity = store.getDouble(polygonFillOpacityDef);
  final polygonBorderOpacity = store.getDouble(polygonBorderOpacityDef);
  final rawFillPattern = store.getString(polygonFillPatternDef);
  final polygonFillPattern =
      (rawFillPattern != 'solid' || existingStyle?.polygonFillPattern != null) ? rawFillPattern : null;
  final rawPatternSpacing = store.getDouble(polygonPatternSpacingDef);
  final isHatchOrDots = rawFillPattern != 'solid' && rawFillPattern != 'none';
  final polygonPatternSpacing =
      (isHatchOrDots || existingStyle?.polygonPatternSpacing != null) ? rawPatternSpacing : null;
  final rawBorderDash = store.getString(polygonBorderDashDef);
  final polygonBorderDash =
      (rawBorderDash != 'solid' || existingStyle?.polygonBorderDash != null) ? rawBorderDash : null;
  final rawBorderCasingOn = store.getBool(polygonBorderCasingEnabledDef);
  final polygonBorderCasingEnabled =
      (rawBorderCasingOn || existingStyle?.polygonBorderCasingEnabled != null) ? rawBorderCasingOn : null;
  final rawBorderCasingCol = store.getColor(polygonBorderCasingColorDef);
  final polygonBorderCasingColor =
      (rawBorderCasingOn || existingStyle?.polygonBorderCasingColor != null) ? rawBorderCasingCol : null;
  final rawBorderCasingW = store.getDouble(polygonBorderCasingWidthDef);
  final polygonBorderCasingWidth =
      (rawBorderCasingOn || existingStyle?.polygonBorderCasingWidth != null) ? rawBorderCasingW : null;

  // QGIS 複合シンボル（symbolLayers）の扱い:
  // - 描き分けレンダラ（qgisRenderer != null）のときは UI でシンボル編集しないため維持
  // - 単一シンボルのときは、ユーザーがシンボル項目を変更したら symbolLayers を外して UI の値を反映し、
  //   ラベルしか触っていない場合は元の複合シンボルを維持する
  final prev = existingStyle;
  final prevSingleSvg = prev?.symbolLayers != null &&
          prev!.symbolLayers!.markers.length == 1 &&
          prev.symbolLayers!.markers.first.svgContent != null &&
          prev.symbolLayers!.strokes.isEmpty &&
          prev.symbolLayers!.fills.isEmpty
      ? prev.symbolLayers!.markers.first
      : null;
  final symbolUnchanged = prev != null &&
      prev.symbolLayers != null &&
      pointSize == (prev.pointSize ?? store.resolveDouble(pointSizeDef, prev)) &&
      pointColor == (prev.pointColor ?? store.resolveColor(pointColorDef, prev)) &&
      pointOpacity == (prev.pointOpacity ?? store.resolveDouble(pointOpacityDef, prev)) &&
      rawPointShape == (prev.pointShape ?? 'circle') &&
      rawPointOutlineOn == (prev.pointOutlineEnabled ?? true) &&
      lineWidth == (prev.lineWidth ?? store.resolveDouble(lineWidthDef, prev)) &&
      lineColor == (prev.lineColor ?? store.resolveColor(lineColorDef, prev)) &&
      lineOpacity == (prev.lineOpacity ?? store.resolveDouble(lineOpacityDef, prev)) &&
      rawLineDash == (prev.lineDash ?? 'solid') &&
      rawLineCasingOn == (prev.lineCasingEnabled ?? false) &&
      polygonBorderWidth == (prev.polygonBorderWidth ?? store.resolveDouble(polygonBorderWidthDef, prev)) &&
      polygonBorderColor == (prev.polygonBorderColor ?? store.resolveColor(polygonBorderColorDef, prev)) &&
      polygonFillColor == (prev.polygonFillColor ?? store.resolveColor(polygonFillColorDef, prev)) &&
      polygonFillOpacity == (prev.polygonFillOpacity ?? store.resolveDouble(polygonFillOpacityDef, prev)) &&
      polygonBorderOpacity == (prev.polygonBorderOpacity ?? store.resolveDouble(polygonBorderOpacityDef, prev)) &&
      rawFillPattern == (prev.polygonFillPattern ?? 'solid') &&
      rawBorderDash == (prev.polygonBorderDash ?? 'solid') &&
      rawBorderCasingOn == (prev.polygonBorderCasingEnabled ?? false);
  ResolvedSymbolLayers? keepSymbolLayers;
  if (qgisRenderer != null || symbolUnchanged) {
    keepSymbolLayers = prev?.symbolLayers;
  } else if (prevSingleSvg != null &&
      rawPointShape == (prev?.pointShape ?? 'circle') &&
      pointColor == (prev?.pointColor ?? store.resolveColor(pointColorDef, prev))) {
    // SvgMarker でサイズ・不透明度のみ調整された場合は SVG シンボルを維持したままサイズ・アルファを更新する
    keepSymbolLayers = ResolvedSymbolLayers(
      markers: [
        ResolvedPointLayer(
          shape: prevSingleSvg.shape,
          color: pointColor.withValues(alpha: pointOpacity),
          radiusPx: pointSize,
          outlineColor: rawPointOutlineOn && pointOutlineColor != null
              ? pointOutlineColor.withValues(alpha: pointOpacity)
              : prevSingleSvg.outlineColor,
          outlineWidthPx: rawPointOutlineOn ? (pointOutlineWidth ?? prevSingleSvg.outlineWidthPx) : 0,
          angleDeg: prevSingleSvg.angleDeg,
          svgContent: prevSingleSvg.svgContent,
          svgPath: prevSingleSvg.svgPath,
        ),
      ],
    );
  }

  return KMetaLayerStyle(
    pointSize: pointSize,
    pointColor: pointColor,
    pointOpacity: pointOpacity,
    pointShape: pointShape,
    pointOutlineEnabled: pointOutlineEnabled,
    pointOutlineColor: pointOutlineColor,
    pointOutlineWidth: pointOutlineWidth,
    pointAngle: prev?.pointAngle,
    lineWidth: lineWidth,
    lineColor: lineColor,
    lineOpacity: lineOpacity,
    lineDash: lineDash,
    lineCasingEnabled: lineCasingEnabled,
    lineCasingColor: lineCasingColor,
    lineCasingWidth: lineCasingWidth,
    polygonBorderWidth: polygonBorderWidth,
    polygonBorderColor: polygonBorderColor,
    polygonFillColor: polygonFillColor,
    polygonFillOpacity: polygonFillOpacity,
    polygonBorderOpacity: polygonBorderOpacity,
    polygonFillPattern: polygonFillPattern,
    polygonPatternSpacing: polygonPatternSpacing,
    polygonPatternLineWidth: prev?.polygonPatternLineWidth,
    polygonBorderDash: polygonBorderDash,
    polygonBorderCasingEnabled: polygonBorderCasingEnabled,
    polygonBorderCasingColor: polygonBorderCasingColor,
    polygonBorderCasingWidth: polygonBorderCasingWidth,
    labelEnabled: store.getBool(labelEnabledDef),
    labelProperty: normalizeLabelExpression(store.getString(labelPropertyDef)),
    labelFontSize: store.getDouble(labelFontSizeDef),
    labelColor: store.getColor(labelColorDef),
    labelHaloColor: store.getColor(labelHaloColorDef),
    labelOpacity: store.getDouble(labelOpacityDef),
    labelHaloEnabled: prev?.labelHaloEnabled,
    labelHaloSize: prev?.labelHaloSize,
    labelWrapChar: prev?.labelWrapChar,
    labelBgEnabled: prev?.labelBgEnabled,
    labelBgShape: prev?.labelBgShape,
    labelBgColor: prev?.labelBgColor,
    labelBgBorderColor: prev?.labelBgBorderColor,
    labelBgBorderWidth: prev?.labelBgBorderWidth,
    minScale: prev?.minScale,
    maxScale: prev?.maxScale,
    symbolLayers: keepSymbolLayers,
    dataDefined: prev?.dataDefined,
    // QGIS 側の描き分けの印は、ラベルを変えても消さない
    qgisRenderer: omitLayerQgisRenderer ? null : qgisRenderer,
    qgisRendererDef: omitLayerQgisRenderer ? null : qgisRendererDef,
  );
}

/// [full] のうち [base] と同じ項目を null にする（View はレイヤと違う項目だけ持つ）
KMetaLayerStyle computeViewStyleDiff(KMetaLayerStyle full, KMetaLayerStyle? base) {
  if (base == null) return full;
  T? d<T>(T? a, T? b) => a == b ? null : a;
  return KMetaLayerStyle(
    pointSize: d(full.pointSize, base.pointSize),
    pointColor: d(full.pointColor, base.pointColor),
    pointOpacity: d(full.pointOpacity, base.pointOpacity),
    pointShape: d(full.pointShape ?? 'circle', base.pointShape ?? 'circle'),
    pointOutlineEnabled: d(full.pointOutlineEnabled ?? true, base.pointOutlineEnabled ?? true),
    pointOutlineColor: d(full.pointOutlineColor, base.pointOutlineColor),
    pointOutlineWidth: d(full.pointOutlineWidth, base.pointOutlineWidth),
    pointAngle: d(full.pointAngle, base.pointAngle),
    lineWidth: d(full.lineWidth, base.lineWidth),
    lineColor: d(full.lineColor, base.lineColor),
    lineOpacity: d(full.lineOpacity, base.lineOpacity),
    lineDash: d(full.lineDash ?? 'solid', base.lineDash ?? 'solid'),
    lineCasingEnabled: d(full.lineCasingEnabled ?? false, base.lineCasingEnabled ?? false),
    lineCasingColor: d(full.lineCasingColor, base.lineCasingColor),
    lineCasingWidth: d(full.lineCasingWidth, base.lineCasingWidth),
    polygonBorderWidth: d(full.polygonBorderWidth, base.polygonBorderWidth),
    polygonBorderColor: d(full.polygonBorderColor, base.polygonBorderColor),
    polygonFillColor: d(full.polygonFillColor, base.polygonFillColor),
    polygonFillOpacity: d(full.polygonFillOpacity, base.polygonFillOpacity),
    polygonBorderOpacity: d(full.polygonBorderOpacity, base.polygonBorderOpacity),
    polygonFillPattern: d(full.polygonFillPattern ?? 'solid', base.polygonFillPattern ?? 'solid'),
    polygonPatternSpacing: d(full.polygonPatternSpacing, base.polygonPatternSpacing),
    polygonBorderDash: d(full.polygonBorderDash ?? 'solid', base.polygonBorderDash ?? 'solid'),
    polygonBorderCasingEnabled:
        d(full.polygonBorderCasingEnabled ?? false, base.polygonBorderCasingEnabled ?? false),
    polygonBorderCasingColor: d(full.polygonBorderCasingColor, base.polygonBorderCasingColor),
    polygonBorderCasingWidth: d(full.polygonBorderCasingWidth, base.polygonBorderCasingWidth),
    labelEnabled: d(full.labelEnabled, base.labelEnabled),
    labelProperty: d(full.labelProperty, base.labelProperty),
    labelFontSize: d(full.labelFontSize, base.labelFontSize),
    labelColor: d(full.labelColor, base.labelColor),
    labelHaloColor: d(full.labelHaloColor, base.labelHaloColor),
    labelOpacity: d(full.labelOpacity, base.labelOpacity),
    minScale: d(full.minScale, base.minScale),
    maxScale: d(full.maxScale, base.maxScale),
    symbolLayers: d(full.symbolLayers, base.symbolLayers),
    dataDefined: d(full.dataDefined, base.dataDefined),
  );
}

/// View スタイル差分を保存し、レイヤの表示グループを再構築する
Future<void> saveViewStyleToKMeta({
  required LayerNode targetLayer,
  required ViewNode targetView,
  required KMetaLayerStyle currentStyle,
  required KMetaLayerStyle? baseLayerStyle,
}) async {
  var diff = computeViewStyleDiff(currentStyle, baseLayerStyle);
  // View 自身が持っていた描き分けの印は残す
  final viewRenderer = targetView.style?.qgisRenderer;
  if (viewRenderer != null) {
    diff = diff.copyWith(qgisRenderer: viewRenderer, qgisRendererDef: targetView.style?.qgisRendererDef);
  }
  targetView.style = diff.isEmpty ? null : diff;
  await targetLayer.persistViews();
  targetLayer.folderNode?.invalidateMetaCache();
  await targetLayer.refreshStyleGroups();
  AppLogger.debug('[LayerStyle] View設定を保存: ${targetView.viewKey}（差分 ${diff.isEmpty ? '無し' : 'あり'}）');
}

/// レイヤ固有スタイルを保存し、配下 View の不透明度同期・表示グループ更新を行う
Future<void> saveLayerStyleToKMeta({
  required String folderPath,
  required LayerNode targetLayer,
  required KMetaLayerStyle style,
  required KMetaLayerStyle? previousLayerStyle,
}) async {
  await KMetaService.instance.setLayerStyle(
    folderPath,
    targetLayer.layerKey,
    style,
  );
  var viewsChanged = false;
  for (final v in targetLayer.views) {
    final vs = v.style;
    if (v.isDefaultView || vs == null) continue;
    final next = vs.copyWith(
      pointOpacity: style.pointOpacity != previousLayerStyle?.pointOpacity ? style.pointOpacity : vs.pointOpacity,
      lineOpacity: style.lineOpacity != previousLayerStyle?.lineOpacity ? style.lineOpacity : vs.lineOpacity,
      polygonFillOpacity: style.polygonFillOpacity != previousLayerStyle?.polygonFillOpacity
          ? style.polygonFillOpacity
          : vs.polygonFillOpacity,
      polygonBorderOpacity: style.polygonBorderOpacity != previousLayerStyle?.polygonBorderOpacity
          ? style.polygonBorderOpacity
          : vs.polygonBorderOpacity,
      labelOpacity: style.labelOpacity != previousLayerStyle?.labelOpacity ? style.labelOpacity : vs.labelOpacity,
    );
    if (next != vs) {
      v.style = next;
      viewsChanged = true;
    }
  }
  if (viewsChanged) {
    await targetLayer.persistViews();
  }
  targetLayer.folderNode?.invalidateMetaCache();
  targetLayer.invalidateKmetaStyleCache();
  // スタイルを変えたら「どのフィーチャがどのグループか」も取り直す
  await targetLayer.refreshStyleGroups();
  AppLogger.debug('[LayerStyle] レイヤー固有設定を保存: ${targetLayer.layerKey}');
}

/// View のスタイル差分をクリアし、「レイヤに従う」状態に戻す
Future<void> resetViewStyleToFollowLayer({
  required SettingsStore store,
  required LayerNode targetLayer,
  required ViewNode targetView,
  required KMetaLayerStyle? layerStyle,
}) async {
  targetView.style = null;
  await targetLayer.persistViews();
  targetLayer.folderNode?.invalidateMetaCache();
  await targetLayer.refreshStyleGroups();
  store.loadOverlay(layerStyle);
  AppLogger.debug('[LayerStyle] View をレイヤに従わせた: ${targetView.viewKey}');
}

/// レイヤ固有スタイルを KMeta から削除し、グローバル既定値へ戻す（QGIS レンダラ印は維持）
Future<void> resetLayerStyleInKMeta({
  required SettingsStore store,
  required String folderPath,
  required LayerNode targetLayer,
  required String? qgisRenderer,
  required QgisRenderer? qgisRendererDef,
  required bool rendererFromView,
}) async {
  final rawMeta = await KMetaService.instance.getRawMeta(folderPath) ?? KMeta.empty;
  final updatedLayers = Map<String, KMetaLayerStyle>.from(rawMeta.styles.layers);
  updatedLayers.remove(targetLayer.layerKey);
  // QGIS 側の描き分けの印は残す（戻しても `.qgs` のレンダラは QGIS のまま）
  if (qgisRenderer != null && !rendererFromView) {
    updatedLayers[targetLayer.layerKey] =
        KMetaLayerStyle(qgisRenderer: qgisRenderer, qgisRendererDef: qgisRendererDef);
  }
  final updatedStyles = KMetaStyles(
    defaultStyle: rawMeta.styles.defaultStyle,
    layers: updatedLayers,
  );
  await KMetaService.instance.saveMeta(
    folderPath,
    rawMeta.copyWith(styles: updatedStyles),
  );
  targetLayer.invalidateKmetaStyleCache();
  await targetLayer.refreshStyleGroups();
  store.loadOverlay(null);
}
