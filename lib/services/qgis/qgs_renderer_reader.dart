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
// こかげマップ: `.qgs` の `<renderer-v2>` とシンボルを読む
//
// 単一シンボルは `QgsStyleReader` が [QgsSymbolReader.read] で読む。
// 分類（categorizedSymbol）・段階（graduatedSymbol）・ルール（RuleRenderer）および
// ラッパー系レンダラ（invertedPolygonRenderer / mergedFeatureRenderer / pointCluster / pointDisplacement）は
// [QgsRendererReader.read] が [QgisRenderer] にする。どちらも読むだけで、`.qgs` は書き換えない。

import 'dart:math' as math;

import 'package:flutter/material.dart' show Color;
import 'package:xml/xml.dart';

import '../../core/terrain/svg_marker_atlas.dart';
import '../../models/kmeta.dart';
import '../../models/qgis_renderer.dart';
import 'qgs_xml.dart';

export 'qgs_xml.dart' show kQgsMmToPx;

/// プロジェクトフォルダ内の相対パス SVG を解決するための読み取りコールバック
typedef QgsSvgFileReader = String? Function(String rawPath);

/// `<symbol>` → 見た目（単層 UI フィールドへの逆マッピング ＋ マルチレイヤ [ResolvedSymbolLayers] 構築）
abstract final class QgsSymbolReader {
  /// [symbol] の見た目。[opacity] はレイヤの不透明度（`<layerOpacity>`）。読めない形なら null。
  static KMetaLayerStyle? read(
    XmlElement symbol, {
    double opacity = 1,
    bool invertedPolygon = false,
    QgsSvgFileReader? svgFileReader,
  }) {
    final layers = [
      for (final l in symbol.findElements('layer'))
        if (l.getAttribute('enabled') != '0') l,
    ];
    if (layers.isEmpty) return null;
    final symAlpha = ((double.tryParse(symbol.getAttribute('alpha') ?? '') ?? 1.0) * opacity).clamp(0.0, 1.0);

    // シンボル全体のデータ定義プロパティ＋各レイヤのデータ定義プロパティを集約
    final dd = <String, String>{};
    for (final l in layers) {
      dd.addAll(_normalizeDataDefined(readDataDefinedExpressions(l), symbol.getAttribute('type')));
    }

    switch (symbol.getAttribute('type')) {
      case 'marker':
        return _readMarkerSymbol(symbol, layers, symAlpha, dd, svgFileReader: svgFileReader);
      case 'line':
        return _readLineSymbol(symbol, layers, symAlpha, dd, svgFileReader: svgFileReader);
      case 'fill':
        return _readFillSymbol(
          symbol,
          layers,
          symAlpha,
          dd,
          invertedPolygon: invertedPolygon,
          svgFileReader: svgFileReader,
        );
      default:
        return null;
    }
  }

  // ── Marker ─────────────────────────────────────────

  static KMetaLayerStyle? _readMarkerSymbol(
    XmlElement symbol,
    List<XmlElement> layers,
    double symAlpha,
    Map<String, String> dd, {
    QgsSvgFileReader? svgFileReader,
  }) {
    final markers = <ResolvedPointLayer>[];
    KMetaLayerStyle? primary;

    for (final l in layers) {
      final cls = l.getAttribute('class') ?? 'SimpleMarker';
      final props = readProps(l);
      if (props.isEmpty) continue;

      final isSvg = cls == 'SvgMarker';
      final shape = cls == 'SimpleMarker'
          ? PointMarkerShape.fromQgisName(props['name'])
          : PointMarkerShape.circle;
      final sizeUnit = props['size_unit'];
      final radius = parseQgsSizeToPx(props['size'], unit: sizeUnit, divideBy: 2) ?? 3.8;
      final rawColor = props['color'] ?? props['fill_color'] ?? props['fill'];
      final rgb = color(rawColor) ?? (isSvg ? const Color(0xFF232323) : const Color(0xFFF44336));
      final effAlpha = ((alphaOf(rawColor) ?? 1.0) * symAlpha).clamp(0.0, 1.0);

      final outlineStyle = (props['outline_style'] ?? 'solid').trim().toLowerCase();
      final rawOutlineColor = props['outline_color'] ?? props['line_color'] ?? props['outline'];
      final outlineRgb = color(rawOutlineColor) ?? const Color(0xFF232323);
      final outlineAlpha = ((alphaOf(rawOutlineColor) ?? 1.0) * symAlpha).clamp(0.0, 1.0);
      final outlineWidth = outlineStyle == 'no'
          ? 0.0
          : (parseQgsSizeToPx(props['outline_width'], unit: props['outline_width_unit']) ?? 0.0);
      final angle = double.tryParse(props['angle'] ?? '') ?? 0.0;

      String? svgContent;
      String? svgPath;
      if (isSvg) {
        final rawName = props['name'];
        svgPath = rawName;
        var rawSvg = decodeBase64QgisSvg(rawName);
        if (rawSvg == null && rawName != null && rawName.isNotEmpty && svgFileReader != null) {
          rawSvg = svgFileReader(rawName);
        }
        rawSvg ??= QgisStandardSvgLibrary.resolve(rawName);
        if (rawSvg != null) {
          svgContent = applyQgisSvgParams(
            rawSvg,
            fillColor: rgb,
            fillOpacity: effAlpha,
            outlineColor: outlineRgb,
            outlineOpacity: outlineAlpha,
            outlineWidthPx: outlineWidth,
            diameterPx: radius * 2.0,
          );
        }
      }

      // QGIS の既定 SimpleMarker は outline_width="0"（ヘアラインまたは実質縁なし）なので、
      // 明示幅 > 0 のときはその幅、outline_style="no" なら 0、既定 0 のときはこかげ既定白縁 (1.5px) に委ねる。
      // SvgMarker は SVG 自体が輪郭を持つため outline_width="0" はそのまま 0 とする。
      final resolvedOutlineWidth = isSvg
          ? outlineWidth
          : (outlineStyle == 'no' ? 0.0 : (outlineWidth > 0 ? outlineWidth : 1.5));
      final resolvedOutlineColor = isSvg
          ? outlineRgb.withValues(alpha: outlineWidth > 0 ? outlineAlpha : 0.0)
          : (outlineStyle == 'no'
              ? const Color(0x00000000)
              : (outlineWidth > 0
                  ? outlineRgb.withValues(alpha: outlineAlpha)
                  : Color.fromARGB((outlineAlpha * 255).round(), 255, 255, 255)));

      markers.add(
        ResolvedPointLayer(
          color: rgb.withValues(alpha: effAlpha),
          radiusPx: radius,
          shape: shape,
          outlineColor: resolvedOutlineColor,
          outlineWidthPx: resolvedOutlineWidth,
          angleDeg: angle,
          svgContent: svgContent,
          svgPath: svgPath,
        ),
      );

      final bool? uiOutlineEnabled = isSvg
          ? (outlineWidth > 0 ? true : false)
          : (outlineStyle == 'no' ? false : (outlineWidth > 0 ? true : null));

      primary = KMetaLayerStyle(
        pointColor: rgb,
        pointSize: parseQgsSizeToPx(props['size'], unit: sizeUnit, divideBy: 2),
        pointOpacity: _nonOpaque(effAlpha),
        pointShape: shape == PointMarkerShape.circle ? null : shape.id,
        pointOutlineEnabled: uiOutlineEnabled,
        pointOutlineColor: outlineWidth > 0 ? outlineRgb : null,
        pointOutlineWidth: outlineWidth > 0 ? outlineWidth : null,
        pointAngle: angle == 0 ? null : angle,
        dataDefined: dd.isEmpty ? null : dd,
      );
    }

    if (primary == null) return null;
    if (markers.length > 1 || markers.any((m) => m.svgContent != null)) {
      return primary.copyWith(symbolLayers: ResolvedSymbolLayers(markers: markers));
    }
    return primary;
  }

