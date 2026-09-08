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
    final s = step ?? dem.cellSize * mesh.step;
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

/// DEM に沿って持ち上げた面（描画用）
///
/// 面を三角形に分け（耳切り）、各三角形を DEM のセルで切り分け、
/// 各片の頂点を DEM で持ち上げる。テクスチャに焼かないので、崖でも伸びない。
/// 三角形 ∩ 矩形は凸なので扇状分割で正しい。
class LiftedPolygon {
  LiftedPolygon({required this.xyz, required this.cells, required this.color, required TerrainMesh mesh}) {
    // チャンクごとに束ねる（チャンク番号は象限に依らず静的）。投影先の配列も同じ長さで用意
    final grouped = <int, List<double>>{};
    for (var t = 0; t < triangleCount; t++) {
      final buf = grouped[mesh.chunkOfCell(cells[t])] ??= <double>[];
      for (var k = 0; k < 9; k++) {
        buf.add(xyz[t * 9 + k]);
      }
    }
    for (final e in grouped.entries) {
      byChunk[e.key] = Float32List.fromList(e.value);
      projected[e.key] = Float32List(e.value.length ~/ 3 * 2);
    }
  }

  /// 三角形の頂点 x, y, z（三角形数 × 9）
  final Float32List xyz;

  /// 各三角形が属するセル番号
  final Int32List cells;

  final Color color;

  /// チャンク番号 → その中の三角形（x, y, z × 3 × n）
  final Map<int, Float32List> byChunk = {};

  /// [byChunk] を投影した画面座標のバッファ（毎フレーム上書き）
  final Map<int, Float32List> projected = {};

  int get triangleCount => cells.length;

  static LiftedPolygon lift(List<Offset> ring, TerrainMesh mesh, {required Color color}) {
    final dem = mesh.dem;
    final cell = dem.cellSize * mesh.step;
    final out = <double>[];
    final cells = <int>[];
    for (final tri in earClip(ring)) {
      // 三角形の bbox に掛かるセルを走査
      final xs = [tri[0].dx, tri[1].dx, tri[2].dx];
      final ys = [tri[0].dy, tri[1].dy, tri[2].dy];
      final c0 = (xs.reduce(math.min) / cell).floor();
      final c1 = (xs.reduce(math.max) / cell).floor();
      final r0 = (ys.reduce(math.min) / cell).floor();
      final r1 = (ys.reduce(math.max) / cell).floor();
      for (var r = r0; r <= r1; r++) {
        for (var c = c0; c <= c1; c++) {
          final rect = Rect.fromLTWH(c * cell, r * cell, cell, cell);
          final piece = clipToRect(tri, rect);
          if (piece.length < 3) continue;
          final ci = mesh.cellIndexAt(rect.center.dx, rect.center.dy);
          for (var k = 1; k + 1 < piece.length; k++) {
            for (final p in [piece[0], piece[k], piece[k + 1]]) {
              out.addAll([p.dx, p.dy, dem.elevationAt(p.dx + dem.originX, p.dy + dem.originY)]);
            }
            cells.add(ci);
          }
        }
      }
    }
    return LiftedPolygon(
      xyz: Float32List.fromList(out),
      cells: Int32List.fromList(cells),
      color: color,
      mesh: mesh,
    );
  }

