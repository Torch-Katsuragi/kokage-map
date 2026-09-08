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
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'terrain_camera.dart';
import 'terrain_mesh.dart';
import 'terrain_painter.dart';
import 'terrain_scene.dart';

/// 描画順に並んだ 1 タイルぶんの描き物（座標はタイルの DEM 原点基準）
class TerrainTileDrawable {
  TerrainTileDrawable({
    required this.originX,
    required this.originY,
    required this.mesh,
    required this.texture,
    this.lines = const [],
    this.polygons = const [],
    this.segmentSets = const [],
    this.points = const [],
    this.labels = const [],
  });

  /// タイルの DEM 原点（Mercator m）
  final double originX;
  final double originY;
  final TerrainMesh mesh;
  final ui.Image? texture;
  final List<LiftedPolyline> lines;
  final List<LiftedPolygon> polygons;
  final List<LiftedSegments> segmentSets;
  final List<TerrainPoint> points;
  final List<TerrainLabel> labels;
}

/// 世界（複数タイル）を 1 枚に描く
///
/// 描画順: タイル（奥 → 手前・呼び出し側が並べる）→ タイル内はチャンクの帯 → 帯ごとに面・線分・線。
/// 点とラベルは全タイルぶんを最後に画面座標で描く（重なりは先勝ちで間引く）。
/// 座標系: 各タイルは自分の DEM 原点基準。投影は線形なので、タイルごとに
/// 「カメラ中心をそのタイルの座標で投影した点」を引くだけで並ぶ。
class TerrainWorldPainter extends CustomPainter {
  TerrainWorldPainter({
    required this.camera,
    required this.tiles,
    required this.elevationAt,
    required this.heightRange,
    required this.stepMeters,
    this.collideLabels = true,
    this.onPainted,
    super.repaint,
  });

  TerrainCamera camera;

  /// 描画順（奥 → 手前）
  List<TerrainTileDrawable> tiles;

  /// 世界座標（Mercator）→ 標高。無い所は null（計算メッシュ）
  double? Function(double x, double y) elevationAt;

  /// 読み込み済みの標高の範囲（視線なぞりの上下限）
  (double, double) heightRange;

  /// 視線なぞりの刻み（最も細かい DEM のセル幅）
  double stepMeters;

  bool collideLabels;
  TerrainHit? selected;
  final Set<int> visibleLabels = {};
  final void Function(Duration)? onPainted;

  double get _centerHeight => elevationAt(camera.centerX, camera.centerY) ?? 0;

  /// タイル座標での「画面中心に来る点」の投影座標
  Offset _pcFor(TerrainTileDrawable t) =>
      camera.project(camera.centerX - t.originX, camera.centerY - t.originY, _centerHeight);

  /// 世界座標 → 画面座標
  Offset toScreen(double x, double y, double z, Size size) {
    final p = camera.project(x - camera.centerX, y - camera.centerY, z - _centerHeight);
    return Offset(size.width / 2 + p.dx * camera.scale, size.height / 2 + p.dy * camera.scale);
  }

  /// 画面座標 → 視線と地形の交点（世界座標）。地形の外なら null
  Offset? unproject(Offset screen, Size size) {
    final h0 = _centerHeight;
    // 原点 = カメラ中心（高さ h0）の投影座標系で交点を求める
    final projected = Offset(
      (screen.dx - size.width / 2) / camera.scale,
      (screen.dy - size.height / 2) / camera.scale,
    );
    final pc = camera.project(0, 0, h0);
    final hit = camera.intersectHeightField(
      Offset(projected.dx + pc.dx, projected.dy + pc.dy),
      (x, y) => elevationAt(camera.centerX + x, camera.centerY + y),
      minHeight: heightRange.$1,
      maxHeight: heightRange.$2,
      stepMeters: stepMeters,
    );
    if (hit == null) return null;
    return Offset(camera.centerX + hit.dx, camera.centerY + hit.dy);
  }

