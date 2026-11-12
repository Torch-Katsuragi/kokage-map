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
// こかげマップ: 面ハッチング・ドットパターン・破線パス・点マーカー形状の共通描画ヘルパー
//
// 地形テクスチャ焼き込み・Canvas フォールバック・スタイル設定プレビュー・QGIS 凡例スウォッチで共用する。

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/qgis_symbol.dart';
import 'svg_marker_atlas.dart';

/// ハッチング・ドットパターンの `ui.ImageShader` キャッシュ（LRU 256 件）
class FillPatternCache {
  FillPatternCache._();

  static final FillPatternCache instance = FillPatternCache._();

  static const int _maxEntries = 256;
  final LinkedHashMap<ResolvedFillLayer, ui.ImageShader> _shaders =
      LinkedHashMap<ResolvedFillLayer, ui.ImageShader>();

  ui.ImageShader? shaderFor(ResolvedFillLayer layer) {
    if (layer.kind == FillLayerKind.solid) return null;
    final hit = _shaders.remove(layer);
    if (hit != null) {
      _shaders[layer] = hit;
      return hit;
    }
    if (layer.kind == FillLayerKind.pointPattern && layer.pointSvgContent != null) {
      final svgSlot = SvgMarkerCache.instance.slotFor(layer.pointSvgContent!);
      if (svgSlot == null) {
        // 非同期ラスタライズ完了前はドットシェーダを仮返しし、キャッシュには入れない
        return _buildPointPatternShader(layer);
      }
      final createdSvg = _buildPointPatternShader(layer, svgSlot: svgSlot);
      if (createdSvg != null) {
        if (_shaders.length >= _maxEntries) {
          _shaders.remove(_shaders.keys.first);
        }
        _shaders[layer] = createdSvg;
      }
      return createdSvg;
    }
    final created = switch (layer.kind) {
      FillLayerKind.solid => null,
      FillLayerKind.linePattern => _buildLinePatternShader(layer),
      FillLayerKind.pointPattern => _buildPointPatternShader(layer),
    };
    if (created != null) {
      if (_shaders.length >= _maxEntries) {
        _shaders.remove(_shaders.keys.first);
      }
      _shaders[layer] = created;
    }
    return created;
  }

  static ui.ImageShader? _buildLinePatternShader(ResolvedFillLayer layer) {
    try {
      final spacing = layer.spacingPx.clamp(3.0, 128.0);
      final tileH = math.max(3, spacing.round());
      final sy = spacing / tileH;

      final dash = layer.dashArray;
      double dashPeriod = 0;
      if (dash != null && dash.length >= 2) {
        for (final v in dash) {
          if (v > 0) dashPeriod += v;
        }
      }
      final hasDash = dashPeriod >= 2.0;
      final tileW = hasDash ? dashPeriod.round().clamp(4, 256) : 16;
      final sx = hasDash ? dashPeriod / tileW : 1.0;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final lw = (layer.lineWidthPx / sy).clamp(0.6, tileH.toDouble());
      final paint = ui.Paint()
        ..color = layer.color
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = lw
        ..strokeCap = ui.StrokeCap.butt
        ..isAntiAlias = true;

      var yCenter = (tileH * 0.5 + layer.offsetPx / sy) % tileH;
      if (yCenter < 0) yCenter += tileH;

      void drawHorizontalAt(double y) {
        if (!hasDash) {
          canvas.drawLine(ui.Offset(-1, y), ui.Offset(tileW + 1.0, y), paint);
          return;
        }
        final scaledDash = [for (final v in dash!) v / sx];
        final p = ui.Path()
          ..moveTo(0, y)
          ..lineTo(tileW.toDouble(), y);
        canvas.drawPath(dashPath(p, scaledDash), paint);
      }

      drawHorizontalAt(yCenter);
      if (yCenter - lw < 0) drawHorizontalAt(yCenter + tileH);
      if (yCenter + lw > tileH) drawHorizontalAt(yCenter - tileH);

      final picture = recorder.endRecording();
      final img = picture.toImageSync(tileW, tileH);
      picture.dispose();

      // QGIS の angle は水平右向きから反時計回り（45° = 右上がり `/`）。
      // 画面座標は Y 下向きなので -angleDeg 回転させる。
      final rad = -layer.angleDeg * math.pi / 180.0;
      final c = math.cos(rad);
      final s = math.sin(rad);
      final matrix = Float64List.fromList([
        sx * c, sx * s, 0, 0,
        -sy * s, sy * c, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
      ]);
      return ui.ImageShader(
        img,
        ui.TileMode.repeated,
        ui.TileMode.repeated,
        matrix,
        filterQuality: ui.FilterQuality.low,
      );
    } catch (_) {
      return null;
    }
  }

