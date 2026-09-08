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
import 'dart:ui';

import 'dem_grid.dart';
import 'terrain_camera.dart';

/// 奥行き順に並んだセルのひとかたまり
///
/// 帯ごとに `drawVertices` を 1 回呼び、その帯に落ちるベクタを続けて描くことで
/// 深度バッファなしに前後関係を出す（[TerrainMesh] 参照）。
class TerrainMeshBand {
  TerrainMeshBand({required this.vertices, required this.cellCount});

  /// `Vertices.raw` で組んだ三角形（テクスチャ座標・陰影色つき）
  final Vertices vertices;

  final int cellCount;
}

/// 組み立て時間の内訳（計測用）
class TerrainMeshTiming {
  const TerrainMeshTiming({
    required this.project,
    required this.sort,
    required this.assemble,
    required this.resorted,
  });

  final Duration project;
  final Duration sort;
  final Duration assemble;

  /// 並び替えをやり直したか（角度がしきい値を超えたとき）
  final bool resorted;

  Duration get total => project + sort + assemble;

  @override
  String toString() =>
      'proj=${project.inMilliseconds} sort=${sort.inMilliseconds} '
      'asm=${assemble.inMilliseconds}${resorted ? ' resort' : ''}';
}

/// DEM 格子を painter's algorithm 用に並べた三角形メッシュ
///
/// 正射影で視点が地表より上なら、標高場は xy の関数なので
/// 「遠いセルから順に描く」だけで隠面処理が正しく出る。
/// あるセルを隠せるのは、視線の地上投影に沿って手前にあるセルだけなので、
/// **行を奥から手前へ、行内も奥から手前へ**と格子をなぞる順で十分。
/// 並び順は [TerrainCamera.bearing] の象限（4 通り）だけで決まり、
/// pitch / pan / zoom では変わらない。ソートは要らない。
class TerrainMesh {
  TerrainMesh._({
    required this.bands,
    required this.cellBand,
    required this.dem,
    required this.step,
    required this.timing,
  });

  final List<TerrainMeshBand> bands;

  /// 間引き後のセル番号 → 帯番号（ベクタを帯に振り分けるため）
  final Uint16List cellBand;

  final DemGrid dem;

  /// 格子の間引き（1 = 全点、2 = 1 つ飛ばし）
  final int step;

  final TerrainMeshTiming timing;

  /// 組み立てに掛かった時間（計測用）
  Duration get buildTime => timing.total;

  /// 単発で組む（テスト・簡易用）。連続で組むなら [TerrainMeshBuilder] を持つ
  static TerrainMesh build(
    DemGrid dem,
    TerrainCamera camera, {
    required int textureWidth,
    required int textureHeight,
    int cellsPerBand = 4000,
    int step = 1,
  }) {
    return TerrainMeshBuilder(
      dem,
      textureWidth: textureWidth,
      textureHeight: textureHeight,
      cellsPerBand: cellsPerBand,
      step: step,
    ).build(camera);
  }

  int get _cellCols => (dem.cols - 1) ~/ step;
  int get _cellRows => (dem.rows - 1) ~/ step;

  /// 世界座標（DEM 原点基準）の間引き後セル番号。格子外は端に寄せる
  int cellIndexAt(double x, double y) {
    final size = dem.cellSize * step;
    final c = (x / size).floor().clamp(0, _cellCols - 1);
    final r = (y / size).floor().clamp(0, _cellRows - 1);
    return r * _cellCols + c;
  }
}