  /// 単純多角形を耳切りで三角形に分ける（穴なし）
  static List<List<Offset>> earClip(List<Offset> ring) {
    final pts = List<Offset>.from(ring);
    if (pts.length >= 2 && (pts.first - pts.last).distance < 1e-9) pts.removeLast();
    if (pts.length < 3) return const [];
    // 反時計回りに揃える
    var area = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i];
      final b = pts[(i + 1) % pts.length];
      area += a.dx * b.dy - b.dx * a.dy;
    }
    if (area < 0) pts.setAll(0, pts.reversed.toList());
    final idx = List<int>.generate(pts.length, (i) => i);
    final tris = <List<Offset>>[];
    var guard = 0;
    while (idx.length > 3 && guard++ < 10000) {
      var clipped = false;
      for (var i = 0; i < idx.length; i++) {
        final ia = idx[(i - 1 + idx.length) % idx.length];
        final ib = idx[i];
        final ic = idx[(i + 1) % idx.length];
        final a = pts[ia];
        final b = pts[ib];
        final c = pts[ic];
        if (_cross(a, b, c) <= 0) continue; // 凹角
        var ok = true;
        for (final j in idx) {
          if (j == ia || j == ib || j == ic) continue;
          if (inTriangle(pts[j], a, b, c)) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        tris.add([a, b, c]);
        idx.removeAt(i);
        clipped = true;
        break;
      }
      if (!clipped) break; // 退化した多角形
    }
    if (idx.length == 3) tris.add([pts[idx[0]], pts[idx[1]], pts[idx[2]]]);
    return tris;
  }

  static double _cross(Offset a, Offset b, Offset c) =>
      (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);

  static bool inTriangle(Offset p, Offset a, Offset b, Offset c) {
    final d1 = _cross(a, b, p);
    final d2 = _cross(b, c, p);
    final d3 = _cross(c, a, p);
    final hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
    final hasPos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(hasNeg && hasPos);
  }

  /// 多角形を矩形で切る（Sutherland–Hodgman）
  static List<Offset> clipToRect(List<Offset> poly, Rect rect) {
    var out = poly;
    for (var edge = 0; edge < 4 && out.isNotEmpty; edge++) {
      final input = out;
      out = <Offset>[];
      bool inside(Offset p) => switch (edge) {
            0 => p.dx >= rect.left,
            1 => p.dx <= rect.right,
            2 => p.dy >= rect.top,
            _ => p.dy <= rect.bottom,
          };
      Offset intersect(Offset a, Offset b) {
        switch (edge) {
          case 0:
          case 1:
            final x = edge == 0 ? rect.left : rect.right;
            final t = (x - a.dx) / (b.dx - a.dx);
            return Offset(x, a.dy + (b.dy - a.dy) * t);
          default:
            final y = edge == 2 ? rect.top : rect.bottom;
            final t = (y - a.dy) / (b.dy - a.dy);
            return Offset(a.dx + (b.dx - a.dx) * t, y);
        }
      }

      for (var i = 0; i < input.length; i++) {
        final cur = input[i];
        final prev = input[(i - 1 + input.length) % input.length];
        final curIn = inside(cur);
        final prevIn = inside(prev);
        if (curIn) {
          if (!prevIn) out.add(intersect(prev, cur));
          out.add(cur);
        } else if (prevIn) {
          out.add(intersect(prev, cur));
        }
      }
    }
    return out;
  }
}

/// DEM に沿って持ち上げた独立線分の束（等高線など、本数が多いもの）
///
/// 折れ線 1 本ずつ Path を作ると 1 万本を超えたところで描画が破綻する（等高線 2.5 万本で 60ms）。
/// チャンクごとに `x, y, z` を並べておき、毎フレーム投影して
/// `drawRawPoints(PointMode.lines)` で 1 チャンク 1 回に描く。
class LiftedSegments {
  LiftedSegments._({required this.byChunk, required this.color, required this.widthPx}) {
    for (final e in byChunk.entries) {
      projected[e.key] = Float32List(e.value.length ~/ 3 * 2);
    }
  }

  /// 2 点の線分の並び（各点は DEM 原点基準の 2D。標高は DEM から引く）
  static LiftedSegments lift(
    List<List<Offset>> segments,
    TerrainMesh mesh, {
    required Color color,
    required double widthPx,
  }) {
    final dem = mesh.dem;
    final grouped = <int, List<double>>{};
    for (final seg in segments) {
      for (var i = 0; i + 1 < seg.length; i++) {
        final a = seg[i];
        final b = seg[i + 1];
        final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
        final chunk = mesh.chunkOfCell(mesh.cellIndexAt(mid.dx, mid.dy));
        (grouped[chunk] ??= <double>[]).addAll([
          a.dx, a.dy, dem.elevationAt(a.dx + dem.originX, a.dy + dem.originY),
          b.dx, b.dy, dem.elevationAt(b.dx + dem.originX, b.dy + dem.originY),
        ]);
      }
    }
    return LiftedSegments._(
      byChunk: {for (final e in grouped.entries) e.key: Float32List.fromList(e.value)},
      color: color,
      widthPx: widthPx,
    );
  }

  /// チャンク番号 → x, y, z × 2 × 線分数
  final Map<int, Float32List> byChunk;

  /// [byChunk] を投影した画面座標のバッファ（毎フレーム上書き）
  final Map<int, Float32List> projected = {};

  final Color color;
  final double widthPx;

  int get segmentCount => byChunk.values.fold(0, (a, v) => a + v.length ~/ 6);
}

/// 地形に乗せるラベル（ビルボード）
class TerrainLabel {
  TerrainLabel({required this.x, required this.y, required this.painter});

  /// DEM 原点基準の Mercator m
  final double x;
  final double y;
  final TextPainter painter;
}

/// ヒットテストの結果
class TerrainHit {
  const TerrainHit({required this.kind, required this.index, required this.distancePx});

  /// 'label' / 'line' / 'polygon'
  final String kind;
  final int index;
  final double distancePx;

  @override
  String toString() => '$kind #$index (${distancePx.toStringAsFixed(1)}px)';
}

