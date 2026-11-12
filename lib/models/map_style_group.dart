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
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show listEquals;

import 'qgis_symbol.dart';

/// フィーチャの GeoJSON に載せるプロパティ名（MapSourceManager から移した。2026-09-11 MapLibre 撤去）
///
/// [kStyleProp] はスタイルグループのキー（View のキー）。
/// 3D 描画系（`TerrainSceneBuilder`）はこれを見て見た目を決める
const kStyleProp = 'k-style';

/// スタイルグループ 1 つぶんの、解決済みの見た目。
///
/// View（またはレイヤ）に固有のスタイルが付いているぶんだけ作られる。
/// グローバル設定との合成は呼び出し側（`map_page`）が済ませてから渡す。
/// 色は `#RRGGBB` の 16 進（`TerrainFeatureStyle.fromHex` で Flutter の色にする）
class MapStyleGroup {
  const MapStyleGroup({
    required this.key,
    required this.fillHex,
    required this.fillOpacity,
    required this.outlineHex,
    required this.outlineOpacity,
    required this.borderWidth,
    required this.lineHex,
    this.lineOpacity = 1.0,
    required this.lineWidth,
    required this.pointHex,
    this.pointOpacity = 1.0,
    required this.pointSize,
    this.labelFontSize = 12.0,
    this.labelHex = '#000000',
    this.labelHaloHex = '#ffffff',
    this.labelOpacity = 1.0,
    this.lineStrokes = const [],
    this.polygonFills = const [],
    this.polygonOutlineStrokes = const [],
    this.pointShape = PointMarkerShape.circle,
    this.pointOutlineColor = const Color(0xFFFFFFFF),
    this.pointOutlineWidth = 1.5,
    this.pointAngle = 0.0,
    this.pointSvgContent,
    this.invertedPolygon = false,
    this.nullSymbol = false,
    this.minScale,
    this.maxScale,
    this.labelHaloEnabled = true,
    this.labelHaloSize,
    this.labelWrapChar,
    this.labelBgEnabled = false,
    this.labelBgShape,
    this.labelBgColor,
    this.labelBgBorderColor,
    this.labelBgBorderWidth,
  });

  /// フィーチャの `k-style` 属性と突き合わせるキー（View のキー）
  final String key;
  final String fillHex;
  final double fillOpacity;
  final String outlineHex;
  final double outlineOpacity;
  final double borderWidth;
  final String lineHex;
  final double lineOpacity;
  final double lineWidth;
  final String pointHex;
  final double pointOpacity;
  final double pointSize;
  final double labelFontSize;
  final String labelHex;
  final String labelHaloHex;
  final double labelOpacity;

  // 拡張シンボル属性（空の場合は基本フィールドから組み立てる）
  final List<ResolvedLineStroke> lineStrokes;
  final List<ResolvedFillLayer> polygonFills;
  final List<ResolvedLineStroke> polygonOutlineStrokes;
  final PointMarkerShape pointShape;
  final Color pointOutlineColor;
  final double pointOutlineWidth;
  final double pointAngle;
  final String? pointSvgContent;
  final bool invertedPolygon;
  final bool nullSymbol;
  final double? minScale;
  final double? maxScale;

  // リッチラベル属性
  final bool labelHaloEnabled;
  final double? labelHaloSize;
  final String? labelWrapChar;
  final bool labelBgEnabled;
  final String? labelBgShape;
  final Color? labelBgColor;
  final Color? labelBgBorderColor;
  final double? labelBgBorderWidth;

  /// テクスチャ焼き込み世代判定用の署名文字列
  String get signature =>
      '$key $fillHex $fillOpacity $outlineHex $outlineOpacity $borderWidth '
      '$lineHex $lineWidth $lineOpacity $pointHex $pointSize $pointOpacity '
      '$labelFontSize $labelHex $labelHaloHex $labelOpacity '
      '${pointShape.id} ${pointOutlineColor.toARGB32()} $pointOutlineWidth $pointAngle '
      '${pointSvgContent.hashCode} '
      '$invertedPolygon $nullSymbol $minScale $maxScale '
      '$labelHaloEnabled $labelHaloSize $labelWrapChar '
      '$labelBgEnabled $labelBgShape ${labelBgColor?.toARGB32()} '
      '${labelBgBorderColor?.toARGB32()} $labelBgBorderWidth '
      '${Object.hashAll(lineStrokes)} ${Object.hashAll(polygonFills)} ${Object.hashAll(polygonOutlineStrokes)}';

  @override
  bool operator ==(Object other) =>
      other is MapStyleGroup &&
      other.key == key &&
      other.fillHex == fillHex &&
      other.fillOpacity == fillOpacity &&
      other.outlineHex == outlineHex &&
      other.outlineOpacity == outlineOpacity &&
      other.borderWidth == borderWidth &&
      other.lineHex == lineHex &&
      other.lineOpacity == lineOpacity &&
      other.lineWidth == lineWidth &&
      other.pointHex == pointHex &&
      other.pointOpacity == pointOpacity &&
      other.pointSize == pointSize &&
      other.labelFontSize == labelFontSize &&
      other.labelHex == labelHex &&
      other.labelHaloHex == labelHaloHex &&
      other.labelOpacity == labelOpacity &&
      listEquals(other.lineStrokes, lineStrokes) &&
      listEquals(other.polygonFills, polygonFills) &&
      listEquals(other.polygonOutlineStrokes, polygonOutlineStrokes) &&
      other.pointShape == pointShape &&
      other.pointOutlineColor == pointOutlineColor &&
      other.pointOutlineWidth == pointOutlineWidth &&
      other.pointAngle == pointAngle &&
      other.pointSvgContent == pointSvgContent &&
      other.invertedPolygon == invertedPolygon &&
      other.nullSymbol == nullSymbol &&
      other.minScale == minScale &&
      other.maxScale == maxScale &&
      other.labelHaloEnabled == labelHaloEnabled &&
      other.labelHaloSize == labelHaloSize &&
      other.labelWrapChar == labelWrapChar &&
      other.labelBgEnabled == labelBgEnabled &&
      other.labelBgShape == labelBgShape &&
      other.labelBgColor == labelBgColor &&
      other.labelBgBorderColor == labelBgBorderColor &&
      other.labelBgBorderWidth == labelBgBorderWidth;

  @override
  int get hashCode => Object.hashAll([
        key,
        fillHex,
        fillOpacity,
        outlineHex,
        outlineOpacity,
        borderWidth,
        lineHex,
        lineOpacity,
        lineWidth,
        pointHex,
        pointOpacity,
        pointSize,
        labelFontSize,
        labelHex,
        labelHaloHex,
        labelOpacity,
        Object.hashAll(lineStrokes),
        Object.hashAll(polygonFills),
        Object.hashAll(polygonOutlineStrokes),
        pointShape,
        pointOutlineColor,
        pointOutlineWidth,
        pointAngle,
        pointSvgContent,
        invertedPolygon,
        nullSymbol,
        minScale,
        maxScale,
        labelHaloEnabled,
        labelHaloSize,
        labelWrapChar,
        labelBgEnabled,
        labelBgShape,
        labelBgColor,
        labelBgBorderColor,
        labelBgBorderWidth,
      ]);
}

/// Flutter の色を `#RRGGBB`（不透明度は別フィールド）に
String colorToHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// 2 つのリストが同じ並びか
bool styleGroupsEqual(List<MapStyleGroup> a, List<MapStyleGroup> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
