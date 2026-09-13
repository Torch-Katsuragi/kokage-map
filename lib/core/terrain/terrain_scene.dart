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

import 'terrain_mesh.dart';
import 'terrain_painter.dart';
import 'web_mercator.dart';

/// 解決済みのフィーチャの見た目（1 スタイルグループぶん）
///
/// `MapStyleGroup`（MapLibre 向けの 16 進色）と同じ内容を Flutter の色で持つ。
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
  });

  final Color lineColor;
  final double lineWidth;
  final Color fillColor;
  final Color outlineColor;
  final double outlineWidth;
  final Color pointColor;
  final double pointSize;

  static const fallback = TerrainFeatureStyle(
    lineColor: Color(0xFF1E88E5),
    lineWidth: 3,
    fillColor: Color(0x662E7D32),
    outlineColor: Color(0xFF2E7D32),
    outlineWidth: 2,
    pointColor: Color(0xFFD32F2F),
    pointSize: 6,
  );

  /// `#RRGGBB` と不透明度から色を作る（MapStyleGroup の形）
  static Color fromHex(String hex, [double opacity = 1]) {
    final h = hex.replaceFirst('#', '');
    final v = int.parse(h.length == 6 ? 'FF$h' : h, radix: 16);
    return Color(v).withValues(alpha: opacity);
  }
}

/// DEM に持ち上げた点（ビルボードの丸）
class TerrainPoint {
  const TerrainPoint({required this.x, required this.y, required this.color, required this.sizePx, this.headingDeg});

  /// DEM 原点基準の Mercator m
  final double x;
  final double y;
  final Color color;
  final double sizePx;

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
  });

  /// 面を切り分ける格子の粗さ（DEM セルの倍数）。大きい面が多いなら 4 程度
  final int polygonClipCells;

  final TerrainMesh mesh;
  final Map<String, TerrainFeatureStyle> stylesByKey;
  final TerrainFeatureStyle defaultStyle;
  final String styleKeyProp;
  final String labelProp;
  final TextStyle labelTextStyle;

  /// [clipRect] を渡すと（DEM 原点基準）、その矩形の中だけを貼り付ける（タイル単位の貼り付け）。
  /// 線は矩形で切り、面は矩形で切ってから貼り、点とラベルは矩形の中のものだけ
  TerrainScene build({
    Iterable<geo.Feature<geo.Geometry>> lines = const [],
    Iterable<geo.Feature<geo.Geometry>> polygons = const [],
    Iterable<geo.Feature<geo.Point>> points = const [],
    Rect? clipRect,
  }) {
    final outLines = <LiftedPolyline>[];
    final outPolys = <LiftedPolygon>[];
    final outlines = <LiftedPolyline>[];
    final outPoints = <TerrainPoint>[];
    final labels = <TerrainLabel>[];
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

    void label(Offset at, geo.Feature f) {
      if (!inside(at)) return;
      final text = f.properties[labelProp];
      if (text is! String || text.isEmpty) return;
      labels.add(TerrainLabel(x: at.dx, y: at.dy, text: text, style: labelTextStyle));
    }

    for (final f in lines) {
      final style = _styleOf(f);
      for (final chain in _chainsOf(f.geometry)) {
        final pts = _toLocal(chain);
        if (pts.length < 2 || !bboxHits(pts)) continue;
        final pieces = clipRect == null ? [pts] : clipPolylineToRect(pts, clipRect);
        for (final piece in pieces) {
          outLines.add(LiftedPolyline.lift(piece, mesh, color: style.lineColor, widthPx: style.lineWidth));
        }
        label(_midpointAlong(pts), f);
      }
    }
    for (final f in polygons) {
      final style = _styleOf(f);
      for (final rings in _ringsOf(f.geometry)) {
        if (rings.isEmpty) continue;
        final exterior = _toLocal(rings.first);
        if (exterior.length < 3 || !bboxHits(exterior)) continue;
        // ⚠ 穴は塗りには反映しない（耳切りが穴なし）。縁だけ描く
        final fillRing = clipRect == null ? exterior : LiftedPolygon.clipToRect(exterior, clipRect);
        if (fillRing.length >= 3) {
          outPolys.add(LiftedPolygon.lift(fillRing, mesh, color: style.fillColor, clipCells: polygonClipCells));
        }
        for (final ring in rings) {
          final pts = _toLocal(ring);
          if (pts.length < 2) continue;
          if ((pts.first - pts.last).distance > 1e-6) pts.add(pts.first);
          final pieces = clipRect == null ? [pts] : clipPolylineToRect(pts, clipRect);
          for (final piece in pieces) {
            outlines.add(LiftedPolyline.lift(piece, mesh, color: style.outlineColor, widthPx: style.outlineWidth));
          }
        }
        var cx = 0.0;
        var cy = 0.0;
        for (final p in exterior) {
          cx += p.dx;
          cy += p.dy;
        }
        label(Offset(cx / exterior.length, cy / exterior.length), f);
      }
    }
    for (final f in points) {
      final style = _styleOf(f);
      final g = f.geometry;
      if (g == null) continue;
      final p = _toLocalPosition(g.position);
      if (!inside(p)) continue;
      outPoints.add(TerrainPoint(x: p.dx, y: p.dy, color: style.pointColor, sizePx: style.pointSize));
      label(p, f);
    }
    return TerrainScene(lines: outLines, polygons: outPolys, outlines: outlines, points: outPoints, labels: labels);
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
  static Iterable<geo.PositionSeries> chainsOf(geo.Geometry? g) => _chainsOf(g);

  /// 面のリング（Polygon / MultiPolygon。各要素の先頭が外周）
  static Iterable<List<geo.PositionSeries>> ringsOf(geo.Geometry? g) => _ringsOf(g);

  static Iterable<geo.PositionSeries> _chainsOf(geo.Geometry? g) => switch (g) {
        geo.LineString() => [g.chain],
        geo.MultiLineString() => g.chains,
        _ => const [],
      };

  static Iterable<List<geo.PositionSeries>> _ringsOf(geo.Geometry? g) => switch (g) {
        geo.Polygon() => [g.rings],
        geo.MultiPolygon() => g.ringArrays,
        _ => const [],
      };
}