/// 地形メッシュ・ラスタ・ベクタ・ラベルを 1 枚に描く
///
/// 描画順:
/// 1. 帯ごとに地形（テクスチャ × 陰影色）→ その帯に落ちる面 → 線
/// 2. ラベルは最後に画面座標で（地形に隠れない方針）
///
/// 1 インスタンスを使い回し、中身を差し替えて [repaint] で通知する。
/// 毎フレーム `setState` で画面全体を組み直すと、地図面以外のウィジェットの
/// 再構築が UI スレッドを食う（debug で 10ms 超）。
class TerrainPainter extends CustomPainter {
  TerrainPainter({
    required this.mesh,
    required this.camera,
    required this.texture,
    required this.lines,
    required this.labels,
    this.polygons = const [],
    this.segmentSets = const [],
    this.onPainted,
    super.repaint,
  });

  TerrainMesh mesh;
  TerrainCamera camera;
  ui.Image? texture;
  List<LiftedPolyline> lines;
  List<LiftedPolygon> polygons;

  /// 等高線などの線分の束（面の上、線の下に描く）
  List<LiftedSegments> segmentSets;
  List<TerrainLabel> labels;

  /// 選択中（強調表示）
  TerrainHit? selected;

  /// 描画に掛かった時間の通知（計測用）
  final void Function(Duration)? onPainted;

  /// カメラ中心の投影座標（倍率 1・DEM 原点基準）
  Offset _projectedCenter() {
    final dem = mesh.dem;
    return camera.project(
      camera.centerX - dem.originX,
      camera.centerY - dem.originY,
      dem.elevationAt(camera.centerX, camera.centerY),
    );
  }