  /// 世界座標の点が手前の地形に隠れているか
  bool isOccluded(double x, double y, double z) {
    final sinP = math.sin(camera.pitch);
    if (sinP < 1e-6) return false;
    final tanP = math.tan(camera.pitch);
    final dirX = -math.sin(camera.bearing);
    final dirY = -math.cos(camera.bearing);
    final rise = 1 / (camera.zScale * tanP);
    final maxH = heightRange.$2;
    var d = stepMeters;
    while (true) {
      final zRay = z + d * rise;
      if (zRay > maxH) return false;
      final h = elevationAt(x + dirX * d, y + dirY * d);
      if (h != null && h > zRay + 0.5) return true;
      d += stepMeters;
      if (d > 50000) return false;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    final cosB = math.cos(camera.bearing);
    final sinB = math.sin(camera.bearing);
    final cosP = math.cos(camera.pitch);
    final zk = camera.zScale * math.sin(camera.pitch);
    void projectInto(Float32List src, Float32List dst) {
      var o = 0;
      for (var i = 0; i < src.length; i += 3) {
        final x = src[i];
        final y = src[i + 1];
        dst[o] = x * cosB - y * sinB;
        dst[o + 1] = -((x * sinB + y * cosB) * cosP + src[i + 2] * zk);
        o += 2;
      }
    }

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint();
    final segmentPaint = Paint()..strokeCap = StrokeCap.butt;
    final identity = Float64List.fromList(Matrix4.identity().storage);

    for (final t in tiles) {
      final mesh = t.mesh;
      final pc = _pcFor(t);
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(camera.scale);
      canvas.translate(-pc.dx, -pc.dy);

      final terrainPaint = Paint();
      if (t.texture != null) {
        terrainPaint.shader = ui.ImageShader(
          t.texture!,
          TileMode.clamp,
          TileMode.clamp,
          identity,
          filterQuality: FilterQuality.low,
        );
      } else {
        terrainPaint.color = Colors.white;
      }

      // 線を帯ごとに振り分けた Path
      final pathsByBand = <int, List<(Path, int)>>{};
      for (var li = 0; li < t.lines.length; li++) {
        final line = t.lines[li];
        final n = line.pointCount;
        var currentBand = -1;
        Path? path;
        for (var i = 0; i < n - 1; i++) {
          final band = mesh.cellBand[line.cells[i]];
          final a = camera.project(line.xyz[i * 3], line.xyz[i * 3 + 1], line.xyz[i * 3 + 2]);
          final b = camera.project(line.xyz[i * 3 + 3], line.xyz[i * 3 + 4], line.xyz[i * 3 + 5]);
          if (band != currentBand) {
            path = Path()..moveTo(a.dx, a.dy);
            (pathsByBand[band] ??= []).add((path, li));
            currentBand = band;
          }
          path!.lineTo(b.dx, b.dy);
        }
      }

      final skirt = mesh.skirt;
      if (skirt != null) canvas.drawVertices(skirt, BlendMode.modulate, terrainPaint);
      for (var b = 0; b < mesh.bands.length; b++) {
        canvas.drawVertices(mesh.bands[b].vertices, BlendMode.modulate, terrainPaint);
        final chunk = mesh.bandChunk[b];
        for (final poly in t.polygons) {
          final src = poly.byChunk[chunk];
          if (src == null) continue;
          final dst = poly.projected[chunk]!;
          projectInto(src, dst);
          fillPaint.color = poly.color;
          canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, dst), BlendMode.srcOver, fillPaint);
        }
        for (final set in t.segmentSets) {
          final src = set.byChunk[chunk];
          if (src == null) continue;
          final dst = set.projected[chunk]!;
          projectInto(src, dst);
          segmentPaint
            ..color = set.color
            ..strokeWidth = set.widthPx / camera.scale;
          canvas.drawRawPoints(ui.PointMode.lines, dst, segmentPaint);
        }
        final paths = pathsByBand[b];
        if (paths == null) continue;
        for (final (path, li) in paths) {
          final line = t.lines[li];
          linePaint
            ..color = line.color
            ..strokeWidth = line.widthPx / camera.scale;
          canvas.drawPath(path, linePaint);
        }
      }
      canvas.restore();
    }

    // 点（画面座標）。隠れているものは描かない
    final viewport = Offset.zero & size;
    final pointPaint = Paint();
    final pointEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white;
    for (final t in tiles) {
      for (final pt in t.points) {
        final wx = t.originX + pt.x;
        final wy = t.originY + pt.y;
        final z = elevationAt(wx, wy) ?? 0;
        final sp = toScreen(wx, wy, z, size);
        if (!viewport.inflate(16).contains(sp)) continue;
        if (isOccluded(wx, wy, z)) continue;
        pointPaint.color = pt.color;
        canvas.drawCircle(sp, pt.sizePx, pointPaint);
        canvas.drawCircle(sp, pt.sizePx, pointEdge);
      }
    }

    // ラベル（画面座標）。重なりは先勝ちで間引く
    final placed = <Rect>[];
    visibleLabels.clear();
    var labelIndex = 0;
    for (final t in tiles) {
      for (final label in t.labels) {
        final i = labelIndex++;
        final wx = t.originX + label.x;
        final wy = t.originY + label.y;
        final sp = toScreen(wx, wy, elevationAt(wx, wy) ?? 0, size);
        if (!viewport.inflate(64).contains(sp)) continue;
        final tp = label.painter;
        final origin = sp - Offset(tp.width / 2, tp.height + 4);
        final box = Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2);
        if (collideLabels) {
          var overlaps = false;
          for (final r in placed) {
            if (r.overlaps(box)) {
              overlaps = true;
              break;
            }
          }
          if (overlaps) {
            canvas.drawCircle(sp, 2, Paint()..color = Colors.black54);
            continue;
          }
        }
        placed.add(box);
        visibleLabels.add(i);
        canvas.drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(3)),
          Paint()..color = Colors.white.withValues(alpha: 0.85),
        );
        tp.paint(canvas, origin);
        canvas.drawCircle(sp, 2.5, Paint()..color = Colors.black);
      }
    }
    sw.stop();
    onPainted?.call(sw.elapsed);
  }

  @override
  bool shouldRepaint(covariant TerrainWorldPainter old) => true;
}