  // ── Line ───────────────────────────────────────────

  static KMetaLayerStyle? _readLineSymbol(
    XmlElement symbol,
    List<XmlElement> layers,
    double symAlpha,
    Map<String, String> dd, {
    QgsSvgFileReader? svgFileReader,
  }) {
    final strokes = <ResolvedLineStroke>[];

    // QGIS 3.40+ / 4.x のシンボルレベル <buffer enabled="1"> 対応
    final bufferStroke = _readSymbolBufferAsStroke(
      symbol,
      layers,
      symAlpha,
      svgFileReader: svgFileReader,
    );
    if (bufferStroke != null) {
      strokes.add(bufferStroke);
    }

    var hasComplexLayer = bufferStroke != null;
    _DecodedLineLayer? singleSimple;
    final simpleLayers = <_DecodedLineLayer>[];

    for (var i = 0; i < layers.length; i++) {
      final l = layers[i];
      final cls = l.getAttribute('class') ?? 'SimpleLine';
      final passAttr = int.tryParse(l.getAttribute('pass') ?? '');
      // 複数レイヤ重ね合わせ時は、pass 指定が無ければレイヤ順（背面 0 → 前面 i）を pass に使う
      final pass = passAttr ?? (bufferStroke != null ? i + 1 : i);

      if (cls == 'SimpleLine') {
        final d = _decodeSimpleLine(l, symAlpha, pass: pass);
        if (d == null) continue;
        singleSimple = d;
        simpleLayers.add(d);
        if (d.hasCustomDash || d.offsetPx != 0) hasComplexLayer = true;
        if (d.stroke != null) strokes.add(d.stroke!);
      } else if (cls == 'MarkerLine' || cls == 'HashLine') {
        hasComplexLayer = true;
        final approx = _decodeMarkerOrHashLine(
          l,
          symAlpha,
          pass: pass,
          svgFileReader: svgFileReader,
        );
        if (approx != null) strokes.add(approx);
      } else {
        final d = _decodeSimpleLine(l, symAlpha, pass: pass);
        if (d != null) {
          singleSimple = d;
          if (d.stroke != null) strokes.add(d.stroke!);
        }
      }
    }

    if (strokes.isEmpty && singleSimple == null) return null;

    // ケース1: 単一 SimpleLine（最も一般的。既存ゴールデン互換を厳密維持）
    if (!hasComplexLayer && simpleLayers.length == 1) {
      final s = simpleLayers.first;
      return KMetaLayerStyle(
        lineColor: s.rgb,
        lineWidth: s.widthPx,
        lineOpacity: _nonOpaque(s.effAlpha),
        lineDash: s.dash == LineDashPattern.solid ? null : s.dash.id,
        dataDefined: dd.isEmpty ? null : dd,
      );
    }

    // ケース2: 背面太線（実線）＋前面細線の典型的な 2 層ケーシング（または <buffer> + 単線）
    if (simpleLayers.length == 2 &&
        bufferStroke == null &&
        !simpleLayers[0].hasCustomDash &&
        !simpleLayers[1].hasCustomDash &&
        simpleLayers[0].offsetPx == 0 &&
        simpleLayers[1].offsetPx == 0 &&
        simpleLayers[0].dash == LineDashPattern.solid &&
        simpleLayers[0].widthPx > simpleLayers[1].widthPx &&
        simpleLayers[1].widthPx > 0) {
      final back = simpleLayers[0];
      final front = simpleLayers[1];
      final casingW = (back.widthPx - front.widthPx) / 2.0;
      final sameAlpha = (back.effAlpha - front.effAlpha).abs() < 0.01;
      return KMetaLayerStyle(
        lineColor: front.rgb,
        lineWidth: front.widthPx,
        lineOpacity: _nonOpaque(front.effAlpha),
        lineDash: front.dash == LineDashPattern.solid ? null : front.dash.id,
        lineCasingEnabled: true,
        lineCasingColor: back.rgb,
        lineCasingWidth: casingW,
        symbolLayers: sameAlpha ? null : ResolvedSymbolLayers(strokes: strokes),
        dataDefined: dd.isEmpty ? null : dd,
      );
    }

    if (bufferStroke != null && simpleLayers.length == 1 && !simpleLayers.first.hasCustomDash) {
      final front = simpleLayers.first;
      final casingW = math.max(0.5, (bufferStroke.widthPx - front.widthPx) / 2.0);
      return KMetaLayerStyle(
        lineColor: front.rgb,
        lineWidth: front.widthPx,
        lineOpacity: _nonOpaque(front.effAlpha),
        lineDash: front.dash == LineDashPattern.solid ? null : front.dash.id,
        lineCasingEnabled: true,
        lineCasingColor: Color.fromARGB(
          255,
          (bufferStroke.color.r * 255).round(),
          (bufferStroke.color.g * 255).round(),
          (bufferStroke.color.b * 255).round(),
        ),
        lineCasingWidth: casingW,
        symbolLayers: ResolvedSymbolLayers(strokes: strokes),
        dataDefined: dd.isEmpty ? null : dd,
      );
    }

    // ケース3: 3層以上・カスタムダッシュ・平行オフセット・MarkerLine 等
    final rep = singleSimple;
    final repStroke = strokes.isNotEmpty ? strokes.last : null;
    final repColor = rep?.rgb ??
        (repStroke != null
            ? Color.fromARGB(
                255,
                (repStroke.color.r * 255).round(),
                (repStroke.color.g * 255).round(),
                (repStroke.color.b * 255).round(),
              )
            : null);
    return KMetaLayerStyle(
      lineColor: repColor,
      lineWidth: rep?.widthPx ?? repStroke?.widthPx,
      lineOpacity: _nonOpaque(rep?.effAlpha ?? repStroke?.color.a ?? 1.0),
      lineDash: rep != null && rep.dash != LineDashPattern.solid ? rep.dash.id : null,
      symbolLayers: strokes.isEmpty ? null : ResolvedSymbolLayers(strokes: strokes),
      dataDefined: dd.isEmpty ? null : dd,
    );
  }

