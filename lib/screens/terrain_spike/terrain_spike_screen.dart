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
import 'package:flutter/scheduler.dart';
import 'package:geobase/geobase.dart' as geo;

import '../../core/terrain/contours.dart';
import '../../core/terrain/dem_grid.dart';
import '../../core/terrain/dem_tiles.dart';
import '../../core/terrain/gpu/terrain_gpu.dart';
import '../../core/terrain/terrain_camera.dart';
import '../../core/terrain/terrain_mesh.dart';
import '../../core/terrain/terrain_painter.dart';
import '../../core/terrain/terrain_scene.dart';
import '../../core/terrain/terrain_world_painter.dart';
import '../../core/terrain/web_mercator.dart';
import 'spike_title_stub.dart'
    if (dart.library.js_interop) 'spike_title_web.dart';

/// 3D 描画スパイク（開発用・製品機能ではない）
///
/// 純 Dart（`drawVertices` + painter's algorithm）で
/// 「DEM + 背景テクスチャ + 持ち上げた線・面 + ラベル」を描いて fps を測る。
/// 設計は Vault の `3D化の詰め_2026-09-07`。
///
/// 操作: 1 本指ドラッグ = pan、2 本指 = ズーム / 回転 / 上下で pitch、タップ = ヒットテスト。
/// 下のパネルで合成地形の格子サイズ・北山村の実 DEM・ラベル数・アニメーションを切り替える。
/// web ではタブのタイトルに計測値を出す。
class TerrainSpikeScreen extends StatefulWidget {
  const TerrainSpikeScreen({super.key});

  @override
  State<TerrainSpikeScreen> createState() => _TerrainSpikeScreenState();
}

/// 北山村役場付近
const _kitayamaLon = 135.97;
const _kitayamaLat = 33.93;

