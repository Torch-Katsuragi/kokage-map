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
// こかげマップ: シンボル表現プリミティブ（線種・縁取り・面ハッチング・点形状・マルチレイヤ構造）

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 線の種類（実線・破線・点線・鎖線・線なし）
enum LineDashPattern {
  solid('solid', 'solid'),
  dash('dash', 'dash'),
  dot('dot', 'dot'),
  dashDot('dash_dot', 'dash dot'),
  dashDotDot('dash_dot_dot', 'dash dot dot'),
  none('none', 'no');

  const LineDashPattern(this.id, this.qgisPenStyle);

  /// KMeta / SettingsStore 保存用の識別子
  final String id;

  /// QGIS `line_style` / `outline_style` の値
  final String qgisPenStyle;

  static LineDashPattern fromId(String? raw) {
    if (raw == null || raw.isEmpty) return LineDashPattern.solid;
    for (final v in values) {
      if (v.id == raw || v.qgisPenStyle == raw) return v;
    }
    return LineDashPattern.solid;
  }

  static LineDashPattern fromQgisPenStyle(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      null || '' || 'solid' => LineDashPattern.solid,
      'dash' => LineDashPattern.dash,
      'dot' => LineDashPattern.dot,
      'dash dot' || 'dash_dot' => LineDashPattern.dashDot,
      'dash dot dot' || 'dash_dot_dot' => LineDashPattern.dashDotDot,
      'no' || 'none' => LineDashPattern.none,
      _ => LineDashPattern.solid,
    };
  }

  /// 線幅 [widthPx] に対する論理 px の `[on, off, ...]` 配列（実線・線なしは null）
  List<double>? toDashArray(double widthPx) {
    final u = math.max(widthPx, 2.0);
    return switch (this) {
      LineDashPattern.solid || LineDashPattern.none => null,
      LineDashPattern.dash => [u * 4.0, u * 2.2],
      LineDashPattern.dot => [u * 1.1, u * 2.0],
      LineDashPattern.dashDot => [u * 4.0, u * 2.0, u * 1.1, u * 2.0],
      LineDashPattern.dashDotDot => [u * 4.0, u * 2.0, u * 1.1, u * 2.0, u * 1.1, u * 2.0],
    };
  }
}

/// 面の塗りパターン（ベタ塗り・ハッチング各種・ドット・塗りなし）
enum PolygonFillPattern {
  solid('solid', 'solid'),
  slash('slash', 'b_diagonal'),
  backslash('backslash', 'f_diagonal'),
  cross('cross', 'diagonal_x'),
  grid('grid', 'cross'),
  horizontal('horizontal', 'horizontal'),
  vertical('vertical', 'vertical'),
  dots('dots', 'dense5'),
  none('none', 'no');

  const PolygonFillPattern(this.id, this.qgisBrushStyle);

  final String id;
  final String qgisBrushStyle;

  bool get isHatchOrDots => this != PolygonFillPattern.solid && this != PolygonFillPattern.none;

  static PolygonFillPattern fromId(String? raw) {
    if (raw == null || raw.isEmpty) return PolygonFillPattern.solid;
    for (final v in values) {
      if (v.id == raw || v.qgisBrushStyle == raw) return v;
    }
    return fromQgisBrushStyle(raw);
  }

  static PolygonFillPattern fromQgisBrushStyle(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      null || '' || 'solid' => PolygonFillPattern.solid,
      'no' || 'none' => PolygonFillPattern.none,
      'b_diagonal' || 'slash' => PolygonFillPattern.slash,
      'f_diagonal' || 'backslash' => PolygonFillPattern.backslash,
      'diagonal_x' || 'cross_diag' => PolygonFillPattern.cross,
      'cross' || 'grid' => PolygonFillPattern.grid,
      'horizontal' => PolygonFillPattern.horizontal,
      'vertical' => PolygonFillPattern.vertical,
      'dense1' ||
      'dense2' ||
      'dense3' ||
      'dense4' ||
      'dense5' ||
      'dense6' ||
      'dense7' ||
      'dots' =>
        PolygonFillPattern.dots,
      _ => PolygonFillPattern.solid,
    };
  }
}

/// 点マーカーの形状（GPU シェーダ `shapeId` と 1:1 対応）
enum PointMarkerShape {
  circle('circle', 'circle', 0),
  square('square', 'square', 1),
  diamond('diamond', 'diamond', 2),
  triangle('triangle', 'triangle', 3),
  star('star', 'star', 4),
  cross('cross', 'cross', 5),
  cross2('cross2', 'cross2', 6);

