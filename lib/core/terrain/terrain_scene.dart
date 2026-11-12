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
import 'package:flutter/material.dart';
import 'package:geobase/geobase.dart' as geo;

import '../../models/qgis_symbol.dart';
import 'fill_pattern_painter.dart';
import 'terrain_lifted.dart';
import 'terrain_mesh.dart';
import 'web_mercator.dart';

/// 解決済みのフィーチャの見た目（1 スタイルグループぶん）
///
/// `MapStyleGroup`（16 進色で持つ）と同じ内容を Flutter の色で持つ。
/// 設定の解決規則（KMeta → SharedPreferences → 既定）は持ち込まない。
class TerrainFeatureStyle {
  const TerrainFeatureStyle({
    required this.lineColor,
    required this.lineWidth,
    required this.fillColor,
    required this.outlineColor,
    required this.outlineWidth,
    required this.pointColor,
    required this.pointSize,
    this.labelTextStyle,
    this.labelHaloColor,
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
    this.labelBgShape,
    this.labelBgColor,
    this.labelBgBorderColor,
    this.labelBgBorderWidth,
  });

  final Color lineColor;
  final double lineWidth;
  final Color fillColor;
  final Color outlineColor;
  final double outlineWidth;
  final Color pointColor;
  final double pointSize;
  final TextStyle? labelTextStyle;
  final Color? labelHaloColor;

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

  /// 縮尺依存表示（QGIS `<maplayer>` と同極性: `minScale` = 縮小側上限分母・大、`maxScale` = 拡大側下限分母・小）
  final double? minScale;
  final double? maxScale;

  final bool labelHaloEnabled;
  final double? labelHaloSize;
  final String? labelWrapChar;
  final String? labelBgShape;
  final Color? labelBgColor;
  final Color? labelBgBorderColor;
  final double? labelBgBorderWidth;

  static const fallback = TerrainFeatureStyle(
    lineColor: Color(0xFF1E88E5),
    lineWidth: 3,
    fillColor: Color(0x662E7D32),
    outlineColor: Color(0xFF2E7D32),
    outlineWidth: 2,
    pointColor: Color(0xFFD32F2F),
    pointSize: 6,
  );

  List<ResolvedLineStroke> get effectiveLineStrokes {
    if (nullSymbol) return const [];
    if (lineStrokes.isNotEmpty) return lineStrokes;
    if (lineColor.a > 0 && lineWidth > 0) {
      return [ResolvedLineStroke(color: lineColor, widthPx: lineWidth)];
    }
    return const [];
  }

  List<ResolvedFillLayer> get effectivePolygonFills {
    if (nullSymbol) return const [];
    if (polygonFills.isNotEmpty) return polygonFills;
    if (fillColor.a > 0) {
      return [ResolvedFillLayer.solid(color: fillColor)];
    }
    return const [];
  }

  List<ResolvedLineStroke> get effectivePolygonOutlineStrokes {
    if (nullSymbol) return const [];
    if (polygonOutlineStrokes.isNotEmpty) return polygonOutlineStrokes;
    if (outlineColor.a > 0 && outlineWidth > 0) {
      return [ResolvedLineStroke(color: outlineColor, widthPx: outlineWidth)];
    }
    return const [];
  }

  /// 指定された縮尺分母 [scaleDenom] で表示対象か
  bool isScaleVisible(double? scaleDenom) {
    if (scaleDenom == null || scaleDenom <= 0) return true;
    if (maxScale != null && maxScale! > 0 && scaleDenom < maxScale!) return false;
    if (minScale != null && minScale! > 0 && scaleDenom > minScale!) return false;
    return true;
  }

  /// 塗りだけ透明にした写し
  TerrainFeatureStyle withoutFill() => TerrainFeatureStyle(
        lineColor: lineColor,
        lineWidth: lineWidth,
        fillColor: const Color(0x00000000),
        outlineColor: outlineColor,
        outlineWidth: outlineWidth,
        pointColor: pointColor,
        pointSize: pointSize,
        labelTextStyle: labelTextStyle,
        labelHaloColor: labelHaloColor,
        lineStrokes: lineStrokes,
        polygonFills: const [],
        polygonOutlineStrokes: polygonOutlineStrokes,
        pointShape: pointShape,
        pointOutlineColor: pointOutlineColor,
        pointOutlineWidth: pointOutlineWidth,
        pointAngle: pointAngle,
        pointSvgContent: pointSvgContent,
        invertedPolygon: false,
        nullSymbol: nullSymbol,
        minScale: minScale,
        maxScale: maxScale,
        labelHaloEnabled: labelHaloEnabled,
        labelHaloSize: labelHaloSize,
        labelWrapChar: labelWrapChar,
        labelBgShape: labelBgShape,
        labelBgColor: labelBgColor,
        labelBgBorderColor: labelBgBorderColor,
        labelBgBorderWidth: labelBgBorderWidth,
      );

