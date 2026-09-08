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

/// 奥行き順に並んだセルのひとかたまり（= チャンク 1 つ）
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

  /// 投影（チャンクごとの位置配列の計算）
  final Duration project;

  /// 象限が変わったときのインデックス・並び順の作り直し
  final Duration sort;

  /// `Vertices.raw` の生成
  final Duration assemble;

  /// 並び順をやり直したか（象限が変わったとき）
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
///
/// 格子は [TerrainMeshBuilder.chunkSize] セル角のチャンクに分け、チャンクを
/// 象限走査の順に描く。チャンク内も同じ走査順。チャンク単位なら頂点を
/// 隣のセルと共有でき（`Vertices.raw` の index は 16bit なので 1 チャンク ≤ 65535 頂点）、
/// 毎フレームのコピー量がセルごとの複製より 5 倍ほど減る。
class TerrainMesh {
  TerrainMesh._({
    required this.bands,
    required this.cellBand,
    required this.bandChunk,
    required this.chunkSize,
    required this.chunkCols,
    required this.dem,
    required this.step,
    required this.timing,
    this.skirt,
  });

  /// タイルの縁から [TerrainMeshBuilder.skirtDepth] だけ下に垂らした壁（4 辺）。
  /// 段が違う隣との裂け目を隠す。地形より先に描く（縁の下に見えるのはこれだけ）
  final Vertices? skirt;

  /// 描画順に並んだチャンク
  final List<TerrainMeshBand> bands;

  /// 間引き後のセル番号 → 帯番号（ベクタを帯に振り分けるため）
  final Uint16List cellBand;

  /// 帯番号 → チャンク番号（静的な並び。象限に依らないので、面の三角形はこれで束ねておく）
  final Int32List bandChunk;

  /// チャンクの一辺（セル数）と横方向のチャンク数
  final int chunkSize;
  final int chunkCols;

  /// GPU 側の頂点バッファを返す（捨てるタイルのメッシュはこれを呼ぶ。忘れると Graphics メモリが溜まる）
  void dispose() {
    skirt?.dispose();
    for (final b in bands) {
      b.vertices.dispose();
    }
  }