  static ui.ImageShader? _buildPointPatternShader(
    ResolvedFillLayer layer, {
    SvgAtlasSlot? svgSlot,
  }) {
    try {
      final dx = layer.dxPx.clamp(3.0, 128.0);
      final dy = layer.dyPx.clamp(3.0, 128.0);
      final tileW = math.max(3, dx.round());
      final tileH = math.max(3, dy.round());
      final sx = dx / tileW;
      final sy = dy / tileH;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final r = (layer.pointRadiusPx / math.min(sx, sy)).clamp(0.6, math.min(tileW, tileH) * 0.48);
      if (svgSlot != null) {
        final scale = (r * 2.0) / svgSlot.srcRect.width;
        canvas.drawAtlas(
          svgSlot.atlas,
          [
            ui.RSTransform.fromComponents(
              rotation: 0,
              scale: scale,
              anchorX: svgSlot.srcRect.width * 0.5,
              anchorY: svgSlot.srcRect.height * 0.5,
              translateX: tileW * 0.5,
              translateY: tileH * 0.5,
            ),
          ],
          [svgSlot.srcRect],
          null,
          null,
          null,
          ui.Paint()
            ..filterQuality = ui.FilterQuality.low
            ..color = Color.fromRGBO(255, 255, 255, layer.color.a.clamp(0.0, 1.0)),
        );
      } else {
        drawPointMarkerShape(
          canvas,
          ui.Offset(tileW * 0.5, tileH * 0.5),
          r,
          shape: layer.pointShape,
          fillColor: layer.color,
          outlineColor: const Color(0x00000000),
          outlineWidth: 0,
        );
      }
      final picture = recorder.endRecording();
      final img = picture.toImageSync(tileW, tileH);
      picture.dispose();

      final matrix = Float64List.fromList([
        sx, 0, 0, 0,
        0, sy, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
      ]);
      return ui.ImageShader(
        img,
        ui.TileMode.repeated,
        ui.TileMode.repeated,
        matrix,
        filterQuality: ui.FilterQuality.low,
      );
    } catch (_) {
      return null;
    }
  }
}

/// ポリゴンの塗りレイヤ列（ベタ塗り・ハッチング・ドット・重ね塗り・反転ポリゴン）を [canvas] に描く
void drawPolygonFillLayers(
  ui.Canvas canvas,
  ui.Path polygonPath,
  List<ResolvedFillLayer> fills, {
  bool inverted = false,
  ui.Rect? outerBounds,
}) {
  if (fills.isEmpty) return;
  final targetPath = inverted && outerBounds != null
      ? (ui.Path()
        ..fillType = ui.PathFillType.evenOdd
        ..addRect(outerBounds.inflate(4.0))
        ..addPath(polygonPath, ui.Offset.zero))
      : polygonPath;

  final paint = ui.Paint()..style = ui.PaintingStyle.fill;
  for (final layer in fills) {
    if (layer.color.a <= 0) continue;
    if (layer.kind == FillLayerKind.solid) {
      paint
        ..shader = null
        ..color = layer.color;
      canvas.drawPath(targetPath, paint);
      continue;
    }
    final shader = FillPatternCache.instance.shaderFor(layer);
    if (shader != null) {
      paint
        ..color = const Color(0xFFFFFFFF)
        ..shader = shader;
      canvas.drawPath(targetPath, paint);
    } else {
      // 万一シェーダ生成に失敗した環境では薄いベタ塗りにフォールバック
      paint
        ..shader = null
        ..color = layer.color.withValues(alpha: (layer.color.a * 0.35).clamp(0.0, 1.0));
      canvas.drawPath(targetPath, paint);
    }
  }
}

/// 線ストローク列（ケーシング・破線・マルチレイヤ）を 1 本の [path] に対して順に描く
void drawLineStrokeLayers(
  ui.Canvas canvas,
  ui.Path path,
  List<ResolvedLineStroke> strokes, {
  double minWidth = 1.0,
}) {
  if (strokes.isEmpty) return;
  final paint = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeJoin = ui.StrokeJoin.round;
  for (final s in strokes) {
    if (s.color.a <= 0 || s.widthPx <= 0) continue;
    paint
      ..color = s.color
      ..strokeWidth = math.max(minWidth, s.widthPx)
      ..strokeCap = s.capRound ? ui.StrokeCap.round : ui.StrokeCap.butt;
    final drawTarget = s.isDashed ? dashPath(path, s.dashArray!) : path;
    canvas.drawPath(drawTarget, paint);
  }
}