  /// `#RRGGBB` と不透明度から色を作る（MapStyleGroup の形）
  static Color fromHex(String hex, [double opacity = 1]) {
    final h = hex.replaceFirst('#', '');
    final v = int.parse(h.length == 6 ? 'FF$h' : h, radix: 16);
    return Color(v).withValues(alpha: opacity);
  }
}

/// DEM に持ち上げた点（ビルボード）
class TerrainPoint {
  const TerrainPoint({
    required this.x,
    required this.y,
    required this.color,
    required this.sizePx,
    this.shape = PointMarkerShape.circle,
    this.outlineColor = const Color(0xFFFFFFFF),
    this.outlineWidthPx = 1.5,
    this.angleDeg = 0.0,
    this.svgContent,
    this.headingDeg,
    this.icon,
  });

  /// 印の中に描く記号（写真のカメラなど）。あれば白地の丸に [color] の縁と記号で描く
  final IconData? icon;

  /// DEM 原点基準の Mercator m
  final double x;
  final double y;
  final Color color;
  final double sizePx;
  final PointMarkerShape shape;
  final Color outlineColor;
  final double outlineWidthPx;
  final double angleDeg;

  /// `SvgMarker` のパラメータ置換済み SVG XML（指定時は 3D ビルボードアトラスで描画）
  final String? svgContent;

  /// 端末の向き（度、北から時計回り）。現在位置の点だけ持ち、画面上に 60° の扇（2D と同じ）を描く
  final double? headingDeg;
}

/// 地形に載せるもの一式
class TerrainScene {
  const TerrainScene({
    required this.lines,
    required this.polygons,
    required this.outlines,
    required this.points,
    required this.labels,
  });

  final List<LiftedPolyline> lines;
  final List<LiftedPolygon> polygons;

  /// 面の縁（線として持ち上げる）
  final List<LiftedPolyline> outlines;
  final List<TerrainPoint> points;
  final List<TerrainLabel> labels;

  static const empty = TerrainScene(lines: [], polygons: [], outlines: [], points: [], labels: []);
}

/// GeoJSON（geobase の Feature）→ [TerrainScene]
///
/// 入力は既存の地図と同じ形: 経度緯度のジオメトリと、プロパティ `k-style`（スタイルグループのキー）・
/// `k-label`（ラベル文字列）。`FeatureGeoJsonCache` が作るものをそのまま受ける想定（seam ②）。
/// スタイルは解決済みの [TerrainFeatureStyle] をキーで引く。キーが無ければ [defaultStyle]。
class TerrainSceneBuilder {
  TerrainSceneBuilder({
    required this.mesh,
    required this.stylesByKey,
    this.defaultStyle = TerrainFeatureStyle.fallback,
    this.styleKeyProp = 'k-style',
    this.labelProp = 'k-label',
    this.labelTextStyle = const TextStyle(fontSize: 12, color: Colors.black),
    this.polygonClipCells = 1,
    this.scaleDenom,
  });

  /// 面を切り分ける格子の粗さ（DEM セルの倍数）。大きい面が多いなら 4 程度
  final int polygonClipCells;

  final TerrainMesh mesh;
  final Map<String, TerrainFeatureStyle> stylesByKey;
  final TerrainFeatureStyle defaultStyle;
  final String styleKeyProp;
  final String labelProp;
  final TextStyle labelTextStyle;

  /// 現在のタイルの代表縮尺分母（縮尺依存表示の判定用。null なら制限なし）
  final double? scaleDenom;

  /// [clipRect] を渡すと（DEM 原点基準）、その矩形の中だけを貼り付ける（タイル単位の貼り付け）。
  /// 線は矩形で切り、面は矩形で切ってから貼り、点とラベルは矩形の中のものだけ
  TerrainScene build({
    Iterable<geo.Feature<geo.Geometry>> lines = const [],
    Iterable<geo.Feature<geo.Geometry>> polygons = const [],
    Iterable<geo.Feature<geo.Point>> points = const [],
    Rect? clipRect,
    double? scaleDenom,
  }) {
    final effScale = scaleDenom ?? this.scaleDenom;
    final outLines = <LiftedPolyline>[];
    final outPolys = <LiftedPolygon>[];
    final outlines = <LiftedPolyline>[];
    final outPoints = <TerrainPoint>[];
    final labels = <TerrainLabel>[];
    final linePasses = <int>[];
    final outlinePasses = <int>[];
    var hasMultiPassLine = false;
    var hasMultiPassOutline = false;

    bool inside(Offset p) => clipRect == null || clipRect.contains(p);
    bool bboxHits(List<Offset> pts) {
      if (clipRect == null) return true;
      var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
      for (final p in pts) {
        if (p.dx < minX) minX = p.dx;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dy > maxY) maxY = p.dy;
      }
      // 幅や高さが 0 の bbox（水平な線など）でも当たるように区間で見る
      return maxX >= clipRect.left && minX <= clipRect.right && maxY >= clipRect.top && minY <= clipRect.bottom;
    }