class _TerrainSpikeScreenState extends State<TerrainSpikeScreen>
    with SingleTickerProviderStateMixin {
  static const _syntheticTextureSize = 2048;

  /// ジェスチャ中に許すセル数の目安。これを超える格子は間引く
  static const _gestureCellBudget = 40000;

  int _gridPoints = 401; // 5m 格子 × 401 = 2km 四方
  int _labelCount = 200;
  String _sceneName = '合成 401²';
  DemGrid? _dem;
  ui.Image? _texture;
  int _textureWidth = _syntheticTextureSize;
  int _textureHeight = _syntheticTextureSize;
  String _attribution = '合成地形（テクスチャも合成）';
  String _status = '';
  TerrainMesh? _mesh;
  final Map<int, TerrainMeshBuilder> _builders = {}; // step ごと
  int _coarseStep = 2;
  bool _lod = true;
  int _chunkSize = 32;
  final _repaint = ValueNotifier<int>(0);
  TerrainPainter? _painter;
  Duration _lastLift = Duration.zero;
  final Map<int, List<LiftedPolyline>> _linesByStep = {};
  final Map<int, List<LiftedPolygon>> _polygonsByStep = {};
  String _timing = '';
  late TerrainCamera _camera;
  List<LiftedPolyline> _lines = const [];
  List<LiftedPolygon> _polygons = const [];
  List<TerrainLabel> _labels = const [];
  List<List<Offset>> _rawLines = const [];
  List<List<Offset>> _rawPolygons = const [];
  double _contourInterval = 0; // 0 = なし
  final Map<int, List<List<Offset>>> _contourLinesByStep = {}; // 格子の間引き段ごと
  int _contourCount = 0;
  final Map<int, LiftedSegments> _contoursByStep = {};
  Duration _lastContour = Duration.zero;
  String _hitText = '';
  bool _useGeoJson = false; // 合成の線・面の代わりに GeoJSON → TerrainSceneBuilder のシーンを出す
  final Map<int, TerrainScene> _sceneByStep = {};

  // flutter_gpu スパイク（Vault 3D化の詰め 12 節）: 頂点はデバイスバッファに一度だけ、毎フレームは mvp だけ。
  // 深度バッファがあるので pitch の上限も帯分割も無い。ラベルは Canvas で上描き
  bool _useGpu = false;
  bool _perspective = false;
  int _gpuLoadPolygons = 0; // 負荷用の格子状の面（0 / 1 万 / 10 万）
  TerrainGpuRenderer? _gpu;
  String _gpuStatus = '';
  bool _gpuBusy = false;

  // 本体の描画系（TerrainWorldPainter + TerrainGpuWorldRenderer）を 1 タイルで動かす。web の WebGL2 の検証用
  bool _useWorld = false;
  TerrainGpuWorldRenderer? _worldGpu;
  TerrainWorldPainter? _worldPainter;
  TerrainMesh? _worldMesh;
  List<TerrainTileDrawable> _worldTiles = const [];
  bool _worldTilesGeoJson = false;
  (double, double) _worldHeightRange = (0, 0);

  double get _maxPitchDeg => _useGpu || _useWorld ? 85 : 70;

  // 計測
  late final Ticker _ticker;
  int _frames = 0;
  Duration _windowStart = Duration.zero;
  double _fps = 0;
  Duration _lastPaint = Duration.zero;
  Duration _lastBuild = Duration.zero;
  String _animation = 'none'; // none / rotate / pan / pitch
  final List<int> _uiMs = [];
  final List<int> _rasterMs = [];
  late final TimingsCallback _timingsCallback;

  // ジェスチャ
  double _scaleStart = 1;
  double _bearingStart = 0;
  double _pitchStart = 0;
  Offset _focalStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    _camera = TerrainCamera(centerX: 0, centerY: 0, scale: 0.4, pitch: 45 * math.pi / 180);
    _timingsCallback = (timings) {
      for (final t in timings) {
        _uiMs.add(t.buildDuration.inMilliseconds);
        _rasterMs.add(t.rasterDuration.inMilliseconds);
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_timingsCallback);
    _ticker = createTicker(_onTick)..start();
    _loadSynthetic();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_timingsCallback);
    _texture?.dispose();
    _gpu?.dispose();
    _worldGpu?.dispose();
    super.dispose();
  }

  // ── 本体の描画系 ────────────────────────────────────

  Future<void> _ensureWorldGpu() async {
    if (_gpuBusy) return;
    _gpuBusy = true;
    try {
      final sw = Stopwatch()..start();
      final r = _worldGpu ??= await TerrainGpuWorldRenderer.create();
      r.onTextureReady = () => _repaint.value++;
      _worldPainter = null;
      _worldMesh = null;
      _worldTiles = const [];
      _gpuStatus = 'world GPU 準備 ${sw.elapsedMilliseconds}ms (platform view: ${r.platformViewType != null})';
    } catch (e) {
      _gpuStatus = 'world GPU 不可: $e';
      _useWorld = false;
    } finally {
      _gpuBusy = false;
      if (mounted) setState(() {});
    }
  }

  /// いまのシーンを 1 タイルの描き物にする（骨組みのメッシュは 1 回だけ組む）
  List<TerrainTileDrawable> _buildWorldTiles() {
    final dem = _dem!;
    final builder = _builderFor(1);
    final mesh = _worldMesh ??= builder.buildStatic();
    if (_worldTiles.isNotEmpty && identical(_worldTiles.first.mesh, mesh) && _worldTilesGeoJson == _useGeoJson) return _worldTiles;
    _worldTilesGeoJson = _useGeoJson;
    var lo = double.infinity;
    var hi = -double.infinity;
    for (final v in dem.heights) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    _worldHeightRange = (lo, hi);
    final scene = _useGeoJson ? (_sceneByStep[1] ??= _buildGeoJsonScene(mesh)) : null;
    return _worldTiles = [
      TerrainTileDrawable(
        originX: dem.originX,
        originY: dem.originY,
        mesh: mesh,
        builder: builder,
        texture: _texture,
        textureKey: _texture,
        lines: scene == null ? _lines : [...scene.outlines, ...scene.lines],
        polygons: scene == null ? _polygons : scene.polygons,
        points: scene?.points ?? const [],
        labels: scene?.labels ?? _labels,
      ),
    ];
  }

  TerrainWorldPainter _worldPainterFor(BuildContext context) {
    final dem = _dem!;
    final tiles = _buildWorldTiles();
    final p = _worldPainter ??= TerrainWorldPainter(
      camera: _camera,
      tiles: tiles,
      elevationAt: dem.elevationAt,
      heightRange: _worldHeightRange,
      stepMeters: dem.cellSize,
      onPainted: (d) => _lastPaint = d,
      repaint: _repaint,
    )..gpu = _worldGpu;
    p
      ..tiles = tiles
      ..heightRange = _worldHeightRange
      ..pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return p;
  }

  // ── flutter_gpu ────────────────────────────────────

  /// GPU 描画系を用意して、いまのシーン（DEM・テクスチャ・面）を上げる
  Future<void> _ensureGpu() async {
    if (_gpuBusy) return;
    _gpuBusy = true;
    try {
      _gpu ??= await TerrainGpuRenderer.create();
      final dem = _dem;
      final tex = _texture;
      if (dem == null || tex == null) return; // テクスチャが来たら _setTexture からまた呼ばれる
      final sw = Stopwatch()..start();
      _gpu!.setTerrain(dem);
      await _gpu!.setTexture(tex);
      _gpu!.setPolygons(_gpuPolygonBatches(dem));
      _gpuStatus =
          'GPU 準備 ${sw.elapsedMilliseconds}ms 地形 ${_gpu!.terrainVertexCount} 頂点 面 ${_gpu!.polygonVertexCount} 頂点';
    } catch (e) {
      _gpuStatus = 'GPU 不可: $e';
      _useGpu = false;
    } finally {
      _gpuBusy = false;
      if (mounted) setState(() {});
      _repaint.value++;
    }
  }

  /// 負荷用の面だけ差し替える
  void _uploadGpuPolygons() {
    final dem = _dem;
    final gpu = _gpu;
    if (dem == null || gpu == null) return;
    final sw = Stopwatch()..start();
    gpu.setPolygons(_gpuPolygonBatches(dem));
    _gpuStatus = '面 ${gpu.polygonVertexCount} 頂点を上げた ${sw.elapsedMilliseconds}ms';
    _repaint.value++;
  }

  /// いまの面（全解像度で持ち上げたもの）＋負荷用の格子状の面
  List<PolygonBatch> _gpuPolygonBatches(DemGrid dem) {
    final lifted = _useGeoJson ? (_sceneByStep[1]?.polygons ?? const <LiftedPolygon>[]) : (_polygonsByStep[1] ?? _polygons);
    return [
      ...PolygonBatch.byChunk(lifted).values,
      if (_gpuLoadPolygons > 0) _gridPolygons(dem, _gpuLoadPolygons),
    ];
  }

  /// DEM の上に [count] 個の小さな四角を格子状に並べた面の束（三角形 2 枚ずつ、半透明の 2 色）。
  /// 角の高さは DEM から引く。セルに切り分けないので、四角が DEM のセルより大きいと地形に埋まる所が出る
  static PolygonBatch _gridPolygons(DemGrid dem, int count) {
    final n = math.sqrt(count).ceil();
    final pitchX = dem.width / n;
    final pitchY = dem.height / n;
    final s = math.min(pitchX, pitchY) * 0.8;
    final xyz = Float32List(n * n * 18);
    final colors = Int32List(n * n * 6);
    var o = 0;
    var v = 0;
    double z(double x, double y) => dem.elevationAt(dem.originX + x, dem.originY + y);
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final x0 = i * pitchX + (pitchX - s) / 2;
        final y0 = j * pitchY + (pitchY - s) / 2;
        final x1 = x0 + s;
        final y1 = y0 + s;
        final z00 = z(x0, y0), z10 = z(x1, y0), z01 = z(x0, y1), z11 = z(x1, y1);
        final tri = [x0, y0, z00, x1, y0, z10, x0, y1, z01, x1, y0, z10, x1, y1, z11, x0, y1, z01];
        xyz.setRange(o, o + 18, tri);
        o += 18;
        final color = (i + j).isEven ? 0x732E7D32 : 0x73E65100;
        colors.fillRange(v, v + 6, color);
        v += 6;
      }
    }
    return PolygonBatch(xyz, colors);
  }

  // ── シーン ─────────────────────────────────────────

  Future<void> _loadSynthetic() async {
    final dem = DemGrid.synthetic(cols: _gridPoints, rows: _gridPoints);
    _sceneName = '合成 $_gridPoints²';
    _attribution = '合成地形（テクスチャも合成）';
    _setScene(dem, zScale: WebMercator.zScaleAt(_kitayamaLat));
    final tex = await _buildSyntheticTexture();
    _setTexture(tex, _syntheticTextureSize, _syntheticTextureSize);
  }

  /// 北山村の実 DEM（AWS Terrain Tiles）と地理院標準地図
  Future<void> _loadReal(int z, int tilesAcross) async {
    setState(() => _status = '標高タイル取得中…');
    final range = TileRange.around(_kitayamaLon, _kitayamaLat, z, tilesAcross);
    try {
      final dem = await DemTileLoader(source: DemTileSource.aws).load(
        range,
        onProgress: (d, t) => setState(() => _status = '標高タイル $d/$t'),
      );
      if (!mounted) return;
      _sceneName = '北山村 z$z ${tilesAcross}x$tilesAcross';
      _attribution = '地理院タイル（標準地図） / ${DemTileSource.aws.attribution}';
      _setScene(dem, zScale: WebMercator.zScaleAt(_kitayamaLat));
      final texRange = range.zoomIn(2);
      final tex = await RasterTileComposer(
        urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png',
      ).compose(texRange, onProgress: (d, t) => setState(() => _status = '地図タイル $d/$t'));
      if (!mounted) {
        tex.dispose();
        return;
      }
      _setTexture(tex, tex.width, tex.height);
      setState(() => _status = '');
    } catch (e) {
      setState(() => _status = '取得失敗: $e');
    }
  }

  void _setScene(DemGrid dem, {required double zScale}) {
    _dem = dem;
    _camera
      ..centerX = dem.originX + dem.width / 2
      ..centerY = dem.originY + dem.height / 2
      ..scale = 800 / dem.width
      ..zScale = zScale;
    final rnd = math.Random(7);
    // 線: 対角を蛇行する道 1 本 + 等高線風の環 3 本 + 短い区画線 20 本（DEM 原点基準）
    final w = dem.width;
    final lines = <List<Offset>>[];
    final road = <Offset>[];
    for (var i = 0; i <= 60; i++) {
      final t = i / 60;
      road.add(Offset(t * w, t * w + math.sin(t * 12) * w * 0.05));
    }
    lines.add(road);
    for (var k = 0; k < 3; k++) {
      final cx = w * (0.25 + 0.25 * k);
      final cy = w * (0.3 + 0.2 * k);
      final r = w * 0.08 * (k + 1);
      lines.add([
        for (var i = 0; i <= 48; i++)
          Offset(
            cx + r * math.cos(i / 48 * 2 * math.pi),
            cy + r * math.sin(i / 48 * 2 * math.pi) * 0.7,
          ),
      ]);
    }
    for (var k = 0; k < 20; k++) {
      final a = Offset(rnd.nextDouble() * w, rnd.nextDouble() * w);
      lines.add([a, a + Offset(rnd.nextDouble() * w * 0.15 - w * 0.075, rnd.nextDouble() * w * 0.15 - w * 0.075)]);
    }
    _rawLines = lines;
    // 面: 凸六角形・凹の L 字・大きめの四角（区画のつもり）
    final s = w * 0.12;
    _rawPolygons = [
      [
        for (var i = 0; i < 6; i++)
          Offset(w * 0.2 + s * math.cos(i / 6 * 2 * math.pi), w * 0.7 + s * math.sin(i / 6 * 2 * math.pi)),
      ],
      [
        Offset(w * 0.55, w * 0.15),
        Offset(w * 0.75, w * 0.15),
        Offset(w * 0.75, w * 0.22),
        Offset(w * 0.62, w * 0.22),
        Offset(w * 0.62, w * 0.35),
        Offset(w * 0.55, w * 0.35),
      ],
      [
        Offset(w * 0.6, w * 0.6),
        Offset(w * 0.85, w * 0.62),
        Offset(w * 0.83, w * 0.85),
        Offset(w * 0.58, w * 0.8),
      ],
    ];
    _linesByStep.clear();
    _polygonsByStep.clear();
    _sceneByStep.clear();
    _contoursByStep.clear();
    _builders.clear();
    _worldMesh = null;
    _worldTiles = const [];
    _extractContours();
    final cells = (dem.cols - 1) * (dem.rows - 1);
    _coarseStep = math.max(2, math.sqrt(cells / _gestureCellBudget).ceil());
    _rebuildLabels();
    _rebuildMesh();
    _painter?.selected = null;
    _hitText = '';
  }

  /// 等高線のキャッシュを捨てる（間隔や DEM が変わったとき）
  void _extractContours() {
    _contoursByStep.clear();
    _contourLinesByStep.clear();
    _contourCount = 0;
    _lastContour = Duration.zero;
  }

  /// [meshStep] の格子に合わせて等高線を引く（間隔 0 = なし）
  ///
  /// ジェスチャ中（間引いた格子）は等高線も間引いた格子から引く。線分数が減って raster が軽くなる
  List<List<Offset>> _contourLinesFor(int meshStep) {
    final dem = _dem;
    if (dem == null || _contourInterval <= 0) return const [];
    return _contourLinesByStep[meshStep] ??= () {
      final sw = Stopwatch()..start();
      // 全解像度でもセル数 10 万を目安に間引く
      final cells = (dem.cols - 1) * (dem.rows - 1);
      final step = math.max(meshStep, math.sqrt(cells / 100000).ceil());
      final byLevel = ContourExtractor.extract(dem, interval: _contourInterval, step: step);
      final lines = [for (final segs in byLevel.values) ...segs];
      _lastContour = sw.elapsed;
      return lines;
    }();
  }

  void _setTexture(ui.Image image, int width, int height) {
    _texture?.dispose();
    _texture = image;
    _textureWidth = width;
    _textureHeight = height;
    // テクスチャ座標はビルダーが持つので作り直す
    _builders.clear();
    _worldMesh = null;
    _worldTiles = const [];
    _painter?.texture = image;
    _rebuildMesh();
    if (_useGpu) _ensureGpu();
  }

  TerrainMeshBuilder _builderFor(int step) => _builders[step] ??= TerrainMeshBuilder(
        _dem!,
        textureWidth: _textureWidth,
        textureHeight: _textureHeight,
        chunkSize: _chunkSize,
        step: step,
      );

  void _rebuildLabels() {
    final dem = _dem!;
    final rnd = math.Random(11);
    _labels = [
      for (var i = 0; i < _labelCount; i++)
        TerrainLabel(
          x: rnd.nextDouble() * dem.width,
          y: rnd.nextDouble() * dem.height,
          painter: TextPainter(
            text: TextSpan(
              text: '区画 ${i + 1}',
              style: const TextStyle(fontSize: 12, color: Colors.black),
            ),
            textDirection: TextDirection.ltr,
          )..layout(),
        ),
    ];
    _painter?.labels = _labels;
    _repaint.value++;
  }

  /// DEM の中に置いた GeoJSON のサンプル（経度緯度）。既存の地図と同じ形でシーンにする
  TerrainScene _buildGeoJsonScene(TerrainMesh mesh) {
    final dem = mesh.dem;
    geo.Geographic at(double fx, double fy) => geo.Geographic(
          lon: WebMercator.lonFromX(dem.originX + dem.width * fx),
          lat: WebMercator.latFromY(dem.originY + dem.height * fy),
        );
    final builder = TerrainSceneBuilder(
      mesh: mesh,
      stylesByKey: {
        'road': const TerrainFeatureStyle(
          lineColor: Color(0xFFE53935), lineWidth: 4,
          fillColor: Color(0x00000000), outlineColor: Color(0x00000000), outlineWidth: 0,
          pointColor: Color(0xFFE53935), pointSize: 6,
        ),
        'stand': const TerrainFeatureStyle(
          lineColor: Color(0xFF2E7D32), lineWidth: 2,
          fillColor: Color(0x662E7D32), outlineColor: Color(0xFF1B5E20), outlineWidth: 2,
          pointColor: Color(0xFF2E7D32), pointSize: 6,
        ),
      },
    );
    return builder.build(
      lines: [
        geo.Feature<geo.Geometry>(
          geometry: geo.LineString.from([for (var i = 0; i <= 20; i++) at(i / 20, 0.15 + 0.6 * i / 20)]),
          properties: const {'k-style': 'road', 'k-label': '林道 1 号'},
        ),
        geo.Feature<geo.Geometry>(
          geometry: geo.LineString.from([at(0.1, 0.8), at(0.4, 0.75), at(0.5, 0.9)]),
          properties: const {'k-label': '作業道'},
        ),
      ],
      polygons: [
        geo.Feature<geo.Geometry>(
          geometry: geo.Polygon.from([
            [at(0.55, 0.2), at(0.85, 0.25), at(0.8, 0.5), at(0.6, 0.45), at(0.55, 0.2)],
          ]),
          properties: const {'k-style': 'stand', 'k-label': '12 林班'},
        ),
        geo.Feature<geo.Geometry>(
          geometry: geo.Polygon.from([
            [at(0.15, 0.3), at(0.35, 0.3), at(0.35, 0.5), at(0.15, 0.5), at(0.15, 0.3)],
          ]),
          properties: const {'k-label': '13 林班'},
        ),
      ],
      points: [
        for (var i = 0; i < 12; i++)
          geo.Feature<geo.Point>(
            geometry: geo.Point(at(0.1 + 0.07 * i, 0.6 + 0.03 * (i % 3))),
            properties: {'k-style': i.isEven ? 'road' : 'stand', 'k-label': '測点 ${i + 1}'},
          ),
      ],
    );
  }

  /// [coarse] はジェスチャ・アニメ中の LOD（格子を間引く）で組む
  void _rebuildMesh({bool coarse = false}) {
    // GPU 描画系では頂点を組み直さない（それを無くすのがスパイクの目的）。面・ラベルを持ち上げる土台の
    // メッシュは最初の 1 回だけ組む
    if ((_useGpu || _useWorld) && _mesh != null) {
      _repaint.value++;
      return;
    }
    final step = (coarse && _lod) ? _coarseStep : 1;
    final mesh = _builderFor(step).build(_camera);
    _mesh = mesh;
    _lastBuild = mesh.buildTime;
    _timing = mesh.timing.toString();
    final sw = Stopwatch()..start();
    if (_useGeoJson) {
      final scene = _sceneByStep[step] ??= _buildGeoJsonScene(mesh);
      final contours = _contoursByStep[step] ??=
          LiftedSegments.lift(_contourLinesFor(step), mesh, color: const Color(0xCC6D4C41), widthPx: 1);
      _contourCount = contours.segmentCount;
      _lastLift = sw.elapsed;
      _painter
        ?..mesh = mesh
        ..lines = [...scene.outlines, ...scene.lines]
        ..polygons = scene.polygons
        ..points = scene.points
        ..labels = scene.labels
        ..segmentSets = [contours];
      _repaint.value++;
      return;
    }
    final colors = [Colors.red, Colors.blue, Colors.orange, Colors.purple];
    _lines = _linesByStep[step] ??= [
      for (var i = 0; i < _rawLines.length; i++)
        LiftedPolyline.lift(
          _rawLines[i],
          mesh,
          color: i == 0 ? Colors.red : colors[i % colors.length],
          widthPx: i == 0 ? 4 : 2,
        ),
    ];
    final fills = [
      Colors.green.withValues(alpha: 0.45),
      Colors.deepOrange.withValues(alpha: 0.45),
      Colors.indigo.withValues(alpha: 0.35),
    ];
    _polygons = _polygonsByStep[step] ??= [
      for (var i = 0; i < _rawPolygons.length; i++)
        LiftedPolygon.lift(_rawPolygons[i], mesh, color: fills[i % fills.length]),
    ];
    final contours = _contoursByStep[step] ??=
        LiftedSegments.lift(_contourLinesFor(step), mesh, color: const Color(0xCC6D4C41), widthPx: 1);
    _contourCount = contours.segmentCount;
    _lastLift = sw.elapsed;
    _painter
      ?..mesh = mesh
      ..lines = _lines
      ..polygons = _polygons
      ..points = const []
      ..labels = _labels
      ..segmentSets = [contours];
    _repaint.value++;
  }

  /// 地図らしいテクスチャを描いて画像にする（格子線・区画の塗り・道路・数字）
  Future<ui.Image> _buildSyntheticTexture() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const s = _syntheticTextureSize * 1.0;
    canvas.drawRect(const Rect.fromLTWH(0, 0, s, s), Paint()..color = const Color(0xFFE8F0DC));
    final rnd = math.Random(3);
    for (var i = 0; i < 80; i++) {
      final rect = Rect.fromLTWH(
        rnd.nextDouble() * s,
        rnd.nextDouble() * s,
        60 + rnd.nextDouble() * 300,
        60 + rnd.nextDouble() * 300,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = Color.lerp(
            const Color(0xFFB7D7A8),
            const Color(0xFF6FA86A),
            rnd.nextDouble(),
          )!
              .withValues(alpha: 0.7),
      );
    }
    final grid = Paint()
      ..color = const Color(0xFF9AA5B1)
      ..strokeWidth = 1;
    const cellPx = s / 20;
    for (var i = 0; i <= 20; i++) {
      canvas.drawLine(Offset(i * cellPx, 0), Offset(i * cellPx, s), grid);
      canvas.drawLine(Offset(0, i * cellPx), Offset(s, i * cellPx), grid);
    }
    final road = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke;
    final roadEdge = Paint()
      ..color = const Color(0xFF888888)
      ..strokeWidth = 9
      ..style = PaintingStyle.stroke;
    final path = Path()..moveTo(0, s * 0.7);
    for (var i = 1; i <= 40; i++) {
      final t = i / 40;
      path.lineTo(t * s, s * 0.7 - t * s * 0.5 + math.sin(t * 9) * 80);
    }
    canvas.drawPath(path, roadEdge);
    canvas.drawPath(path, road);
    for (var i = 0; i < 20; i++) {
      for (var j = 0; j < 20; j++) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${i * 20 + j}',
            style: const TextStyle(fontSize: 22, color: Color(0xFF445566)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(i * cellPx + 6, j * cellPx + 4));
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(_syntheticTextureSize, _syntheticTextureSize);
    picture.dispose();
    return image;
  }

  // ── 計測・アニメ ───────────────────────────────────

  void _onTick(Duration elapsed) {
    _frames++;
    if (elapsed - _windowStart >= const Duration(seconds: 1)) {
      final secs = (elapsed - _windowStart).inMicroseconds / 1e6;
      _fps = _frames / secs;
      _frames = 0;
      _windowStart = elapsed;
      String stat(List<int> v) {
        if (v.isEmpty) return '-';
        final s = [...v]..sort();
        return '${s[s.length ~/ 2]}/${s.last}';
      }
      final line =
          'spike fps=${_fps.toStringAsFixed(1)} ui=${stat(_uiMs)} raster=${stat(_rasterMs)} '
          'paint=${_lastPaint.inMilliseconds}ms '
          'build=${_lastBuild.inMilliseconds}ms ($_timing) lift=${_lastLift.inMilliseconds}ms '
          'contour=${_contourInterval.toStringAsFixed(0)}m/$_contourCount本/${_lastContour.inMilliseconds}ms '
          'step=${_mesh?.step} lod=$_lod chunk=$_chunkSize '
          'scene=${_sceneName.replaceAll(' ', '_')} labels=$_labelCount anim=$_animation'
          '${_useGpu ? ' persp=$_perspective loadPolys=$_gpuLoadPolygons ${_gpu?.stats}' : ''}'
          '${_useWorld && _worldGpu != null ? ' world persp=$_perspective encode=${_worldGpu!.lastEncode.inMilliseconds}ms draws=${_worldGpu!.lastDrawCalls} tex=${_worldGpu!.mippedTextureCount}/${_worldGpu!.textureCount} err=${_worldGpu!.lastError}' : ''}';
      _uiMs.clear();
      _rasterMs.clear();
      setSpikeTitle(line);
      debugPrint(line); // Android は logcat で拾う
      if (mounted) setState(() {}); // 計測表示の更新は 1 秒に 1 回だけ
    }
    final dem = _dem;
    if (dem == null) return;
    switch (_animation) {
      case 'rotate':
        _camera.bearing += 0.5 * math.pi / 180;
        _rebuildMesh(coarse: true);
      case 'pitch':
        _camera.pitch = (math.sin(elapsed.inMilliseconds / 2000) * 0.5 + 0.5) * 60 * math.pi / 180;
        _rebuildMesh(coarse: true);
      case 'pan':
        final r = dem.width * 0.2;
        _camera.centerX = dem.originX + dem.width / 2 + math.sin(elapsed.inMilliseconds / 1500) * r;
        _camera.centerY = dem.originY + dem.height / 2 + math.cos(elapsed.inMilliseconds / 1500) * r;
        _repaint.value++;
      default:
        return; // 静止中は描き直さない
    }
  }

  // ── ジェスチャ ─────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _scaleStart = _camera.scale;
    _bearingStart = _camera.bearing;
    _pitchStart = _camera.pitch;
    _focalStart = d.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      _camera.scale = (_scaleStart * d.scale).clamp(0.02, 20);
      _camera.bearing = _bearingStart - d.rotation;
      final dy = d.focalPoint.dy - _focalStart.dy;
      _camera.pitch = (_pitchStart - dy * 0.004).clamp(0.0, _maxPitchDeg * math.pi / 180);
      _rebuildMesh(coarse: true);
    } else {
      final move = _camera.unprojectPan(d.focalPointDelta);
      _camera.centerX -= move.dx;
      _camera.centerY -= move.dy;
      _repaint.value++;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // ジェスチャが終わったら全解像度で組み直す
    setState(_rebuildMesh);
  }

  void _onTapUp(TapUpDetails d, Size size) {
    if (_useGpu || _useWorld) {
      setState(() => _hitText = 'GPU 描画系: ヒットテストはスパイクの範囲外');
      return;
    }
    final painter = _painter;
    if (painter == null) return;
    final sw = Stopwatch()..start();
    final hit = painter.pick(d.localPosition, size);
    final ground = painter.unproject(d.localPosition, size);
    painter.selected = hit;
    _repaint.value++;
    final dem = _dem!;
    final where = ground == null
        ? '地形外'
        : '${WebMercator.latFromY(ground.dy + dem.originY).toStringAsFixed(5)}, '
            '${WebMercator.lonFromX(ground.dx + dem.originX).toStringAsFixed(5)} '
            '${dem.elevationAt(ground.dx + dem.originX, ground.dy + dem.originY).toStringAsFixed(0)}m';
    setState(() {
      _hitText = hit == null
          ? 'タップ: なし @ $where (${sw.elapsedMilliseconds}ms)'
          : 'タップ: ${hit.kind == 'label' ? painter.labels[hit.index].painter.plainText : hit} @ $where (${sw.elapsedMilliseconds}ms)';
    });
  }

  // ── UI ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mesh = _mesh;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'fps ${_fps.toStringAsFixed(1)}  paint ${_lastPaint.inMilliseconds}ms  '
          'build ${_lastBuild.inMilliseconds}ms ($_timing) step ${_mesh?.step}',
          style: const TextStyle(fontSize: 13),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: mesh == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      _camera
                        ..viewport = size
                        ..perspective = _useWorld && _perspective;
                      final worldGpu = _worldGpu;
                      return Stack(
                        children: [
                          // 本体の描画系（web は WebGL2 の canvas を下に敷く）
                          if (_useWorld && worldGpu != null && worldGpu.platformViewType != null)
                            Positioned.fill(child: IgnorePointer(child: HtmlElementView(viewType: worldGpu.platformViewType!))),
                          GestureDetector(
                            onScaleStart: _onScaleStart,
                            onScaleUpdate: _onScaleUpdate,
                            onScaleEnd: _onScaleEnd,
                            onTapUp: (d) => _onTapUp(d, size),
                            child: ClipRect(
                              child: CustomPaint(
                                painter: _useWorld && worldGpu != null && _dem != null
                                    ? _worldPainterFor(context)
                                    : _useGpu && _gpu != null && _dem != null
                                    ? _GpuSpikePainter(
                                        renderer: _gpu!,
                                        camera: _camera,
                                        dem: _dem!,
                                        labels: _labels,
                                        perspective: _perspective,
                                        pixelRatio: MediaQuery.devicePixelRatioOf(context),
                                        onPainted: (d) => _lastPaint = d,
                                        repaint: _repaint,
                                      )
                                    : _painter ??= TerrainPainter(
                                        mesh: mesh,
                                        camera: _camera,
                                        texture: _texture,
                                        lines: _lines,
                                        polygons: _polygons,
                                        labels: _labels,
                                        onPainted: (d) => _lastPaint = d,
                                        repaint: _repaint,
                                      ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 6,
                            bottom: 4,
                            child: Text(
                              _attribution,
                              style: const TextStyle(fontSize: 10, color: Colors.black87, backgroundColor: Colors.white70),
                            ),
                          ),
                          if (_status.isNotEmpty || _hitText.isNotEmpty || _gpuStatus.isNotEmpty)
                            Positioned(
                              left: 6,
                              top: 4,
                              child: Text(
                                [_status, _hitText, _gpuStatus].where((s) => s.isNotEmpty).join('  '),
                                style: const TextStyle(fontSize: 12, color: Colors.black, backgroundColor: Colors.white70),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
          _buildControls(),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final pitchDeg = _camera.pitch * 180 / math.pi;
    final bearingDeg = (_camera.bearing * 180 / math.pi) % 360;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(width: 72, child: Text('pitch ${pitchDeg.toStringAsFixed(0)}°')),
                Expanded(
                  child: Slider(
                    value: math.min(pitchDeg, _maxPitchDeg),
                    max: _maxPitchDeg,
                    onChanged: (v) => setState(() {
                      _camera.pitch = v * math.pi / 180;
                      _rebuildMesh();
                    }),
                  ),
                ),
                SizedBox(width: 80, child: Text('方位 ${bearingDeg.toStringAsFixed(0)}°')),
                Expanded(
                  child: Slider(
                    value: bearingDeg,
                    max: 360,
                    onChanged: (v) => setState(() {
                      _camera.bearing = v * math.pi / 180;
                      _rebuildMesh();
                    }),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('合成'),
                for (final n in [201, 401, 801])
                  ChoiceChip(
                    label: Text('$n²'),
                    selected: _sceneName == '合成 $n²',
                    onSelected: (_) => setState(() {
                      _gridPoints = n;
                      _loadSynthetic();
                    }),
                  ),
                const Text('北山村'),
                for (final (z, t) in [(13, 2), (14, 2), (14, 4)])
                  ChoiceChip(
                    label: Text('z$z ${t}x$t'),
                    selected: _sceneName == '北山村 z$z ${t}x$t',
                    onSelected: (_) => _loadReal(z, t),
                  ),
                const SizedBox(width: 8),
                const Text('ラベル'),
                for (final n in [0, 200, 1000])
                  ChoiceChip(
                    label: Text('$n'),
                    selected: _labelCount == n,
                    onSelected: (_) => setState(() {
                      _labelCount = n;
                      _rebuildLabels();
                    }),
                  ),
                const SizedBox(width: 8),
                const Text('チャンク'),
                for (final n in [16, 32, 64])
                  ChoiceChip(
                    label: Text('c$n'),
                    selected: _chunkSize == n,
                    onSelected: (_) => setState(() {
                      _chunkSize = n;
                      _builders.clear();
                      _rebuildMesh();
                    }),
                  ),
                for (final v in [true, false])
                  ChoiceChip(
                    label: Text(v ? 'lod on' : 'lod off'),
                    selected: _lod == v,
                    onSelected: (_) => setState(() {
                      _lod = v;
                      _rebuildMesh();
                    }),
                  ),
                ChoiceChip(
                  label: const Text('GeoJSON'),
                  selected: _useGeoJson,
                  onSelected: (v) => setState(() {
                    _useGeoJson = v;
                    _painter?.selected = null;
                    _rebuildMesh();
                  }),
                ),
                const Text('等高線'),
                for (final n in [0.0, 10.0, 20.0, 50.0])
                  ChoiceChip(
                    label: Text(n == 0 ? 'なし' : '${n.toStringAsFixed(0)}m'),
                    selected: _contourInterval == n,
                    onSelected: (_) => setState(() {
                      _contourInterval = n;
                      _extractContours();
                      _rebuildMesh();
                    }),
                  ),
                const Text('アニメ'),
                for (final a in ['none', 'pan', 'rotate', 'pitch'])
                  ChoiceChip(
                    label: Text(a),
                    selected: _animation == a,
                    onSelected: (_) => setState(() => _animation = a),
                  ),
                const Text('GPU'),
                ChoiceChip(
                  label: Text(TerrainGpuRenderer.isSupported ? 'flutter_gpu' : 'flutter_gpu（web 不可）'),
                  selected: _useGpu,
                  onSelected: TerrainGpuRenderer.isSupported
                      ? (v) {
                          setState(() {
                            _useGpu = v;
                            _gpuStatus = v ? 'GPU 準備中…' : '';
                          });
                          if (v) {
                            _ensureGpu();
                          } else {
                            _camera.pitch = math.min(_camera.pitch, 70 * math.pi / 180);
                            _rebuildMesh();
                          }
                        }
                      : null,
                ),
                ChoiceChip(
                  label: const Text('world GPU'),
                  selected: _useWorld,
                  onSelected: (v) {
                    setState(() {
                      _useWorld = v;
                      _gpuStatus = v ? 'world GPU 準備中…' : '';
                    });
                    if (v) {
                      _ensureWorldGpu();
                    } else {
                      _worldPainter = null;
                      _camera.pitch = math.min(_camera.pitch, 70 * math.pi / 180);
                      _rebuildMesh();
                    }
                  },
                ),
                if (_useWorld) ...[
                  ChoiceChip(
                    label: const Text('深度なし'),
                    selected: TerrainGpuWorldRenderer.debugNoDepth,
                    onSelected: (v) => setState(() {
                      TerrainGpuWorldRenderer.debugNoDepth = v;
                      _repaint.value++;
                    }),
                  ),
                  ChoiceChip(
                    label: const Text('getError'),
                    selected: TerrainGpuWorldRenderer.debugCheckErrors,
                    onSelected: (v) => setState(() {
                      TerrainGpuWorldRenderer.debugCheckErrors = v;
                      _repaint.value++;
                    }),
                  ),
                  ChoiceChip(
                    label: const Text('flush'),
                    selected: TerrainGpuWorldRenderer.debugFlush,
                    onSelected: (v) => setState(() {
                      TerrainGpuWorldRenderer.debugFlush = v;
                      _repaint.value++;
                    }),
                  ),
                  ChoiceChip(
                    label: const Text('MSAA なし'),
                    selected: TerrainGpuWorldRenderer.debugDirect,
                    onSelected: (v) => setState(() {
                      TerrainGpuWorldRenderer.debugDirect = v;
                      _repaint.value++;
                    }),
                  ),
                ],
                ChoiceChip(
                  label: const Text('透視'),
                  selected: _perspective,
                  onSelected: _useGpu || _useWorld
                      ? (v) => setState(() {
                            _perspective = v;
                            _repaint.value++;
                          })
                      : null,
                ),
                for (final n in [0, 10000, 100000])
                  ChoiceChip(
                    label: Text(n == 0 ? '負荷面なし' : '${n ~/ 10000}万面'),
                    selected: _gpuLoadPolygons == n,
                    onSelected: _useGpu
                        ? (_) {
                            setState(() => _gpuLoadPolygons = n);
                            _uploadGpuPolygons();
                          }
                        : null,
                  ),
                Text(
                  'zoom ${_camera.scale.toStringAsFixed(2)} px/m  '
                  '格子 ${_dem?.cols}x${_dem?.rows} (${_dem?.cellSize.toStringAsFixed(1)}m)  '
                  'LOD step $_coarseStep  帯 ${_mesh?.bands.length ?? 0}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// flutter_gpu で描いた画像を貼り、ラベルを Canvas で上描きする（スパイク用。重なり判定なし・200 個まで）
class _GpuSpikePainter extends CustomPainter {
  _GpuSpikePainter({
    required this.renderer,
    required this.camera,
    required this.dem,
    required this.labels,
    required this.perspective,
    required this.pixelRatio,
    this.onPainted,
    super.repaint,
  });

  final TerrainGpuRenderer renderer;
  final TerrainCamera camera;
  final DemGrid dem;
  final List<TerrainLabel> labels;
  final bool perspective;
  final double pixelRatio;
  final void Function(Duration)? onPainted;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    final image = renderer.render(
      camera,
      size,
      origin: Offset(dem.originX, dem.originY),
      centerHeight: dem.elevationAt(camera.centerX, camera.centerY),
      pixelRatio: pixelRatio,
      perspective: perspective,
    );
    if (image != null) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Offset.zero & size,
        Paint()..filterQuality = FilterQuality.low,
      );
    }
    final viewport = Offset.zero & size;
    final boxPaint = Paint()..color = Colors.white.withValues(alpha: 0.85);
    final anchorPaint = Paint()..color = Colors.black;
    var placed = 0;
    for (final label in labels) {
      if (placed >= 200) break;
      final z = dem.elevationAt(dem.originX + label.x, dem.originY + label.y);
      final sp = renderer.toScreen(label.x, label.y, z, size);
      if (sp == null || !viewport.contains(sp)) continue;
      final tp = label.painter;
      final origin = sp - Offset(tp.width / 2, tp.height + 4);
      final box = Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(3)), boxPaint);
      tp.paint(canvas, origin);
      canvas.drawCircle(sp, 2.5, anchorPaint);
      placed++;
    }
    onPainted?.call(sw.elapsed);
  }

  @override
  bool shouldRepaint(covariant _GpuSpikePainter old) => true;
}
