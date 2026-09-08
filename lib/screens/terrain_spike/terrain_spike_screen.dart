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

import '../../core/terrain/dem_grid.dart';
import '../../core/terrain/terrain_camera.dart';
import '../../core/terrain/terrain_mesh.dart';
import '../../core/terrain/terrain_painter.dart';
import 'spike_title_stub.dart'
    if (dart.library.js_interop) 'spike_title_web.dart';

/// 3D 描画スパイク（開発用・製品機能ではない）
///
/// 純 Dart（`drawVertices` + painter's algorithm）で
/// 「DEM + 背景テクスチャ + 持ち上げた線 + ラベル」を描いて fps を測る。
/// 設計は Vault の `3D化の詰め_2026-09-07`。
///
/// 操作: 1 本指ドラッグ = pan、2 本指 = ズーム / 回転 / 上下で pitch。
/// 下のパネルで格子サイズ・ラベル数・アニメーションを切り替える。
/// web ではタブのタイトルに計測値を出す。
class TerrainSpikeScreen extends StatefulWidget {
  const TerrainSpikeScreen({super.key});

  @override
  State<TerrainSpikeScreen> createState() => _TerrainSpikeScreenState();
}

class _TerrainSpikeScreenState extends State<TerrainSpikeScreen>
    with SingleTickerProviderStateMixin {
  static const _textureSize = 2048;

  int _gridPoints = 401; // 5m 格子 × 401 = 2km 四方
  int _labelCount = 200;
  DemGrid? _dem;
  ui.Image? _texture;
  TerrainMesh? _mesh;
  TerrainMeshBuilder? _builderFull;
  TerrainMeshBuilder? _builderCoarse; // ジェスチャ・アニメ中の LOD（1 つ飛ばし）
  bool _lod = true;
  int _chunkSize = 32;
  final _repaint = ValueNotifier<int>(0);
  TerrainPainter? _painter;
  Duration _lastLift = Duration.zero;
  final Map<int, List<LiftedPolyline>> _linesByStep = {}; // 持ち上げはカメラに依らないので step ごとに使い回す
  String _timing = '';
  late TerrainCamera _camera;
  List<LiftedPolyline> _lines = const [];
  List<TerrainLabel> _labels = const [];
  List<List<Offset>> _rawLines = const [];

  // 計測
  late final Ticker _ticker;
  int _frames = 0;
  Duration _windowStart = Duration.zero;
  double _fps = 0;
  Duration _lastPaint = Duration.zero;
  Duration _maxPaint = Duration.zero;
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
    _camera = TerrainCamera(
      centerX: 1000,
      centerY: 1000,
      scale: 0.4, // 0.4 px/m = 2km が 800px
      pitch: 45 * math.pi / 180,
      zScale: 1 / math.cos(33.9 * math.pi / 180), // 北山村付近の緯度
    );
    _timingsCallback = (timings) {
      for (final t in timings) {
        _uiMs.add(t.buildDuration.inMilliseconds);
        _rasterMs.add(t.rasterDuration.inMilliseconds);
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_timingsCallback);
    _ticker = createTicker(_onTick)..start();
    _rebuildScene();
    _buildTexture();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_timingsCallback);
    _texture?.dispose();
    super.dispose();
  }

  void _rebuildScene() {
    final dem = DemGrid.synthetic(cols: _gridPoints, rows: _gridPoints);
    _dem = dem;
    final rnd = math.Random(7);
    // 線: 対角を蛇行する道 1 本 + 等高線風の環 3 本 + 短い区画線 20 本
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
      lines.add([a, a + Offset(rnd.nextDouble() * 300 - 150, rnd.nextDouble() * 300 - 150)]);
    }
    _rawLines = lines;
    _linesByStep.clear();
    _builderFull = TerrainMeshBuilder(dem, textureWidth: _textureSize, textureHeight: _textureSize, chunkSize: _chunkSize);
    _builderCoarse = TerrainMeshBuilder(dem, textureWidth: _textureSize, textureHeight: _textureSize, step: 2, chunkSize: _chunkSize);
    _rebuildLabels();
    _rebuildMesh();
  }

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

  /// [coarse] は LOD（1 つ飛ばしの格子）で組む。ジェスチャ・アニメ中に使う
  void _rebuildMesh({bool coarse = false}) {
    final builder = (coarse && _lod) ? _builderCoarse! : _builderFull!;
    final mesh = builder.build(_camera);
    _mesh = mesh;
    _lastBuild = mesh.buildTime;
    _timing = mesh.timing.toString();
    final sw = Stopwatch()..start();
    final colors = [Colors.red, Colors.blue, Colors.orange, Colors.purple];
    _lines = _linesByStep[mesh.step] ??= [
      for (var i = 0; i < _rawLines.length; i++)
        LiftedPolyline.lift(
          _rawLines[i],
          mesh,
          color: i == 0 ? Colors.red : colors[i % colors.length],
          widthPx: i == 0 ? 4 : 2,
        ),
    ];
    _lastLift = sw.elapsed;
    _painter?.mesh = mesh;
    _painter?.lines = _lines;
    _repaint.value++;
  }

  /// 地図らしいテクスチャを描いて画像にする（格子線・区画の塗り・道路・数字）
  Future<void> _buildTexture() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const s = _textureSize * 1.0;
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
    const cellPx = s / 20; // 100m ごと
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
    final image = await picture.toImage(_textureSize, _textureSize);
    picture.dispose();
    if (!mounted) {
      image.dispose();
      return;
    }
    _texture = image;
    _painter?.texture = image;
    _repaint.value++;
  }

  void _onTick(Duration elapsed) {
    _frames++;
    if (elapsed - _windowStart >= const Duration(seconds: 1)) {
      final secs = (elapsed - _windowStart).inMicroseconds / 1e6;
      _fps = _frames / secs;
      _frames = 0;
      _windowStart = elapsed;
      _maxPaint = Duration.zero;
      String stat(List<int> v) {
        if (v.isEmpty) return '-';
        final s = [...v]..sort();
        return '${s[s.length ~/ 2]}/${s.last}';
      }
      final line =
          'spike fps=${_fps.toStringAsFixed(1)} ui=${stat(_uiMs)} raster=${stat(_rasterMs)} '
          'paint=${_lastPaint.inMilliseconds}ms '
          'build=${_lastBuild.inMilliseconds}ms ($_timing) lift=${_lastLift.inMilliseconds}ms '
          'step=${_mesh?.step} lod=$_lod chunk=$_chunkSize '
          'grid=$_gridPoints labels=$_labelCount anim=$_animation';
      _uiMs.clear();
      _rasterMs.clear();
      setSpikeTitle(line);
      debugPrint(line); // Android は logcat で拾う
      setState(() {}); // 計測表示の更新は 1 秒に 1 回だけ
    }
    switch (_animation) {
      case 'rotate':
        _camera.bearing += 0.5 * math.pi / 180;
        _rebuildMesh(coarse: true);
      case 'pitch':
        _camera.pitch = (math.sin(elapsed.inMilliseconds / 2000) * 0.5 + 0.5) * 60 * math.pi / 180;
        _rebuildMesh(coarse: true);
      case 'pan':
        _camera.centerX = 1000 + math.sin(elapsed.inMilliseconds / 1500) * 400;
        _camera.centerY = 1000 + math.cos(elapsed.inMilliseconds / 1500) * 400;
        _repaint.value++;
      default:
        return; // 静止中は描き直さない
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _scaleStart = _camera.scale;
    _bearingStart = _camera.bearing;
    _pitchStart = _camera.pitch;
    _focalStart = d.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      _camera.scale = (_scaleStart * d.scale).clamp(0.05, 20);
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

  @override
  Widget build(BuildContext context) {
    final mesh = _mesh;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'fps ${_fps.toStringAsFixed(1)}  paint ${_lastPaint.inMilliseconds}ms  '
          'build ${_lastBuild.inMilliseconds}ms ($_timing) step ${_mesh?.step}',
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: mesh == null
                ? const Center(child: CircularProgressIndicator())
                : GestureDetector(
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: ClipRect(
                      child: CustomPaint(
                        painter: _painter ??= TerrainPainter(
                          mesh: mesh,
                          camera: _camera,
                          texture: _texture,
                          lines: _lines,
                          labels: _labels,
                          onPainted: (d) {
                            _lastPaint = d;
                            if (d > _maxPaint) _maxPaint = d;
                          },
                          repaint: _repaint,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
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
                const Text('格子'),
                for (final n in [201, 401, 801])
                  ChoiceChip(
                    label: Text('$n²'),
                    selected: _gridPoints == n,
                    onSelected: (_) => setState(() {
                      _gridPoints = n;
                      _rebuildScene();
                    }),
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
                      _rebuildScene();
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
                const Text('アニメ'),
                for (final a in ['none', 'pan', 'rotate', 'pitch'])
                  ChoiceChip(
                    label: Text(a),
                    selected: _animation == a,
                    onSelected: (_) => setState(() => _animation = a),
                  ),
                Text(
                  'zoom ${_camera.scale.toStringAsFixed(2)} px/m  '
                  '三角形 ${((_gridPoints - 1) * (_gridPoints - 1) * 2 / 1000).toStringAsFixed(0)}k  '
                  '帯 ${_mesh?.bands.length ?? 0}',
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
