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
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'terrain_camera.dart';
import 'terrain_mesh.dart';

/// DEM に沿って持ち上げた折れ線（描画用）
///
/// 元の 2D 折れ線をセル幅ごとに細分し、各点の標高を DEM から引いたもの。
/// 座標は DEM 原点基準の Mercator m。
class LiftedPolyline {
  LiftedPolyline({
    required this.xyz,
    required this.cells,
    required this.color,
    required this.widthPx,
  });

  /// x, y, z の並び（点数 × 3）
  final Float32List xyz;

  /// 各区間（点 i → i+1）が属するセル番号（点数 - 1）
  final Int32List cells;

  final Color color;
  final double widthPx;

  int get pointCount => xyz.length ~/ 3;

  /// 2D 折れ線を DEM で持ち上げる。[step] より長い区間は分割する
  static LiftedPolyline lift(
    List<Offset> points,
    TerrainMesh mesh, {
    required Color color,
    required double widthPx,
    double? step,
  }) {
    final dem = mesh.dem;
    final s = step ?? dem.cellSize;
    final out = <double>[];
    final cells = <int>[];
    void addPoint(double x, double y) {
      out.addAll([x, y, dem.elevationAt(x + dem.originX, y + dem.originY)]);
    }

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      if (i == 0) {
        addPoint(p.dx, p.dy);
        continue;
      }
      final q = points[i - 1];
      final len = (p - q).distance;
      final n = (len / s).ceil().clamp(1, 1 << 16);
      for (var k = 1; k <= n; k++) {
        final t = k / n;
        final x = q.dx + (p.dx - q.dx) * t;
        final y = q.dy + (p.dy - q.dy) * t;
        final mx = q.dx + (p.dx - q.dx) * (k - 0.5) / n;
        final my = q.dy + (p.dy - q.dy) * (k - 0.5) / n;
        cells.add(mesh.cellIndexAt(mx, my));
        addPoint(x, y);
      }
    }
    return LiftedPolyline(
      xyz: Float32List.fromList(out),
      cells: Int32List.fromList(cells),
      color: color,
      widthPx: widthPx,
    );
  }
}

/// 地形に乗せるラベル（ビルボード）
class TerrainLabel {
  TerrainLabel({required this.x, required this.y, required this.painter});

  /// DEM 原点基準の Mercator m
  final double x;
  final double y;
  final TextPainter painter;
}

/// 地形メッシュ・ラスタ・ベクタ・ラベルを 1 枚に描く
///
/// 描画順:
/// 1. 帯ごとに地形（テクスチャ × 陰影色）→ その帯に落ちる線
/// 2. ラベルは最後に画面座標で（地形に隠れない方針）
class TerrainPainter extends CustomPainter {
  TerrainPainter({
    required this.mesh,
    required this.camera,
    required this.texture,
    required this.lines,
    required this.labels,
    this.onPainted,
  });

  final TerrainMesh mesh;
  final TerrainCamera camera;
  final ui.Image? texture;
  final List<LiftedPolyline> lines;
  final List<TerrainLabel> labels;

  /// 描画に掛かった時間の通知（計測用）
  final void Function(Duration)? onPainted;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    final dem = mesh.dem;
    final cx = camera.centerX - dem.originX;
    final cy = camera.centerY - dem.originY;
    final pc = camera.project(cx, cy, dem.elevationAt(camera.centerX, camera.centerY));

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(camera.scale);
    canvas.translate(-pc.dx, -pc.dy);

    final terrainPaint = Paint();
    if (texture != null) {
      terrainPaint.shader = ui.ImageShader(
        texture!,
        TileMode.clamp,
        TileMode.clamp,
        Float64List.fromList(Matrix4.identity().storage),
        filterQuality: FilterQuality.low,
      );
    }

    // 線を帯ごとに振り分けた Path（毎フレーム組み直す。点数は少ない前提）
    final pathsByBand = <int, List<(Path, LiftedPolyline)>>{};
    for (final line in lines) {
      final n = line.pointCount;
      var currentBand = -1;
      Path? path;
      for (var i = 0; i < n - 1; i++) {
        final band = mesh.cellBand[line.cells[i]];
        final a = camera.project(line.xyz[i * 3], line.xyz[i * 3 + 1], line.xyz[i * 3 + 2]);
        final b = camera.project(
          line.xyz[i * 3 + 3],
          line.xyz[i * 3 + 4],
          line.xyz[i * 3 + 5],
        );
        if (band != currentBand) {
          path = Path()..moveTo(a.dx, a.dy);
          (pathsByBand[band] ??= []).add((path, line));
          currentBand = band;
        }
        path!.lineTo(b.dx, b.dy);
      }
    }

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var b = 0; b < mesh.bands.length; b++) {
      canvas.drawVertices(mesh.bands[b].vertices, BlendMode.modulate, terrainPaint);
      final paths = pathsByBand[b];
      if (paths == null) continue;
      for (final (path, line) in paths) {
        linePaint
          ..color = line.color
          ..strokeWidth = line.widthPx / camera.scale;
        canvas.drawPath(path, linePaint);
      }
    }
    canvas.restore();

    // ラベル（画面座標）
    final viewport = Offset.zero & size;
    for (final label in labels) {
      final z = dem.elevationAt(label.x + dem.originX, label.y + dem.originY);
      final p = camera.project(label.x, label.y, z);
      final sp = Offset(
        size.width / 2 + (p.dx - pc.dx) * camera.scale,
        size.height / 2 + (p.dy - pc.dy) * camera.scale,
      );
      if (!viewport.inflate(64).contains(sp)) continue;
      final tp = label.painter;
      final origin = sp - Offset(tp.width / 2, tp.height + 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2),
          const Radius.circular(3),
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.8),
      );
      tp.paint(canvas, origin);
      canvas.drawCircle(sp, 2.5, Paint()..color = Colors.black);
    }
    sw.stop();
    onPainted?.call(sw.elapsed);
  }

  @override
  bool shouldRepaint(covariant TerrainPainter old) => true;
}