/// [source] を `[on, off, ...]` の周期で切り分けた破線 [ui.Path] を返す
ui.Path dashPath(ui.Path source, List<double> dashArray) {
  final pattern = [for (final v in dashArray) if (v > 0) math.max(0.5, v)];
  if (pattern.length < 2) return source;
  final out = ui.Path();
  for (final metric in source.computeMetrics()) {
    final total = metric.length;
    if (total <= 0) continue;
    var dist = 0.0;
    var idx = 0;
    var draw = true;
    var guard = 0;
    while (dist < total && guard++ < 100000) {
      final step = pattern[idx % pattern.length];
      final next = math.min(dist + step, total);
      if (draw && next > dist) {
        out.addPath(metric.extractPath(dist, next), ui.Offset.zero);
      }
      dist = next;
      idx++;
      draw = !draw;
    }
  }
  return out;
}

/// 2D 折れ線を進行方向右側へ [offset] だけ平行移動した頂点列を返す
List<ui.Offset> offsetPolyline2D(List<ui.Offset> pts, double offset) {
  if (offset.abs() < 1e-6 || pts.length < 2) return pts;
  final n = pts.length;
  final normals = List<ui.Offset>.filled(n - 1, ui.Offset.zero);
  for (var i = 0; i < n - 1; i++) {
    final d = pts[i + 1] - pts[i];
    final len = d.distance;
    if (len > 1e-9) {
      // 画面座標（Y下向き）または Mercator（Y北向き）での右手側法線
      normals[i] = ui.Offset(d.dy / len, -d.dx / len);
    }
  }
  final out = <ui.Offset>[];
  for (var i = 0; i < n; i++) {
    ui.Offset dir;
    if (i == 0) {
      dir = normals[0];
    } else if (i == n - 1) {
      dir = normals[n - 2];
    } else {
      final sum = normals[i - 1] + normals[i];
      final len = sum.distance;
      if (len > 1e-6) {
        // マイター長が暴れないよう 2 倍で頭打ち
        final dot = normals[i - 1].dx * (sum.dx / len) + normals[i - 1].dy * (sum.dy / len);
        final scale = dot > 0.5 ? 1.0 / dot : 2.0;
        dir = (sum / len) * scale;
      } else {
        dir = normals[i];
      }
    }
    out.add(pts[i] + dir * offset);
  }
  return out;
}

/// `SvgMarker` スプライト（準備完了時）または 7 形状マーカーを [canvas] に描く
void drawPointOrSvgMarker(
  ui.Canvas canvas,
  ui.Offset center,
  double radius, {
  String? svgContent,
  PointMarkerShape shape = PointMarkerShape.circle,
  required Color fillColor,
  Color outlineColor = const Color(0xFFFFFFFF),
  double outlineWidth = 1.5,
  double angleDeg = 0.0,
  double opacity = 1.0,
}) {
  if (radius <= 0) return;
  if (svgContent != null) {
    final slot = SvgMarkerCache.instance.slotFor(svgContent);
    if (slot != null) {
      final scale = (radius * 2.0) / slot.srcRect.width;
      final effOpacity = (opacity * (fillColor.a > 0 ? fillColor.a : 1.0)).clamp(0.0, 1.0);
      canvas.drawAtlas(
        slot.atlas,
        [
          ui.RSTransform.fromComponents(
            rotation: angleDeg * math.pi / 180.0,
            scale: scale,
            anchorX: slot.srcRect.width * 0.5,
            anchorY: slot.srcRect.height * 0.5,
            translateX: center.dx,
            translateY: center.dy,
          ),
        ],
        [slot.srcRect],
        null,
        null,
        null,
        ui.Paint()
          ..filterQuality = ui.FilterQuality.low
          ..color = Color.fromRGBO(255, 255, 255, effOpacity),
      );
      return;
    }
  }
  drawPointMarkerShape(
    canvas,
    center,
    radius,
    shape: shape,
    fillColor: opacity < 1.0 ? fillColor.withValues(alpha: (fillColor.a * opacity).clamp(0.0, 1.0)) : fillColor,
    outlineColor:
        opacity < 1.0 ? outlineColor.withValues(alpha: (outlineColor.a * opacity).clamp(0.0, 1.0)) : outlineColor,
    outlineWidth: outlineWidth,
    angleDeg: angleDeg,
  );
}