  /// DEM 原点基準の世界座標 → 画面座標
  Offset toScreen(double x, double y, double z, Size size, Offset pc) {
    final p = camera.project(x, y, z);
    return Offset(
      size.width / 2 + (p.dx - pc.dx) * camera.scale,
      size.height / 2 + (p.dy - pc.dy) * camera.scale,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    final dem = mesh.dem;
    final pc = _projectedCenter();

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
    } else {
      terrainPaint.color = Colors.white; // 頂点色（陰影）だけで描く
    }

    // 線を帯ごとに振り分けた Path（毎フレーム組み直す。点数は少ない前提）
    final pathsByBand = <int, List<(Path, int)>>{};
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
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
          (pathsByBand[band] ??= []).add((path, li));
          currentBand = band;
        }
        path!.lineTo(b.dx, b.dy);
      }
    }

    // 面: チャンク単位で束ねてあるので、帯 → チャンク で引いて投影する
    final cosB = math.cos(camera.bearing);
    final sinB = math.sin(camera.bearing);
    final cosP = math.cos(camera.pitch);
    final zk = camera.zScale * math.sin(camera.pitch);

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint();
    final segmentPaint = Paint()..strokeCap = StrokeCap.butt;
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
    for (var b = 0; b < mesh.bands.length; b++) {
      canvas.drawVertices(mesh.bands[b].vertices, BlendMode.modulate, terrainPaint);
      final chunk = mesh.bandChunk[b];
      for (var pi = 0; pi < polygons.length; pi++) {
        final poly = polygons[pi];
        final src = poly.byChunk[chunk];
        if (src == null) continue;
        final dst = poly.projected[chunk]!;
        projectInto(src, dst);
        final isSel = selected?.kind == 'polygon' && selected?.index == pi;
        fillPaint.color = isSel ? Colors.yellow.withValues(alpha: 0.7) : poly.color;
        canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, dst), BlendMode.srcOver, fillPaint);
      }
      for (final set in segmentSets) {
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
        final line = lines[li];
        final isSel = selected?.kind == 'line' && selected?.index == li;
        linePaint
          ..color = isSel ? Colors.yellow : line.color
          ..strokeWidth = (isSel ? line.widthPx + 3 : line.widthPx) / camera.scale;
        canvas.drawPath(path, linePaint);
      }
    }
    canvas.restore();

    // ラベル（画面座標）
    final viewport = Offset.zero & size;
    for (var i = 0; i < labels.length; i++) {
      final label = labels[i];
      final z = dem.elevationAt(label.x + dem.originX, label.y + dem.originY);
      final sp = toScreen(label.x, label.y, z, size, pc);
      if (!viewport.inflate(64).contains(sp)) continue;
      final tp = label.painter;
      final origin = sp - Offset(tp.width / 2, tp.height + 4);
      final isSel = selected?.kind == 'label' && selected?.index == i;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2),
          const Radius.circular(3),
        ),
        Paint()..color = (isSel ? Colors.yellow : Colors.white).withValues(alpha: 0.85),
      );
      tp.paint(canvas, origin);
      canvas.drawCircle(sp, isSel ? 5 : 2.5, Paint()..color = Colors.black);
    }
    sw.stop();
    onPainted?.call(sw.elapsed);
  }

  /// 画面座標でのヒットテスト。優先は ラベル > 線 > 面
  ///
  /// 線と面は地形に隠れていれば当てない（[isOccluded]）。ラベルは最後に上描きしているので当てる。
  TerrainHit? pick(Offset point, Size size, {double tolerancePx = 20}) {
    final dem = mesh.dem;
    final pc = _projectedCenter();
    TerrainHit? best;
    void consider(String kind, int index, double d) {
      if (d > tolerancePx) return;
      if (best == null || d < best!.distancePx) {
        best = TerrainHit(kind: kind, index: index, distancePx: d);
      }
    }

    for (var i = 0; i < labels.length; i++) {
      final l = labels[i];
      final sp = toScreen(l.x, l.y, dem.elevationAt(l.x + dem.originX, l.y + dem.originY), size, pc);
      consider('label', i, (sp - point).distance);
    }
    if (best != null) return best;
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      var prev = toScreen(line.xyz[0], line.xyz[1], line.xyz[2], size, pc);
      for (var i = 1; i < line.pointCount; i++) {
        final cur = toScreen(line.xyz[i * 3], line.xyz[i * 3 + 1], line.xyz[i * 3 + 2], size, pc);
        final d = _distanceToSegment(point, prev, cur) - line.widthPx / 2;
        if (d <= tolerancePx && !isOccluded(line.xyz[i * 3], line.xyz[i * 3 + 1], line.xyz[i * 3 + 2])) {
          consider('line', li, d);
        }
        prev = cur;
      }
    }
    if (best != null) return best;
    for (var pi = 0; pi < polygons.length; pi++) {
      final poly = polygons[pi];
      for (var t = 0; t < poly.triangleCount; t++) {
        final o = t * 9;
        final a = toScreen(poly.xyz[o], poly.xyz[o + 1], poly.xyz[o + 2], size, pc);
        final b = toScreen(poly.xyz[o + 3], poly.xyz[o + 4], poly.xyz[o + 5], size, pc);
        final c = toScreen(poly.xyz[o + 6], poly.xyz[o + 7], poly.xyz[o + 8], size, pc);
        if (LiftedPolygon.inTriangle(point, a, b, c)) {
          // 三角形の重心で遮蔽を見る（三角形はセルより小さいので十分）
          final gx = (poly.xyz[o] + poly.xyz[o + 3] + poly.xyz[o + 6]) / 3;
          final gy = (poly.xyz[o + 1] + poly.xyz[o + 4] + poly.xyz[o + 7]) / 3;
          final gz = (poly.xyz[o + 2] + poly.xyz[o + 5] + poly.xyz[o + 8]) / 3;
          if (isOccluded(gx, gy, gz)) continue;
          return TerrainHit(kind: 'polygon', index: pi, distancePx: 0);
        }
      }
    }
    return best;
  }

  /// 世界座標（DEM 原点基準）の点が、手前の地形に隠れているか
  ///
  /// 正射影なので視線は平行。点から視点側へ地上投影の向き `(-sinB, -cosB)` に
  /// セル幅ずつ進み、視線の高さ（`1/tan(pitch)` で上がる）より地形が高ければ隠れている。
  /// 視線が DEM の最高点を超えたら打ち切る。
  bool isOccluded(double x, double y, double z) {
    final p = camera.pitch;
    if (p <= 1e-6) return false; // 真上からは何も隠れない
    final dem = mesh.dem;
    final dx = -math.sin(camera.bearing);
    final dy = -math.cos(camera.bearing);
    final cell = dem.cellSize;
    final rise = cell / math.tan(p) / camera.zScale; // 1 歩ごとに視線が上がる高さ（真の m）
    var maxH = -double.infinity;
    for (final h in dem.heights) {
      if (h > maxH) maxH = h;
    }
    var cx = x;
    var cy = y;
    var cz = z + 0.5; // 自分自身のセルに引っ掛からないよう少し浮かせる
    final steps = ((dem.width + dem.height) / cell).ceil();
    for (var i = 0; i < steps; i++) {
      cx += dx * cell;
      cy += dy * cell;
      cz += rise;
      if (cz > maxH) return false;
      if (cx < 0 || cy < 0 || cx > dem.width || cy > dem.height) return false;
      if (dem.elevationAt(cx + dem.originX, cy + dem.originY) > cz) return true;
    }
    return false;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  @override
  bool shouldRepaint(covariant TerrainPainter old) => true;
}