  /// 間引き後のセル番号 → チャンク番号（静的）
  int chunkOfCell(int cellIndex) {
    final c = cellIndex % _cellCols;
    final r = cellIndex ~/ _cellCols;
    return (r ~/ chunkSize) * chunkCols + (c ~/ chunkSize);
  }

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
    int chunkSize = 32,
    int step = 1,
  }) {
    return TerrainMeshBuilder(
      dem,
      textureWidth: textureWidth,
      textureHeight: textureHeight,
      chunkSize: chunkSize,
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

/// チャンク 1 つぶんの静的データ
class _Chunk {
  _Chunk({
    required this.c0,
    required this.r0,
    required this.cellCols,
    required this.cellRows,
    required this.texCoords,
    required this.colors,
  }) : positions = Float32List((cellCols + 1) * (cellRows + 1) * 2);

  /// 左下セルの格子座標
  final int c0;
  final int r0;
  final int cellCols;
  final int cellRows;
  int get vertexCols => cellCols + 1;
  int get vertexRows => cellRows + 1;
  int get cellCount => cellCols * cellRows;

  final Float32List texCoords;
  final Int32List colors;

  /// 投影座標（毎フレーム書き換える。`Vertices.raw` がコピーするので使い回してよい）
  final Float32List positions;

  /// 象限ごとのインデックス（走査順）。使うときに作る
  final List<Uint16List?> indicesByQuadrant = List.filled(4, null);

  Uint16List indicesFor(int quadrant) {
    final cached = indicesByQuadrant[quadrant];
    if (cached != null) return cached;
    final eastFar = (quadrant & 1) != 0;
    final northFar = (quadrant & 2) != 0;
    final idx = Uint16List(cellCount * 6);
    var k = 0;
    for (var rr = 0; rr < cellRows; rr++) {
      final r = northFar ? cellRows - 1 - rr : rr;
      for (var cc = 0; cc < cellCols; cc++) {
        final c = eastFar ? cellCols - 1 - cc : cc;
        final v00 = r * vertexCols + c;
        final v10 = v00 + 1;
        final v01 = v00 + vertexCols;
        final v11 = v01 + 1;
        idx[k++] = v00;
        idx[k++] = v10;
        idx[k++] = v01;
        idx[k++] = v10;
        idx[k++] = v11;
        idx[k++] = v01;
      }
    }
    indicesByQuadrant[quadrant] = idx;
    return idx;
  }
}

/// [TerrainMeshBuilder.buildInIsolate] の引数
class TerrainMeshBuilderArgs {
  const TerrainMeshBuilderArgs({
    required this.dem,
    required this.textureWidth,
    required this.textureHeight,
    this.chunkSize = 32,
    this.step = 1,
    this.skirtDepth = 0,
  });

  final DemGrid dem;
  final int textureWidth;
  final int textureHeight;
  final int chunkSize;
  final int step;
  final double skirtDepth;
}

/// [TerrainMesh] を繰り返し組むための作業台
///
/// カメラに依らないもの（間引き格子・頂点の陰影色・テクスチャ座標・チャンク分割）は
/// 最初に 1 回だけ計算し、毎回やるのは投影と `Vertices.raw` の生成だけ。
/// 並び順（象限走査）とインデックスは方位の象限が変わったときだけ作り直す。
class TerrainMeshBuilder {
  TerrainMeshBuilder(
    this.dem, {
    required int textureWidth,
    required int textureHeight,
    this.chunkSize = 32,
    this.step = 1,
    this.skirtDepth = 0,
    int lightAzimuthDeg = 315,
    int lightAltitudeDeg = 45,
  })  : cols = (dem.cols - 1) ~/ step + 1,
        rows = (dem.rows - 1) ~/ step + 1,
        assert(chunkSize > 0 && (chunkSize + 1) * (chunkSize + 1) <= 65536) {
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
    _cellCols = cellCols;
    _cellCount = cellCols * cellRows;
    _cellBand = Uint16List(_cellCount);

    // 頂点ごとの陰影（中央差分の法線 × 光源）
    final az = lightAzimuthDeg * math.pi / 180;
    final alt = lightAltitudeDeg * math.pi / 180;
    final lx = math.sin(az) * math.cos(alt);
    final ly = math.cos(az) * math.cos(alt);
    final lz = math.sin(alt);
    final vertexColor = Int32List(cols * rows);
    for (var r = 0; r < rows; r++) {
      final rS = r == 0 ? 0 : r - 1;
      final rN = r == rows - 1 ? rows - 1 : r + 1;
      for (var c = 0; c < cols; c++) {
        final cW = c == 0 ? 0 : c - 1;
        final cE = c == cols - 1 ? cols - 1 : c + 1;
        final nx = -(_heights[r * cols + cE] - _heights[r * cols + cW]) / ((cE - cW) * cell);
        final ny = -(_heights[rN * cols + c] - _heights[rS * cols + c]) / ((rN - rS) * cell);
        final len = math.sqrt(nx * nx + ny * ny + 1);
        final dot = (nx * lx + ny * ly + lz) / len;
        final shade = (0.35 + 0.65 * dot.clamp(0.0, 1.0)).clamp(0.0, 1.0);
        final g = (shade * 255).round();
        vertexColor[r * cols + c] = 0xFF000000 | (g << 16) | (g << 8) | g;
      }
    }

    // チャンク分割（左下から東・北へ）
    final texSx = textureWidth / dem.width;
    final texSy = textureHeight / dem.height;
    _texW = textureWidth.toDouble();
    _texH = textureHeight.toDouble();
    _chunkCols = (cellCols + chunkSize - 1) ~/ chunkSize;
    _chunkRows = (cellRows + chunkSize - 1) ~/ chunkSize;
    _chunks = <_Chunk>[];
    for (var cr = 0; cr < _chunkRows; cr++) {
      for (var cc = 0; cc < _chunkCols; cc++) {
        final c0 = cc * chunkSize;
        final r0 = cr * chunkSize;
        final w = math.min(chunkSize, cellCols - c0);
        final h = math.min(chunkSize, cellRows - r0);
        final nv = (w + 1) * (h + 1);
        final tex = Float32List(nv * 2);
        final colors = Int32List(nv);
        var v = 0;
        for (var r = r0; r <= r0 + h; r++) {
          for (var c = c0; c <= c0 + w; c++) {
            // テクスチャ座標（画像は北が上なので v を反転）
            tex[v * 2] = c * cell * texSx;
            tex[v * 2 + 1] = textureHeight - r * cell * texSy;
            colors[v] = vertexColor[r * cols + c];
            v++;
          }
        }
        _chunks.add(
          _Chunk(c0: c0, r0: r0, cellCols: w, cellRows: h, texCoords: tex, colors: colors),
        );
      }
    }
    _bandChunk = Int32List(_chunks.length);
  }

  /// isolate で作る（`compute` 向け）。前計算が 512² で 200ms 前後あるので UI スレッドを塞がない
  static TerrainMeshBuilder buildInIsolate(TerrainMeshBuilderArgs a) => TerrainMeshBuilder(
        a.dem,
        textureWidth: a.textureWidth,
        textureHeight: a.textureHeight,
        chunkSize: a.chunkSize,
        step: a.step,
        skirtDepth: a.skirtDepth,
      );

  final DemGrid dem;

  /// チャンクの一辺（セル数）。小さいほどベクタの割り込みが細かく、`drawVertices` の回数は増える
  final int chunkSize;
  final int step;

  /// スカートの深さ（m）。0 なら作らない
  final double skirtDepth;

  /// 間引き後の格子点数
  final int cols;
  final int rows;

  late final double _cellSize;
  late final double _texW;
  late final double _texH;
  late final Float32List _heights;
  late final int _cellCols;
  late final int _cellCount;
  late final Uint16List _cellBand;
  late final int _chunkCols;
  late final int _chunkRows;
  late final List<_Chunk> _chunks;
  late final Int32List _bandChunk;

  /// 描画順に並べたチャンク（象限が変わったときだけ作り直す）
  List<_Chunk>? _drawOrder;
  int? _orderedQuadrant;

  int get chunkCount => _chunks.length;

  TerrainMesh build(TerrainCamera camera) {
    final sw = Stopwatch()..start();
    final cell = _cellSize;
    final cosB = math.cos(camera.bearing);
    final sinB = math.sin(camera.bearing);
    final cosP = math.cos(camera.pitch);
    final sinP = math.sin(camera.pitch);
    final zk = camera.zScale * sinP;

    // 1. チャンクごとに投影（倍率 1・DEM 原点基準）。境界の頂点は隣と重複して計算する
    for (final ch in _chunks) {
      final pos = ch.positions;
      var v = 0;
      for (var r = ch.r0; r < ch.r0 + ch.vertexRows; r++) {
        final y = r * cell;
        final ySin = y * sinB;
        final yCos = y * cosB;
        final row = r * cols;
        for (var c = ch.c0; c < ch.c0 + ch.vertexCols; c++) {
          final x = c * cell;
          pos[v] = x * cosB - ySin;
          pos[v + 1] = -((x * sinB + yCos) * cosP + _heights[row + c] * zk);
          v += 2;
        }
      }
    }
    final tProject = sw.elapsed;

    // 2. 並び順（象限が変わったときだけ）
    final quadrant = _quadrantOf(sinB, cosB);
    final needResort = _orderedQuadrant != quadrant;
    if (needResort) {
      _reorder(quadrant);
      _orderedQuadrant = quadrant;
    }
    final tSort = sw.elapsed - tProject;

    // 3. Vertices を組む（配列はコピーされるので使い回してよい）
    final order = _drawOrder!;
    final bands = List<TerrainMeshBand>.generate(order.length, (i) {
      final ch = order[i];
      return TerrainMeshBand(
        vertices: Vertices.raw(
          VertexMode.triangles,
          ch.positions,
          textureCoordinates: ch.texCoords,
          colors: ch.colors,
          indices: ch.indicesFor(quadrant),
        ),
        cellCount: ch.cellCount,
      );
    }, growable: false);
    final tAssemble = sw.elapsed - tProject - tSort;
    return TerrainMesh._(
      bands: bands,
      cellBand: _cellBand,
      bandChunk: _bandChunk,
      chunkSize: chunkSize,
      chunkCols: _chunkCols,
      dem: dem,
      step: step,
      skirt: skirtDepth > 0 ? _buildSkirt(cell, cosB, sinB, cosP, zk) : null,
      timing: TerrainMeshTiming(
        project: tProject,
        sort: tSort,
        assemble: tAssemble,
        resorted: needResort,
      ),
    );
  }

  /// 4 辺のスカート。縁の頂点と、その真下（[skirtDepth] 下）を結ぶ帯
  Vertices _buildSkirt(double cell, double cosB, double sinB, double cosP, double zk) {
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
    final n = edge.length;
    final positions = Float32List(n * 4);
    final tex = Float32List(n * 4);
    final colors = Int32List(n * 2);
    final indices = Uint16List((n - 1) * 6);
    for (var i = 0; i < n; i++) {
      final (c, r) = edge[i];
      final x = c * cell;
      final y = r * cell;
      final h = _heights[r * cols + c];
      final sx = x * cosB - y * sinB;
      final syBase = -((x * sinB + y * cosB) * cosP);
      positions[i * 4] = sx;
      positions[i * 4 + 1] = syBase - h * zk;
      positions[i * 4 + 2] = sx;
      positions[i * 4 + 3] = syBase - (h - skirtDepth) * zk;
      // テクスチャは縁の色を引き伸ばす
      final u = x / dem.width * _texW;
      final v = _texH - y / dem.height * _texH;
      tex[i * 4] = u;
      tex[i * 4 + 1] = v;
      tex[i * 4 + 2] = u;
      tex[i * 4 + 3] = v;
      colors[i * 2] = 0xFFB0B0B0;
      colors[i * 2 + 1] = 0xFF707070;
      if (i + 1 < n) {
        final t = i * 6;
        final v0 = i * 2;
        indices[t] = v0;
        indices[t + 1] = v0 + 2;
        indices[t + 2] = v0 + 1;
        indices[t + 3] = v0 + 2;
        indices[t + 4] = v0 + 3;
        indices[t + 5] = v0 + 1;
      }
    }
    return Vertices.raw(VertexMode.triangles, positions, textureCoordinates: tex, colors: colors, indices: indices);
  }

  /// 視線の地上投影の向きから象限を決める
  ///
  /// 画面上向き（遠ざかる向き）の世界ベクトルは (sinB, cosB)。
  /// bit0: 東向き成分が正（東が遠い）、bit1: 北向き成分が正（北が遠い）
  static int _quadrantOf(double sinB, double cosB) =>
      (sinB > 0 ? 1 : 0) | (cosB > 0 ? 2 : 0);

  /// チャンクを象限走査の順に並べ、セル → 帯番号を引き直す
  ///
  /// 遠い側のチャンク行から手前へ、行内も遠い側から手前へ。
  void _reorder(int quadrant) {
    final eastFar = (quadrant & 1) != 0;
    final northFar = (quadrant & 2) != 0;
    final order = <_Chunk>[];
    for (var rr = 0; rr < _chunkRows; rr++) {
      final cr = northFar ? _chunkRows - 1 - rr : rr;
      for (var cc = 0; cc < _chunkCols; cc++) {
        final ccol = eastFar ? _chunkCols - 1 - cc : cc;
        order.add(_chunks[cr * _chunkCols + ccol]);
      }
    }
    for (var b = 0; b < order.length; b++) {
      final ch = order[b];
      _bandChunk[b] = (ch.r0 ~/ chunkSize) * _chunkCols + (ch.c0 ~/ chunkSize);
      for (var r = ch.r0; r < ch.r0 + ch.cellRows; r++) {
        final base = r * _cellCols;
        for (var c = ch.c0; c < ch.c0 + ch.cellCols; c++) {
          _cellBand[base + c] = b;
        }
      }
    }
    _drawOrder = order;
  }
}