  const PointMarkerShape(this.id, this.qgisName, this.gpuId);

  final String id;
  final String qgisName;
  final int gpuId;

  static PointMarkerShape fromId(String? raw) {
    if (raw == null || raw.isEmpty) return PointMarkerShape.circle;
    for (final v in values) {
      if (v.id == raw) return v;
    }
    return fromQgisName(raw);
  }

  static PointMarkerShape fromQgisName(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      null || '' || 'circle' || 'semi_circle' || 'third_circle' || 'quarter_circle' => PointMarkerShape.circle,
      'square' || 'rectangle' || 'square_with_corners' || 'pentagon' || 'hexagon' || 'octagon' =>
        PointMarkerShape.square,
      'diamond' => PointMarkerShape.diamond,
      'triangle' || 'equilateral_triangle' || 'arrowhead' || 'filled_arrowhead' => PointMarkerShape.triangle,
      'star' || 'regular_star' || 'asterisk_fill' => PointMarkerShape.star,
      'cross' || 'cross_fill' || 'line' => PointMarkerShape.cross,
      'cross2' || 'x' => PointMarkerShape.cross2,
      _ => PointMarkerShape.circle,
    };
  }
}

/// 解決済みの線ストローク 1 層分（背面 pass 0 → 前面 pass N の順に描画）
@immutable
class ResolvedLineStroke {
  const ResolvedLineStroke({
    required this.color,
    required this.widthPx,
    this.dashArray,
    this.offsetPx = 0.0,
    this.pass = 0,
    this.capRound = true,
  });

  final Color color;
  final double widthPx;

  /// `[on, off, ...]`（論理 px）。null または空なら実線
  final List<double>? dashArray;

  /// 進行方向に対する左右平行オフセット（論理 px、正で右側）
  final double offsetPx;

  /// シンボルレベル（小さい pass ほど背面で全地物を先に描く）
  final int pass;

  /// 端部を丸めるか（破線では false の方が切れ目が明瞭）
  final bool capRound;

  bool get isDashed => dashArray != null && dashArray!.length >= 2;

  /// GPU 頂点属性 `vec4 dash` 用のエンコード。
  /// - `(0, 0, 0, 0)`: 実線
  /// - `(on1, off1, 0, 0)`: 1 ペア破線 / 点線
  /// - `(on1, off1, on2, off2)` (`on2 > 0`): 2 ペア（一点鎖線など）
  /// - `(on1, off1, -on2, off2)` (`on2 < 0`): 二点鎖線（`[on1, off1, on2, off2, on2, off2]`）
  (double, double, double, double) get gpuDashVec4 {
    final d = dashArray;
    if (d == null || d.length < 2) return (0.0, 0.0, 0.0, 0.0);
    final on1 = math.max(0.5, d[0]);
    final off1 = math.max(0.5, d[1]);
    if (d.length >= 6) {
      final on2 = math.max(0.5, d[2]);
      final off2 = math.max(0.5, d[3]);
      return (on1, off1, -on2, off2);
    }
    if (d.length >= 4) {
      return (on1, off1, math.max(0.5, d[2]), math.max(0.5, d[3]));
    }
    return (on1, off1, 0.0, 0.0);
  }

  ResolvedLineStroke withOpacityFactor(double factor) {
    if (factor >= 0.999) return this;
    return ResolvedLineStroke(
      color: color.withValues(alpha: (color.a * factor).clamp(0.0, 1.0)),
      widthPx: widthPx,
      dashArray: dashArray,
      offsetPx: offsetPx,
      pass: pass,
      capRound: capRound,
    );
  }

  Map<String, dynamic> toJson() => {
        'color': _colorToHex(color),
        'widthPx': widthPx,
        if (dashArray != null && dashArray!.isNotEmpty) 'dashArray': dashArray,
        if (offsetPx != 0) 'offsetPx': offsetPx,
        if (pass != 0) 'pass': pass,
        if (!capRound) 'capRound': false,
      };