  // ── Fill ───────────────────────────────────────────

  static KMetaLayerStyle? _readFillSymbol(
    XmlElement symbol,
    List<XmlElement> layers,
    double symAlpha,
    Map<String, String> dd, {
    required bool invertedPolygon,
    QgsSvgFileReader? svgFileReader,
  }) {
    // 単一の SimpleFill（実線枠・ベタ塗りまたは no）の高速・完全互換パス
    if (layers.length == 1 && !invertedPolygon && layers.first.getAttribute('class') == 'SimpleFill') {
      final props = readProps(layers.first);
      if (props.isEmpty) return null;
      final brushStyle = (props['style'] ?? 'solid').trim().toLowerCase();
      final outlineStyle = (props['outline_style'] ?? 'solid').trim().toLowerCase();
      final fillPattern = PolygonFillPattern.fromQgisBrushStyle(brushStyle);
      final borderDash = LineDashPattern.fromQgisPenStyle(outlineStyle);
      final strokeRaw = props['outline_color'] ?? props['border_color'];
      final fillUnit = props['outline_width_unit'] ?? props['border_width_unit'];
      if ((brushStyle == 'solid' || brushStyle == 'no') &&
          (outlineStyle == 'solid' || outlineStyle == 'no')) {
        return KMetaLayerStyle(
          polygonFillColor: color(props['color']),
          polygonFillOpacity: _times(alphaOf(props['color']), symAlpha, hidden: brushStyle == 'no'),
          polygonBorderColor: color(strokeRaw),
          polygonBorderOpacity: _times(alphaOf(strokeRaw), symAlpha, hidden: outlineStyle == 'no'),
          polygonBorderWidth: parseQgsSizeToPx(props['outline_width'] ?? props['border_width'], unit: fillUnit),
          dataDefined: dd.isEmpty ? null : dd,
        );
      }
      return KMetaLayerStyle(
        polygonFillColor: color(props['color']),
        polygonFillOpacity: _times(alphaOf(props['color']), symAlpha, hidden: brushStyle == 'no'),
        polygonFillPattern: brushStyle == 'no'
            ? PolygonFillPattern.none.id
            : (fillPattern == PolygonFillPattern.solid ? null : fillPattern.id),
        polygonBorderColor: color(strokeRaw),
        polygonBorderOpacity: _times(alphaOf(strokeRaw), symAlpha, hidden: outlineStyle == 'no'),
        polygonBorderWidth: parseQgsSizeToPx(props['outline_width'] ?? props['border_width'], unit: fillUnit),
        polygonBorderDash: outlineStyle == 'no'
            ? null
            : (borderDash == LineDashPattern.solid ? null : borderDash.id),
        dataDefined: dd.isEmpty ? null : dd,
      );
    }

    // 単一の SimpleLine（輪郭のみのポリゴンシンボル）
    if (layers.length == 1 && !invertedPolygon && layers.first.getAttribute('class') == 'SimpleLine') {
      final d = _decodeSimpleLine(layers.first, symAlpha, pass: 0);
      if (d == null) return null;
      return KMetaLayerStyle(
        polygonFillOpacity: 0,
        polygonBorderColor: d.rgb,
        polygonBorderOpacity: d.dash == LineDashPattern.none ? 0 : d.effAlpha,
        polygonBorderWidth: d.widthPx,
        polygonBorderDash: d.dash == LineDashPattern.solid || d.dash == LineDashPattern.none ? null : d.dash.id,
        symbolLayers: d.hasCustomDash || d.offsetPx != 0
            ? ResolvedSymbolLayers(outlineStrokes: [if (d.stroke != null) d.stroke!])
            : null,
        dataDefined: dd.isEmpty ? null : dd,
      );
    }

    // マルチレイヤまたは LinePatternFill / PointPatternFill / CentroidFill / invertedPolygon
    final fills = <ResolvedFillLayer>[];
    final outlineStrokes = <ResolvedLineStroke>[];

    Color? repFillRgb;
    double? repFillAlpha;
    PolygonFillPattern? repPattern;
    double? repSpacing;
    double? repLineWidth;
    Color? repBorderRgb;
    double? repBorderAlpha;
    double? repBorderWidth;
    LineDashPattern? repBorderDash;
    final simpleOutlineLayers = <_DecodedLineLayer>[];

    for (var i = 0; i < layers.length; i++) {
      final l = layers[i];
      final cls = l.getAttribute('class') ?? 'SimpleFill';
      final props = readProps(l);
      final pass = int.tryParse(l.getAttribute('pass') ?? '') ?? i;

      switch (cls) {
        case 'SimpleFill':
          final brushStyle = (props['style'] ?? 'solid').trim().toLowerCase();
          final rawFill = props['color'];
          final fRgb = color(rawFill) ?? const Color(0xFF808080);
          final fAlpha = ((alphaOf(rawFill) ?? 1.0) * symAlpha).clamp(0.0, 1.0);
          if (brushStyle != 'no' && fAlpha > 0) {
            repFillRgb = fRgb;
            repFillAlpha = fAlpha;
            final pat = PolygonFillPattern.fromQgisBrushStyle(brushStyle);
            repPattern = pat;
            fills.addAll(
              buildEffectivePolygonFills(
                fillColor: fRgb.withValues(alpha: fAlpha),
                pattern: pat,
                spacingPx: _denseSpacingFor(brushStyle),
              ),
            );
          }
          final outlineStyle = (props['outline_style'] ?? 'solid').trim().toLowerCase();
          final rawStroke = props['outline_color'] ?? props['border_color'];
          final bRgb = color(rawStroke) ?? const Color(0xFF232323);
          final bAlpha = ((alphaOf(rawStroke) ?? 1.0) * symAlpha).clamp(0.0, 1.0);
          final bWidth = parseQgsSizeToPx(
                props['outline_width'] ?? props['border_width'],
                unit: props['outline_width_unit'] ?? props['border_width_unit'],
              ) ??
              1.0;
          if (outlineStyle != 'no' && bWidth > 0 && bAlpha > 0) {
            final bDash = LineDashPattern.fromQgisPenStyle(outlineStyle);
            repBorderRgb = bRgb;
            repBorderAlpha = bAlpha;
            repBorderWidth = bWidth;
            repBorderDash = bDash;
            final dArr = bDash.toDashArray(bWidth);
            outlineStrokes.add(
              ResolvedLineStroke(
                color: bRgb.withValues(alpha: bAlpha),
                widthPx: bWidth,
                dashArray: dArr,
                pass: pass,
                capRound: dArr == null,
              ),
            );
          }

        case 'LinePatternFill':
          final angle = double.tryParse(props['angle'] ?? props['lineangle'] ?? '') ?? 45.0;
          final spacing = parseQgsSizeToPx(
                props['distance'] ?? props['line_distance'],
                unit: props['distance_unit'] ?? props['line_distance_unit'],
              ) ??
              8.0;
          final offset = parseQgsSizeToPx(props['offset'], unit: props['offset_unit']) ?? 0.0;

          Color lRgb = color(props['color']) ?? const Color(0xFF000000);
          double lAlpha = ((alphaOf(props['color']) ?? 1.0) * symAlpha).clamp(0.0, 1.0);
          double lWidth = parseQgsSizeToPx(props['line_width'], unit: props['line_width_unit']) ?? 1.5;
          List<double>? lDash;

          final subLine = l.findElements('symbol').where((s) => s.getAttribute('type') == 'line').firstOrNull;
          if (subLine != null) {
            final subAlpha = ((double.tryParse(subLine.getAttribute('alpha') ?? '') ?? 1.0) * symAlpha).clamp(0.0, 1.0);
            final subLayer = subLine.findElements('layer').where((e) => e.getAttribute('enabled') != '0').firstOrNull;
            if (subLayer != null) {
              final d = _decodeSimpleLine(subLayer, subAlpha, pass: 0);
              if (d != null) {
                lRgb = d.rgb;
                lAlpha = d.effAlpha;
                lWidth = math.max(0.5, d.widthPx);
                lDash = d.stroke?.dashArray;
              }
            }
          }

          fills.add(
            ResolvedFillLayer.linePattern(
              color: lRgb.withValues(alpha: lAlpha),
              angleDeg: angle,
              spacingPx: math.max(2.0, spacing),
              lineWidthPx: lWidth,
              offsetPx: offset,
              dashArray: lDash,
            ),
          );
          repFillRgb ??= lRgb;
          repFillAlpha ??= lAlpha;
          repPattern = _angleToFillPattern(angle, previous: repPattern);
          repSpacing = spacing;
          repLineWidth = lWidth;

          // 古い形式の LinePatternFill で outline_width 等を持つ場合のフォールバック
          final outWidth = parseQgsSizeToPx(props['outline_width'], unit: props['outline_width_unit']) ?? 0;
          if (outWidth > 0 && props['outline_color'] != null) {
            final bRgb = color(props['outline_color']) ?? const Color(0xFF232323);
            final bAlpha = ((alphaOf(props['outline_color']) ?? 1.0) * symAlpha).clamp(0.0, 1.0);
            repBorderRgb ??= bRgb;
            repBorderAlpha ??= bAlpha;
            repBorderWidth ??= outWidth;
            outlineStrokes.add(ResolvedLineStroke(color: bRgb.withValues(alpha: bAlpha), widthPx: outWidth, pass: pass));
          }

        case 'PointPatternFill':
          final dx = parseQgsSizeToPx(props['distance_x'], unit: props['distance_x_unit']) ?? 8.0;
          final dy = parseQgsSizeToPx(props['distance_y'], unit: props['distance_y_unit']) ?? 8.0;
          Color pRgb = const Color(0xFF000000);
          double pAlpha = symAlpha;
          double pRadius = 1.5;
          PointMarkerShape pShape = PointMarkerShape.circle;
          String? pSvg;

          final subMarker = l.findElements('symbol').where((s) => s.getAttribute('type') == 'marker').firstOrNull;
          if (subMarker != null) {
            final subStyle = read(subMarker, opacity: symAlpha, svgFileReader: svgFileReader);
            if (subStyle != null) {
              pRgb = subStyle.pointColor ?? pRgb;
              pAlpha = subStyle.pointOpacity ?? symAlpha;
              pRadius = math.max(0.8, subStyle.pointSize ?? 1.5);
              pShape = PointMarkerShape.fromId(subStyle.pointShape);
              pSvg = subStyle.symbolLayers?.markers.lastOrNull?.svgContent;
            }
          }
          fills.add(
            ResolvedFillLayer.pointPattern(
              color: pRgb.withValues(alpha: pAlpha),
              dxPx: math.max(3.0, dx),
              dyPx: math.max(3.0, dy),
              pointRadiusPx: pRadius,
              pointShape: pShape,
              pointSvgContent: pSvg,
            ),
          );
          repFillRgb ??= pRgb;
          repFillAlpha ??= pAlpha;
          repPattern = PolygonFillPattern.dots;
          repSpacing = (dx + dy) / 2.0;

        case 'SimpleLine' || 'MarkerLine' || 'HashLine':
          final decoded = cls == 'SimpleLine' ? _decodeSimpleLine(l, symAlpha, pass: pass) : null;
          if (decoded != null) simpleOutlineLayers.add(decoded);
          final stroke = cls == 'SimpleLine'
              ? decoded?.stroke
              : _decodeMarkerOrHashLine(l, symAlpha, pass: pass, svgFileReader: svgFileReader);
          if (stroke != null) {
            outlineStrokes.add(stroke);
            repBorderRgb = Color.fromARGB(
              255,
              (stroke.color.r * 255).round(),
              (stroke.color.g * 255).round(),
              (stroke.color.b * 255).round(),
            );
            repBorderAlpha = stroke.color.a;
            repBorderWidth = stroke.widthPx;
            if (decoded != null) repBorderDash = decoded.dash;
          }

        case 'CentroidFill':
          final subMarker = l.findElements('symbol').where((s) => s.getAttribute('type') == 'marker').firstOrNull;
          if (subMarker != null) {
            final subStyle = read(subMarker, opacity: symAlpha, svgFileReader: svgFileReader);
            if (subStyle?.pointColor != null) {
              final c = subStyle!.pointColor!;
              repFillRgb ??= c;
              repFillAlpha ??= 0.25 * symAlpha;
              fills.add(ResolvedFillLayer.solid(color: c.withValues(alpha: 0.25 * symAlpha)));
            }
          }
      }
    }

    if (fills.isEmpty && outlineStrokes.isEmpty && !invertedPolygon) return null;

    bool? borderCasingEnabled;
    Color? borderCasingRgb;
    double? borderCasingW;
    if (simpleOutlineLayers.length == 2 &&
        outlineStrokes.length == 2 &&
        !simpleOutlineLayers[0].hasCustomDash &&
        !simpleOutlineLayers[1].hasCustomDash &&
        simpleOutlineLayers[0].dash == LineDashPattern.solid &&
        simpleOutlineLayers[0].widthPx > simpleOutlineLayers[1].widthPx &&
        simpleOutlineLayers[1].widthPx > 0) {
      borderCasingEnabled = true;
      borderCasingRgb = simpleOutlineLayers[0].rgb;
      borderCasingW = (simpleOutlineLayers[0].widthPx - simpleOutlineLayers[1].widthPx) / 2.0;
    }

    return KMetaLayerStyle(
      polygonFillColor: repFillRgb,
      polygonFillOpacity: fills.isEmpty ? 0.0 : repFillAlpha,
      polygonFillPattern: fills.isEmpty
          ? PolygonFillPattern.none.id
          : (repPattern == null || repPattern == PolygonFillPattern.solid ? null : repPattern.id),
      polygonPatternSpacing: repSpacing,
      polygonPatternLineWidth: repLineWidth,
      polygonBorderColor: repBorderRgb,
      polygonBorderOpacity: outlineStrokes.isEmpty ? 0.0 : repBorderAlpha,
      polygonBorderWidth: outlineStrokes.isEmpty ? 0.0 : repBorderWidth,
      polygonBorderDash: repBorderDash == null || repBorderDash == LineDashPattern.solid ? null : repBorderDash.id,
      polygonBorderCasingEnabled: borderCasingEnabled,
      polygonBorderCasingColor: borderCasingRgb,
      polygonBorderCasingWidth: borderCasingW,
      symbolLayers: ResolvedSymbolLayers(
        fills: fills,
        outlineStrokes: outlineStrokes,
        invertedPolygon: invertedPolygon,
      ),
      dataDefined: dd.isEmpty ? null : dd,
    );
  }

