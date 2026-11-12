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
// こかげマップ: View 固有のレイヤスタイルを、全体設定と合成して描画用のグループに落とす

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/map_style_group.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/qgis_symbol.dart';
import '../../../providers/ui_state_providers.dart';
import '../../layer_style_settings_screen.dart';
import '../map_page_state_base.dart';

mixin MapStyleMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  /// View（とレイヤ）に固有のスタイルを、描画用のグループに落とす。
  ///
  /// > [!IMPORTANT] 「グローバル設定にKMetaを重ねる」規則はここにしか無い
  /// > `SettingsStore.resolveXxx(def, kmeta)` が合成を担当する。
  /// > 描画側には解決済みの値だけを渡し、設定の知識を持ち込まない。
  ///
  /// 固有スタイルが1つも無ければ空リストを返す。そのとき描画は
  /// View 導入前とまったく同じになる。
  List<MapStyleGroup> buildStyleGroups() {
    final style = layerStyleSettings;
    final groups = <MapStyleGroup>[];
    final seen = <String>{};

    // 可視レイヤを、ツリーの並び（＝z順の根拠）で辿る
    final tree = ref.read(folderTreeProvider);
    final layers = tree == null
        ? const <LayerNode>[]
        : tree.getVisibleLayerNodes().whereType<LayerNode>();

    for (final layer in layers) {
      for (final entry in layer.styleGroups.entries) {
        if (!seen.add(entry.key)) continue;
        final kmeta = entry.value;

        final fillRgb = style.resolveColor(polygonFillColorDef, kmeta);
        final fillOpacity = style.resolveDouble(polygonFillOpacityDef, kmeta);
        final fillColor = fillRgb.withValues(alpha: fillOpacity);

        final outlineRgb = style.resolveColor(polygonBorderColorDef, kmeta);
        final outlineOpacity = style.resolveDouble(polygonBorderOpacityDef, kmeta);
        final outlineColor = outlineRgb.withValues(alpha: outlineOpacity);
        final borderWidth = style.resolveDouble(polygonBorderWidthDef, kmeta);

        final lineRgb = style.resolveColor(lineColorDef, kmeta);
        final lineOpacity = style.resolveDouble(lineOpacityDef, kmeta);
        final lineColor = lineRgb.withValues(alpha: lineOpacity);
        final lineWidth = style.resolveDouble(lineWidthDef, kmeta);

        final pointRgb = style.resolveColor(pointColorDef, kmeta);
        final pointOpacity = style.resolveDouble(pointOpacityDef, kmeta);
        final pointSize = style.resolveDouble(pointSizeDef, kmeta);

        final sl = kmeta.symbolLayers;
        final nullSym = sl?.nullSymbol ?? false;
        final inverted = sl?.invertedPolygon ?? false;

        // 線ストローク列（マルチレイヤ優先、無ければ UI 項目から構築）
        final lineDash = LineDashPattern.fromId(style.resolveString(lineDashDef, kmeta));
        final lineCasingOn = style.resolveBool(lineCasingEnabledDef, kmeta);
        final lineCasingColor = style.resolveColor(lineCasingColorDef, kmeta);
        final lineCasingWidth = style.resolveDouble(lineCasingWidthDef, kmeta);
        final lineStrokes = buildEffectiveLineStrokes(
          lineColor: lineColor,
          lineWidth: lineWidth,
          dash: lineDash,
          casingEnabled: lineCasingOn,
          casingColor: lineCasingColor,
          casingWidth: lineCasingWidth,
          symbolLayers: sl,
        );

        // 面塗りレイヤ列
        final fillPattern = PolygonFillPattern.fromId(style.resolveString(polygonFillPatternDef, kmeta));
        final fillSpacing = style.resolveDouble(polygonPatternSpacingDef, kmeta);
        final fillHatchWidth = kmeta.polygonPatternLineWidth ?? 1.5;
        final polygonFills = buildEffectivePolygonFills(
          fillColor: fillColor,
          pattern: fillPattern,
          spacingPx: fillSpacing,
          lineWidthPx: fillHatchWidth,
          symbolLayers: sl,
        );

        // 面の輪郭ストローク列
        final borderDash = LineDashPattern.fromId(style.resolveString(polygonBorderDashDef, kmeta));
        final borderCasingOn = style.resolveBool(polygonBorderCasingEnabledDef, kmeta);
        final borderCasingColor = style.resolveColor(polygonBorderCasingColorDef, kmeta);
        final borderCasingWidth = style.resolveDouble(polygonBorderCasingWidthDef, kmeta);
        final polygonOutlineStrokes = (sl != null && (sl.outlineStrokes.isNotEmpty || sl.fills.isNotEmpty))
            ? sl.outlineStrokes
            : buildEffectiveLineStrokes(
                lineColor: outlineColor,
                lineWidth: borderWidth,
                dash: borderDash,
                casingEnabled: borderCasingOn,
                casingColor: borderCasingColor,
                casingWidth: borderCasingWidth,
              );

        // 点マーカー
        final ptMarker = (sl != null && sl.markers.isNotEmpty) ? sl.markers.last : null;
        final pointShape = ptMarker?.shape ?? PointMarkerShape.fromId(style.resolveString(pointShapeDef, kmeta));
        final pointOutlineEnabled = style.resolveBool(pointOutlineEnabledDef, kmeta);
        final pointOutlineWidth = ptMarker != null
            ? ptMarker.outlineWidthPx
            : (pointOutlineEnabled ? style.resolveDouble(pointOutlineWidthDef, kmeta) : 0.0);
        final pointOutlineColor = ptMarker != null
            ? ptMarker.outlineColor
            : style.resolveColor(pointOutlineColorDef, kmeta).withValues(alpha: pointOpacity);
        final pointAngle = kmeta.pointAngle ?? ptMarker?.angleDeg ?? 0.0;
        final pointSvgContent = ptMarker?.svgContent;

        groups.add(
          MapStyleGroup(
            key: entry.key,
            fillHex: colorToHex(fillRgb),
            fillOpacity: fillOpacity,
            outlineHex: colorToHex(outlineRgb),
            outlineOpacity: outlineOpacity,
            borderWidth: borderWidth,
            lineHex: colorToHex(lineRgb),
            lineOpacity: lineOpacity,
            lineWidth: lineWidth,
            pointHex: colorToHex(pointRgb),
            pointOpacity: pointOpacity,
            pointSize: pointSize,
            labelFontSize: style.resolveDouble(labelFontSizeDef, kmeta),
            labelHex: colorToHex(style.resolveColor(labelColorDef, kmeta)),
            labelHaloHex: colorToHex(style.resolveColor(labelHaloColorDef, kmeta)),
            labelOpacity: style.resolveDouble(labelOpacityDef, kmeta),
            lineStrokes: lineStrokes,
            polygonFills: polygonFills,
            polygonOutlineStrokes: polygonOutlineStrokes,
            pointShape: pointShape,
            pointOutlineColor: pointOutlineColor,
            pointOutlineWidth: pointOutlineWidth,
            pointAngle: pointAngle,
            pointSvgContent: pointSvgContent,
            invertedPolygon: inverted,
            nullSymbol: nullSym,
            minScale: kmeta.minScale,
            maxScale: kmeta.maxScale,
            labelHaloEnabled: kmeta.labelHaloEnabled ?? true,
            labelHaloSize: kmeta.labelHaloSize,
            labelWrapChar: kmeta.labelWrapChar,
            labelBgEnabled: kmeta.labelBgEnabled ?? false,
            labelBgShape: kmeta.labelBgShape,
            labelBgColor: kmeta.labelBgColor,
            labelBgBorderColor: kmeta.labelBgBorderColor,
            labelBgBorderWidth: kmeta.labelBgBorderWidth,
          ),
        );
      }
    }
    return groups;
  }
}
