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

import '../terrain_painter.dart';

/// [buildMipChain] の引数（isolate へ送る）
class MipChainArgs {
  const MipChainArgs({required this.rgba, required this.width, required this.height});

  /// premultiplied RGBA（`ui.Image.toByteData(rawRgba)` の中身）
  final Uint8List rgba;
  final int width;
  final int height;
}

/// テクスチャのミップ段（1 段目以降。0 段目 = 元画像は含まない）を 2×2 の平均で作る
///
/// 段数は `Texture.fullMipCount` と同じ（1 × 1 まで）。premultiplied なので単純平均で正しい。
/// 512² で 10 段・合計 0.33 倍のバイト数。isolate で回す前提（`TerrainWorker.instance.run(buildMipChain, args)`）
List<Uint8List> buildMipChain(MipChainArgs a) {
  final out = <Uint8List>[];
  var src = a.rgba;
  var w = a.width;
  var h = a.height;
  while (w > 1 || h > 1) {
    final nw = math.max(1, w >> 1);
    final nh = math.max(1, h >> 1);
    final dst = Uint8List(nw * nh * 4);
    var o = 0;
    for (var y = 0; y < nh; y++) {
      final y0 = math.min(y * 2, h - 1) * w;
      final y1 = math.min(y * 2 + 1, h - 1) * w;
      for (var x = 0; x < nw; x++) {
        final x0 = math.min(x * 2, w - 1);
        final x1 = math.min(x * 2 + 1, w - 1);
        final p00 = (y0 + x0) * 4;
        final p01 = (y0 + x1) * 4;
        final p10 = (y1 + x0) * 4;
        final p11 = (y1 + x1) * 4;
        for (var c = 0; c < 4; c++) {
          dst[o + c] = (src[p00 + c] + src[p01 + c] + src[p10 + c] + src[p11 + c] + 2) >> 2;
        }
        o += 4;
      }
    }
    out.add(dst);
    src = dst;
    w = nw;
    h = nh;
  }
  return out;
}

/// GPU に上げる頂点列の組み立て（純 Dart。`package:flutter_gpu` に依らないのでテストとweb でも読める）
///
/// 頂点の並びはシェーダ（`shaders/*.vert`）の入力と 1 対 1。座標はタイルの DEM 原点基準の Mercator m。
/// 投影はシェーダ側の mvp が毎フレームやるので、ここで作る配列はカメラに依らず、タイルが生きている間は使い回す。

/// 地形（DEM 格子 + スカート）の頂点列
///
/// 頂点 = position(3) + uv(2) + shade(1) = 24 バイト。インデックスは 32bit（257² = 66,049 頂点は 16bit に収まらない）
class GpuTerrainGeometry {
  GpuTerrainGeometry._({
    required this.vertices,
    required this.indices,
    required this.vertexCount,
    required this.minZ,
    required this.maxZ,
  });

  static const floatsPerVertex = 6;
  static const strideInBytes = floatsPerVertex * 4;

  final Float32List vertices;
  final Uint32List indices;
  final int vertexCount;
  int get indexCount => indices.length;

  /// 標高の範囲（深度の正規化用）
  final double minZ;
  final double maxZ;

