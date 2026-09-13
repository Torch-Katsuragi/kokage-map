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

import 'gpu/terrain_gpu.dart';
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
    this.builder,
    Object? textureKey,
    this.previousTextureKey,
    this.lines = const [],
    this.polygons = const [],
    this.dynamicLines = const [],
    this.dynamicPolygons = const [],
    this.dynamicPoints = const [],
    this.segmentSets = const [],
    this.points = const [],
    this.labels = const [],
    Map<int, List<PolygonBatch>>? polygonBatches,
  })  : polygonBatches = polygonBatches ?? {for (final e in PolygonBatch.byChunk(polygons).entries) e.key: [e.value]},
        textureKey = textureKey ?? texture ?? mesh;

  /// テクスチャの世代（GPU 側のキャッシュのキー。画像を手放した後も同じキーで GPU 側の複製を引く）
  final Object textureKey;

  /// 1 つ前の世代のキー（web: 新しい世代の転送が終わるまでこちらを描く）
  final Object? previousTextureKey;

  /// チャンク番号 → 面の束（シーン側で一度作って使い回す。投影はこの束ごとにキャッシュされる。
  /// 貼り付けが育つ間は 1 チャンクに束が複数ある）
  final Map<int, List<PolygonBatch>> polygonBatches;

  /// 毎フレーム変わりうる線・面（描画中の線、軌跡、向きの線など）。少ないので投影をキャッシュしない
  final List<LiftedPolyline> dynamicLines;
  final List<LiftedPolygon> dynamicPolygons;

  /// 毎フレーム変わりうる点（現在位置・描画中の点など）。投影をキャッシュしない
  final List<TerrainPoint> dynamicPoints;

  /// タイルの DEM 原点（Mercator m）
  final double originX;
  final double originY;
  final TerrainMesh mesh;

  /// [mesh] を作ったビルダー。GPU 経路はこれをキーに頂点バッファを持つ（縁が変わると別物になる）
  final TerrainMeshBuilder? builder;
  final ui.Image? texture;
  final List<LiftedPolyline> lines;
  final List<LiftedPolygon> polygons;
  final List<LiftedSegments> segmentSets;
  final List<TerrainPoint> points;
  final List<TerrainLabel> labels;
}

/// 面の束を投影した結果（方位・傾きが変わるまで使い回す）
class _ProjectedBatch {
  _ProjectedBatch(this.bearing, this.pitch, this.vertices);

  final double bearing;
  final double pitch;
  final ui.Vertices vertices;

  /// 最後に描いた時刻（ms）。しばらく描かなければ捨てる（Vertices は native 側）
  int lastUsed = 0;
}

/// タイルの点を投影した結果（方位・傾きが変わるまで使い回す）。hidden: 0 = 未判定、1 = 見える、2 = 隠れている
class _ProjectedPoints {
  _ProjectedPoints(this.bearing, this.pitch, this.count, this.xy, this.z, this.hidden);

  final double bearing;
  final double pitch;
  final int count;
  final Float32List xy;
  final Float32List z;
  final Uint8List hidden;
}

/// タイルのラベルを投影した結果（方位・傾きが変わるまで使い回す）
class _ProjectedLabels {
  _ProjectedLabels(this.bearing, this.pitch, this.count, this.xy);

  final double bearing;
  final double pitch;
  final int count;
  final Float32List xy;
}

/// 置いたラベルの矩形を画面の格子に入れて、重なりの判定を近くのものだけにする（1 万ラベル × 200 個の総当たりをしない）
class _PlacedGrid {
  static const _cell = 96.0;
  final Map<int, List<Rect>> _cells = {};
  int length = 0;

  static int _key(int cx, int cy) => cx * 100003 + cy;