  // ── Helpers ────────────────────────────────────────

  static _DecodedLineLayer? _decodeSimpleLine(XmlElement layerEl, double symAlpha, {required int pass}) {
    final props = readProps(layerEl);
    if (props.isEmpty) return null;
    final rawColor = props['line_color'] ?? props['color'];
    final rgb = color(rawColor) ?? const Color(0xFF000000);
    final effAlpha = ((alphaOf(rawColor) ?? 1.0) * symAlpha).clamp(0.0, 1.0);
    final lineStyle = (props['line_style'] ?? props['penstyle'] ?? 'solid').trim().toLowerCase();
    final unit = props['line_width_unit'] ?? props['width_unit'];
    final widthPx = lineStyle == 'no'
        ? 0.0
        : (parseQgsSizeToPx(props['line_width'] ?? props['width'], unit: unit) ?? 1.0);
    final offsetPx = parseQgsSizeToPx(props['offset'], unit: props['offset_unit'] ?? unit) ?? 0.0;

    final useCustom = props['use_custom_dash'] == '1';
    List<double>? customDash;
    if (useCustom && props['customdash'] != null) {
      final dashUnit = props['customdash_unit'] ?? unit;
      final parts = props['customdash']!
          .split(RegExp('[;,]'))
          .map((s) => parseQgsSizeToPx(s.trim(), unit: dashUnit))
          .whereType<double>()
          .where((v) => v > 0)
          .toList();
      if (parts.length >= 2) customDash = parts;
    }

    final dash = lineStyle == 'no'
        ? LineDashPattern.none
        : (customDash != null ? LineDashPattern.dash : LineDashPattern.fromQgisPenStyle(lineStyle));
    final dashArr = customDash ?? dash.toDashArray(widthPx);
    final capStyle = (props['capstyle'] ?? 'square').toLowerCase();

    final stroke = (lineStyle == 'no' || widthPx <= 0 || effAlpha <= 0)
        ? null
        : ResolvedLineStroke(
            color: rgb.withValues(alpha: effAlpha),
            widthPx: widthPx,
            dashArray: dashArr,
            offsetPx: offsetPx,
            pass: pass,
            capRound: dashArr == null && capStyle == 'round',
          );

    return _DecodedLineLayer(
      rgb: rgb,
      effAlpha: effAlpha,
      widthPx: widthPx,
      dash: dash,
      offsetPx: offsetPx,
      hasCustomDash: customDash != null,
      stroke: stroke,
    );
  }

