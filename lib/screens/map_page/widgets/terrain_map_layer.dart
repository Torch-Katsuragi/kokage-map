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
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../../core/terrain/dem_grid.dart';
import '../../../core/terrain/dem_tiles.dart';
import '../../../core/terrain/gpu/terrain_gpu.dart';
import '../../../core/terrain/terrain_camera.dart';
import '../../../core/terrain/terrain_frame.dart';
import '../../../core/terrain/terrain_mesh.dart';
import '../../../core/terrain/terrain_painter.dart';
import '../../../core/terrain/terrain_scene.dart';
import '../../../core/terrain/terrain_world.dart';
import '../../../core/terrain/terrain_world_painter.dart';
import '../../../core/terrain/web_mercator.dart';
import '../../../devices/base/device_tool.dart';
import '../../../i18n/strings.g.dart';
import '../../../interfaces/map_state_interface.dart';
import '../../../interfaces/terrain_projection.dart';
import '../../../models/basemap_provider.dart';
import '../../../models/nodes/overlay_image_node.dart';
import '../../../models/party/party_room.dart';
import '../../../providers/party_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/tool_providers.dart';
import '../../../services/basemap_service.dart';
import '../../../services/map_source_manager.dart';
import '../../../tools/gps_tool.dart';
import '../../../tools/map_tool.dart';
import '../../../tools/overlay_transform_tool.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/global_drawing_state.dart';
import '../../layer_style_settings_screen.dart';
import '../feature_geojson_cache.dart';

part 'terrain_map_layer_drive.dart';

/// 3D 地形モードの地図面（v2: タイルの世界）
///
/// MapLibre の地図の上に重ね、同じシーン（[FeatureGeoJsonCache] の GeoJSON と
/// [MapStyleGroup]）を純 Dart の地形描画系で描く。設計は `docs/technical/terrain-3d.md` の「v2: タイルの世界」。
///
/// - 世界は [TerrainWorld]（DEM タイルのストリーミング）。カメラが動くと見える範囲 + 余白のタイルを揃え、
///   届いたものから描く。読み込みで画面は止まらない
/// - フィーチャはタイルごとに計算メッシュへ貼り付けてキャッシュ。パンで貼り直さない
/// - 入るとき MapLibre のカメラを引き継いで 45° 傾け、出るときに書き戻す（真上ロック = 3D を抜けること）
/// - 3D 中の `IMapState.offsetToLatLng` / `latLngToOffset` は [TerrainProjection] としてここを通る
/// - 操作: 1 本指 = 回転と傾き、2 本指 = 平面移動と拡縮（松本の指定）
class TerrainMapLayer extends ConsumerStatefulWidget {
  const TerrainMapLayer({
    super.key,
    required this.mapState,
    required this.baseMapService,
    required this.geoJson,
    required this.sceneRevision,
    required this.styleGroups,
    required this.currentLocation,
    required this.gpsTrack,
    required this.onProjectionChanged,
    required this.mapBearingNotifier,
    required this.cameraTickNotifier,
    this.heading,
  });

  final IMapState mapState;
  final BaseMapService baseMapService;

  /// 地図に流している GeoJSON（通常 / 選択）。所有は map_page
  final FeatureGeoJsonCache geoJson;

  /// [geoJson] が更新されたら増える
  final ValueListenable<int> sceneRevision;

  /// View 固有スタイル（解決済み）
  final List<MapStyleGroup> Function() styleGroups;

  final LatLng? currentLocation;

  /// 今日の GPS 軌跡（未 Consolidation 分。Consolidation 済みはレイヤ経由で届く）
  final List<LatLng> Function() gpsTrack;

  /// 端末の向き（度）。現在位置から向きの線を引く（2D のコンパス扇に相当）
  final ValueListenable<double?>? heading;

  /// 投影の登録 / 解除（3D に入るとき / 出るとき）
  final void Function(TerrainProjection? projection) onProjectionChanged;

  /// コンパス扇と画面外インジケータの追従用（map_page_state_base のもの）
  final ValueNotifier<double> mapBearingNotifier;
  final ValueNotifier<int> cameraTickNotifier;

  @override
  ConsumerState<TerrainMapLayer> createState() => _TerrainMapLayerState();
}

/// タイル 1 枚ぶんの貼り付け済みフィーチャ（step ごと）
class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white.withValues(alpha: 0.9),
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 22)),
          ),
        ),
      );
}

/// 方位に合わせて回るコンパス。真上（pitch 0）でなければ縁を少し濃くして「傾いている」ことを示す
class _CompassButton extends StatelessWidget {
  const _CompassButton({required this.bearingDeg, required this.pitchDeg, required this.onPressed});

  final double bearingDeg;
  final double pitchDeg;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: t.map.terrain.resetView,
        child: Material(
          color: Colors.white.withValues(alpha: 0.9),
          shape: CircleBorder(side: BorderSide(color: pitchDeg > 1 ? Colors.blueGrey : Colors.black26, width: pitchDeg > 1 ? 2 : 1)),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Transform.rotate(
                angle: -bearingDeg * math.pi / 180,
                child: const Icon(Icons.navigation, size: 24, color: Colors.redAccent),
              ),
            ),
          ),
        ),
      );
}

class _TileScene {
  _TileScene({
    required this.key,
    required this.lines,
    required this.polygons,
    required this.points,
    required this.labels,
    this.dynamicLines = const [],
    this.dynamicPolygons = const [],
    this.dynamicPoints = const [],
    this.staticSource,
    this.complete = true,
  });

  /// まだ持ち上げていないフィーチャがある（時間を分けて育てる静的シーン）
  bool complete;

  Map<int, List<PolygonBatch>>? _batches;
  int _batchesFor = 0;
  bool _coalesced = false;

  /// 合成したシーンは静的シーンの束を指す（静的シーンが育っても同じ束を見る）
  final _TileScene? staticSource;

  /// チャンクごとの面の束。育つ間は増えたぶんだけ束を足す（作り直すと描画側の投影キャッシュが全部飛ぶ）。
  /// 育ち切ったらチャンクごとに 1 本につなぐ
  Map<int, List<PolygonBatch>> get polygonBatches {
    final src = staticSource;
    if (src != null) return src.polygonBatches;
    final batches = _batches ??= {};
    if (_batchesFor != polygons.length) {
      for (final e in PolygonBatch.byChunk(polygons, from: _batchesFor).entries) {
        (batches[e.key] ??= []).add(e.value);
      }
      _batchesFor = polygons.length;
    }
    if (complete && !_coalesced) {
      _coalesced = true;
      for (final e in batches.entries) {
        if (e.value.length > 1) batches[e.key] = [PolygonBatch.concat(e.value)];
      }
    }
    return batches;
  }

  /// 何から作ったか（GeoJSON リストの同一性・選択・軌跡の点数・パーティ・現在位置）
  final List<Object?> key;

  /// 静的（フィーチャ本体など。投影をキャッシュする）
  final List<LiftedPolyline> lines;
  final List<LiftedPolygon> polygons;

  /// 動的（描画中の線・軌跡・向きなど。毎フレーム投影）
  final List<LiftedPolyline> dynamicLines;
  final List<LiftedPolygon> dynamicPolygons;
  final List<TerrainPoint> dynamicPoints;

  /// 静的な点（投影をキャッシュする）。合成シーンでは静的シーンのリストをそのまま指す
  final List<TerrainPoint> points;
  final List<TerrainLabel> labels;
}

/// 静的シーンの育ち具合
class _StaticProgress {
  int phase = 0; // 0: 頂点・選択・写真、1: 面、2: 線、3: 完了
  int polygon = 0;
  int line = 0;

  /// このタイルに掛かるフィーチャの番号（bbox で先に絞る。1 万面を 40 枚のタイルで毎回総当たりしない）
  List<int>? polygonIdx;
  List<int>? lineIdx;

  /// 1 回の持ち上げに渡すフィーチャ数。直前の実測から 2ms ぶんに合わせる（寄った段の面は 1 つが重い）
  int chunk = 64;

  void tune(int n, int micros) {
    chunk = (n * 2000 / math.max(micros, 50)).round().clamp(8, 1000);
  }
}