  bool overlaps(Rect r) {
    final cx0 = (r.left / _cell).floor(), cx1 = (r.right / _cell).floor();
    final cy0 = (r.top / _cell).floor(), cy1 = (r.bottom / _cell).floor();
    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        final list = _cells[_key(cx, cy)];
        if (list == null) continue;
        for (final o in list) {
          if (o.overlaps(r)) return true;
        }
      }
    }
    return false;
  }

  void add(Rect r) {
    final cx0 = (r.left / _cell).floor(), cx1 = (r.right / _cell).floor();
    final cy0 = (r.top / _cell).floor(), cy1 = (r.bottom / _cell).floor();
    for (var cy = cy0; cy <= cy1; cy++) {
      for (var cx = cx0; cx <= cx1; cx++) {
        (_cells[_key(cx, cy)] ??= []).add(r);
      }
    }
    length++;
  }
}

/// タイルの線を投影して帯 × 見た目でまとめた結果
class _ProjectedLines {
  _ProjectedLines(this.bearing, this.pitch, this.thinSkipped, this.count, this.pathsByBand, this.segsByBand);

  final double bearing;
  final double pitch;

  /// 最後に描いた時刻（ms）
  int lastUsed = 0;

  /// 投影したときの本数（静的シーンが育つと増える）
  final int count;

  /// 細い線を省いた（回転中）
  final bool thinSkipped;
  final Map<int, Map<(int, double), Path>> pathsByBand;
  final Map<int, Map<(int, double), Float32List>> segsByBand;
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

  /// 回転・傾けの最中（細い線を省く）
  bool gesturing = false;

  /// 地形・面・線を GPU で描く（null なら純 Dart の `drawVertices`）。点とラベルはどちらでも Canvas
  TerrainGpuWorldRenderer? gpu;

  /// GPU のサーフェスの物理解像度（論理 px × これ）
  double pixelRatio = 1;

  /// 面の束の投影キャッシュ。正射影なので方位・傾きが同じ間は投影が変わらず、
  /// 移動・拡縮は Canvas の変換だけで済む（毎フレーム 50 万頂点を投影し直さない）
  /// ⚠ Expando ではなく Map: 描かなくなったタイル（別の段・画面外）の束が GC を待つ間、native の Vertices が溜まる。
  /// [_sweepMs] 描いていないものはこちらから捨てる
  final Map<PolygonBatch, _ProjectedBatch> _batchCache = {};
  static const _sweepMs = 3000;
  int _lastSweep = 0;

  /// 線の投影キャッシュ（タイルの線リストごと）
  final Map<List<LiftedPolyline>, _ProjectedLines> _lineCache = {};

  /// 点の投影と隠れ判定のキャッシュ（タイルの点リストごと）
  final Expando<_ProjectedPoints> _pointCache = Expando();

  /// ラベルの投影キャッシュ（タイルのラベルリストごと）
  final Expando<_ProjectedLabels> _labelCache = Expando();

  /// 1 フレームに新しく layout するラベルの上限（1 個 0.2〜0.3ms。寄った瞬間に 200 個まとめて layout すると 70ms）
  static const _layoutsPerFrame = 40;

  /// 上限で今フレーム見送ったラベルの数（> 0 なら次のフレームで描き直す）
  int deferredLayouts = 0;

  /// 1 フレームに新しく隠れ判定する点の上限（1 点の判定は視線に沿って標高を何十回も引く）
  static const _occlusionTestsPerFrame = 300;
  TerrainHit? selected;
  final Set<int> visibleLabels = {};
  final void Function(Duration)? onPainted;

  /// 画面中心の標高。カメラ中心とタイルが同じ間は引き直さない（toScreen のたびに引いていた）
  double get _centerHeight {
    if (_chCache == null || _chX != camera.centerX || _chY != camera.centerY || !identical(_chTiles, tiles)) {
      _chX = camera.centerX;
      _chY = camera.centerY;
      _chTiles = tiles;
      _chCache = elevationAt(camera.centerX, camera.centerY) ?? 0;
    }
    return _chCache!;
  }

  double? _chCache;
  double _chX = double.nan;
  double _chY = double.nan;
  Object? _chTiles;

  /// タイル座標での「画面中心に来る点」の投影座標
  Offset _pcFor(TerrainTileDrawable t) =>
      camera.project(camera.centerX - t.originX, camera.centerY - t.originY, _centerHeight);