  static ResolvedLineStroke? _decodeMarkerOrHashLine(
    XmlElement layerEl,
    double symAlpha, {
    required int pass,
    QgsSvgFileReader? svgFileReader,
  }) {
    final props = readProps(layerEl);
    final interval = parseQgsSizeToPx(props['interval'], unit: props['interval_unit']) ?? 8.0;
    Color c = const Color(0xFF000000);
    double alpha = symAlpha;
    double w = 2.5;

    final subSym = layerEl.findElements('symbol').firstOrNull;
    if (subSym != null) {
      final sub = read(subSym, opacity: symAlpha, svgFileReader: svgFileReader);
      if (sub != null) {
        c = sub.pointColor ?? sub.lineColor ?? c;
        alpha = sub.pointOpacity ?? sub.lineOpacity ?? symAlpha;
        w = (sub.pointSize != null ? sub.pointSize! * 1.6 : sub.lineWidth) ?? 2.5;
      }
    }
    final onPx = math.max(1.5, w * 0.9);
    final offPx = math.max(2.0, interval - onPx);
    return ResolvedLineStroke(
      color: c.withValues(alpha: alpha.clamp(0.0, 1.0)),
      widthPx: w.clamp(1.0, 12.0),
      dashArray: [onPx, offPx],
      pass: pass,
      capRound: layerEl.getAttribute('class') == 'MarkerLine',
    );
  }