  /// [heights] は南から北へ行が進む `rows × cols`（間引き済み）。[shade] は頂点ごとの陰影（0〜1）。
  /// uv は DEM の全幅 [width] × [height] で正規化（画像は北が上なので v を反転）。
  /// [skirtDepth] > 0 なら 4 辺の縁から真下に垂らした壁を足す（段が違う隣との裂け目を隠す）
  static GpuTerrainGeometry build({
    required Float32List heights,
    required int cols,
    required int rows,
    required double cellSize,
    required double width,
    required double height,
    required Float32List shade,
    double skirtDepth = 0,
  }) {
    assert(heights.length == cols * rows && shade.length == cols * rows);
    final gridVertices = cols * rows;
    final edgeCount = skirtDepth > 0 ? 2 * (cols + rows) : 0;
    final total = gridVertices + edgeCount * 2;
    final data = Float32List(total * floatsPerVertex);
    var o = 0;
    var minZ = double.infinity;
    var maxZ = -double.infinity;
    final invW = width > 0 ? 1 / width : 0.0;
    final invH = height > 0 ? 1 / height : 0.0;
    for (var r = 0; r < rows; r++) {
      final y = r * cellSize;
      final v = 1 - y * invH;
      for (var c = 0; c < cols; c++) {
        final x = c * cellSize;
        final h = heights[r * cols + c];
        data[o] = x;
        data[o + 1] = y;
        data[o + 2] = h;
        data[o + 3] = x * invW;
        data[o + 4] = v;
        data[o + 5] = shade[r * cols + c];
        o += floatsPerVertex;
        if (h < minZ) minZ = h;
        if (h > maxZ) maxZ = h;
      }
    }
    final cellCols = cols - 1;
    final cellRows = rows - 1;
    final quadCount = cellCols * cellRows + (edgeCount > 0 ? edgeCount - 1 : 0);
    final indices = Uint32List(quadCount * 6);
    var k = 0;
    for (var r = 0; r < cellRows; r++) {
      for (var c = 0; c < cellCols; c++) {
        final sw = r * cols + c;
        final se = sw + 1;
        final nw = sw + cols;
        final ne = nw + 1;
        indices[k++] = sw;
        indices[k++] = se;
        indices[k++] = nw;
        indices[k++] = se;
        indices[k++] = ne;
        indices[k++] = nw;
      }
    }
    if (edgeCount > 0) {
      // 縁を南辺 → 東辺 → 北辺 → 西辺と一周（TerrainMeshBuilder._buildSkirt と同じ並び）
      final edge = <(int, int)>[];
      for (var c = 0; c < cols; c++) {
        edge.add((c, 0));
      }
      for (var r = 0; r < rows; r++) {
        edge.add((cols - 1, r));
      }
      for (var c = cols - 1; c >= 0; c--) {
        edge.add((c, rows - 1));
      }
      for (var r = rows - 1; r >= 0; r--) {
        edge.add((0, r));
      }
      assert(edge.length == edgeCount);
      final base = gridVertices;
      for (var i = 0; i < edgeCount; i++) {
        final (c, r) = edge[i];
        final x = c * cellSize;
        final y = r * cellSize;
        final h = heights[r * cols + c];
        final u = x * invW;
        final v = 1 - y * invH;
        // 上（縁と同じ点）と下（skirtDepth 下）。テクスチャは縁の色を引き伸ばし、壁は暗くする
        // （shade はオーバーレイ用のグレー。0.5 で変化なし）
        data[o] = x;
        data[o + 1] = y;
        data[o + 2] = h;
        data[o + 3] = u;
        data[o + 4] = v;
        data[o + 5] = 0.35;
        data[o + 6] = x;
        data[o + 7] = y;
        data[o + 8] = h - skirtDepth;
        data[o + 9] = u;
        data[o + 10] = v;
        data[o + 11] = 0.25;
        o += floatsPerVertex * 2;
        if (i + 1 < edgeCount) {
          final t0 = base + i * 2;
          final b0 = t0 + 1;
          final t1 = t0 + 2;
          final b1 = t0 + 3;
          indices[k++] = t0;
          indices[k++] = t1;
          indices[k++] = b0;
          indices[k++] = t1;
          indices[k++] = b1;
          indices[k++] = b0;
        }
      }
    }
    assert(k == indices.length);
    return GpuTerrainGeometry._(
      vertices: data,
      indices: indices,
      vertexCount: total,
      minZ: minZ.isFinite ? minZ : 0,
      maxZ: maxZ.isFinite ? maxZ : 0,
    );
  }
}

/// 面の束の頂点列: position(3) + rgba(4)（straight alpha、シェーダで premultiply）= 28 バイト
class GpuPolygonGeometry {
  static const floatsPerVertex = 7;
  static const strideInBytes = floatsPerVertex * 4;

  /// [batches] を 1 本の頂点列に。戻り値の長さは 頂点数 × 7
  static Float32List pack(Iterable<PolygonBatch> batches) {
    var n = 0;
    for (final b in batches) {
      n += b.colors.length;
    }
    final data = Float32List(n * floatsPerVertex);
    var o = 0;
    for (final b in batches) {
      final xyz = b.xyz;
      final colors = b.colors;
      for (var v = 0; v < colors.length; v++) {
        final argb = colors[v];
        data[o] = xyz[v * 3];
        data[o + 1] = xyz[v * 3 + 1];
        data[o + 2] = xyz[v * 3 + 2];
        data[o + 3] = ((argb >> 16) & 0xFF) / 255;
        data[o + 4] = ((argb >> 8) & 0xFF) / 255;
        data[o + 5] = (argb & 0xFF) / 255;
        data[o + 6] = ((argb >> 24) & 0xFF) / 255;
        o += floatsPerVertex;
      }
    }
    return data;
  }

  static int vertexCountOf(Float32List packed) => packed.length ~/ floatsPerVertex;