    void label(Offset at, geo.Feature f, TerrainFeatureStyle fStyle, {double? markerGap}) {
      if (!inside(at)) return;
      final rawText = f.properties[labelProp];
      if (rawText is! String || rawText.isEmpty) return;
      final textStyle = fStyle.labelTextStyle ?? labelTextStyle;
      if ((textStyle.color?.a ?? 1.0) <= 0) return;
      final wrap = fStyle.labelWrapChar;
      final text = (wrap != null && wrap.isNotEmpty) ? rawText.replaceAll(wrap, '\n') : rawText;
      labels.add(TerrainLabel(
        x: at.dx,
        y: at.dy,
        text: text,
        style: textStyle,
        haloColor: fStyle.labelHaloColor,
        haloEnabled: fStyle.labelHaloEnabled,
        haloSizePx: fStyle.labelHaloSize,
        bgShape: fStyle.labelBgShape,
        bgColor: fStyle.labelBgColor,
        bgBorderColor: fStyle.labelBgBorderColor,
        bgBorderWidth: fStyle.labelBgBorderWidth,
        markerGap: markerGap,
      ));
    }

    final mPerPx = mesh.dem.cellSize * mesh.step * 0.5;

    for (final f in lines) {
      final style = _styleOf(f);
      if (!style.isScaleVisible(effScale)) continue;
      final strokes = style.effectiveLineStrokes;
      for (final chain in chainsOf(f.geometry)) {
        final pts = _toLocal(chain);
        if (pts.length < 2 || !bboxHits(pts)) continue;
        if (strokes.isNotEmpty) {
          final pieces = clipRect == null ? [pts] : clipPolylineToRect(pts, clipRect);
          for (final piece in pieces) {
            for (final stroke in strokes) {
              if (stroke.color.a <= 0 || stroke.widthPx <= 0) continue;
              // Mercator 座標系（Y 北向き）では右手側は +offset
              final shifted = stroke.offsetPx.abs() > 0.01
                  ? offsetPolyline2D(piece, stroke.offsetPx * mPerPx)
                  : piece;
              outLines.add(
                LiftedPolyline.lift(
                  shifted,
                  mesh,
                  color: stroke.color,
                  widthPx: stroke.widthPx,
                  dashVec4: stroke.gpuDashVec4,
                  dashArray: stroke.dashArray,
                ),
              );
              linePasses.add(stroke.pass);
              if (stroke.pass != 0) hasMultiPassLine = true;
            }
          }
        }
        label(_midpointAlong(pts), f, style);
      }
    }
    for (final f in polygons) {
      final style = _styleOf(f);
      if (!style.isScaleVisible(effScale)) continue;
      final fillLayers = style.effectivePolygonFills;
      final outStrokes = style.effectivePolygonOutlineStrokes;
      for (final rings in ringsOf(f.geometry)) {
        if (rings.isEmpty) continue;
        final exterior = _toLocal(rings.first);
        if (exterior.length < 3 || !bboxHits(exterior)) continue;
        // ⚠ 穴は塗りには反映しない（耳切りが穴なし）。縁だけ描く
        final fillRing = clipRect == null ? exterior : LiftedPolygon.clipToRect(exterior, clipRect);
        // 塗りが透明なら板を作らない（寄った段の塗りはテクスチャに描くので、ここは枠線だけになる）
        if (fillRing.length >= 3 && fillLayers.isNotEmpty && !style.invertedPolygon) {
          final repColor = fillLayers.first.color;
          if (repColor.a > 0) {
            outPolys.add(LiftedPolygon.lift(fillRing, mesh, color: repColor, clipCells: polygonClipCells));
          }
        }
        if (outStrokes.isNotEmpty) {
          for (final ring in rings) {
            final pts = _toLocal(ring);
            if (pts.length < 2) continue;
            if ((pts.first - pts.last).distance > 1e-6) pts.add(pts.first);
            final pieces = clipRect == null ? [pts] : clipPolylineToRect(pts, clipRect);
            for (final piece in pieces) {
              for (final stroke in outStrokes) {
                if (stroke.color.a <= 0 || stroke.widthPx <= 0) continue;
                outlines.add(
                  LiftedPolyline.lift(
                    piece,
                    mesh,
                    color: stroke.color,
                    widthPx: stroke.widthPx,
                    dashVec4: stroke.gpuDashVec4,
                    dashArray: stroke.dashArray,
                  ),
                );
                outlinePasses.add(stroke.pass);
                if (stroke.pass != 0) hasMultiPassOutline = true;
              }
            }
          }
        }
        var cx = 0.0;
        var cy = 0.0;
        for (final p in exterior) {
          cx += p.dx;
          cy += p.dy;
        }
        label(Offset(cx / exterior.length, cy / exterior.length), f, style);
      }
    }
    for (final f in points) {
      final style = _styleOf(f);
      if (!style.isScaleVisible(effScale)) continue;
      final g = f.geometry;
      if (g == null) continue;
      final p = _toLocalPosition(g.position);
      if (!inside(p)) continue;
      final hasFill = style.pointColor.a > 0;
      final hasOutline = style.pointOutlineWidth > 0 && style.pointOutlineColor.a > 0;
      final hasSvg = style.pointSvgContent != null;
      if (!style.nullSymbol && style.pointSize > 0 && (hasFill || hasOutline || hasSvg)) {
        outPoints.add(
          TerrainPoint(
            x: p.dx,
            y: p.dy,
            color: style.pointColor,
            sizePx: style.pointSize,
            shape: style.pointShape,
            outlineColor: style.pointOutlineColor,
            outlineWidthPx: style.pointOutlineWidth,
            angleDeg: style.pointAngle,
            svgContent: style.pointSvgContent,
          ),
        );
      }
      label(p, f, style, markerGap: style.nullSymbol ? null : style.pointSize + 2);
    }