  static ResolvedLineStroke? _readSymbolBufferAsStroke(
    XmlElement symbol,
    List<XmlElement> layers,
    double symAlpha, {
    QgsSvgFileReader? svgFileReader,
  }) {
    final buf = symbol.getElement('buffer');
    if (buf == null) return null;
    final optMap = symbolOptionMap(buf);
    final enabled = buf.getAttribute('enabled') ?? namedOption(optMap ?? buf, 'enabled')?.getAttribute('value');
    if (enabled != '1' && enabled?.toLowerCase() != 'true') return null;

    final sizeRaw = buf.getAttribute('size') ?? namedOption(optMap ?? buf, 'size')?.getAttribute('value');
    final sizeUnit = buf.getAttribute('sizeUnits') ?? namedOption(optMap ?? buf, 'size_unit')?.getAttribute('value');
    final bufPx = parseQgsSizeToPx(sizeRaw, unit: sizeUnit) ?? 2.0;
    if (bufPx <= 0) return null;

    // メイン線の最大幅を推定
    var baseWidth = 2.0;
    for (final l in layers) {
      if (l.getAttribute('class') == 'SimpleLine') {
        final d = _decodeSimpleLine(l, symAlpha, pass: 0);
        if (d != null && d.widthPx > baseWidth) baseWidth = d.widthPx;
      }
    }

    Color bufColor = const Color(0xFFFFFFFF);
    double bufAlpha = symAlpha;
    final rawColorAttr = buf.getAttribute('color') ?? namedOption(optMap ?? buf, 'color')?.getAttribute('value');
    if (rawColorAttr != null) {
      bufColor = color(rawColorAttr) ?? bufColor;
      bufAlpha = ((alphaOf(rawColorAttr) ?? 1.0) * symAlpha).clamp(0.0, 1.0);
    }
    final fillSym = buf.findElements('symbol').where((s) => s.getAttribute('type') == 'fill').firstOrNull;
    if (fillSym != null) {
      final fillStyle = read(fillSym, opacity: symAlpha, svgFileReader: svgFileReader);
      if (fillStyle?.polygonFillColor != null) {
        bufColor = fillStyle!.polygonFillColor!;
        bufAlpha = fillStyle.polygonFillOpacity ?? symAlpha;
      }
    }
    return ResolvedLineStroke(
      color: bufColor.withValues(alpha: bufAlpha.clamp(0.0, 1.0)),
      widthPx: baseWidth + bufPx * 2.0,
      pass: 0,
      capRound: true,
    );
  }

