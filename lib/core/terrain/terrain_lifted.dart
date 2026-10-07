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

import 'package:flutter/material.dart';

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
      out
        ..add(x)
        ..add(y)
        ..add(dem.elevationAtLocal(x, y));
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

/// 折れ線を矩形で切って、中に残る部分の列を返す（Liang–Barsky）
List<List<Offset>> clipPolylineToRect(List<Offset> points, Rect rect) {
  final out = <List<Offset>>[];
  var current = <Offset>[];
  for (var i = 0; i + 1 < points.length; i++) {
    final a = points[i];
    final b = points[i + 1];
    var t0 = 0.0;
    var t1 = 1.0;
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    var visible = true;
    for (final (p, q) in [
      (-dx, a.dx - rect.left),
      (dx, rect.right - a.dx),
      (-dy, a.dy - rect.top),
      (dy, rect.bottom - a.dy),
    ]) {
      if (p == 0) {
        if (q < 0) {
          visible = false;
          break;
        }
        continue;
      }
      final t = q / p;
      if (p < 0) {
        if (t > t1) {
          visible = false;
          break;
        }
        if (t > t0) t0 = t;
      } else {
        if (t < t0) {
          visible = false;
          break;
        }
        if (t < t1) t1 = t;
      }
    }
    if (!visible) {
      if (current.length >= 2) out.add(current);
      current = <Offset>[];
      continue;
    }
    final ca = Offset(a.dx + dx * t0, a.dy + dy * t0);
    final cb = Offset(a.dx + dx * t1, a.dy + dy * t1);
    if (current.isEmpty || (current.last - ca).distance > 1e-9) {
      if (current.length >= 2) out.add(current);
      current = <Offset>[ca];
    }
    current.add(cb);
  }
  if (current.length >= 2) out.add(current);
  return out;
}

/// チャンク 1 つぶんの面の三角形をまとめた束（色は頂点ごと）。
/// 面ごとに drawVertices を呼ぶと 1 万面で 1 フレーム数千回になるので、チャンクごとに 1 回にする
class PolygonBatch {
  PolygonBatch(this.xyz, this.colors) : projected = Float32List(xyz.length ~/ 3 * 2);

  /// 頂点の x, y, z（三角形数 × 9）
  final Float32List xyz;

  /// 頂点ごとの色（ARGB、三角形数 × 3）
  final Int32List colors;

  /// 投影した画面座標（毎フレーム上書き）
  final Float32List projected;

  /// [batches] を 1 本につなぐ
  static PolygonBatch concat(List<PolygonBatch> batches) {
    if (batches.length == 1) return batches.first;
    var n = 0;
    for (final b in batches) {
      n += b.xyz.length;
    }
    final xyz = Float32List(n);
    final colors = Int32List(n ~/ 3);
    var o = 0;
    for (final b in batches) {
      xyz.setRange(o, o + b.xyz.length, b.xyz);
      colors.setRange(o ~/ 3, o ~/ 3 + b.colors.length, b.colors);
      o += b.xyz.length;
    }
    return PolygonBatch(xyz, colors);
  }

  /// [polygons] の [from] 番目以降をチャンク番号ごとにまとめる
  static Map<int, PolygonBatch> byChunk(List<LiftedPolygon> polygons, {int from = 0}) {
    final xyzs = <int, List<Float32List>>{};
    final counts = <int, int>{};
    for (var i = from; i < polygons.length; i++) {
      final p = polygons[i];
      for (final e in p.byChunk.entries) {
        (xyzs[e.key] ??= []).add(e.value);
        counts[e.key] = (counts[e.key] ?? 0) + e.value.length;
      }
    }
    final out = <int, PolygonBatch>{};
    for (final e in xyzs.entries) {
      final xyz = Float32List(counts[e.key]!);
      final colors = Int32List(counts[e.key]! ~/ 3);
      var o = 0;
      var v = 0;
      for (var i = from; i < polygons.length; i++) {
        final p = polygons[i];
        final src = p.byChunk[e.key];
        if (src == null) continue;
        xyz.setRange(o, o + src.length, src);
        o += src.length;
        final argb = p.color.toARGB32();
        final nv = src.length ~/ 3;
        colors.fillRange(v, v + nv, argb);
        v += nv;
      }
      out[e.key] = PolygonBatch(xyz, colors);
    }
    return out;
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

  /// [clipCells] は面を切り分ける格子の粗さ（DEM セルの倍数）。
  /// 4.8m の DEM で 1 だと 500m 四方の林班が 1 万片になる。4 なら 1/16 で、見た目の差はほぼ無い
  static LiftedPolygon lift(List<Offset> ring, TerrainMesh mesh, {required Color color, int clipCells = 1}) {
    final dem = mesh.dem;
    final cell = dem.cellSize * mesh.step * clipCells;
    final out = <double>[];
    final cells = <int>[];
    for (final tri in earClip(ring)) {
      // 三角形の bbox に掛かるセルを走査
      final (t0, t1, t2) = (tri[0], tri[1], tri[2]);
      // 格子の外（タイルの外）は作らない
      final maxC = (dem.width / cell).ceil() - 1;
      final maxR = (dem.height / cell).ceil() - 1;
      final c0 = (math.min(math.min(t0.dx, t1.dx), t2.dx) / cell).floor().clamp(0, maxC);
      final c1 = (math.max(math.max(t0.dx, t1.dx), t2.dx) / cell).floor().clamp(0, maxC);
      final r0 = (math.min(math.min(t0.dy, t1.dy), t2.dy) / cell).floor().clamp(0, maxR);
      final r1 = (math.max(math.max(t0.dy, t1.dy), t2.dy) / cell).floor().clamp(0, maxR);
      for (var r = r0; r <= r1; r++) {
        for (var c = c0; c <= c1; c++) {
          final rect = Rect.fromLTWH(c * cell, r * cell, cell, cell);
          final piece = clipToRect(tri, rect);
          if (piece.length < 3) continue;
          final ci = mesh.cellIndexAt(rect.center.dx, rect.center.dy);
          void addVertex(Offset p) {
            out
              ..add(p.dx)
              ..add(p.dy)
              ..add(dem.elevationAtLocal(p.dx, p.dy));
          }

          // 三角形 ∩ 矩形は凸なので扇状に分ける
          for (var k = 1; k + 1 < piece.length; k++) {
            addVertex(piece[0]);
            addVertex(piece[k]);
            addVertex(piece[k + 1]);
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
          a.dx, a.dy, dem.elevationAtLocal(a.dx, a.dy),
          b.dx, b.dy, dem.elevationAtLocal(b.dx, b.dy),
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
}

/// 地形に乗せるラベル（ビルボード）
class TerrainLabel {
  /// [painter] を渡さなければ [text] と [style] から**描くときに**作る（1 万ラベルの layout を貼り付け時にやらない）
  TerrainLabel({required this.x, required this.y, TextPainter? painter, String? text, this.style, this.markerGap})
      : _painter = painter,
        text = text ?? painter?.text?.toPlainText() ?? '';

  /// DEM 原点基準の Mercator m
  final double x;
  final double y;
  final String text;
  final TextStyle? style;

  /// 点の印に付くラベル: 印の半径＋すき間（論理 px）。印があるので位置の黒点は打たず、ラベルを印の上に離して置く。
  /// null は面・線のラベル（重心や中点に黒点を打ち、その上に置く）
  final double? markerGap;
  TextPainter? _painter;

  /// layout 済みか（描画側は 1 フレームに新しく layout する数を絞る）
  bool get isLaidOut => _painter != null;

  TextPainter get painter => _painter ??= TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
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