    if (hasMultiPassLine) _sortByPass(outLines, linePasses);
    if (hasMultiPassOutline) _sortByPass(outlines, outlinePasses);

    return TerrainScene(lines: outLines, polygons: outPolys, outlines: outlines, points: outPoints, labels: labels);
  }

  /// シンボルレベルの pass 昇順（背面 → 前面）に安定ソートする（ケーシング交差点融合用）
  static void _sortByPass(List<LiftedPolyline> list, List<int> passes) {
    final idx = List<int>.generate(list.length, (i) => i)
      ..sort((a, b) {
        final c = passes[a].compareTo(passes[b]);
        return c != 0 ? c : a.compareTo(b);
      });
    final copy = [for (final i in idx) list[i]];
    list.setAll(0, copy);
  }

  /// 折れ線の長さの中点（ラベルの置き場）
  static Offset _midpointAlong(List<Offset> pts) {
    var total = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      total += (pts[i + 1] - pts[i]).distance;
    }
    var remain = total / 2;
    for (var i = 0; i + 1 < pts.length; i++) {
      final d = (pts[i + 1] - pts[i]).distance;
      if (remain <= d) {
        final t = d == 0 ? 0.0 : remain / d;
        return pts[i] + (pts[i + 1] - pts[i]) * t;
      }
      remain -= d;
    }
    return pts.last;
  }

  TerrainFeatureStyle _styleOf(geo.Feature f) {
    final key = f.properties[styleKeyProp];
    if (key is String) return stylesByKey[key] ?? defaultStyle;
    return defaultStyle;
  }

  /// 経度緯度 → DEM 原点基準の Mercator m
  Offset _toLocalPosition(geo.Position p) {
    final dem = mesh.dem;
    return Offset(WebMercator.xFromLon(p.x) - dem.originX, WebMercator.yFromLat(p.y) - dem.originY);
  }

  List<Offset> _toLocal(geo.PositionSeries series) => [for (final p in series.positions) _toLocalPosition(p)];

  /// 線の頂点列（LineString / MultiLineString）
  static Iterable<geo.PositionSeries> chainsOf(geo.Geometry? g) => switch (g) {
        geo.LineString() => [g.chain],
        geo.MultiLineString() => g.chains,
        _ => const [],
      };

  /// 面のリング（Polygon / MultiPolygon。各要素の先頭が外周）
  static Iterable<List<geo.PositionSeries>> ringsOf(geo.Geometry? g) => switch (g) {
        geo.Polygon() => [g.rings],
        geo.MultiPolygon() => g.ringArrays,
        _ => const [],
      };
}