  /// 透視で描いているか（GPU 経路のみ）
  bool get _perspective => gpu != null && camera.perspective && camera.viewport != Size.zero;

  /// 世界座標 → 画面座標
  Offset toScreen(double x, double y, double z, Size size) {
    if (_perspective) {
      return camera.projectPerspective(x - camera.centerX, y - camera.centerY, z, _centerHeight) ?? const Offset(-1e6, -1e6);
    }
    final p = camera.project(x - camera.centerX, y - camera.centerY, z - _centerHeight);
    return Offset(size.width / 2 + p.dx * camera.scale, size.height / 2 + p.dy * camera.scale);
  }

  /// 画面座標 → 視線と地形の交点（世界座標）。地形の外なら null
  Offset? unproject(Offset screen, Size size) {
    final h0 = _centerHeight;
    if (_perspective) {
      final hit = camera.intersectRayPerspective(
        screen,
        h0,
        (x, y) => elevationAt(camera.centerX + x, camera.centerY + y),
        stepMeters: stepMeters,
        maxHeight: heightRange.$2,
      );
      if (hit == null) return null;
      return Offset(camera.centerX + hit.dx, camera.centerY + hit.dy);
    }
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
    if (_perspective) {
      // 点から視点へ向かってなぞる
      final eye = camera.eyeAt(_centerHeight);
      final dx = camera.centerX + eye.x - x;
      final dy = camera.centerY + eye.y - y;
      final dz = eye.z / camera.zScale - z;
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist < 1e-3) return false;
      final n = (dist / stepMeters).ceil().clamp(1, 4000);
      final maxH = heightRange.$2;
      for (var i = 1; i < n; i++) {
        final k = i / n;
        final zRay = z + dz * k;
        if (zRay > maxH) return false;
        final h = elevationAt(x + dx * k, y + dy * k);
        if (h != null && h > zRay + 0.5) return true;
      }
      return false;
    }
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