  static double _denseSpacingFor(String brushStyle) => switch (brushStyle) {
        'dense1' || 'dense2' => 4.0,
        'dense3' || 'dense4' => 6.0,
        'dense5' => 8.0,
        'dense6' || 'dense7' => 11.0,
        _ => 8.0,
      };

  static PolygonFillPattern _angleToFillPattern(double angleDeg, {PolygonFillPattern? previous}) {
    final norm = ((angleDeg % 180) + 180) % 180;
    final current = norm < 22.5 || norm >= 157.5
        ? PolygonFillPattern.horizontal
        : norm < 67.5
            ? PolygonFillPattern.slash
            : norm < 112.5
                ? PolygonFillPattern.vertical
                : PolygonFillPattern.backslash;
    if ((previous == PolygonFillPattern.slash && current == PolygonFillPattern.backslash) ||
        (previous == PolygonFillPattern.backslash && current == PolygonFillPattern.slash)) {
      return PolygonFillPattern.cross;
    }
    if ((previous == PolygonFillPattern.horizontal && current == PolygonFillPattern.vertical) ||
        (previous == PolygonFillPattern.vertical && current == PolygonFillPattern.horizontal)) {
      return PolygonFillPattern.grid;
    }
    return current;
  }

  static Map<String, String> _normalizeDataDefined(Map<String, String> raw, String? symType) {
    if (raw.isEmpty) return const {};
    final out = <String, String>{};
    for (final e in raw.entries) {
      final key = switch ((symType, e.key)) {
        ('marker', 'size') => 'pointSize',
        ('marker', 'angle') => 'pointAngle',
        ('marker', 'color' || 'fillColor') => 'pointColor',
        ('line', 'width' || 'outlineWidth') => 'lineWidth',
        ('line', 'color' || 'outlineColor') => 'lineColor',
        ('fill', 'color' || 'fillColor') => 'polygonFillColor',
        ('fill', 'outlineColor') => 'polygonBorderColor',
        ('fill', 'outlineWidth') => 'polygonBorderWidth',
        _ => e.key,
      };
      out[key] = e.value;
    }
    return out;
  }

  /// 完全不透明（1.0）のときは null（JSON ノイズを出さない）、半透明のときだけ値を返す
  static double? _nonOpaque(double alpha) => (alpha - 1.0).abs() < 1e-6 ? null : alpha;

  /// 色のアルファ × 不透明度。描かない設定（`style="no"`）なら 0。どちらも既定なら null（＝書かない）
  static double? _times(double? colorAlpha, double opacity, {bool hidden = false}) {
    if (hidden) return 0;
    if (colorAlpha == null && opacity == 1) return null;
    return (colorAlpha ?? 1) * opacity;
  }

  /// シンボルレイヤのプロパティを読む。
  ///
  /// ⚠ QGIS 3.x は `<Option name= value=>`、それ以前は `<prop k= v=>`。
  /// **両方読む。** 他人のファイルは古い形式で来る。
  static Map<String, String> readProps(XmlElement symbolLayer) {
    final props = <String, String>{};

    // 旧形式（QGIS 3.x より前）。`<layer>` の直下に並ぶ
    for (final prop in symbolLayer.findElements('prop')) {
      final k = prop.getAttribute('k');
      final v = prop.getAttribute('v');
      if (k != null && v != null) props[k] = v;
    }

    // 新形式。`<layer>` の**直下の** `<Option type="Map">` の子だけを見る。
    //
    // ⚠ 再帰で拾ってはいけない。QGIS は `<layer>` の中に
    //   `<data_defined_properties>` も書き、そこにも `name="name"` などの
    //   `<Option>` が入っている。まとめて読むと本物の値を上書きしてしまう
    //   （QGIS 3.44 の実出力で確認）。
    for (final map in symbolLayer.findElements('Option')) {
      if (map.getAttribute('type') != 'Map') continue;
      for (final option in map.findElements('Option')) {
        final name = option.getAttribute('name');
        final value = option.getAttribute('value');
        if (name != null && value != null) props[name] = value;
      }
    }
    return props;
  }

  /// QGIS の `R,G,B,A`（各0-255）
  static Color? color(String? value) => parseQgsColor(value);

  /// `R,G,B,A` のAを 0..1 で返す
  static double? alphaOf(String? value) => parseQgsColorAlpha(value);

  static double? px(String? mm, {double divideBy = 1}) => parseQgsMmToPx(mm, divideBy: divideBy);
}

class _DecodedLineLayer {
  const _DecodedLineLayer({
    required this.rgb,
    required this.effAlpha,
    required this.widthPx,
    required this.dash,
    required this.offsetPx,
    required this.hasCustomDash,
    required this.stroke,
  });

  final Color rgb;
  final double effAlpha;
  final double widthPx;
  final LineDashPattern dash;
  final double offsetPx;
  final bool hasCustomDash;
  final ResolvedLineStroke? stroke;
}