/// 点マーカー（7 形状＋縁取り＋回転）を [canvas] に描く
void drawPointMarkerShape(
  ui.Canvas canvas,
  ui.Offset center,
  double radius, {
  PointMarkerShape shape = PointMarkerShape.circle,
  required Color fillColor,
  Color outlineColor = const Color(0xFFFFFFFF),
  double outlineWidth = 1.5,
  double angleDeg = 0.0,
}) {
  if (radius <= 0) return;
  final hasFill = fillColor.a > 0;
  final hasOutline = outlineWidth > 0 && outlineColor.a > 0;
  if (!hasFill && !hasOutline) return;

  final rotated = angleDeg.abs() > 0.01 && shape != PointMarkerShape.circle;
  final c = rotated ? ui.Offset.zero : center;
  if (rotated) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angleDeg * math.pi / 180.0);
  }

  final fillPaint = ui.Paint()
    ..style = ui.PaintingStyle.fill
    ..color = fillColor;
  final edgePaint = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = outlineWidth
    ..strokeJoin = ui.StrokeJoin.round
    ..color = outlineColor;

  switch (shape) {
    case PointMarkerShape.circle:
      if (hasFill) canvas.drawCircle(c, radius, fillPaint);
      if (hasOutline) canvas.drawCircle(c, radius, edgePaint);
    case PointMarkerShape.square:
      final rect = ui.Rect.fromCircle(center: c, radius: radius * 0.88);
      if (hasFill) canvas.drawRect(rect, fillPaint);
      if (hasOutline) canvas.drawRect(rect, edgePaint);
    case PointMarkerShape.diamond:
      final r = radius * 1.08;
      final path = ui.Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close();
      if (hasFill) canvas.drawPath(path, fillPaint);
      if (hasOutline) canvas.drawPath(path, edgePaint);
    case PointMarkerShape.triangle:
      final tr = radius * 1.12;
      final halfW = tr * 0.8660254;
      final path = ui.Path()
        ..moveTo(c.dx, c.dy - tr)
        ..lineTo(c.dx + halfW, c.dy + tr * 0.5)
        ..lineTo(c.dx - halfW, c.dy + tr * 0.5)
        ..close();
      if (hasFill) canvas.drawPath(path, fillPaint);
      if (hasOutline) canvas.drawPath(path, edgePaint);
    case PointMarkerShape.star:
      final ro = radius * 1.15;
      final ri = ro * 0.42;
      final path = ui.Path();
      for (var i = 0; i < 10; i++) {
        final rr = i.isEven ? ro : ri;
        final a = -math.pi / 2 + i * math.pi / 5;
        final p = ui.Offset(c.dx + rr * math.cos(a), c.dy + rr * math.sin(a));
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      if (hasFill) canvas.drawPath(path, fillPaint);
      if (hasOutline) canvas.drawPath(path, edgePaint);
    case PointMarkerShape.cross:
      final path = _crossPolygonPath(c, radius, math.max(1.0, radius * 0.28));
      if (hasFill) canvas.drawPath(path, fillPaint);
      if (hasOutline) canvas.drawPath(path, edgePaint);
    case PointMarkerShape.cross2:
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(math.pi / 4);
      final path = _crossPolygonPath(ui.Offset.zero, radius, math.max(1.0, radius * 0.28));
      if (hasFill) canvas.drawPath(path, fillPaint);
      if (hasOutline) canvas.drawPath(path, edgePaint);
      canvas.restore();
  }

  if (rotated) {
    canvas.restore();
  }
}

ui.Path _crossPolygonPath(ui.Offset c, double r, double th) {
  return ui.Path()
    ..moveTo(c.dx - th, c.dy - r)
    ..lineTo(c.dx + th, c.dy - r)
    ..lineTo(c.dx + th, c.dy - th)
    ..lineTo(c.dx + r, c.dy - th)
    ..lineTo(c.dx + r, c.dy + th)
    ..lineTo(c.dx + th, c.dy + th)
    ..lineTo(c.dx + th, c.dy + r)
    ..lineTo(c.dx - th, c.dy + r)
    ..lineTo(c.dx - th, c.dy + th)
    ..lineTo(c.dx - r, c.dy + th)
    ..lineTo(c.dx - r, c.dy - th)
    ..lineTo(c.dx - th, c.dy - th)
    ..close();
}
