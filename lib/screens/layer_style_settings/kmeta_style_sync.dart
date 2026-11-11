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

/// [store] の現在値から [KMetaLayerStyle] を組み立てる
KMetaLayerStyle buildStyleFromStore(
  SettingsStore store, {
  required bool omitLayerQgisRenderer,
  required String? qgisRenderer,
  required QgisRenderer? qgisRendererDef,
}) =>
    KMetaLayerStyle(
      pointSize: store.getDouble(pointSizeDef),
      pointColor: store.getColor(pointColorDef),
      pointOpacity: store.getDouble(pointOpacityDef),
      lineWidth: store.getDouble(lineWidthDef),
      lineColor: store.getColor(lineColorDef),
      lineOpacity: store.getDouble(lineOpacityDef),
      polygonBorderWidth: store.getDouble(polygonBorderWidthDef),
      polygonBorderColor: store.getColor(polygonBorderColorDef),
      polygonFillColor: store.getColor(polygonFillColorDef),
      polygonFillOpacity: store.getDouble(polygonFillOpacityDef),
      polygonBorderOpacity: store.getDouble(polygonBorderOpacityDef),
      labelEnabled: store.getBool(labelEnabledDef),
      labelProperty: normalizeLabelExpression(store.getString(labelPropertyDef)),
      labelFontSize: store.getDouble(labelFontSizeDef),
      labelColor: store.getColor(labelColorDef),
      labelHaloColor: store.getColor(labelHaloColorDef),
      labelOpacity: store.getDouble(labelOpacityDef),
      // QGIS 側の描き分けの印は、ラベルを変えても消さない
      qgisRenderer: omitLayerQgisRenderer ? null : qgisRenderer,
      qgisRendererDef: omitLayerQgisRenderer ? null : qgisRendererDef,
    );

/// [full] のうち [base] と同じ項目を null にする（View はレイヤと違う項目だけ持つ）
KMetaLayerStyle computeViewStyleDiff(KMetaLayerStyle full, KMetaLayerStyle? base) {
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