  /// [polygons] の [from] 番目以降を 1 本の頂点列に（束を経由しない。色は面ごと）
  static Float32List packPolygons(List<LiftedPolygon> polygons, {int from = 0}) {
    var n = 0;
    for (var i = from; i < polygons.length; i++) {
      n += polygons[i].xyz.length ~/ 3;
    }
    final data = Float32List(n * floatsPerVertex);
    var o = 0;
    for (var i = from; i < polygons.length; i++) {
      final p = polygons[i];
      final xyz = p.xyz;
      final c = p.color;
      final r = c.r, g = c.g, b = c.b, a = c.a;
      for (var v = 0; v + 2 < xyz.length; v += 3) {
        data[o] = xyz[v];
        data[o + 1] = xyz[v + 1];
        data[o + 2] = xyz[v + 2];
        data[o + 3] = r;
        data[o + 4] = g;
        data[o + 5] = b;
        data[o + 6] = a;
        o += floatsPerVertex;
      }
    }
    return data;
  }
}

/// 線の頂点列。線分 1 本 = 頂点 4 つ（両端 × 左右）+ インデックス 6 つ。
/// 太さは頂点シェーダが画面空間で付ける（`shaders/line.vert`）。
///
/// 頂点 = a(3) + b(3) + t(1) + side(1) + width(1) + rgba(4) = 52 バイト。
/// a, b は線分の両端（タイルの DEM 原点基準）、t は自分がどちらの端か（0 = a、1 = b）、side は左右（±1）、
/// width は論理 px（シェーダで pixelRatio を掛ける）
class GpuLineGeometry {
  GpuLineGeometry._(this.vertices, this.indices, this.segmentCount);

  static const floatsPerVertex = 13;
  static const strideInBytes = floatsPerVertex * 4;

  final Float32List vertices;
  final Uint32List indices;
  final int segmentCount;
  int get vertexCount => segmentCount * 4;
  int get indexCount => indices.length;
  bool get isEmpty => segmentCount == 0;

  /// 折れ線（[LiftedPolyline]: 点の並び）と線分の集合（[LiftedSegments]: 2 点ずつ）をまとめて 1 本に
  static GpuLineGeometry pack({
    Iterable<LiftedPolyline> polylines = const [],
    Iterable<LiftedSegments> segmentSets = const [],
  }) {
    var segments = 0;
    for (final l in polylines) {
      segments += l.pointCount > 1 ? l.pointCount - 1 : 0;
    }
    for (final s in segmentSets) {
      for (final buf in s.byChunk.values) {
        segments += buf.length ~/ 6;
      }
    }
    final data = Float32List(segments * 4 * floatsPerVertex);
    final indices = Uint32List(segments * 6);
    var seg = 0;
    void addSegment(
      double ax, double ay, double az,
      double bx, double by, double bz,
      double width, double r, double g, double b, double a,
    ) {
      var o = seg * 4 * floatsPerVertex;
      for (var corner = 0; corner < 4; corner++) {
        data[o] = ax;
        data[o + 1] = ay;
        data[o + 2] = az;
        data[o + 3] = bx;
        data[o + 4] = by;
        data[o + 5] = bz;
        data[o + 6] = corner >= 2 ? 1 : 0; // t
        data[o + 7] = (corner & 1) == 0 ? -1 : 1; // side
        data[o + 8] = width;
        data[o + 9] = r;
        data[o + 10] = g;
        data[o + 11] = b;
        data[o + 12] = a;
        o += floatsPerVertex;
      }
      final v0 = seg * 4;
      final i0 = seg * 6;
      indices[i0] = v0;
      indices[i0 + 1] = v0 + 1;
      indices[i0 + 2] = v0 + 2;
      indices[i0 + 3] = v0 + 1;
      indices[i0 + 4] = v0 + 3;
      indices[i0 + 5] = v0 + 2;
      seg++;
    }

    for (final l in polylines) {
      final xyz = l.xyz;
      final n = l.pointCount;
      final c = l.color;
      for (var i = 0; i + 1 < n; i++) {
        addSegment(
          xyz[i * 3], xyz[i * 3 + 1], xyz[i * 3 + 2],
          xyz[i * 3 + 3], xyz[i * 3 + 4], xyz[i * 3 + 5],
          l.widthPx, c.r, c.g, c.b, c.a,
        );
      }
    }
    for (final s in segmentSets) {
      final c = s.color;
      for (final buf in s.byChunk.values) {
        for (var i = 0; i + 5 < buf.length; i += 6) {
          addSegment(buf[i], buf[i + 1], buf[i + 2], buf[i + 3], buf[i + 4], buf[i + 5], s.widthPx, c.r, c.g, c.b, c.a);
        }
      }
    }
    assert(seg == segments);
    return GpuLineGeometry._(data, indices, segments);
  }
}
