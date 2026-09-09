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
    Map<int, PolygonBatch>? polygonBatches,
  }) : polygonBatches = polygonBatches ?? PolygonBatch.byChunk(polygons);

  /// チャンク番号 → 面の束（シーン側で一度作って使い回す）
  final Map<int, PolygonBatch> polygonBatches;

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

    Paint terrainPaintFor(TerrainTileDrawable t) {
      final paint = Paint();
      if (t.texture != null) {
        paint.shader = ui.ImageShader(
          t.texture!,
          TileMode.clamp,
          TileMode.clamp,
          identity,
          filterQuality: FilterQuality.low,
        );
      } else {
        paint.color = Colors.white;
      }
      return paint;
    }

    void enterTile(TerrainTileDrawable t) {
      final pc = _pcFor(t);
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(camera.scale);
      canvas.translate(-pc.dx, -pc.dy);
    }

    // スカートは全タイルぶんを先に描く（地形の前に）。
    // タイルごとに「スカート → 地形」の順だと、手前のタイルのスカートが奥のタイルの斜面の上に乗る
    // （斜面が縁から下がっていく所では、縁から垂らした壁の方が手前に来る）。全部先に描けば、
    // どのタイルの地形にも覆われ、段違いの裂け目からだけ見える
    for (final t in tiles) {
      final skirt = t.mesh.skirt;
      if (skirt == null) continue;
      enterTile(t);
      canvas.drawVertices(skirt, BlendMode.modulate, terrainPaintFor(t));
      canvas.restore();
    }

    for (final t in tiles) {
      final mesh = t.mesh;
      enterTile(t);
      final terrainPaint = terrainPaintFor(t);

      // 線を「帯 × 見た目（色・太さ）」ごとにまとめる（線ごとに drawPath すると数千回になる）。
      // 細い線（≤ 2.5px）は線分の配列にして drawRawPoints（Path を毎フレーム組むより軽い。継ぎ目の欠けは太さ的に見えない）、
      // 太い線は角と端を丸くしたいので Path
      final pathsByBand = <int, Map<(int, double), Path>>{};
      final segsByBand = <int, Map<(int, double), List<double>>>{};
      for (var li = 0; li < t.lines.length; li++) {
        final line = t.lines[li];
        final n = line.pointCount;
        final styleKey = (line.color.toARGB32(), line.widthPx);
        final thin = line.widthPx <= 2.5;
        var currentBand = -1;
        Path? path;
        List<double>? segs;
        for (var i = 0; i < n - 1; i++) {
          final band = mesh.cellBand[line.cells[i]];
          final a = camera.project(line.xyz[i * 3], line.xyz[i * 3 + 1], line.xyz[i * 3 + 2]);
          final b = camera.project(line.xyz[i * 3 + 3], line.xyz[i * 3 + 4], line.xyz[i * 3 + 5]);
          if (thin) {
            if (band != currentBand) {
              segs = (segsByBand[band] ??= {})[styleKey] ??= <double>[];
              currentBand = band;
            }
            segs!
              ..add(a.dx)
              ..add(a.dy)
              ..add(b.dx)
              ..add(b.dy);
          } else {
            if (band != currentBand) {
              path = (pathsByBand[band] ??= {})[styleKey] ??= Path();
              path.moveTo(a.dx, a.dy);
              currentBand = band;
            }
            path!.lineTo(b.dx, b.dy);
          }
        }
      }

      for (var b = 0; b < mesh.bands.length; b++) {
        canvas.drawVertices(mesh.bands[b].vertices, BlendMode.modulate, terrainPaint);
        final chunk = mesh.bandChunk[b];
        final batch = t.polygonBatches[chunk];
        if (batch != null) {
          projectInto(batch.xyz, batch.projected);
          canvas.drawVertices(
            ui.Vertices.raw(ui.VertexMode.triangles, batch.projected, colors: batch.colors),
            BlendMode.srcOver,
            fillPaint,
          );
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
        final segs = segsByBand[b];
        if (segs != null) {
          for (final e in segs.entries) {
            segmentPaint
              ..color = Color(e.key.$1)
              ..strokeWidth = e.key.$2 / camera.scale;
            canvas.drawRawPoints(ui.PointMode.lines, Float32List.fromList(e.value), segmentPaint);
          }
        }
        final paths = pathsByBand[b];
        if (paths == null) continue;
        for (final e in paths.entries) {
          linePaint
            ..color = Color(e.key.$1)
            ..strokeWidth = e.key.$2 / camera.scale;
          canvas.drawPath(e.value, linePaint);
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

    // ラベル（画面座標）。重なりは先勝ちで間引く。
    // 勝ち負けの順はタイルの描画順（方位で変わる）ではなく、文字と位置で決めた固定の順にする
    // （回転中にラベルの出入りがちらつかないように）。番号（visibleLabels・pick）はタイル順のまま
    final placed = <Rect>[];
    visibleLabels.clear();
    final entries = <(int, TerrainTileDrawable, TerrainLabel)>[];
    var labelIndex = 0;
    for (final t in tiles) {
      for (final label in t.labels) {
        entries.add((labelIndex++, t, label));
      }
    }
    entries.sort((a, b) {
      final ta = a.$3.text;
      final tb = b.$3.text;
      final c = ta.compareTo(tb);
      if (c != 0) return c;
      final ya = a.$2.originY + a.$3.y;
      final yb = b.$2.originY + b.$3.y;
      return ya != yb ? ya.compareTo(yb) : (a.$2.originX + a.$3.x).compareTo(b.$2.originX + b.$3.x);
    });
    for (final (i, t, label) in entries) {
      {
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
