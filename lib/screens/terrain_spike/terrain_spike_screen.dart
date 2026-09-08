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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/terrain/contours.dart';
import '../../core/terrain/dem_grid.dart';
import '../../core/terrain/dem_tiles.dart';
import '../../core/terrain/terrain_camera.dart';
import '../../core/terrain/terrain_mesh.dart';
import '../../core/terrain/terrain_painter.dart';
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
  List<List<Offset>> _contourLines = const [];
  final Map<int, LiftedSegments> _contoursByStep = {};
  Duration _lastContour = Duration.zero;
  String _hitText = '';

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
    super.dispose();
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
    _contoursByStep.clear();
    _builders.clear();
    _extractContours();
    final cells = (dem.cols - 1) * (dem.rows - 1);
    _coarseStep = math.max(2, math.sqrt(cells / _gestureCellBudget).ceil());
    _rebuildLabels();
    _rebuildMesh();
    _painter?.selected = null;
    _hitText = '';
  }

  /// DEM から等高線を引き直す（間隔 0 = なし）
  void _extractContours() {
    final dem = _dem;
    _contoursByStep.clear();
    if (dem == null || _contourInterval <= 0) {
      _contourLines = const [];
      _lastContour = Duration.zero;
      return;
    }
    final sw = Stopwatch()..start();
    // 格子が細かすぎると線分が増えるので、セル数 10 万を目安に間引く
    final cells = (dem.cols - 1) * (dem.rows - 1);
    final step = math.max(1, math.sqrt(cells / 100000).ceil());
    final byLevel = ContourExtractor.extract(dem, interval: _contourInterval, step: step);
    _contourLines = [for (final segs in byLevel.values) ...segs];
    _lastContour = sw.elapsed;
  }

  void _setTexture(ui.Image image, int width, int height) {
    _texture?.dispose();
    _texture = image;
    _textureWidth = width;
    _textureHeight = height;
    // テクスチャ座標はビルダーが持つので作り直す
    _builders.clear();
    _painter?.texture = image;
    _rebuildMesh();
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

  /// [coarse] はジェスチャ・アニメ中の LOD（格子を間引く）で組む
  void _rebuildMesh({bool coarse = false}) {
    final step = (coarse && _lod) ? _coarseStep : 1;
    final mesh = _builderFor(step).build(_camera);
    _mesh = mesh;
    _lastBuild = mesh.buildTime;
    _timing = mesh.timing.toString();
    final sw = Stopwatch()..start();
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
        LiftedSegments.lift(_contourLines, mesh, color: const Color(0xCC6D4C41), widthPx: 1);
    _lastLift = sw.elapsed;
    _painter
      ?..mesh = mesh
      ..lines = _lines
      ..polygons = _polygons
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
          'contour=${_contourInterval.toStringAsFixed(0)}m/${_contourLines.length}本/${_lastContour.inMilliseconds}ms '
          'step=${_mesh?.step} lod=$_lod chunk=$_chunkSize '
          'scene=${_sceneName.replaceAll(' ', '_')} labels=$_labelCount anim=$_animation';
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
      _camera.pitch = (_pitchStart - dy * 0.004).clamp(0.0, 70 * math.pi / 180);
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
    final painter = _painter;
    if (painter == null) return;
    final sw = Stopwatch()..start();
    final hit = painter.pick(d.localPosition, size);
    painter.selected = hit;
    _repaint.value++;
    setState(() {
      _hitText = hit == null
          ? 'タップ: なし (${sw.elapsedMilliseconds}ms)'
          : 'タップ: ${hit.kind == 'label' ? '区画 ${hit.index + 1}' : hit} (${sw.elapsedMilliseconds}ms)';
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
                      return Stack(
                        children: [
                          GestureDetector(
                            onScaleStart: _onScaleStart,
                            onScaleUpdate: _onScaleUpdate,
                            onScaleEnd: _onScaleEnd,
                            onTapUp: (d) => _onTapUp(d, size),
                            child: ClipRect(
                              child: CustomPaint(
                                painter: _painter ??= TerrainPainter(
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
                          if (_status.isNotEmpty || _hitText.isNotEmpty)
                            Positioned(
                              left: 6,
                              top: 4,
                              child: Text(
                                [_status, _hitText].where((s) => s.isNotEmpty).join('  '),
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
                    value: pitchDeg,
                    max: 70,
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
                const Text('等高線'),
                for (final n in [0.0, 10.0, 20.0, 50.0])
                  ChoiceChip(
                    label: Text(n == 0 ? 'なし' : '${n.toStringAsFixed(0)}m'),
                    selected: _contourInterval == n,
                    onSelected: (_) => setState(() {
                      _contourInterval = n;
                      _extractContours();
                      _contoursByStep.clear();
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