  factory ResolvedLineStroke.fromJson(Map<String, dynamic> json) => ResolvedLineStroke(
        color: _parseColor(json['color']) ?? const Color(0xFF000000),
        widthPx: (json['widthPx'] as num?)?.toDouble() ?? 1.0,
        dashArray: (json['dashArray'] as List?)?.whereType<num>().map((e) => e.toDouble()).toList(),
        offsetPx: (json['offsetPx'] as num?)?.toDouble() ?? 0.0,
        pass: (json['pass'] as num?)?.toInt() ?? 0,
        capRound: json['capRound'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedLineStroke &&
          color == other.color &&
          widthPx == other.widthPx &&
          listEquals(dashArray, other.dashArray) &&
          offsetPx == other.offsetPx &&
          pass == other.pass &&
          capRound == other.capRound;

  @override
  int get hashCode => Object.hash(
        color,
        widthPx,
        dashArray == null ? null : Object.hashAll(dashArray!),
        offsetPx,
        pass,
        capRound,
      );
}

/// 面の塗りレイヤの種別
enum FillLayerKind { solid, linePattern, pointPattern }

/// 解決済みの面塗り 1 層分（背面 → 前面の順に重ね塗りする）
@immutable
class ResolvedFillLayer {
  const ResolvedFillLayer.solid({
    required this.color,
  })  : kind = FillLayerKind.solid,
        angleDeg = 0.0,
        spacingPx = 0.0,
        lineWidthPx = 0.0,
        offsetPx = 0.0,
        dashArray = null,
        dxPx = 0.0,
        dyPx = 0.0,
        pointRadiusPx = 0.0,
        pointShape = PointMarkerShape.circle,
        pointSvgContent = null;

  const ResolvedFillLayer.linePattern({
    required this.color,
    required this.angleDeg,
    required this.spacingPx,
    this.lineWidthPx = 1.5,
    this.offsetPx = 0.0,
    this.dashArray,
  })  : kind = FillLayerKind.linePattern,
        dxPx = 0.0,
        dyPx = 0.0,
        pointRadiusPx = 0.0,
        pointShape = PointMarkerShape.circle,
        pointSvgContent = null;

  const ResolvedFillLayer.pointPattern({
    required this.color,
    required this.dxPx,
    required this.dyPx,
    this.pointRadiusPx = 1.5,
    this.pointShape = PointMarkerShape.circle,
    this.pointSvgContent,
  })  : kind = FillLayerKind.pointPattern,
        angleDeg = 0.0,
        spacingPx = 0.0,
        lineWidthPx = 0.0,
        offsetPx = 0.0,
        dashArray = null;

  final FillLayerKind kind;
  final Color color;

  // linePattern 用
  final double angleDeg;
  final double spacingPx;
  final double lineWidthPx;
  final double offsetPx;
  final List<double>? dashArray;

  // pointPattern 用
  final double dxPx;
  final double dyPx;
  final double pointRadiusPx;
  final PointMarkerShape pointShape;
  final String? pointSvgContent;

  ResolvedFillLayer withOpacityFactor(double factor) {
    if (factor >= 0.999) return this;
    final c = color.withValues(alpha: (color.a * factor).clamp(0.0, 1.0));
    return switch (kind) {
      FillLayerKind.solid => ResolvedFillLayer.solid(color: c),
      FillLayerKind.linePattern => ResolvedFillLayer.linePattern(
          color: c,
          angleDeg: angleDeg,
          spacingPx: spacingPx,
          lineWidthPx: lineWidthPx,
          offsetPx: offsetPx,
          dashArray: dashArray,
        ),
      FillLayerKind.pointPattern => ResolvedFillLayer.pointPattern(
          color: c,
          dxPx: dxPx,
          dyPx: dyPx,
          pointRadiusPx: pointRadiusPx,
          pointShape: pointShape,
          pointSvgContent: pointSvgContent,
        ),
    };
  }

  Map<String, dynamic> toJson() => switch (kind) {
        FillLayerKind.solid => {
            'kind': 'solid',
            'color': _colorToHex(color),
          },
        FillLayerKind.linePattern => {
            'kind': 'linePattern',
            'color': _colorToHex(color),
            'angleDeg': angleDeg,
            'spacingPx': spacingPx,
            'lineWidthPx': lineWidthPx,
            if (offsetPx != 0) 'offsetPx': offsetPx,
            if (dashArray != null && dashArray!.isNotEmpty) 'dashArray': dashArray,
          },
        FillLayerKind.pointPattern => {
            'kind': 'pointPattern',
            'color': _colorToHex(color),
            'dxPx': dxPx,
            'dyPx': dyPx,
            'pointRadiusPx': pointRadiusPx,
            if (pointShape != PointMarkerShape.circle) 'pointShape': pointShape.id,
            if (pointSvgContent != null) 'pointSvgContent': pointSvgContent,
          },
      };

  factory ResolvedFillLayer.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String? ?? 'solid';
    final color = _parseColor(json['color']) ?? const Color(0xFF000000);
    return switch (kind) {
      'linePattern' => ResolvedFillLayer.linePattern(
          color: color,
          angleDeg: (json['angleDeg'] as num?)?.toDouble() ?? 45.0,
          spacingPx: (json['spacingPx'] as num?)?.toDouble() ?? 8.0,
          lineWidthPx: (json['lineWidthPx'] as num?)?.toDouble() ?? 1.5,
          offsetPx: (json['offsetPx'] as num?)?.toDouble() ?? 0.0,
          dashArray: (json['dashArray'] as List?)?.whereType<num>().map((e) => e.toDouble()).toList(),
        ),
      'pointPattern' => ResolvedFillLayer.pointPattern(
          color: color,
          dxPx: (json['dxPx'] as num?)?.toDouble() ?? 8.0,
          dyPx: (json['dyPx'] as num?)?.toDouble() ?? 8.0,
          pointRadiusPx: (json['pointRadiusPx'] as num?)?.toDouble() ?? 1.5,
          pointShape: PointMarkerShape.fromId(json['pointShape'] as String?),
          pointSvgContent: json['pointSvgContent'] as String?,
        ),
      _ => ResolvedFillLayer.solid(color: color),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedFillLayer &&
          kind == other.kind &&
          color == other.color &&
          angleDeg == other.angleDeg &&
          spacingPx == other.spacingPx &&
          lineWidthPx == other.lineWidthPx &&
          offsetPx == other.offsetPx &&
          listEquals(dashArray, other.dashArray) &&
          dxPx == other.dxPx &&
          dyPx == other.dyPx &&
          pointRadiusPx == other.pointRadiusPx &&
          pointShape == other.pointShape &&
          pointSvgContent == other.pointSvgContent;

  @override
  int get hashCode => Object.hash(
        kind,
        color,
        angleDeg,
        spacingPx,
        lineWidthPx,
        offsetPx,
        dashArray == null ? null : Object.hashAll(dashArray!),
        dxPx,
        dyPx,
        pointRadiusPx,
        pointShape,
        pointSvgContent,
      );
}

/// 解決済みの点マーカー 1 層分
@immutable
class ResolvedPointLayer {
  const ResolvedPointLayer({
    required this.color,
    required this.radiusPx,
    this.shape = PointMarkerShape.circle,
    this.outlineColor = const Color(0xFFFFFFFF),
    this.outlineWidthPx = 1.5,
    this.angleDeg = 0.0,
    this.svgContent,
    this.svgPath,
  });

  final Color color;
  final double radiusPx;
  final PointMarkerShape shape;
  final Color outlineColor;
  final double outlineWidthPx;
  final double angleDeg;

  /// QGIS `param(...)` 置換済みの描画用 SVG XML（`SvgMarker` のとき非 null）
  final String? svgContent;

  /// 元の QGIS SVG 指定（`gpsicons/tree.svg`、`./icons/dam.svg`、`base64:...` 等）
  final String? svgPath;

  Map<String, dynamic> toJson() => {
        'color': _colorToHex(color),
        'radiusPx': radiusPx,
        if (shape != PointMarkerShape.circle) 'shape': shape.id,
        'outlineColor': _colorToHex(outlineColor),
        'outlineWidthPx': outlineWidthPx,
        if (angleDeg != 0) 'angleDeg': angleDeg,
        if (svgContent != null) 'svgContent': svgContent,
        if (svgPath != null) 'svgPath': svgPath,
      };

  factory ResolvedPointLayer.fromJson(Map<String, dynamic> json) => ResolvedPointLayer(
        color: _parseColor(json['color']) ?? const Color(0xFFF44336),
        radiusPx: (json['radiusPx'] as num?)?.toDouble() ?? 4.0,
        shape: PointMarkerShape.fromId(json['shape'] as String?),
        outlineColor: _parseColor(json['outlineColor']) ?? const Color(0xFFFFFFFF),
        outlineWidthPx: (json['outlineWidthPx'] as num?)?.toDouble() ?? 1.5,
        angleDeg: (json['angleDeg'] as num?)?.toDouble() ?? 0.0,
        svgContent: json['svgContent'] as String?,
        svgPath: json['svgPath'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedPointLayer &&
          color == other.color &&
          radiusPx == other.radiusPx &&
          shape == other.shape &&
          outlineColor == other.outlineColor &&
          outlineWidthPx == other.outlineWidthPx &&
          angleDeg == other.angleDeg &&
          svgContent == other.svgContent &&
          svgPath == other.svgPath;

  @override
  int get hashCode => Object.hash(
        color,
        radiusPx,
        shape,
        outlineColor,
        outlineWidthPx,
        angleDeg,
        svgContent,
        svgPath,
      );
}

/// QGIS 由来のマルチレイヤシンボル構造や特殊レンダラ属性（反転ポリゴン・nullSymbol）の保持コンテナ
@immutable
class ResolvedSymbolLayers {
  const ResolvedSymbolLayers({
    this.strokes = const [],
    this.fills = const [],
    this.outlineStrokes = const [],
    this.markers = const [],
    this.invertedPolygon = false,
    this.nullSymbol = false,
  });

  /// 線シンボルのストローク群（背面 → 前面）
  final List<ResolvedLineStroke> strokes;

  /// 面シンボルの塗りレイヤ群（背面 → 前面）
  final List<ResolvedFillLayer> fills;

  /// 面シンボルの輪郭ストローク群（背面 → 前面）
  final List<ResolvedLineStroke> outlineStrokes;

  /// 点シンボルのマーカーレイヤ群（背面 → 前面）
  final List<ResolvedPointLayer> markers;

  /// `invertedPolygonRenderer`（ポリゴン外側をマスク塗りする）
  final bool invertedPolygon;

  /// `nullSymbol`（ジオメトリを描かずラベルのみ描画する）
  final bool nullSymbol;

  bool get isEmpty =>
      strokes.isEmpty &&
      fills.isEmpty &&
      outlineStrokes.isEmpty &&
      markers.isEmpty &&
      !invertedPolygon &&
      !nullSymbol;

  ResolvedSymbolLayers copyWith({
    List<ResolvedLineStroke>? strokes,
    List<ResolvedFillLayer>? fills,
    List<ResolvedLineStroke>? outlineStrokes,
    List<ResolvedPointLayer>? markers,
    bool? invertedPolygon,
    bool? nullSymbol,
  }) =>
      ResolvedSymbolLayers(
        strokes: strokes ?? this.strokes,
        fills: fills ?? this.fills,
        outlineStrokes: outlineStrokes ?? this.outlineStrokes,
        markers: markers ?? this.markers,
        invertedPolygon: invertedPolygon ?? this.invertedPolygon,
        nullSymbol: nullSymbol ?? this.nullSymbol,
      );

  Map<String, dynamic> toJson() => {
        if (strokes.isNotEmpty) 'strokes': [for (final s in strokes) s.toJson()],
        if (fills.isNotEmpty) 'fills': [for (final f in fills) f.toJson()],
        if (outlineStrokes.isNotEmpty) 'outlineStrokes': [for (final s in outlineStrokes) s.toJson()],
        if (markers.isNotEmpty) 'markers': [for (final m in markers) m.toJson()],
        if (invertedPolygon) 'invertedPolygon': true,
        if (nullSymbol) 'nullSymbol': true,
      };

  static ResolvedSymbolLayers? tryFromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final res = ResolvedSymbolLayers(
      strokes: [
        for (final e in (raw['strokes'] as List? ?? const []))
          if (e is Map<String, dynamic>) ResolvedLineStroke.fromJson(e),
      ],
      fills: [
        for (final e in (raw['fills'] as List? ?? const []))
          if (e is Map<String, dynamic>) ResolvedFillLayer.fromJson(e),
      ],
      outlineStrokes: [
        for (final e in (raw['outlineStrokes'] as List? ?? const []))
          if (e is Map<String, dynamic>) ResolvedLineStroke.fromJson(e),
      ],
      markers: [
        for (final e in (raw['markers'] as List? ?? const []))
          if (e is Map<String, dynamic>) ResolvedPointLayer.fromJson(e),
      ],
      invertedPolygon: raw['invertedPolygon'] as bool? ?? false,
      nullSymbol: raw['nullSymbol'] as bool? ?? false,
    );
    return res.isEmpty ? null : res;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedSymbolLayers &&
          listEquals(strokes, other.strokes) &&
          listEquals(fills, other.fills) &&
          listEquals(outlineStrokes, other.outlineStrokes) &&
          listEquals(markers, other.markers) &&
          invertedPolygon == other.invertedPolygon &&
          nullSymbol == other.nullSymbol;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(strokes),
        Object.hashAll(fills),
        Object.hashAll(outlineStrokes),
        Object.hashAll(markers),
        invertedPolygon,
        nullSymbol,
      );
}

/// UI 設定項目（線色・太さ・破線・縁取り）または [symbolLayers] から実効ストローク列を組み立てる
List<ResolvedLineStroke> buildEffectiveLineStrokes({
  required Color lineColor,
  required double lineWidth,
  LineDashPattern dash = LineDashPattern.solid,
  bool casingEnabled = false,
  Color casingColor = const Color(0xFFFFFFFF),
  double casingWidth = 2.0,
  ResolvedSymbolLayers? symbolLayers,
  double opacityFactor = 1.0,
}) {
  if (symbolLayers != null && symbolLayers.nullSymbol) return const [];
  if (symbolLayers != null && symbolLayers.strokes.isNotEmpty) {
    if (opacityFactor >= 0.999) return symbolLayers.strokes;
    return [for (final s in symbolLayers.strokes) s.withOpacityFactor(opacityFactor)];
  }
  if (dash == LineDashPattern.none || lineWidth <= 0 || lineColor.a <= 0) {
    return const [];
  }
  final out = <ResolvedLineStroke>[];
  if (casingEnabled && casingWidth > 0) {
    final cAlpha = (casingColor.a * lineColor.a).clamp(0.0, 1.0);
    out.add(
      ResolvedLineStroke(
        color: casingColor.withValues(alpha: cAlpha),
        widthPx: lineWidth + casingWidth * 2.0,
        pass: 0,
        capRound: true,
      ),
    );
  }
  final dashArr = dash.toDashArray(lineWidth);
  out.add(
    ResolvedLineStroke(
      color: lineColor,
      widthPx: lineWidth,
      dashArray: dashArr,
      pass: casingEnabled && casingWidth > 0 ? 1 : 0,
      capRound: dashArr == null,
    ),
  );
  return out;
}

/// UI 設定項目（面塗り色・パターン・間隔・太さ）または [symbolLayers] から実効塗りレイヤ列を組み立てる
List<ResolvedFillLayer> buildEffectivePolygonFills({
  required Color fillColor,
  PolygonFillPattern pattern = PolygonFillPattern.solid,
  double spacingPx = 8.0,
  double lineWidthPx = 1.5,
  ResolvedSymbolLayers? symbolLayers,
  double opacityFactor = 1.0,
}) {
  if (symbolLayers != null && symbolLayers.nullSymbol) return const [];
  if (symbolLayers != null && symbolLayers.fills.isNotEmpty) {
    if (opacityFactor >= 0.999) return symbolLayers.fills;
    return [for (final f in symbolLayers.fills) f.withOpacityFactor(opacityFactor)];
  }
  if (pattern == PolygonFillPattern.none || fillColor.a <= 0) {
    return const [];
  }
  final sp = math.max(3.0, spacingPx);
  final lw = math.max(0.8, lineWidthPx);
  return switch (pattern) {
    PolygonFillPattern.none => const [],
    PolygonFillPattern.solid => [ResolvedFillLayer.solid(color: fillColor)],
    PolygonFillPattern.slash => [
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 45, spacingPx: sp, lineWidthPx: lw),
      ],
    PolygonFillPattern.backslash => [
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 135, spacingPx: sp, lineWidthPx: lw),
      ],
    PolygonFillPattern.cross => [
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 45, spacingPx: sp, lineWidthPx: lw),
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 135, spacingPx: sp, lineWidthPx: lw),
      ],
    PolygonFillPattern.grid => [
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 0, spacingPx: sp, lineWidthPx: lw),
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 90, spacingPx: sp, lineWidthPx: lw),
      ],
    PolygonFillPattern.horizontal => [
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 0, spacingPx: sp, lineWidthPx: lw),
      ],
    PolygonFillPattern.vertical => [
        ResolvedFillLayer.linePattern(color: fillColor, angleDeg: 90, spacingPx: sp, lineWidthPx: lw),
      ],
    PolygonFillPattern.dots => [
        ResolvedFillLayer.pointPattern(
          color: fillColor,
          dxPx: sp,
          dyPx: sp,
          pointRadiusPx: math.max(1.2, lw * 0.85),
        ),
      ],
  };
}

Color? _parseColor(Object? value) {
  if (value is int) return Color(value);
  if (value is String) {
    final hex = value.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
  }
  return null;
}

String _colorToHex(Color color) => '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