/// [TerrainMesh] を繰り返し組むための作業台
///
/// カメラに依らないもの（間引き格子・陰影色・テクスチャ座標）は最初に 1 回だけ計算し、
/// 毎回やるのは投影と帯の組み立てだけ。並び順（象限走査）とそれに沿った
/// テクスチャ座標・色・インデックスは、方位の象限が変わったときだけ作り直す。
class TerrainMeshBuilder {
  TerrainMeshBuilder(
    this.dem, {
    required int textureWidth,
    required int textureHeight,
    this.cellsPerBand = 16000,
    this.step = 1,
    int lightAzimuthDeg = 315,
    int lightAltitudeDeg = 45,
  })  : cols = (dem.cols - 1) ~/ step + 1,
        rows = (dem.rows - 1) ~/ step + 1 {
    final cell = dem.cellSize * step;
    _cellSize = cell;
    // 間引いた標高
    _heights = Float32List(cols * rows);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        _heights[r * cols + c] = dem.heightAtIndex(c * step, r * step);
      }
    }
    final cellCols = cols - 1;
    final cellRows = rows - 1;
    _cellCount = cellCols * cellRows;
    _cellColor = Int32List(_cellCount);
    _cellTex = Float32List(_cellCount * 8);
    _px = Float32List(cols * rows);
    _py = Float32List(cols * rows);
    _order = Int32List(_cellCount);
    _cellBand = Uint16List(_cellCount);

    final az = lightAzimuthDeg * math.pi / 180;
    final alt = lightAltitudeDeg * math.pi / 180;
    final lx = math.sin(az) * math.cos(alt);
    final ly = math.cos(az) * math.cos(alt);
    final lz = math.sin(alt);
    final texSx = textureWidth / dem.width;
    final texSy = textureHeight / dem.height;
    for (var r = 0; r < cellRows; r++) {
      for (var c = 0; c < cellCols; c++) {
        final ci = r * cellCols + c;
        final i00 = r * cols + c;
        final h00 = _heights[i00];
        final h10 = _heights[i00 + 1];
        final h01 = _heights[i00 + cols];
        final h11 = _heights[i00 + cols + 1];
        // 陰影: 対角の差分から法線
        final nx = -((h10 + h11) - (h00 + h01)) / (2 * cell);
        final ny = -((h01 + h11) - (h00 + h10)) / (2 * cell);
        final len = math.sqrt(nx * nx + ny * ny + 1);
        final dot = (nx * lx + ny * ly + lz) / len;
        final shade = (0.35 + 0.65 * dot.clamp(0.0, 1.0)).clamp(0.0, 1.0);
        final g = (shade * 255).round();
        _cellColor[ci] = 0xFF000000 | (g << 16) | (g << 8) | g;
        // テクスチャ座標（画像は北が上なので v を反転）
        final u0 = c * cell * texSx;
        final u1 = (c + 1) * cell * texSx;
        final t0 = textureHeight - r * cell * texSy;
        final t1 = textureHeight - (r + 1) * cell * texSy;
        final t = ci * 8;
        _cellTex[t] = u0;
        _cellTex[t + 1] = t0;
        _cellTex[t + 2] = u1;
        _cellTex[t + 3] = t0;
        _cellTex[t + 4] = u0;
        _cellTex[t + 5] = t1;
        _cellTex[t + 6] = u1;
        _cellTex[t + 7] = t1;
      }
    }
  }

  final DemGrid dem;
  final int cellsPerBand;
  final int step;

  /// 間引き後の格子点数
  final int cols;
  final int rows;

  late final double _cellSize;
  late final Float32List _heights;
  late final int _cellCount;
  late final Int32List _cellColor;
  late final Float32List _cellTex;
  late final Float32List _px;
  late final Float32List _py;
  late final Int32List _order;
  late final Uint16List _cellBand;

  // 並び順に沿って並べ直した帯ごとの静的配列（象限が変わったときだけ作り直す）
  List<Float32List>? _bandTex;
  List<Int32List>? _bandColors;
  List<Uint16List>? _bandIndices;
  int? _orderedQuadrant;

  TerrainMesh build(TerrainCamera camera) {
    final sw = Stopwatch()..start();
    final cell = _cellSize;
    final cellCols = cols - 1;

    // 1. 格子点の投影座標（倍率 1・DEM 原点基準）
    final cosB = math.cos(camera.bearing);
    final sinB = math.sin(camera.bearing);
    final cosP = math.cos(camera.pitch);
    final sinP = math.sin(camera.pitch);
    final zk = camera.zScale * sinP;
    for (var r = 0; r < rows; r++) {
      final y = r * cell;
      final ySin = y * sinB;
      final yCos = y * cosB;
      for (var c = 0; c < cols; c++) {
        final i = r * cols + c;
        final x = c * cell;
        _px[i] = x * cosB - ySin;
        _py[i] = -((x * sinB + yCos) * cosP + _heights[i] * zk);
      }
    }
    final tProject = sw.elapsed;

    // 2. 並び順（象限が変わったときだけ）
    final quadrant = _quadrantOf(sinB, cosB);
    final needResort = _orderedQuadrant != quadrant;
    if (needResort) {
      _reorder(quadrant, cellCols);
      _orderedQuadrant = quadrant;
    }
    final tSort = sw.elapsed - tProject;

    // 3. 帯ごとに位置だけ詰めて Vertices を組む
    final bands = <TerrainMeshBand>[];
    var pos = 0;
    var b = 0;
    while (pos < _cellCount) {
      final n = math.min(cellsPerBand, _cellCount - pos);
      final positions = Float32List(n * 8);
      for (var k = 0; k < n; k++) {
        final ci = _order[pos + k];
        final c = ci % cellCols;
        final r = ci ~/ cellCols;
        final i00 = r * cols + c;
        final v = k * 8;
        positions[v] = _px[i00];
        positions[v + 1] = _py[i00];
        positions[v + 2] = _px[i00 + 1];
        positions[v + 3] = _py[i00 + 1];
        positions[v + 4] = _px[i00 + cols];
        positions[v + 5] = _py[i00 + cols];
        positions[v + 6] = _px[i00 + cols + 1];
        positions[v + 7] = _py[i00 + cols + 1];
      }
      bands.add(
        TerrainMeshBand(
          vertices: Vertices.raw(
            VertexMode.triangles,
            positions,
            textureCoordinates: _bandTex![b],
            colors: _bandColors![b],
            indices: _bandIndices![b],
          ),
          cellCount: n,
        ),
      );
      pos += n;
      b++;
    }
    final tAssemble = sw.elapsed - tProject - tSort;
    return TerrainMesh._(
      bands: bands,
      cellBand: _cellBand,
      dem: dem,
      step: step,
      timing: TerrainMeshTiming(
        project: tProject,
        sort: tSort,
        assemble: tAssemble,
        resorted: needResort,
      ),
    );
  }

  /// 視線の地上投影の向きから象限を決める
  ///
  /// 画面上向き（遠ざかる向き）の世界ベクトルは (sinB, cosB)。
  /// bit0: 東向き成分が正（東が遠い）、bit1: 北向き成分が正（北が遠い）
  static int _quadrantOf(double sinB, double cosB) =>
      (sinB > 0 ? 1 : 0) | (cosB > 0 ? 2 : 0);

  /// 象限走査で並び順を作り、帯ごとの静的配列を並べ直す
  ///
  /// 遠い側の行から手前の行へ、行内も遠い側の列から手前の列へ。
  /// 行と列のどちらを外側にしても正しいが、ここでは行（南北）を外側にする。
  void _reorder(int quadrant, int cellCols) {
    final cellRows = _cellCount ~/ cellCols;
    final eastFar = (quadrant & 1) != 0;
    final northFar = (quadrant & 2) != 0;
    var k = 0;
    for (var rr = 0; rr < cellRows; rr++) {
      final r = northFar ? cellRows - 1 - rr : rr;
      for (var cc = 0; cc < cellCols; cc++) {
        final c = eastFar ? cellCols - 1 - cc : cc;
        _order[k++] = r * cellCols + c;
      }
    }

    // 帯ごとの静的配列を並び順で作り直す
    final tex = <Float32List>[];
    final colors = <Int32List>[];
    final indices = <Uint16List>[];
    var pos = 0;
    var b = 0;
    while (pos < _cellCount) {
      final n = math.min(cellsPerBand, _cellCount - pos);
      final bt = Float32List(n * 8);
      final bc = Int32List(n * 4);
      final bi = Uint16List(n * 6);
      for (var k = 0; k < n; k++) {
        final ci = _order[pos + k];
        _cellBand[ci] = b;
        bt.setRange(k * 8, k * 8 + 8, _cellTex, ci * 8);
        final argb = _cellColor[ci];
        final v = k * 4;
        bc[v] = argb;
        bc[v + 1] = argb;
        bc[v + 2] = argb;
        bc[v + 3] = argb;
        final t = k * 6;
        bi[t] = v;
        bi[t + 1] = v + 1;
        bi[t + 2] = v + 2;
        bi[t + 3] = v + 1;
        bi[t + 4] = v + 3;
        bi[t + 5] = v + 2;
      }
      tex.add(bt);
      colors.add(bc);
      indices.add(bi);
      pos += n;
      b++;
    }
    _bandTex = tex;
    _bandColors = colors;
    _bandIndices = indices;
  }
}
