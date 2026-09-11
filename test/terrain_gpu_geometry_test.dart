// GPU に上げる頂点列の組み立て（純 Dart 部分）と、骨組みだけのメッシュ
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/core/terrain/dem_grid.dart';
import 'package:root_maps/core/terrain/gpu/gpu_geometry.dart';
import 'package:root_maps/core/terrain/terrain_camera.dart';
import 'package:root_maps/core/terrain/terrain_mesh.dart';
import 'package:root_maps/core/terrain/terrain_painter.dart';
import 'package:root_maps/core/terrain/terrain_scene.dart';

void main() {
  DemGrid dem({int n = 9, double cell = 10}) => DemGrid(
        cols: n,
        rows: n,
        originX: 1000,
        originY: 2000,
        cellSize: cell,
        heights: Float32List.fromList([for (var r = 0; r < n; r++) for (var c = 0; c < n; c++) (c + r).toDouble()]),
      );

  group('GpuTerrainGeometry', () {
    test('格子の頂点・インデックス・uv', () {
      final d = dem();
      final shade = Float32List(81)..fillRange(0, 81, 0.5);
      final g = GpuTerrainGeometry.build(
        heights: d.heights,
        cols: 9,
        rows: 9,
        cellSize: 10,
        width: d.width,
        height: d.height,
        shade: shade,
      );
      expect(g.vertexCount, 81);
      expect(g.indexCount, 8 * 8 * 6);
      expect(g.vertices.length, 81 * GpuTerrainGeometry.floatsPerVertex);
      // 南西の角: 原点、uv は左下（画像は北が上なので v = 1）
      expect(g.vertices.sublist(0, 6), [0, 0, 0, 0, 1, 0.5]);
      // 北東の角
      const ne = 80 * 6;
      expect(g.vertices[ne], 80);
      expect(g.vertices[ne + 1], 80);
      expect(g.vertices[ne + 2], 16);
      expect(g.vertices[ne + 3], 1);
      expect(g.vertices[ne + 4], 0);
      expect(g.minZ, 0);
      expect(g.maxZ, 16);
      // インデックスは全部範囲内、各セル 2 三角形
      for (final i in g.indices) {
        expect(i, lessThan(81));
      }
      expect(g.indices.sublist(0, 6), [0, 1, 9, 1, 10, 9]);
    });

    test('スカートは縁を一周して真下に垂らす', () {
      final d = dem();
      final shade = Float32List(81)..fillRange(0, 81, 1);
      final g = GpuTerrainGeometry.build(
        heights: d.heights,
        cols: 9,
        rows: 9,
        cellSize: 10,
        width: d.width,
        height: d.height,
        shade: shade,
        skirtDepth: 5,
      );
      const edge = 2 * (9 + 9);
      expect(g.vertexCount, 81 + edge * 2);
      expect(g.indexCount, (64 + edge - 1) * 6);
      // 最初の縁の点（南西）: 上は格子と同じ高さ、下は 5 下
      const o = 81 * 6;
      expect(g.vertices[o + 2], 0);
      expect(g.vertices[o + 6 + 2], -5);
      expect(g.vertices[o + 5], lessThan(1)); // 壁は暗い
      for (final i in g.indices) {
        expect(i, lessThan(g.vertexCount));
      }
      // 標高の範囲はスカートを含まない
      expect(g.minZ, 0);
    });
  });

  group('GpuPolygonGeometry / GpuLineGeometry', () {
    late TerrainMesh mesh;
    setUp(() {
      mesh = TerrainMeshBuilder(dem(), textureWidth: 8, textureHeight: 8, chunkSize: 4).buildStatic();
    });

    test('面は頂点ごとに色を持つ（from で増分）', () {
      final p1 = LiftedPolygon.lift(const [Offset(5, 5), Offset(25, 5), Offset(25, 25)], mesh, color: const Color(0x80FF0000));
      final p2 = LiftedPolygon.lift(const [Offset(40, 40), Offset(60, 40), Offset(60, 60)], mesh, color: const Color(0xFF00FF00));
      final all = GpuPolygonGeometry.packPolygons([p1, p2]);
      final tail = GpuPolygonGeometry.packPolygons([p1, p2], from: 1);
      expect(GpuPolygonGeometry.vertexCountOf(all), p1.triangleCount * 3 + p2.triangleCount * 3);
      expect(GpuPolygonGeometry.vertexCountOf(tail), p2.triangleCount * 3);
      // 先頭の頂点の色 = p1（赤・半透明、straight alpha）
      expect(all.sublist(3, 7), [1, 0, 0, closeTo(0.5, 0.01)]);
      // 束経由（PolygonBatch）と同じ並び
      final viaBatch = GpuPolygonGeometry.pack(PolygonBatch.byChunk([p1, p2]).values);
      expect(GpuPolygonGeometry.vertexCountOf(viaBatch), GpuPolygonGeometry.vertexCountOf(all));
    });

    test('線分 1 本 = 頂点 4・インデックス 6、両端と左右を持つ', () {
      final line = LiftedPolyline.lift(const [Offset(0, 0), Offset(30, 0), Offset(30, 30)], mesh, color: const Color(0xFF0000FF), widthPx: 3);
      final g = GpuLineGeometry.pack(polylines: [line]);
      expect(g.segmentCount, line.pointCount - 1);
      expect(g.vertexCount, g.segmentCount * 4);
      expect(g.indexCount, g.segmentCount * 6);
      const f = GpuLineGeometry.floatsPerVertex;
      // 最初の線分: a = 点 0、b = 点 1
      expect(g.vertices.sublist(0, 3), line.xyz.sublist(0, 3));
      expect(g.vertices.sublist(3, 6), line.xyz.sublist(3, 6));
      expect([g.vertices[6], g.vertices[7]], [0, -1]); // t, side
      expect([g.vertices[f + 6], g.vertices[f + 7]], [0, 1]);
      expect([g.vertices[2 * f + 6], g.vertices[2 * f + 7]], [1, -1]);
      expect([g.vertices[3 * f + 6], g.vertices[3 * f + 7]], [1, 1]);
      expect(g.vertices[8], 3); // width
      expect(g.vertices.sublist(9, 13), [0, 0, 1, 1]);
      expect(g.indices.sublist(0, 6), [0, 1, 2, 1, 3, 2]);
      for (final i in g.indices) {
        expect(i, lessThan(g.vertexCount));
      }
    });

    test('点 1 つ = 頂点 4・インデックス 6、角と半径と色、標高は elevationAt', () {
      const pts = [
        TerrainPoint(x: 10, y: 20, color: Color(0xFFFF0000), sizePx: 5),
        TerrainPoint(x: 30, y: 40, color: Color(0x8000FF00), sizePx: 3),
      ];
      final g = GpuPointGeometry.pack(pts, elevationAt: (x, y) => x + y);
      expect(g.pointCount, 2);
      expect(g.vertexCount, 8);
      expect(g.indexCount, 12);
      const f = GpuPointGeometry.floatsPerVertex;
      expect(g.vertices.sublist(0, 3), [10, 20, 30]);
      expect([g.vertices[3], g.vertices[4]], [-1, -1]);
      expect([g.vertices[f + 3], g.vertices[f + 4]], [1, -1]);
      expect([g.vertices[2 * f + 3], g.vertices[2 * f + 4]], [-1, 1]);
      expect([g.vertices[3 * f + 3], g.vertices[3 * f + 4]], [1, 1]);
      expect(g.vertices[5], 5);
      expect(g.vertices.sublist(6, 10), [1, 0, 0, 1]);
      expect(g.indices.sublist(6, 12), [4, 5, 6, 5, 7, 6]);
      // from で増分
      final tail = GpuPointGeometry.pack(pts, from: 1, elevationAt: (x, y) => 0);
      expect(tail.pointCount, 1);
      expect(tail.vertices[5], 3);
    });

    test('空なら空', () {
      expect(GpuLineGeometry.pack().isEmpty, isTrue);
      expect(GpuPolygonGeometry.packPolygons(const []), isEmpty);
      expect(GpuPointGeometry.pack(const [], elevationAt: (x, y) => 0).isEmpty, isTrue);
    });
  });

  group('buildMipChain', () {
    test('2×2 の平均で 1×1 まで、段数は fullMipCount − 1', () {
      // 4×4、左半分 (0,0,0,255)・右半分 (255,255,255,255)
      final rgba = Uint8List(4 * 4 * 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final o = (y * 4 + x) * 4;
          final v = x < 2 ? 0 : 255;
          rgba[o] = v;
          rgba[o + 1] = v;
          rgba[o + 2] = v;
          rgba[o + 3] = 255;
        }
      }
      final mips = buildMipChain(MipChainArgs(rgba: rgba, width: 4, height: 4));
      expect(mips.length, 2); // 2×2, 1×1
      expect(mips[0].length, 2 * 2 * 4);
      expect(mips[0].sublist(0, 4), [0, 0, 0, 255]); // 左上 = 黒
      expect(mips[0].sublist(4, 8), [255, 255, 255, 255]); // 右上 = 白
      expect(mips[1].length, 4);
      expect(mips[1][0], closeTo(128, 1)); // 全体の平均
      expect(mips[1][3], 255);
    });

    test('奇数サイズでも端を詰めて 1×1 まで', () {
      final rgba = Uint8List(5 * 3 * 4)..fillRange(0, 5 * 3 * 4, 100);
      final mips = buildMipChain(MipChainArgs(rgba: rgba, width: 5, height: 3));
      expect(mips.map((m) => m.length ~/ 4).toList(), [2 * 1, 1 * 1]);
      expect(mips.last, [100, 100, 100, 100]);
    });
  });

  group('TerrainShading', () {
    tearDown(() {
      TerrainShading.source = TerrainShadeSource.slope;
      TerrainShading.slopeMaxDeg = 50;
      TerrainShading.slopeStrength = 0.6;
    });

    test('傾斜: 平らは 0.5（変化なし）、急なほど暗く、slopeMaxDeg で頭打ち', () {
      TerrainShading.source = TerrainShadeSource.slope;
      TerrainShading.slopeMaxDeg = 45;
      TerrainShading.slopeStrength = 1;
      expect(TerrainShading.grayFor(0, 0), 0.5);
      final g45 = TerrainShading.grayFor(1, 0); // tan 45° = 1
      expect(g45, closeTo(0, 1e-6));
      final g30 = TerrainShading.grayFor(math.tan(30 * math.pi / 180), 0);
      expect(g30, closeTo(0.5 - 0.5 * 30 / 45, 1e-6));
      expect(TerrainShading.grayFor(5, 5), 0); // 頭打ち
      // 向きに依らない
      expect(TerrainShading.grayFor(0, 1), closeTo(g45, 1e-9));
      expect(TerrainShading.grayFor(-1, 0), closeTo(g45, 1e-9));
    });

    test('光源: 従来の倍率の半分（北西向きが明るく南東向きが暗い）', () {
      TerrainShading.source = TerrainShadeSource.hillshade;
      final flat = TerrainShading.grayFor(0, 0);
      expect(flat * 2, closeTo(0.35 + 0.65 * math.sin(45 * math.pi / 180), 1e-6));
      // nx = -dh/dx なので (-0.5, 0.5) は北西向きの斜面（光源 315° に向く）→ 明るい
      expect(TerrainShading.grayFor(-0.5, 0.5), greaterThan(TerrainShading.grayFor(0.5, -0.5)));
    });

    test('ビルダーの頂点色は 2 × グレーの乗算', () {
      TerrainShading.source = TerrainShadeSource.slope;
      final builder = TerrainMeshBuilder(dem(), textureWidth: 8, textureHeight: 8, chunkSize: 4);
      final g = builder.gpuGeometry();
      // dem() は c + r の斜面（tan = √2 / 10）→ 全点同じ傾斜
      final expected = TerrainShading.grayFor(-0.1, -0.1);
      expect(g.vertices[5], closeTo(expected, 1e-6));
    });
  });

  group('TerrainMeshBuilder.buildStatic', () {
    test('帯は空、チャンクの骨組みは build と同じ', () {
      final builder = TerrainMeshBuilder(dem(), textureWidth: 8, textureHeight: 8, chunkSize: 4);
      final s = builder.buildStatic();
      expect(s.bands, isEmpty);
      expect(s.skirt, isNull);
      expect(s.chunkCols, 2);
      final cam = TerrainCamera(centerX: 0, centerY: 0, scale: 1, bearing: 0.3, pitch: 0.5);
      final full = builder.build(cam);
      for (var i = 0; i < 64; i++) {
        expect(s.chunkOfCell(i), full.chunkOfCell(i));
      }
      expect(s.cellIndexAt(35, 5), full.cellIndexAt(35, 5));
      // GPU の頂点列も同じ格子
      final g = builder.gpuGeometry();
      expect(g.vertexCount, 81);
      s.dispose(); // 何も持っていないので何も起きない
    });
  });
}