class _TerrainMapLayerState extends ConsumerState<TerrainMapLayer>
    with SingleTickerProviderStateMixin, _TerrainDrive
    implements TerrainProjection {
  /// 入ったときの傾き。起動時は真上（松本 2026-09-11 決定。2D と同じ絵で始まり、傾けたい人が傾ける）
  static const _defaultPitchDeg = 0.0;

  /// 傾きの上限。正射影では 90° で地面が線に潰れる（横顔になる）ので手前で止める。
  /// 寝かせるほど画面に掛かる地面が広がり、計画が段を下げて粗くなる（枚数は上限内に収まる）
  static const _maxPitchDeg = 75.0;

  /// 標高タイルのソースごとの擬似プロバイダ（背景地図と同じ MBTiles キャッシュに入る。祖先フォールバックはしない）
  static final Map<String, BaseMapProvider> _terrainProviders = {
    for (final s in DemTileSource.defaultCascade)
      s.id: BaseMapProvider(
        id: s.id,
        name: s.id,
        description: '標高タイル ${s.id}',
        urlTemplate: s.urlTemplate,
        attribution: s.attribution,
        minZoom: s.minZoom,
        maxZoom: s.maxZoom,
        type: BaseMapType.terrain,
        icon: Icons.terrain,
      ),
  };

  /// デコード済みタイル画像。3D を出入りしても使い回す（256 枚 ≒ 64MB 上限）
  static final _tileImages = TileImageCache(capacity: 128); // 256² RGBA × 128 ≈ 32MB

  @override
  late final TerrainCamera _camera;
  @override
  late final TerrainWorld _world;
  late final TerrainFramePlanner _planner;
  late final TerrainWorldPainter _painter;

  /// 地形・面・線を描く GPU 経路（flutter_gpu）。用意できるまで／web では null（純 Dart 経路）
  TerrainGpuWorldRenderer? _gpu;
  @override
  TerrainFramePlan? _lastPlan;

  final _repaint = ValueNotifier<int>(0);
  Size _size = Size.zero;
  String _attribution = '';

  /// いま貼っている基図（設定で変わる）
  BaseMapProvider? _basemap;

  BaseMapProvider? _currentBasemap() {
    final layers = widget.baseMapService.activeLayerConfig;
    return layers.isNotEmpty ? layers.first.$1 : null;
  }

  String _attributionFor(BaseMapProvider? basemap) => [
        if (basemap != null) basemap.attribution,
        ...{for (final s in DemTileSource.defaultCascade) s.attribution},
      ].join(' / ');

  /// 基図の設定が変わった（3D 中は MapLibre が無いので、地形のテクスチャを貼り直す）
  void _onBasemapChanged() {
    final b = _currentBasemap();
    if (b?.id == _basemap?.id) return;
    _basemap = b;
    _attribution = _attributionFor(b);
    _tileImages.clear(); // 画像 LRU は層番号で引くので、前の基図の絵が混ざる
    _world.retexture();
    if (mounted) setState(() {});
  }
  @override
  bool _gesturing = false;

  // タイルごとのキャッシュ。キーにビルダー（縁が変わると別物になる）と borderMask を含めるので、
  // タイルが届いても他のタイルのキャッシュは生きたまま
  final Map<TerrainMeshBuilder, (double, double, TerrainMesh)> _meshes = {}; // (bearing, pitch, mesh)

  /// メッシュを最後に描いた時刻（ms）。しばらく描いていないメッシュは捨てる（Vertices は native 側で 1 枚 1〜2MB）
  final Map<TerrainMeshBuilder, int> _meshUsed = {};
  static const _meshKeepMs = 3000;
  // キー: (タイル, step, 縁の組み合わせ, 高さの出どころの段)。近似 → 本物の差し替えで作り直す
  final Map<(TileKey, int, int, int), _TileScene> _scenes = {};
  final Map<(TileKey, int, int, int), _TileScene> _staticScenes = {};
  final Map<(TileKey, int, int, int), _TileScene> _dynamicScenes = {};
  final Map<(TileKey, int, int, int), _StaticProgress> _staticProgress = {};

  /// 1 フレームに育てる静的な貼り付けの枚数と上限（ジェスチャ中は控えめに、静止中は速く）
  int _staticBuilds = 0;
  int get _staticBudget => _gesturing ? 2 : 3;

  /// 1 フレームの貼り付けに使う時間（タイル合計）
  Duration get _sliceBudget => _gesturing ? const Duration(milliseconds: 4) : const Duration(milliseconds: 12);
  final Stopwatch _staticSw = Stopwatch();

  /// 1 フレームのメッシュ生成に使う時間。超えたぶんは手持ちの段か穴埋めで繋いで次のフレームに回す
  /// （新しいタイルが 5 枚同時に届くと 20ms × 5 で 1 フレーム 100ms になっていた）
  static const _meshBudgetMs = 20;
  final Stopwatch _meshSw = Stopwatch();
  int _frameMs = 0;

  /// フィーチャの bbox（Mercator m）。リストごとに一度だけ
  final Expando<Float64List> _bboxCache = Expando();

  Float64List _bboxes(List<geo.Feature<geo.Geometry>> fs) {
    var b = _bboxCache[fs];
    if (b != null) return b;
    b = Float64List(fs.length * 4);
    for (var i = 0; i < fs.length; i++) {
      final box = fs[i].geometry?.calculateBounds();
      if (box == null) {
        b[i * 4] = double.nan;
        continue;
      }
      final x0 = WebMercator.xFromLon(box.minX), x1 = WebMercator.xFromLon(box.maxX);
      final y0 = WebMercator.yFromLat(box.minY), y1 = WebMercator.yFromLat(box.maxY);
      b[i * 4] = math.min(x0, x1);
      b[i * 4 + 1] = math.min(y0, y1);
      b[i * 4 + 2] = math.max(x0, x1);
      b[i * 4 + 3] = math.max(y0, y1);
    }
    _bboxCache[fs] = b;
    return b;
  }

  /// [clip]（Mercator m）に bbox が掛かるフィーチャの番号
  List<int> _featureIndexes(List<geo.Feature<geo.Geometry>> fs, Rect clip) {
    final b = _bboxes(fs);
    final out = <int>[];
    for (var i = 0; i < fs.length; i++) {
      final x0 = b[i * 4];
      if (x0.isNaN) continue;
      if (b[i * 4 + 2] < clip.left || x0 > clip.right || b[i * 4 + 3] < clip.top || b[i * 4 + 1] > clip.bottom) continue;
      out.add(i);
    }
    return out;
  }
  int _worldRevisionSeen = -1;

  // カメラのアニメ（コンパスタップ・ペンの真上ロック）
  late final AnimationController _anim;
  ({double bearing, double pitch, double centerX, double centerY, double zoom})? _animFrom;
  ({double bearing, double pitch, double centerX, double centerY, double zoom})? _animTo;

  /// ペン選択中: 真上に寄せて 1 本指をツール（描画）に渡す。離れたら元の傾きに戻す
  bool _penLock = false;
  double? _pitchBeforePen;

  /// 今の 1 本指ドラッグをツールに渡している最中
  bool _toolDrag = false;

  // オーバーレイ画像（GeoTIFF など）: 地形のテクスチャに焼く
  final Map<String, ui.Image> _overlayImages = {};
  final Set<String> _overlayLoading = {};
  String _overlayKey = '';

  /// 次の作り直しで触る範囲（Mercator）。前回と今回のオーバーレイの四隅を含む。null なら全部
  Rect? _overlayBounds;
  Timer? _retextureTimer;
  Rect? _lastOverlayBounds;

  // ジェスチャ
  double _scaleStart = 1;
  double _bearingStart = 0;
  double _pitchStart = 0;
  Offset _focalStart = Offset.zero;

  @override
  void initState() {
    super.initState();
    final cam = widget.mapState.mapController.camera;
    final center = cam.center;
    _camera = TerrainCamera(
      centerX: WebMercator.xFromLon(center.longitude),
      centerY: WebMercator.yFromLat(center.latitude),
      scale: TerrainCamera.scaleForZoom(cam.zoom),
      bearing: cam.bearing * math.pi / 180,
      pitch: _defaultPitchDeg * math.pi / 180,
      zScale: WebMercator.zScaleAt(center.latitude),
    );
    _basemap = _currentBasemap();
    _attribution = _attributionFor(_basemap);
    widget.baseMapService.addListener(_onBasemapChanged);
    _world = TerrainWorld(
      demSources: DemTileSource.defaultCascade,
      demFetcher: (source, z, x, y) => widget.baseMapService.getTile(_terrainProviders[source.id]!, z, x, y),
      // 基図は設定で変わりうるので、取りに行くたびに今のものを見る
      textureFetcher: (z, x, y) {
        final b = _basemap;
        return b == null ? Future.value(null) : widget.baseMapService.getTile(b, z, x, y);
      },
      imageCache: _tileImages,
    )
      ..addListener(_onWorldChanged)
      ..textureDecorator = _decorateTexture;
    _planner = TerrainFramePlanner(_world);
    _painter = TerrainWorldPainter(
      camera: _camera,
      tiles: const [],
      elevationAt: (x, y) => _world.elevationAt(x, y),
      heightRange: (0, 1000),
      stepMeters: 10,
      repaint: _repaint,
      onPainted: (d) {
        if (_painter.deferredLayouts > 0) _scheduleRefresh();
        if (d.inMilliseconds > 40) {
          var labels = 0, points = 0;
          for (final t in _painter.tiles) {
            labels += t.labels.length;
            points += t.points.length;
          }
          final g = _gpu;
          final gpuInfo = g == null
              ? ''
              : ', gpu encode ${g.lastEncode.inMilliseconds}ms upload ${g.lastUpload.inMilliseconds}ms×${g.lastUploads} draws ${g.lastDrawCalls}';
          debugPrint('[3D] paint ${d.inMilliseconds}ms (tiles ${_painter.tiles.length}, labels $labels, points $points$gpuInfo)');
        }
      },
    );
    widget.sceneRevision.addListener(_onSceneRevision);
    widget.heading?.addListener(_scheduleRefresh);
    widget.onProjectionChanged(this);
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 350))
      ..addListener(_onAnimTick)
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed && mounted) setState(() {});
      });
    final tool = ref.read(currentToolProvider);
    if (_toolTakesDrag(tool.name)) {
      _penLock = true;
      _pitchBeforePen = _camera.pitch;
      _camera.pitch = 0;
    }
    if (tool is DeviceTool) {
      _listenedDevice = tool..addListener(_scheduleRefresh);
    }
    unawaited(_initGpu());
  }

  /// flutter_gpu の描画系を用意する（シェーダ束の読み込みは非同期）。
  /// 用意できるまでは純 Dart 経路で描き、できたら投影済みのメッシュを捨てて骨組みだけのメッシュに切り替える
  /// （貼り付け済みのシーンはチャンクの骨組みが同じなのでそのまま）。失敗したら純 Dart 経路のまま
  Future<void> _initGpu() async {
    if (!TerrainGpuWorldRenderer.isSupported) return;
    try {
      final renderer = await TerrainGpuWorldRenderer.create();
      if (!mounted) {
        renderer.dispose();
        return;
      }
      renderer.onTextureReady = _scheduleRefresh;
      // GPU 側にミップ付きの複製ができたら `ui.Image` は手放す（1 タイル 1MB の二重持ちを解く）
      renderer.onTextureUploaded = (key) {
        for (final tile in _world.tiles) {
          if (identical(tile.textureKey, key)) tile.releaseImage();
        }
      };
      _gpu = renderer;
      _painter.gpu = renderer;
      for (final v in _meshes.values) {
        v.$3.dispose();
      }
      _meshes.clear();
      _meshUsed.clear();
      _painter.disposeCaches();
      debugPrint('[3D] flutter_gpu で描く');
      _scheduleRefresh();
    } catch (e) {
      debugPrint('[3D] flutter_gpu 不可（純 Dart で描く）: $e');
    }
  }

  // ── カメラのアニメ ──────────────────────────────────

  /// 指定した項目だけ 350ms で滑らかに動かす（方位は近い方へ回る）
  void _animateTo({double? bearing, double? pitch, double? centerX, double? centerY, double? zoom}) {
    var b = bearing ?? _camera.bearing;
    // 近い方へ回る
    var d = b - _camera.bearing;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    b = _camera.bearing + d;
    _animFrom = (bearing: _camera.bearing, pitch: _camera.pitch, centerX: _camera.centerX, centerY: _camera.centerY, zoom: _camera.zoom);
    _animTo = (bearing: b, pitch: pitch ?? _camera.pitch, centerX: centerX ?? _camera.centerX, centerY: centerY ?? _camera.centerY, zoom: zoom ?? _camera.zoom);
  }

  /// [_animateTo] で決めた先へ動かす（待てる）

  void _onAnimTick() {
    final a = _animFrom;
    final z = _animTo;
    if (a == null || z == null) return;
    final t = Curves.easeInOutCubic.transform(_anim.value);
    double lerp(double x, double y) => x + (y - x) * t;
    _camera
      ..bearing = lerp(a.bearing, z.bearing)
      ..pitch = lerp(a.pitch, z.pitch)
      ..centerX = lerp(a.centerX, z.centerX)
      ..centerY = lerp(a.centerY, z.centerY)
      ..zoom = lerp(a.zoom, z.zoom);
    _gesturing = _anim.isAnimating;
    _refresh();
  }

  /// コンパスのタップ: 北を上に・真上から
  void _resetView() {
    _animateTo(bearing: 0, pitch: 0);
    _anim.forward(from: 0);
  }

  /// 1 本指を取るツール（真上ロックの対象）
  static bool _toolTakesDrag(String toolName) => toolName == 'Pen' || toolName == 'Overlay Transform';

  /// ツールが変わった: 1 本指を取るツールなら真上に寄せて 1 本指を渡す。離れたら傾きを戻す
  DeviceTool? _listenedDevice;

  void _onToolChanged(String toolName) {
    // 外部機器ツールは計測のたびに notify するので、その間だけ購読する
    final tool = ref.read(currentToolProvider);
    if (!identical(tool, _listenedDevice)) {
      _listenedDevice?.removeListener(_scheduleRefresh);
      _listenedDevice = tool is DeviceTool ? tool : null;
      _listenedDevice?.addListener(_scheduleRefresh);
    }
    final pen = _toolTakesDrag(toolName);
    if (pen && !_penLock) {
      _penLock = true;
      _pitchBeforePen = _camera.pitch;
      _animateTo(pitch: 0);
      _anim.forward(from: 0);
    } else if (!pen && _penLock) {
      _penLock = false;
      _toolDrag = false;
      _animateTo(pitch: _pitchBeforePen ?? _defaultPitchDeg * math.pi / 180);
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _listenedDevice?.removeListener(_scheduleRefresh);
    widget.baseMapService.removeListener(_onBasemapChanged);
    _anim.dispose();
    _retextureTimer?.cancel();
    for (final im in _overlayImages.values) {
      im.dispose();
    }
    _stopDrive();
    widget.heading?.removeListener(_scheduleRefresh);
    widget.sceneRevision.removeListener(_onSceneRevision);
    widget.onProjectionChanged(null);
    // 真上に戻して MapLibre へ書き戻す
    widget.mapState.mapController.moveAndRotate(_centerLatLng(), _camera.zoom, _camera.bearing * 180 / math.pi);
    _world
      ..removeListener(_onWorldChanged)
      ..dispose();
    for (final v in _meshes.values) {
      v.$3.dispose();
    }
    _meshes.clear();
    _painter.disposeCaches();
    _painter.gpu = null;
    _gpu?.dispose();
    _gpu = null;
    _repaint.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerrainMapLayer old) {
    super.didUpdateWidget(old);
    // build の最中なので、描き直しはフレームの後で（同期に通知すると setState during build）。
    // 親の setState（描画中の線・現在位置など）は全部ここに来るので、毎回 1 回だけ予約する
    _scheduleRefresh();
  }

  bool _refreshScheduled = false;

  /// 次のフレームの頭で 1 回だけ描き直す。タイル到着・メッシュ完成・シーン更新など
  /// 非同期のきっかけはすべてここを通す（同期に呼ぶと到着のたびに連鎖して止まる）
  void _scheduleRefresh() {
    if (_refreshScheduled || !mounted) return;
    _refreshScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) _refresh();
    });
  }

  LatLng _centerLatLng() =>
      LatLng(WebMercator.latFromY(_camera.centerY), WebMercator.lonFromX(_camera.centerX));

  void _onWorldChanged() => _scheduleRefresh();

  void _onSceneRevision() => _scheduleRefresh();

  // ── フレームの組み立て ──────────────────────────────

  /// 見える範囲のタイルを揃え、描けるものを描画順に painter へ渡す
  @override
  void _refresh() {
    if (_size == Size.zero) return;
    _syncOverlays();
    final sw = Stopwatch()..start();
    _meshBuilds = 0;
    _placeholders = 0;
    _sceneBuilds = 0;
    _staticBuilds = 0;
    _staticSw
      ..reset()
      ..start();
    _meshSw.reset();
    _frameMs = DateTime.now().millisecondsSinceEpoch;
    final plan = _planner.plan(_camera, _size, gesturing: _gesturing);
    final planMs = sw.elapsedMilliseconds;
    _lastPlan = plan;
    if (_world.revision != _worldRevisionSeen) {
      // タイルの出入り: 消えたタイルのぶんだけ捨てる（縁が変わったタイルはキーが変わるので自然に入れ替わる）
      _scenes.removeWhere((k, _) => !_world.has(k.$1));
      _staticScenes.removeWhere((k, _) => !_world.has(k.$1));
      _staticProgress.removeWhere((k, _) => !_world.has(k.$1));
      _dynamicScenes.removeWhere((k, _) => !_world.has(k.$1));
      _pruneMeshes();
      // GPU 側のテクスチャは生きているタイルの世代だけ残す（`ui.Image` を手放した後の唯一の実体なので時間では捨てない）
      _gpu?.pruneTextures({for (final t in _world.tiles) t.textureKey});
      _worldRevisionSeen = _world.revision;
    }
    final drawables = <TerrainTileDrawable>[];
    for (final tile in plan.tiles) {
      final step = plan.stepFor(tile);
      final skirt = tile.key.span * 0.03; // タイル幅の 3%
      var useStep = step;
      TerrainMeshBuilder builder;
      final ideal = tile.builders[step];
      if (ideal == null) {
        // isolate で作る。できたら描き直す
        tile.builderFor(step, chunkSize: _world.chunkSize, skirtDepth: skirt).then((_) => _scheduleRefresh());
        // できているものがあれば（粗さが違っても）それで繋ぐ。何も無ければ粗い穴埋めをその場で作る
        if (tile.builders.isEmpty) {
          _placeholders++;
          drawables.add(_drawable(tile, tile.placeholderBuilder(chunkSize: _world.chunkSize, skirtDepth: skirt), 16));
          continue;
        }
        useStep = _nearestStep(tile, step, preferScene: true);
        builder = tile.builders[useStep]!;
      } else if (!_hasStaticScene(tile, step) && _staticBuilds >= _staticBudget) {
        // この段の貼り付けはまだ無く、今フレームの予算も尽きた。貼り付けのある段のメッシュで繋ぐ
        // （空のまま描くと回転中にフィーチャが消える）
        final alt = _nearestStep(tile, step, preferScene: true);
        useStep = _hasStaticScene(tile, alt) ? alt : step;
        builder = tile.builders[useStep]!;
      } else {
        builder = ideal;
      }
      drawables.add(_drawable(tile, builder, useStep));
    }
    _pruneStaleMeshes(_frameMs);
    _painter
      ..tiles = drawables
      ..gesturing = _gesturing
      ..heightRange = _world.heightRange ?? (0, 1000)
      ..stepMeters = WebMercator.metersPerPixel(plan.demZoom);
    _repaint.value++;
    _notifyCamera();
    if (!_everCovered && plan.coverage.full && drawables.isNotEmpty) {
      _everCovered = true;
      if (mounted) setState(() {});
    }
    if (sw.elapsedMilliseconds > 40) {
      debugPrint('[3D] refresh ${sw.elapsedMilliseconds}ms (plan $planMs [${_planner.lastTiming}], meshes built $_meshBuilds, '
          'placeholders $_placeholders, scenes built $_sceneBuilds, tiles ${drawables.length})');
    }
  }

  /// 一度でも全面が揃ったか（揃うまで背景は透明）
  bool _everCovered = false;
  int _meshBuilds = 0;
  @override
  int _placeholders = 0;
  int _sceneBuilds = 0;

  bool _hasStaticScene(TerrainTile tile, int step) =>
      _staticScenes.containsKey((tile.key, step, tile.borderMask, tile.sourceZoom));

  /// [step] に一番近いビルダーの段。[preferScene] なら貼り付けが揃っている段を優先
  int _nearestStep(TerrainTile tile, int step, {bool preferScene = false}) {
    int best(Iterable<int> keys) => keys.reduce((a, b) => (a - step).abs() <= (b - step).abs() ? a : b);
    if (preferScene) {
      final withScene = tile.builders.keys.where((s) => _hasStaticScene(tile, s));
      if (withScene.isNotEmpty) return best(withScene);
    }
    return best(tile.builders.keys);
  }

  /// 生きているタイルのビルダーに紐づかないメッシュを捨てる（GPU 側の頂点も返す）。
  /// ビルダーをキーに持つので、ここで外さないとタイルを捨ててもビルダーごと残る
  void _pruneMeshes() {
    final live = <TerrainMeshBuilder>{for (final t in _world.tiles) ...t.builders.values};
    _meshes.removeWhere((b, v) {
      if (live.contains(b)) return false;
      v.$3.dispose();
      _meshUsed.remove(b);
      return true;
    });
  }

  /// [_meshKeepMs] 以上描いていないメッシュを捨てる（方位・傾きが変われば作り直すものなので、持ち続ける価値は薄い）
  void _pruneStaleMeshes(int nowMs) {
    _meshes.removeWhere((b, v) {
      final used = _meshUsed[b];
      if (used != null && nowMs - used <= _meshKeepMs) return false;
      v.$3.dispose();
      _meshUsed.remove(b);
      return true;
    });
  }

  TerrainTileDrawable _drawable(TerrainTile tile, TerrainMeshBuilder builder, int step) {
    final cached = _meshes[builder];
    final TerrainMesh mesh;
    _meshUsed[builder] = _frameMs;
    if (_gpu != null) {
      // GPU 経路: 投影はシェーダ。骨組み（チャンク・セル）だけのメッシュを 1 回作って持つ（方位・傾きに依らない）
      if (cached != null) {
        mesh = cached.$3;
      } else {
        mesh = builder.buildStatic();
        _meshes[builder] = (double.nan, double.nan, mesh);
      }
    } else if (cached != null && cached.$1 == _camera.bearing && cached.$2 == _camera.pitch) {
      mesh = cached.$3;
    } else {
      if (!_gesturing && step != 16 && _meshSw.elapsedMilliseconds > _meshBudgetMs) {
        _scheduleRefresh();
        for (final e in tile.builders.entries) {
          final c = _meshes[e.value];
          if (c != null && c.$1 == _camera.bearing && c.$2 == _camera.pitch) return _drawable(tile, e.value, e.key);
        }
        _placeholders++;
        return _drawable(tile, tile.placeholderBuilder(chunkSize: _world.chunkSize, skirtDepth: tile.key.span * 0.03), 16);
      }
      _meshSw.start();
      mesh = builder.build(_camera);
      _meshSw.stop();
      _meshBuilds++;
      if (mesh.timing.project + mesh.timing.sort + mesh.timing.assemble > const Duration(milliseconds: 25)) {
        debugPrint('[3D] mesh ${tile.key} step $step: project ${mesh.timing.project.inMilliseconds}ms '
            'sort ${mesh.timing.sort.inMilliseconds}ms assemble ${mesh.timing.assemble.inMilliseconds}ms (resorted ${mesh.timing.resorted})');
      }
      // 古いメッシュの Vertices は native 側にあり GC を待つと溜まるので、その場で返す
      cached?.$3.dispose();
      _meshes[builder] = (_camera.bearing, _camera.pitch, mesh);
    }
    final scene = _sceneFor(tile, mesh, step);
    return TerrainTileDrawable(
      originX: tile.bordered.originX,
      originY: tile.bordered.originY,
      mesh: mesh,
      builder: builder,
      texture: tile.texture,
      textureKey: tile.textureKey,
      lines: scene.lines,
      polygons: scene.polygons,
      polygonBatches: scene.polygonBatches,
      dynamicLines: scene.dynamicLines,
      dynamicPolygons: scene.dynamicPolygons,
      dynamicPoints: scene.dynamicPoints,
      points: scene.points,
      labels: scene.labels,
    );
  }

  // ── シーン（タイル単位の貼り付け） ─────────────────

  TerrainFeatureStyle _styleFromGroup(MapStyleGroup g) => TerrainFeatureStyle(
        lineColor: TerrainFeatureStyle.fromHex(g.lineHex),
        lineWidth: g.lineWidth,
        fillColor: TerrainFeatureStyle.fromHex(g.fillHex, g.fillOpacity),
        outlineColor: TerrainFeatureStyle.fromHex(g.outlineHex, g.outlineOpacity),
        outlineWidth: g.borderWidth,
        pointColor: TerrainFeatureStyle.fromHex(g.pointHex),
        pointSize: g.pointSize,
      );

  TerrainFeatureStyle _defaultStyle() {
    final s = layerStyleSettings;
    return TerrainFeatureStyle(
      lineColor: s.getColor(lineColorDef),
      lineWidth: s.getDouble(lineWidthDef),
      fillColor: s.getColor(polygonFillColorDef).withValues(alpha: s.getDouble(polygonFillOpacityDef)),
      outlineColor: s.getColor(polygonBorderColorDef).withValues(alpha: s.getDouble(polygonBorderOpacityDef)),
      outlineWidth: s.getDouble(polygonBorderWidthDef),
      pointColor: s.getColor(pointColorDef),
      pointSize: s.getDouble(pointSizeDef),
    );
  }

  TerrainFeatureStyle _selectedStyle(TerrainFeatureStyle base) {
    final s = layerStyleSettings;
    final color = s.getColor(selectedColorDef);
    final k = s.getDouble(selectedMultiplierDef);
    return TerrainFeatureStyle(
      lineColor: color,
      lineWidth: base.lineWidth * k,
      fillColor: color.withValues(alpha: 0.4),
      outlineColor: color,
      outlineWidth: base.outlineWidth * k,
      pointColor: color,
      pointSize: base.pointSize * k,
    );
  }

  static bool _sameKey(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i]) && a[i] != b[i]) return false;
    }
    return true;
  }

  /// タイル 1 枚の貼り付け。静的な部分（フィーチャ・頂点・写真・選択）と動的な部分（軌跡・パーティ・現在位置）を
  /// 別々にキャッシュする。GPS の更新（1 秒ごと）で作り直すのは動的な部分だけ（数本・数点で軽い）
  ///
  /// 静的な部分は 1 フレーム [_staticBudget] 枚まで。超えたぶんは空のまま描いて次のフレームで足す
  /// （引いた直後に 10 枚ぶん同時に届くと 1 枚 30〜150ms × 10 で止まる）
  _TileScene _sceneFor(TerrainTile tile, TerrainMesh mesh, int step) {
    final g = widget.geoJson;
    final track = widget.gpsTrack();
    final session = ref.read(partySessionProvider);
    final loc = widget.currentLocation;
    final cacheKey = (tile.key, step, tile.borderMask, tile.sourceZoom);
    final staticKey = <Object?>[
      g.polylines, g.polygons, g.markers, g.selectedPolylines, g.selectedPolygons, g.selectedMarkers, g.images,
      g.lineVertices, g.polygonVertices,
    ];
    final drawing = GlobalDrawingState.instance;
    final tool = ref.read(currentToolProvider);
    final selectedOverlays = <OverlayImageNode>[
      ...ref.read(selectedFeaturesProvider).whereType<OverlayImageNode>(),
      if (tool is OverlayTransformTool && tool.target != null) tool.target!,
    ];
    final overlayFrameKey = [for (final n in selectedOverlays) '${n.filePath}@${n.cornerCoordinates}'].join(';');
    final deviceLines = tool is DeviceTool ? tool.overlayLines() : const <geo.Feature<geo.LineString>>[];
    final deviceStation = tool is DeviceTool ? tool.overlayStation : null;
    final headingDeg = widget.heading?.value;
    final headingKey = headingDeg == null ? null : (headingDeg / 5).round();
    final dynamicKey = <Object?>[
      track.length, session, loc, drawing.drawingLine.length, drawing.drawingPolygon.length, drawing.pointPreview,
      overlayFrameKey, tool is OverlayTransformTool ? tool.rotationHandlePosition : null,
      deviceLines.length, deviceStation, headingKey, tool.name,
    ];
    final key = <Object?>[...staticKey, ...dynamicKey];
    final cached = _scenes[cacheKey];
    if (cached != null && _sameKey(cached.key, key)) return cached;

    final dem = mesh.dem;
    final clip = Rect.fromLTWH(0, 0, dem.width, dem.height);
    // 面を地形に沿わせる格子の粗さ: 約 20m、ただし最低 4 セル（引いた段では 1 セルまで切り分けても画面上 1〜2px で意味が無く、
    // 1 万面で貼り付けが 1 秒を超えた）
    final clipCells = math.max(4, (20 / (dem.cellSize * step)).round());
    final labelStyle = TextStyle(
      fontSize: layerStyleSettings.getDouble(labelFontSizeDef),
      color: layerStyleSettings.getColor(labelColorDef),
    );
    TerrainSceneBuilder builder(Map<String, TerrainFeatureStyle> styles, TerrainFeatureStyle def, String labelProp) =>
        TerrainSceneBuilder(
          mesh: mesh,
          stylesByKey: styles,
          defaultStyle: def,
          styleKeyProp: MapSourceManager.kStyleProp,
          labelProp: labelProp,
          labelTextStyle: labelStyle,
          polygonClipCells: clipCells,
        );

    // 静的な部分。1 回あたり数 ms ずつ育てる（1 タイル 1 万面を一度に持ち上げると 0.5〜1 秒止まる）
    var stat = _staticScenes[cacheKey];
    if (stat == null || !_sameKey(stat.key, staticKey)) {
      if (_staticBuilds >= _staticBudget) {
        // 今フレームは見送り。手持ちがあれば古いものを使い、無ければ空
        _scheduleRefresh();
        stat ??= _TileScene(key: const [], lines: const [], polygons: const [], points: const [], labels: const []);
      } else {
        stat = _TileScene(key: staticKey, lines: [], polygons: [], points: [], labels: [], complete: false);
        _staticScenes[cacheKey] = stat;
        _staticProgress[cacheKey] = _StaticProgress();
      }
    }
    if (!stat.complete && _staticBuilds < _staticBudget) {
      _staticBuilds++;
      _sceneBuilds++;
      _advanceStatic(tile, step, stat, _staticProgress[cacheKey] ??= _StaticProgress(), g, builder, clip);
    }
    // 育ち切っていないタイルがある限り次のフレームも来る（今フレームの予算に漏れたタイルも）
    if (!stat.complete) _scheduleRefresh();
    // 動的な部分
    var dyn = _dynamicScenes[cacheKey];
    if (dyn == null || !_sameKey(dyn.key, dynamicKey)) {
      dyn = _buildDynamic(dynamicKey, track, session, loc, dem, builder, clip,
          selectedOverlays: selectedOverlays, tool: tool, deviceLines: deviceLines, deviceStation: deviceStation,
          headingDeg: headingDeg);
      _dynamicScenes[cacheKey] = dyn;
    }
    // 静的な線・面はそのまま（リストと束の同一性を保つ → 描画側の投影キャッシュが効く）。動的な方は別に持つ
    final scene = _TileScene(
      key: key,
      lines: stat.lines,
      polygons: stat.polygons,
      staticSource: stat,
      dynamicLines: dyn.lines,
      dynamicPolygons: dyn.polygons,
      dynamicPoints: dyn.points,
      points: stat.points,
      // 動的なラベルが無ければ静的のリストをそのまま（同一性を保つ → 描画側のラベル投影キャッシュが効く）
      labels: dyn.labels.isEmpty ? stat.labels : [...stat.labels, ...dyn.labels],
      complete: stat.complete,
    );
    // 静的シーンが育ち切るまでは合成も作り直す（点・ラベルは合成時に写すため）
    if (stat.complete) _scenes[cacheKey] = scene;
    return scene;
  }

  /// フィーチャ本体・頂点・写真・選択を [scene] に足す。1 回に [sliceBudget] まで（残りは次の呼び出し）
  static const labelStyleForClusters = TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3F51B5));

  void _advanceStatic(
    TerrainTile tile,
    int step,
    _TileScene scene,
    _StaticProgress progress,
    FeatureGeoJsonCache g,
    TerrainSceneBuilder Function(Map<String, TerrainFeatureStyle>, TerrainFeatureStyle, String) builder,
    Rect clip,
  ) {
    final sliceBudget = _sliceBudget;
    final sw = Stopwatch()..start();
    bool over() {
      if (_staticSw.elapsed <= sliceBudget) return false;
      if (sw.elapsedMilliseconds > 30) {
        debugPrint('[3D] tile ${tile.key} step $step 貼り付け 一片 ${sw.elapsedMilliseconds}ms '
            '(phase ${progress.phase} polys ${progress.polygon}/${progress.polygonIdx?.length} chunk ${progress.chunk})');
      }
      return true;
    }
    final defaultStyle = _defaultStyle();
    final groups = {for (final sg in widget.styleGroups()) sg.key: _styleFromGroup(sg)};
    // 引いた段（セルが 30m 以上 = 表示ズーム 13 以下）で、このタイルに面が多いときだけ輪郭とラベルを省く。
    // 60m の面が数ピクセルの眺めで 1 万面の輪郭（4 万本の線分）を毎フレーム描くと raster が 0.5 秒になる。
    // ⚠ ズームだけで省くと林班の境界（塗りは薄く、輪郭が本体）が引いた途端に消える。数百面なら描く。
    // 判定はデータ全体の面数（タイルごとに変えると継ぎ接ぎになる）
    final coarse = tile.bordered.cellSize * step >= 30;
    final dense = coarse && g.polygons.length > 2000;
    void add(TerrainScene s, {bool withLabels = true}) {
      if (!dense) scene.lines.addAll(s.outlines);
      scene.lines.addAll(s.lines);
      scene.polygons.addAll(s.polygons);
      scene.points.addAll(s.points);
      if (withLabels) scene.labels.addAll(s.labels);
    }

    if (progress.phase == 0) {
      // 選択（先に見せたい）・頂点・写真は少ないので一度に
      add(
        builder({for (final e in groups.entries) e.key: _selectedStyle(e.value)}, _selectedStyle(defaultStyle), '__no_label__')
            .build(lines: g.selectedPolylines, polygons: g.selectedPolygons, points: g.selectedMarkers, clipRect: clip),
        withLabels: false,
      );
      add(
        builder(const {}, TerrainFeatureStyle(
          lineColor: defaultStyle.lineColor, lineWidth: 1, fillColor: defaultStyle.fillColor,
          outlineColor: defaultStyle.outlineColor, outlineWidth: 1, pointColor: Colors.white,
          pointSize: math.max(2.0, defaultStyle.pointSize * 0.45),
        ), '__no_label__').build(
          points: [
            if (layerStyleSettings.getBool(lineVertexPointsEnabledDef)) ...g.lineVertices,
            if (layerStyleSettings.getBool(polygonVertexPointsEnabledDef)) ...g.polygonVertices,
          ],
          clipRect: clip,
        ),
      );
      add(
        builder(const {}, const TerrainFeatureStyle(
          lineColor: Colors.amber, lineWidth: 1, fillColor: Colors.amber, outlineColor: Colors.amber,
          outlineWidth: 1, pointColor: Colors.amber, pointSize: 7,
        ), 'name').build(points: g.images, clipRect: clip),
      );
      // 点フィーチャ。引いた段では格子（画面 60px 相当）でまとめて数を出す（1 万点を 1 点ずつ描かない）
      final pointScene = builder(groups, defaultStyle, FeatureGeoJsonInput.labelPropKey).build(points: g.markers, clipRect: clip);
      if (coarse && pointScene.points.length > 50) {
        final cellM = tile.bordered.cellSize * step * 30; // 1 セル ≒ 2px → 60px
        final buckets = <(int, int), List<TerrainPoint>>{};
        for (final p in pointScene.points) {
          (buckets[((p.x / cellM).floor(), (p.y / cellM).floor())] ??= []).add(p);
        }
        for (final e in buckets.entries) {
          final ps = e.value;
          if (ps.length == 1) {
            scene.points.add(ps.first);
            continue;
          }
          var cx = 0.0, cy = 0.0;
          for (final p in ps) {
            cx += p.x;
            cy += p.y;
          }
          cx /= ps.length;
          cy /= ps.length;
          scene.points.add(TerrainPoint(x: cx, y: cy, color: const Color(0xFF3F51B5), sizePx: 12));
          scene.labels.add(TerrainLabel(x: cx, y: cy, text: '${ps.length}', style: labelStyleForClusters));
        }
      } else {
        add(pointScene); // 引いた段でも点が少なければラベルは出す（多ければ上でまとめている）
      }
      final worldClip = clip.shift(Offset(tile.bordered.originX, tile.bordered.originY));
      progress.polygonIdx = _featureIndexes(g.polygons, worldClip);
      progress.lineIdx = _featureIndexes(g.polylines, worldClip);
      progress.phase = 1;
      if (over()) return;
    }
    // 面（引いた段ではラベル無し）
    final polygonIdx = progress.polygonIdx!;
    while (progress.phase == 1) {
      if (progress.polygon >= polygonIdx.length) {
        progress.phase = 2;
        break;
      }
      final end = math.min(progress.polygon + progress.chunk, polygonIdx.length);
      final t0 = sw.elapsedMicroseconds;
      add(
        builder(groups, defaultStyle, FeatureGeoJsonInput.labelPropKey)
            .build(polygons: [for (var i = progress.polygon; i < end; i++) g.polygons[polygonIdx[i]]], clipRect: clip),
        withLabels: !dense,
      );
      progress.tune(end - progress.polygon, sw.elapsedMicroseconds - t0);
      progress.polygon = end;
      if (over()) return;
    }
    // 線
    final lineIdx = progress.lineIdx!;
    while (progress.phase == 2) {
      if (progress.line >= lineIdx.length) {
        progress.phase = 3;
        break;
      }
      final end = math.min(progress.line + progress.chunk, lineIdx.length);
      final t0 = sw.elapsedMicroseconds;
      add(
        builder(groups, defaultStyle, FeatureGeoJsonInput.labelPropKey)
            .build(lines: [for (var i = progress.line; i < end; i++) g.polylines[lineIdx[i]]], clipRect: clip),
      );
      progress.tune(end - progress.line, sw.elapsedMicroseconds - t0);
      progress.line = end;
      if (over()) return;
    }
    scene.complete = true;
    if (sw.elapsedMilliseconds > 20) {
      debugPrint('[3D] tile ${tile.key} step $step 貼り付け 最後の一片 ${sw.elapsedMilliseconds}ms '
          '(lines ${scene.lines.length} polys ${scene.polygons.length} pts ${scene.points.length})');
    }
  }

  /// 今日の GPS 軌跡・パーティ・現在位置（GPS の更新ごとに作り直す。軽い）
  _TileScene _buildDynamic(
    List<Object?> key,
    List<LatLng> track,
    PartySessionState session,
    LatLng? loc,
    DemGrid dem,
    TerrainSceneBuilder Function(Map<String, TerrainFeatureStyle>, TerrainFeatureStyle, String) builder,
    Rect clip, {
    List<OverlayImageNode> selectedOverlays = const [],
    MapTool? tool,
    List<geo.Feature<geo.LineString>> deviceLines = const [],
    LatLng? deviceStation,
    double? headingDeg,
  }) {
    final lines = <LiftedPolyline>[];
    final polygons = <LiftedPolygon>[];
    final points = <TerrainPoint>[];
    final labels = <TerrainLabel>[];
    void add(TerrainScene s) {
      lines
        ..addAll(s.outlines)
        ..addAll(s.lines);
      polygons.addAll(s.polygons);
      points.addAll(s.points);
      labels.addAll(s.labels);
    }

    // 1. 今日の GPS 軌跡（青緑・細め）
    if (track.length >= 2) {
      add(
        builder(const {}, const TerrainFeatureStyle(
          lineColor: Color(0xCC00897B), lineWidth: 3, fillColor: Color(0x00000000),
          outlineColor: Color(0x00000000), outlineWidth: 0, pointColor: Color(0xFF00897B), pointSize: 4,
        ), '__no_label__').build(
          lines: [
            geo.Feature<geo.Geometry>(
              geometry: geo.LineString.from([for (final p in track) geo.Geographic(lon: p.longitude, lat: p.latitude)]),
            ),
          ],
          clipRect: clip,
        ),
      );
    }
    // 2. パーティの他メンバー（橙）と圏外区間の軌跡
    const peerStyle = TerrainFeatureStyle(
      lineColor: Color(0x80FF5722), lineWidth: 3, fillColor: Color(0x00000000),
      outlineColor: Color(0x00000000), outlineWidth: 0, pointColor: Colors.deepOrange, pointSize: 8,
    );
    bool listed(String uid) => session.members.isEmpty || session.members.any((m) => m.uid == uid);
    add(
      builder(const {}, peerStyle, 'name').build(
        points: [
          for (final peer in session.peers.values)
            if (listed(peer.uid))
              geo.Feature<geo.Point>(
                geometry: geo.Point(geo.Geographic(lon: peer.longitude, lat: peer.latitude)),
                properties: {
                  'name': session.members
                      .firstWhere((m) => m.uid == peer.uid, orElse: () => PartyMember(uid: peer.uid, name: '', role: PartyRole.guest))
                      .name,
                },
              ),
        ],
        lines: [
          for (final entry in session.tracks.entries)
            if (listed(entry.key))
              for (final t in entry.value)
                if (t.points.length >= 2)
                  geo.Feature<geo.Geometry>(
                    geometry: geo.LineString.from([for (final p in t.points) geo.Geographic(lon: p.longitude, lat: p.latitude)]),
                  ),
        ],
        clipRect: clip,
      ),
    );
    // 3. 現在位置（青）と端末の向き（青い線、30m。2D のコンパス扇に相当）
    if (loc != null) {
      final x = WebMercator.xFromLon(loc.longitude) - dem.originX;
      final y = WebMercator.yFromLat(loc.latitude) - dem.originY;
      if (clip.contains(Offset(x, y))) {
        points.add(TerrainPoint(x: x, y: y, color: Colors.blue, sizePx: 9));
      }
      if (headingDeg != null) {
        const len = 30.0;
        final rad = headingDeg * math.pi / 180;
        final tip = LatLng(
          loc.latitude + len * math.cos(rad) / 111320.0,
          loc.longitude + len * math.sin(rad) / (111320.0 * math.cos(loc.latitude * math.pi / 180)),
        );
        add(
          builder(const {}, const TerrainFeatureStyle(
            lineColor: Colors.blue, lineWidth: 4, fillColor: Color(0x00000000),
            outlineColor: Color(0x00000000), outlineWidth: 0, pointColor: Colors.blue, pointSize: 4,
          ), '__no_label__').build(
            lines: [
              geo.Feature<geo.Geometry>(
                geometry: geo.LineString.from([
                  geo.Geographic(lon: loc.longitude, lat: loc.latitude),
                  geo.Geographic(lon: tip.longitude, lat: tip.latitude),
                ]),
              ),
            ],
            clipRect: clip,
          ),
        );
      }
    }
    // 4. 描画中の線・面・点（ペン）。2D の描画プレビューと同じ赤
    final drawing = GlobalDrawingState.instance;
    const drawStyle = TerrainFeatureStyle(
      lineColor: Colors.red, lineWidth: 3, fillColor: Color(0x33FF0000),
      outlineColor: Colors.red, outlineWidth: 2, pointColor: Colors.red, pointSize: 8,
    );
    if (drawing.drawingLine.length >= 2 || drawing.drawingPolygon.length >= 2) {
      add(
        builder(const {}, drawStyle, '__no_label__').build(
          lines: [
            if (drawing.drawingLine.length >= 2)
              geo.Feature<geo.Geometry>(
                geometry: geo.LineString.from([for (final p in drawing.drawingLine) geo.Geographic(lon: p.longitude, lat: p.latitude)]),
              ),
            if (drawing.drawingPolygon.length >= 2)
              geo.Feature<geo.Geometry>(
                geometry: geo.LineString.from([
                  for (final p in drawing.drawingPolygon) geo.Geographic(lon: p.longitude, lat: p.latitude),
                  geo.Geographic(lon: drawing.drawingPolygon.first.longitude, lat: drawing.drawingPolygon.first.latitude),
                ]),
              ),
          ],
          clipRect: clip,
        ),
      );
    }
    final survey = tool is GpsTool;
    if (survey) {
      // GPS 測量: 紫の点に「集めた点数」のラベル（2D の _buildSurveyPointMarker と同じ）
      int countOf(List<Map<String, dynamic>?> meta, int i) {
        if (i >= meta.length) return i + 1;
        final m = meta[i];
        if (m == null) return 1;
        if (m['point_count'] is int) return m['point_count'] as int;
        if (m['collected_points'] is List) return (m['collected_points'] as List).length;
        return 1;
      }

      add(
        builder(const {}, const TerrainFeatureStyle(
          lineColor: Colors.purple, lineWidth: 2, fillColor: Color(0x00000000),
          outlineColor: Colors.purple, outlineWidth: 0, pointColor: Colors.purple, pointSize: 11,
        ), 'name').build(
          points: [
            for (var i = 0; i < drawing.drawingLine.length; i++)
              geo.Feature<geo.Point>(
                geometry: geo.Point(geo.Geographic(lon: drawing.drawingLine[i].longitude, lat: drawing.drawingLine[i].latitude)),
                properties: {'name': '${countOf(drawing.lineMetadata, i)}'},
              ),
            for (var i = 0; i < drawing.drawingPolygon.length; i++)
              geo.Feature<geo.Point>(
                geometry: geo.Point(geo.Geographic(lon: drawing.drawingPolygon[i].longitude, lat: drawing.drawingPolygon[i].latitude)),
                properties: {'name': '${countOf(drawing.polygonMetadata, i)}'},
              ),
          ],
          clipRect: clip,
        ),
      );
    } else {
      for (final p in [
        ...drawing.drawingLine,
        ...drawing.drawingPolygon,
        if (drawing.pointPreview != null) drawing.pointPreview!,
      ]) {
        final x = WebMercator.xFromLon(p.longitude) - dem.originX;
        final y = WebMercator.yFromLat(p.latitude) - dem.originY;
        if (clip.contains(Offset(x, y))) points.add(TerrainPoint(x: x, y: y, color: Colors.red, sizePx: 6));
      }
      // 1 点目の目印（白い輪）: 線・面を描き始めた直後
      final first = drawing.drawingLine.length == 1
          ? drawing.drawingLine.first
          : drawing.drawingPolygon.length == 1
              ? drawing.drawingPolygon.first
              : null;
      if (first != null) {
        final x = WebMercator.xFromLon(first.longitude) - dem.originX;
        final y = WebMercator.yFromLat(first.latitude) - dem.originY;
        if (clip.contains(Offset(x, y))) {
          points
            ..add(TerrainPoint(x: x, y: y, color: Colors.white, sizePx: 14))
            ..add(TerrainPoint(x: x, y: y, color: Colors.red, sizePx: 8));
        }
      }
    }
    // 5. 選択中のオーバーレイ画像の枠（青）と、変換ツールの回転ハンドル（2D の buildOverlaySelectionLayers と同じ）
    if (selectedOverlays.isNotEmpty) {
      const frameStyle = TerrainFeatureStyle(
        lineColor: Colors.blue, lineWidth: 2, fillColor: Color(0x00000000),
        outlineColor: Colors.blue, outlineWidth: 2, pointColor: Colors.blue, pointSize: 10,
      );
      final handle = tool is OverlayTransformTool ? tool.rotationHandlePosition : null;
      add(
        builder(const {}, frameStyle, '__no_label__').build(
          lines: [
            for (final n in {...selectedOverlays})
              geo.Feature<geo.Geometry>(
                geometry: geo.LineString.from([
                  for (final c in n.cornerCoordinates) geo.Geographic(lon: c.longitude, lat: c.latitude),
                  geo.Geographic(lon: n.cornerCoordinates[0].longitude, lat: n.cornerCoordinates[0].latitude),
                ]),
              ),
            if (handle != null && tool is OverlayTransformTool && tool.target != null)
              geo.Feature<geo.Geometry>(
                geometry: geo.LineString.from([
                  geo.Geographic(
                    lon: (tool.target!.cornerCoordinates[0].longitude + tool.target!.cornerCoordinates[1].longitude) / 2,
                    lat: (tool.target!.cornerCoordinates[0].latitude + tool.target!.cornerCoordinates[1].latitude) / 2,
                  ),
                  geo.Geographic(lon: handle.longitude, lat: handle.latitude),
                ]),
              ),
          ],
          clipRect: clip,
        ),
      );
      if (handle != null) {
        final x = WebMercator.xFromLon(handle.longitude) - dem.originX;
        final y = WebMercator.yFromLat(handle.latitude) - dem.originY;
        if (clip.contains(Offset(x, y))) points.add(TerrainPoint(x: x, y: y, color: Colors.blue, sizePx: 10));
      }
    }
    // 6. 外部機器ツール（TruPulse）: 基準点 → 計測点の線（赤）と基準点
    if (deviceLines.isNotEmpty || deviceStation != null) {
      const deviceStyle = TerrainFeatureStyle(
        lineColor: Colors.red, lineWidth: 2, fillColor: Color(0x00000000),
        outlineColor: Colors.red, outlineWidth: 0, pointColor: Colors.red, pointSize: 8,
      );
      if (deviceLines.isNotEmpty) {
        add(builder(const {}, deviceStyle, '__no_label__').build(lines: deviceLines, clipRect: clip));
      }
      if (deviceStation != null) {
        final x = WebMercator.xFromLon(deviceStation.longitude) - dem.originX;
        final y = WebMercator.yFromLat(deviceStation.latitude) - dem.originY;
        if (clip.contains(Offset(x, y))) points.add(TerrainPoint(x: x, y: y, color: Colors.orange, sizePx: 12));
      }
    }
    return _TileScene(key: key, lines: lines, polygons: polygons, points: points, labels: labels);
  }

  void _notifyCamera() {
    widget.mapBearingNotifier.value = _camera.bearing * 180 / math.pi;
    widget.cameraTickNotifier.value++;
    // 3D 中は MapLibre が無いので、戻すときの初期値として覚えさせる
    widget.mapState.mapController.rememberCamera(_centerLatLng(), _camera.zoom, _camera.bearing * 180 / math.pi);
  }

  // ── TerrainProjection ───────────────────────────────

  @override
  LatLng? unproject(Offset screen) {
    if (_size == Size.zero) return null;
    final p = _painter.unproject(screen, _size);
    if (p == null) return null;
    return LatLng(WebMercator.latFromY(p.dy), WebMercator.lonFromX(p.dx));
  }

  @override
  Offset project(LatLng latLng) {
    final x = WebMercator.xFromLon(latLng.longitude);
    final y = WebMercator.yFromLat(latLng.latitude);
    return _painter.toScreen(x, y, _world.elevationAt(x, y) ?? 0, _size);
  }

  @override
  Future<void> jumpTo(LatLng center, double zoom, {bool animate = true}) async {
    final x = WebMercator.xFromLon(center.longitude);
    final y = WebMercator.yFromLat(center.latitude);
    if (!animate) {
      _camera
        ..centerX = x
        ..centerY = y
        ..zoom = zoom;
      _refresh();
      return;
    }
    _animateTo(centerX: x, centerY: y, zoom: zoom);
    await _anim.forward(from: 0);
  }

  @override
  Future<void> fitCoordinates(List<LatLng> coordinates, {EdgeInsets padding = EdgeInsets.zero}) async {
    if (coordinates.isEmpty) return;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final c in coordinates) {
      final x = WebMercator.xFromLon(c.longitude);
      final y = WebMercator.yFromLat(c.latitude);
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    final center = LatLng(WebMercator.latFromY((minY + maxY) / 2), WebMercator.lonFromX((minX + maxX) / 2));
    if (_size == Size.zero) return jumpTo(center, _camera.zoom);
    // 1 点なら寄るだけ。幅は真上から見た Mercator m（傾いていると画面の地面は広いので余裕がある）
    final spanX = math.max(maxX - minX, 20.0);
    final spanY = math.max(maxY - minY, 20.0);
    final w = math.max(_size.width - padding.horizontal, 50.0);
    final h = math.max(_size.height - padding.vertical, 50.0);
    final scale = math.min(w / spanX, h / spanY); // px / m
    final zoom = (math.log(scale * 2 * math.pi * WebMercator.radius / 256) / math.ln2).clamp(2.0, 18.0);
    return jumpTo(center, zoom);
  }

  // ── ジェスチャ ──────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    if (_penLock && d.pointerCount == 1) {
      // 真上ロック中の 1 本指は描画（2D と同じ経路。座標は TerrainProjection を通る）
      _toolDrag = true;
      ref.read(currentToolProvider).onScaleStart(d, widget.mapState);
      return;
    }
    _toolDrag = false;
    _scaleStart = _camera.scale;
    _bearingStart = _camera.bearing;
    _pitchStart = _camera.pitch;
    _focalStart = d.focalPoint;
  }

  /// 1 本指 = 3D の回転（左右で方位、上下で傾き）。2 本指 = 平面移動と拡縮（松本の指定・2026-09-08）
  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_toolDrag) {
      if (d.pointerCount == 1) ref.read(currentToolProvider).onScaleUpdate(d, widget.mapState);
      return;
    }
    if (d.pointerCount >= 2) {
      final before = _camera.scale;
      _camera.scale = (_scaleStart * d.scale).clamp(TerrainCamera.scaleForZoom(8), TerrainCamera.scaleForZoom(22));
      if (before != _camera.scale && _size != Size.zero) {
        final off = d.localFocalPoint - Offset(_size.width / 2, _size.height / 2);
        final k = 1 - before / _camera.scale;
        final move = _camera.unprojectPan(off * k);
        _camera.centerX += move.dx;
        _camera.centerY += move.dy;
      }
      final move = _camera.unprojectPan(d.focalPointDelta);
      _camera.centerX -= move.dx;
      _camera.centerY -= move.dy;
    } else if (_mouse && !HardwareKeyboard.instance.isControlPressed) {
      // マウスの左ドラッグは移動（回転は右ドラッグか Ctrl + 左）
      final move = _camera.unprojectPan(d.focalPointDelta);
      _camera.centerX -= move.dx;
      _camera.centerY -= move.dy;
    } else {
      final delta = d.focalPoint - _focalStart;
      _camera.bearing = _bearingStart + delta.dx * 0.006;
      _camera.pitch = (_pitchStart - delta.dy * 0.004).clamp(0.0, _maxPitchDeg * math.pi / 180);
      _gesturing = true;
    }
    _refresh();
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_toolDrag) {
      _toolDrag = false;
      ref.read(currentToolProvider).onScaleEnd(d, widget.mapState);
      return;
    }
    _gesturing = false;
    _refresh();
  }

  /// ペンロック中の生のポインタ（2D のジェスチャ層と同じく、描画の滑らかさのためにバッファへ）
  /// 今のポインタがマウスか（web / PC）。マウスなら 左ドラッグ = 移動、右ドラッグ or Ctrl + 左 = 回転・傾き、ホイール = 拡縮
  /// （MapLibre の慣例。2 本指が無いので）
  bool _mouse = false;
  Offset? _rightDragLast;

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _mouse = e.kind == PointerDeviceKind.mouse;
      // 右ボタンのドラッグは ScaleGestureRecognizer が拾わないので生のポインタで回す
      _rightDragLast = _mouse && (e.buttons & kSecondaryButton) != 0 ? e.localPosition : null;
    } else if (e is PointerMoveEvent && _rightDragLast != null) {
      final delta = e.localPosition - _rightDragLast!;
      _rightDragLast = e.localPosition;
      _rotateBy(delta);
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (_rightDragLast != null) {
        _rightDragLast = null;
        _gesturing = false;
        _refresh();
      }
    }
    if (!_penLock) return;
    final tool = ref.read(currentToolProvider);
    if (e is PointerDownEvent || e is PointerMoveEvent) {
      tool.addPointerToBuffer(e.localPosition);
    } else if (e is PointerUpEvent) {
      tool.clearPointerBuffer();
    }
  }

  /// 画面上の移動量 [delta] を方位・傾きに（1 本指・右ドラッグ・Ctrl + 左ドラッグで共通）
  void _rotateBy(Offset delta) {
    _camera.bearing += delta.dx * 0.006;
    _camera.pitch = (_camera.pitch - delta.dy * 0.004).clamp(0.0, _maxPitchDeg * math.pi / 180);
    _gesturing = true;
    _refresh();
  }

  /// ホイール = 拡縮（カーソルの下を留める）
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || _size == Size.zero) return;
    final before = _camera.scale;
    final dz = -e.scrollDelta.dy / 400; // 1 ノッチ ≒ 0.25 段
    _camera.zoom = (_camera.zoom + dz).clamp(8, 22);
    final off = e.localPosition - Offset(_size.width / 2, _size.height / 2);
    final k = 1 - before / _camera.scale;
    final move = _camera.unprojectPan(off * k);
    _camera.centerX += move.dx;
    _camera.centerY += move.dy;
    _refresh();
  }

  // ── オーバーレイ画像 ─────────────────────────────────

  /// 見えているオーバーレイ画像の集合・位置が変わったら、画像を読み、テクスチャを作り直す（400ms にまとめる）
  void _syncOverlays() {
    if (kIsWeb) return; // web はファイルパスで読めない（未対応）
    final nodes = widget.mapState.overlayImageNodes;
    final key = [
      for (final n in nodes)
        '${n.filePath}|${n.overlayParams.centerLat},${n.overlayParams.centerLng},${n.overlayParams.scale},'
            '${n.overlayParams.rotation},${n.overlayParams.imageWidth},${n.overlayParams.imageHeight}',
    ].join(';');
    if (key == _overlayKey) return;
    _overlayKey = key;
    // 前回の範囲（消えた分）と今回の範囲（現れた分）の両方を作り直す
    var b = _overlayBounds ?? _lastOverlayBounds;
    for (final n in nodes) {
      for (final c in n.cornerCoordinates) {
        final p = Offset(WebMercator.xFromLon(c.longitude), WebMercator.yFromLat(c.latitude));
        b = b == null ? Rect.fromPoints(p, p) : b.expandToInclude(Rect.fromPoints(p, p));
      }
    }
    _overlayBounds = b?.inflate(50) ?? _overlayBounds;
    _lastOverlayBounds = b;
    AppLogger.debug('[3D] overlays: ${nodes.length} 枚 ${[for (final n in nodes) n.filePath]}');
    for (final n in nodes) {
      if (_overlayImages.containsKey(n.filePath) || _overlayLoading.contains(n.filePath)) continue;
      _overlayLoading.add(n.filePath);
      _loadOverlayImage(n.filePath, n.imageUrl).then((im) {
        _overlayLoading.remove(n.filePath);
        if (im == null || !mounted) return;
        _overlayImages[n.filePath] = im;
        _scheduleRetexture();
      });
    }
    _scheduleRetexture();
  }

  Future<ui.Image?> _loadOverlayImage(String key, String url) async {
    try {
      final path = url.startsWith('file:///') ? Uri.parse(url).toFilePath() : url;
      final bytes = await File(path).readAsBytes();
      return await decodeImageFromList(bytes);
    } catch (e) {
      AppLogger.debug('[3D] overlay $key を読めない: $e');
      return null;
    }
  }

  void _scheduleRetexture() {
    _retextureTimer?.cancel();
    _retextureTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _world.retexture(within: _overlayBounds);
      _overlayBounds = null;
    });
  }

  @override
  void reassemble() {
    super.reassemble();
    _overlayKey = ''; // ホットリロードでオーバーレイを同期し直す
  }

  /// テクスチャの上にオーバーレイ画像を描く（四隅の Mercator 座標 → テクスチャのピクセルへのアフィン変換）
  void _decorateTexture(ui.Canvas canvas, TileRange range) {
    if (_overlayImages.isEmpty) return;
    const ts = WebMercator.tileSize;
    final west = range.west;
    final north = WebMercator.tileNorth(range.y0, range.z);
    final pxPerM = range.width * ts / range.widthMeters;
    final texRect = Rect.fromLTWH(0, 0, range.width * ts * 1.0, range.height * ts * 1.0);
    for (final n in widget.mapState.overlayImageNodes) {
      final im = _overlayImages[n.filePath];
      if (im == null) continue;
      final c = n.cornerCoordinates; // TL, TR, BR, BL
      Offset px(LatLng p) => Offset(
            (WebMercator.xFromLon(p.longitude) - west) * pxPerM,
            (north - WebMercator.yFromLat(p.latitude)) * pxPerM,
          );
      final tl = px(c[0]);
      final tr = px(c[1]);
      final bl = px(c[3]);
      final br = px(c[2]);
      final bbox = Rect.fromPoints(tl, br).expandToInclude(Rect.fromPoints(tr, bl));
      if (!bbox.overlaps(texRect)) continue;
      final w = im.width.toDouble();
      final h = im.height.toDouble();
      // 画像ピクセル (u, v) → tl + u/w (tr − tl) + v/h (bl − tl)
      final m = Float64List.fromList([
        (tr.dx - tl.dx) / w, (tr.dy - tl.dy) / w, 0, 0,
        (bl.dx - tl.dx) / h, (bl.dy - tl.dy) / h, 0, 0,
        0, 0, 1, 0,
        tl.dx, tl.dy, 0, 1,
      ]);
      canvas.save();
      canvas.transform(m);
      canvas.drawImage(im, Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.medium);
      canvas.restore();
    }
  }

  /// ズームボタン（web / PC 向け。画面中心を留めて 1 段）
  void _zoomBy(double delta) {
    _camera.zoom = (_camera.zoom + delta).clamp(8, 22);
    _refresh();
    setState(() {});
  }

  void _onTapUp(TapUpDetails d) {
    // 選択などは既存のツールに任せる（投影は TerrainProjection 経由でここを通る）
    ref.read(currentToolProvider).onTap(d, widget.mapState);
  }

  // ── UI ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    ref.listen(partySessionProvider, (_, _) => _scheduleRefresh());
    ref.listen(currentToolProvider, (_, next) => _onToolChanged(next.name));
    final desktop = kIsWeb || (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _size) {
          _size = size;
          _scheduleRefresh();
        }
        _painter.pixelRatio = MediaQuery.devicePixelRatioOf(context);
        final loading = _world.pendingCount > 0;
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: _onPointer,
                onPointerMove: _onPointer,
                onPointerUp: _onPointer,
                onPointerCancel: _onPointer,
                onPointerSignal: _onPointerSignal,
                child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                onTapUp: _onTapUp,
                child: ClipRect(
                  child: ColoredBox(
                    // 最初に全面が揃うまでは透明にして下の 2D 地図を見せる（入った直後の白い一瞬を消す）
                    color: _everCovered ? const Color(0xFFE6E6E6) : Colors.transparent,
                    child: CustomPaint(painter: _painter, child: const SizedBox.expand()),
                  ),
                ),
              ),
              ),
            ),
            // コンパス: 方位に合わせて回る。タップで北を上に・真上から
            Positioned(
              right: 8,
              top: 8,
              child: ValueListenableBuilder<double>(
                valueListenable: widget.mapBearingNotifier,
                builder: (_, bearingDeg, _) => _CompassButton(bearingDeg: bearingDeg, pitchDeg: _camera.pitch * 180 / math.pi, onPressed: _resetView),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!kReleaseMode) ...[
                    // 台本でカメラを動かして被覆率とフレーム時間を [3D] drive ログに出す（debug / profile）
                    _ZoomButton(
                      icon: _drive == null ? Icons.route : Icons.stop,
                      tooltip: 'ドライブ',
                      onPressed: () => setState(_drive == null ? _startDrive : _stopDrive),
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (desktop) ...[
                    _ZoomButton(icon: Icons.add, tooltip: '拡大', onPressed: () => _zoomBy(1)),
                    const SizedBox(height: 6),
                    _ZoomButton(icon: Icons.remove, tooltip: '縮小', onPressed: () => _zoomBy(-1)),
                  ],
                ],
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
            if (loading)
              Positioned(
                left: 8,
                top: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(t.map.terrain.loading(pending: _world.pendingCount), style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