/// ラッパー系 `<renderer-v2>`（`invertedPolygonRenderer` / `mergedFeatureRenderer` /
/// `pointCluster` / `pointDisplacement`）を内側の本体レンダラへ剥がす
({XmlElement effective, String outerType, bool invertedPolygon}) unwrapQgsRendererElement(XmlElement outer) {
  var cur = outer;
  final outerType = outer.getAttribute('type') ?? '';
  var inverted = false;
  for (var depth = 0; depth < 4; depth++) {
    final t = cur.getAttribute('type');
    if (t == 'invertedPolygonRenderer') inverted = true;
    if (t == 'invertedPolygonRenderer' ||
        t == 'mergedFeatureRenderer' ||
        t == 'pointCluster' ||
        t == 'pointDisplacement') {
      final inner = cur.findElements('renderer-v2').firstOrNull;
      if (inner != null) {
        cur = inner;
        continue;
      }
    }
    break;
  }
  return (effective: cur, outerType: outerType, invertedPolygon: inverted);
}

/// `<renderer-v2>`（分類・段階・ルール・ラッパー系）→ [QgisRenderer]
abstract final class QgsRendererReader {
  /// [maplayer] のレンダラ。描き分けでなければ（単一シンボル・未対応の種類）null
  static QgisRenderer? read(
    XmlElement maplayer, {
    QgsSvgFileReader? svgFileReader,
  }) {
    final rawRenderer = maplayer.findElements('renderer-v2').firstOrNull;
    if (rawRenderer == null) return null;
    final (:effective, outerType: _, :invertedPolygon) = unwrapQgsRendererElement(rawRenderer);
    final renderer = effective;
    final kind = QgisRendererKind.fromQgisType(renderer.getAttribute('type'));
    if (kind == null) return null;

    final opacity = double.tryParse(childText(maplayer, 'layerOpacity') ?? '') ?? 1;
    final symbols = <String, XmlElement>{
      for (final s in renderer.getElement('symbols')?.findElements('symbol') ?? const <XmlElement>[])
        s.getAttribute('name') ?? '': s,
    };
    KMetaLayerStyle? styleOf(String? name) {
      final s = name == null ? null : symbols[name];
      return s == null
          ? null
          : QgsSymbolReader.read(
              s,
              opacity: opacity,
              invertedPolygon: invertedPolygon,
              svgFileReader: svgFileReader,
            );
    }

    bool render(XmlElement e) => e.getAttribute('render') != 'false';

    double? positiveDouble(String? s) {
      final v = double.tryParse(s ?? '');
      return (v != null && v > 0) ? v : null;
    }

    switch (kind) {
      case QgisRendererKind.categorized:
        return QgisRenderer(
          kind: kind,
          attr: renderer.getAttribute('attr'),
          invertedPolygon: invertedPolygon,
          classes: [
            for (final c in renderer.getElement('categories')?.findElements('category') ?? const <XmlElement>[])
              QgisRendererClass(
                label: c.getAttribute('label') ?? '',
                style: styleOf(c.getAttribute('symbol')),
                render: render(c),
                values: _categoryValues(c),
              ),
          ],
        );
      case QgisRendererKind.graduated:
        return QgisRenderer(
          kind: kind,
          attr: renderer.getAttribute('attr'),
          invertedPolygon: invertedPolygon,
          classes: [
            for (final r in renderer.getElement('ranges')?.findElements('range') ?? const <XmlElement>[])
              QgisRendererClass(
                label: r.getAttribute('label') ?? '',
                style: styleOf(r.getAttribute('symbol')),
                render: render(r),
                lower: double.tryParse(r.getAttribute('lower') ?? ''),
                upper: double.tryParse(r.getAttribute('upper') ?? ''),
              ),
          ],
        );
      case QgisRendererKind.rule:
        final classes = <QgisRendererClass>[];
        QgisRule rule(XmlElement e) {
          final symbol = e.getAttribute('symbol');
          final minDenom = positiveDouble(e.getAttribute('scalemindenom'));
          final maxDenom = positiveDouble(e.getAttribute('scalemaxdenom'));
          int? classIndex;
          if (symbol != null && symbols.containsKey(symbol)) {
            classIndex = classes.length;
            classes.add(QgisRendererClass(
              label: e.getAttribute('label') ?? e.getAttribute('filter') ?? '',
              style: styleOf(symbol),
              scaleMinDenom: minDenom,
              scaleMaxDenom: maxDenom,
            ));
          }
          final filter = e.getAttribute('filter');
          return QgisRule(
            filter: filter,
            isElse: filter?.trim().toUpperCase() == 'ELSE',
            active: e.getAttribute('active') != '0',
            classIndex: classIndex,
            scaleMinDenom: minDenom,
            scaleMaxDenom: maxDenom,
            children: [for (final c in e.findElements('rule')) rule(c)],
          );
        }

        final root = renderer.getElement('rules');
        final rules = [for (final e in root?.findElements('rule') ?? const <XmlElement>[]) rule(e)];
        return QgisRenderer(kind: kind, classes: classes, rules: rules, invertedPolygon: invertedPolygon);
    }
  }

  /// 分類の値。`type="NULL"` や空は「その他の値すべて」（空のリスト）。
  /// QGIS 3.36 からの複数値の項目（`<val>` の並び）も読む
  static List<String?> _categoryValues(XmlElement c) {
    final vals = c.findElements('val').toList();
    if (vals.isNotEmpty) {
      return [
        for (final v in vals)
          if (v.getAttribute('type') != 'NULL') v.getAttribute('value'),
      ];
    }
    if (c.getAttribute('type') == 'NULL') return const [];
    final value = c.getAttribute('value');
    return value == null || value.isEmpty ? const [] : [value];
  }
}