  _ProjectedLines _projectLines(List<LiftedPolyline> lines, TerrainMesh mesh, {required bool skipThin}) {
    final pathsByBand = <int, Map<(int, double), Path>>{};
    final segLists = <int, Map<(int, double), List<double>>>{};
    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      final n = line.pointCount;
      final styleKey = (line.color.toARGB32(), line.widthPx);
      final thin = line.widthPx <= 2.5;
      if (thin && skipThin) continue;
      var currentBand = -1;
      Path? path;
      List<double>? segs;
      for (var i = 0; i < n - 1; i++) {
        final band = mesh.cellBand[line.cells[i]];
        final a = camera.project(line.xyz[i * 3], line.xyz[i * 3 + 1], line.xyz[i * 3 + 2]);
        final b = camera.project(line.xyz[i * 3 + 3], line.xyz[i * 3 + 4], line.xyz[i * 3 + 5]);
        if (thin) {
          if (band != currentBand) {
            segs = (segLists[band] ??= {})[styleKey] ??= <double>[];
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
    return _ProjectedLines(camera.bearing, camera.pitch, skipThin, lines.length, pathsByBand, {
      for (final e in segLists.entries) e.key: {for (final s in e.value.entries) s.key: Float32List.fromList(s.value)},
    });
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

    final gpu = this.gpu;
    if (gpu != null) {
      // 地形・面・線は GPU（深度バッファ。タイルの順も帯も要らない）。結果の画像を敷く
      final image = gpu.render(
        camera,
        size,
        tiles,
        pixelRatio: pixelRatio,
        heightRange: heightRange,
        centerHeight: _centerHeight,
      );
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Offset.zero & size,
          Paint()..filterQuality = FilterQuality.low,
        );
      }
    } else {
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
      // 太い線は角と端を丸くしたいので Path。方位・傾きが同じ間はキャッシュ
      var pl = _lineCache[t.lines];
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (pl == null ||
          pl.bearing != camera.bearing ||
          pl.pitch != camera.pitch ||
          pl.thinSkipped != gesturing ||
          pl.count != t.lines.length) {
        pl = _projectLines(t.lines, mesh, skipThin: gesturing);
        _lineCache[t.lines] = pl;
      }
      pl.lastUsed = nowMs;
      final dynLines = t.dynamicLines.isEmpty ? null : _projectLines(t.dynamicLines, mesh, skipThin: false);
      final pathsByBand = pl.pathsByBand;
      final segsByBand = pl.segsByBand;

      for (var b = 0; b < mesh.bands.length; b++) {
        canvas.drawVertices(mesh.bands[b].vertices, BlendMode.modulate, terrainPaint);
        final chunk = mesh.bandChunk[b];
        final batches = t.polygonBatches[chunk];
        if (batches != null) {
          for (final batch in batches) {
            var pb = _batchCache[batch];
            if (pb == null || pb.bearing != camera.bearing || pb.pitch != camera.pitch) {
              projectInto(batch.xyz, batch.projected);
              pb?.vertices.dispose();
              pb = _ProjectedBatch(
                camera.bearing,
                camera.pitch,
                ui.Vertices.raw(ui.VertexMode.triangles, batch.projected, colors: batch.colors),
              );
              _batchCache[batch] = pb;
            }
            pb.lastUsed = nowMs;
            canvas.drawVertices(pb.vertices, BlendMode.srcOver, fillPaint);
          }
        }
        for (final poly in t.dynamicPolygons) {
          final src = poly.byChunk[chunk];
          if (src == null) continue;
          final dst = poly.projected[chunk]!;
          projectInto(src, dst);
          fillPaint.color = poly.color;
          canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, dst), BlendMode.srcOver, fillPaint);
        }
        fillPaint.color = const Color(0xFFFFFFFF);
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
            canvas.drawRawPoints(ui.PointMode.lines, e.value, segmentPaint);
          }
        }
        final paths = pathsByBand[b];
        if (paths != null) {
          for (final e in paths.entries) {
            linePaint
              ..color = Color(e.key.$1)
              ..strokeWidth = e.key.$2 / camera.scale;
            canvas.drawPath(e.value, linePaint);
          }
        }
        if (dynLines != null) {
          final ds = dynLines.segsByBand[b];
          if (ds != null) {
            for (final e in ds.entries) {
              segmentPaint
                ..color = Color(e.key.$1)
                ..strokeWidth = e.key.$2 / camera.scale;
              canvas.drawRawPoints(ui.PointMode.lines, e.value, segmentPaint);
            }
          }
          final dp = dynLines.pathsByBand[b];
          if (dp != null) {
            for (final e in dp.entries) {
              linePaint
                ..color = Color(e.key.$1)
                ..strokeWidth = e.key.$2 / camera.scale;
              canvas.drawPath(e.value, linePaint);
            }
          }
        }
      }
      canvas.restore();
    }
    }

    // 点（画面座標）。隠れているものは描かない。
    // 投影は方位・傾きごとにキャッシュし、隠れ判定は画面に入っている点だけ・1 フレーム上限つきで進める
    // （1 万点を毎フレーム投影して光線探索すると 400ms）
    final viewport = Offset.zero & size;
    final pointPaint = Paint();
    final pointEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white;
    final pc = camera.project(camera.centerX, camera.centerY, _centerHeight);
    var occlusionTests = 0;
    for (final t in tiles) {
      final pts = t.points;
      // GPU 経路では静的な点は GPU が描く（深度テストで隠れる）。動的な点（現在位置など）はここで
      if (pts.isEmpty || gpu != null) {
        _paintDynamicPoints(canvas, t, size, viewport, pointPaint, pointEdge);
        continue;
      }
      var pp = _pointCache[pts];
      if (pp == null || pp.bearing != camera.bearing || pp.pitch != camera.pitch || pp.count != pts.length) {
        final xy = Float32List(pts.length * 2);
        final z = Float32List(pts.length);
        final dem = t.mesh.dem;
        for (var i = 0; i < pts.length; i++) {
          final wx = t.originX + pts[i].x;
          final wy = t.originY + pts[i].y;
          z[i] = dem.elevationAt(wx, wy);
          final p = camera.project(wx, wy, z[i]);
          xy[i * 2] = p.dx;
          xy[i * 2 + 1] = p.dy;
        }
        pp = _ProjectedPoints(camera.bearing, camera.pitch, pts.length, xy, z, Uint8List(pts.length));
        _pointCache[pts] = pp;
      }
      for (var i = 0; i < pts.length; i++) {
        final sp = Offset(
          size.width / 2 + (pp.xy[i * 2] - pc.dx) * camera.scale,
          size.height / 2 + (pp.xy[i * 2 + 1] - pc.dy) * camera.scale,
        );
        if (!viewport.inflate(16).contains(sp)) continue;
        var h = pp.hidden[i];
        if (h == 0 && !gesturing && occlusionTests < _occlusionTestsPerFrame) {
          occlusionTests++;
          h = isOccluded(t.originX + pts[i].x, t.originY + pts[i].y, pp.z[i]) ? 2 : 1;
          pp.hidden[i] = h;
        }
        if (h == 2) continue;
        final pt = pts[i];
        pointPaint.color = pt.color;
        canvas.drawCircle(sp, pt.sizePx, pointPaint);
        canvas.drawCircle(sp, pt.sizePx, pointEdge);
      }
      _paintDynamicPoints(canvas, t, size, viewport, pointPaint, pointEdge);
    }

    // ラベル（画面座標）。重なりは先勝ちで間引く。
    // 勝ち負けの順はタイルの描画順（方位で変わる）ではなく、文字と位置で決めた固定の順にする
    // （回転中にラベルの出入りがちらつかないように）。番号（visibleLabels・pick）はタイル順のまま
    final placed = _PlacedGrid();
    visibleLabels.clear();
    // 勝ち負けの順を固定するのに、ラベル全部を並べ替えると 1 万個で毎フレーム重い。
    // タイルを原点（≒タイルキー）で並べ、タイル内はシーンの順（一定）にすれば、方位に依らない順になる
    final indexBase = <TerrainTileDrawable, int>{};
    var labelIndex = 0;
    for (final t in tiles) {
      indexBase[t] = labelIndex;
      labelIndex += t.labels.length;
    }
    final ordered = [...tiles]..sort((a, b) => a.originY != b.originY ? a.originY.compareTo(b.originY) : a.originX.compareTo(b.originX));
    // 置けるラベルの上限。1 万面 = 1 万ラベルを全部当たり判定・layout すると 1 フレーム秒単位になる
    const maxPlaced = 200;
    var layouts = 0;
    deferredLayouts = 0;
    final dotPaint = Paint()..color = Colors.black54;
    final boxPaint = Paint()..color = Colors.white.withValues(alpha: 0.85);
    final anchorPaint = Paint()..color = Colors.black;
    final labelViewport = viewport.inflate(64);
    for (final t in ordered) {
      final labels = t.labels;
      if (labels.isEmpty) continue;
      final base = indexBase[t]!;
      // 投影は方位・傾きごとにキャッシュ（点と同じ）。標高はタイル自身の DEM から。
      // 透視は線形でないので毎フレーム行列で落とす（ラベル 1 個 = 積和 12 回。1 万個で 1ms）
      final persp = _perspective;
      final dem = t.mesh.dem;
      // 透視: 靄の始まりより遠いラベルは出さない（遠景で積み重なる）
      final labelRange2 = persp ? math.pow(camera.eyeDistance * TerrainCamera.fogStartFactor, 2).toDouble() : double.infinity;
      var pl = _labelCache[labels];
      if (!persp && (pl == null || pl.bearing != camera.bearing || pl.pitch != camera.pitch || pl.count != labels.length)) {
        final xy = Float32List(labels.length * 2);
        for (var k = 0; k < labels.length; k++) {
          final wx = t.originX + labels[k].x;
          final wy = t.originY + labels[k].y;
          final p = camera.project(wx, wy, dem.elevationAt(wx, wy));
          xy[k * 2] = p.dx;
          xy[k * 2 + 1] = p.dy;
        }
        pl = _ProjectedLabels(camera.bearing, camera.pitch, labels.length, xy);
        _labelCache[labels] = pl;
      }
      for (var k = 0; k < labels.length; k++) {
        final Offset sp;
        if (persp) {
          final wx = t.originX + labels[k].x;
          final wy = t.originY + labels[k].y;
          final dx = wx - camera.centerX;
          final dy = wy - camera.centerY;
          if (dx * dx + dy * dy > labelRange2) continue;
          final p = camera.projectPerspective(dx, dy, dem.elevationAt(wx, wy), _centerHeight);
          if (p == null) continue;
          sp = p;
        } else {
          sp = Offset(
            size.width / 2 + (pl!.xy[k * 2] - pc.dx) * camera.scale,
            size.height / 2 + (pl.xy[k * 2 + 1] - pc.dy) * camera.scale,
          );
        }
        if (!labelViewport.contains(sp)) continue;
        final label = labels[k];
        if (collideLabels && placed.length >= maxPlaced) {
          canvas.drawCircle(sp, 2, dotPaint);
          continue;
        }
        // layout（重い）の前に、文字数からの見積もりで重なりを弾く
        final fontSize = label.style?.fontSize ?? 14;
        final estW = label.text.length * fontSize * 0.7 + 4;
        final estH = fontSize * 1.3 + 2;
        final estBox = Rect.fromLTWH(sp.dx - estW / 2, sp.dy - estH - 4, estW, estH);
        if (collideLabels && placed.overlaps(estBox)) {
          canvas.drawCircle(sp, 2, dotPaint);
          continue;
        }
        if (!label.isLaidOut) {
          if (layouts >= _layoutsPerFrame) {
            deferredLayouts++;
            canvas.drawCircle(sp, 2, dotPaint);
            continue;
          }
          layouts++;
        }
        final tp = label.painter;
        final origin = sp - Offset(tp.width / 2, tp.height + 4);
        final box = Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2);
        if (collideLabels && placed.overlaps(box)) {
          canvas.drawCircle(sp, 2, dotPaint);
          continue;
        }
        placed.add(box);
        visibleLabels.add(base + k);
        canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)), boxPaint);
        tp.paint(canvas, origin);
        canvas.drawCircle(sp, 2.5, anchorPaint);
      }
    }
    _sweepCaches();
    sw.stop();
    onPainted?.call(sw.elapsed);
  }

  /// 動的な点（現在位置・描画中の点など）。毎フレーム投影し、隠れ判定は視線なぞり
  void _paintDynamicPoints(Canvas canvas, TerrainTileDrawable t, Size size, Rect viewport, Paint pointPaint, Paint pointEdge) {
    for (final pt in t.dynamicPoints) {
      final wx = t.originX + pt.x;
      final wy = t.originY + pt.y;
      final z = elevationAt(wx, wy) ?? 0;
      final sp = toScreen(wx, wy, z, size);
      if (!viewport.inflate(16).contains(sp)) continue;
      if (!gesturing && isOccluded(wx, wy, z)) continue;
      pointPaint.color = pt.color;
      canvas.drawCircle(sp, pt.sizePx, pointPaint);
      canvas.drawCircle(sp, pt.sizePx, pointEdge);
    }
  }

  /// しばらく描いていない投影キャッシュを捨てる（1 秒に 1 回）
  void _sweepCaches() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSweep < 1000) return;
    _lastSweep = nowMs;
    _batchCache.removeWhere((_, pb) {
      if (nowMs - pb.lastUsed <= _sweepMs) return false;
      pb.vertices.dispose();
      return true;
    });
    _lineCache.removeWhere((_, pl) => nowMs - pl.lastUsed > _sweepMs);
  }

  /// 全部捨てる（レイヤを閉じるとき）
  void disposeCaches() {
    for (final pb in _batchCache.values) {
      pb.vertices.dispose();
    }
    _batchCache.clear();
    _lineCache.clear();
  }

  @override
  bool shouldRepaint(covariant TerrainWorldPainter old) => true;
}
