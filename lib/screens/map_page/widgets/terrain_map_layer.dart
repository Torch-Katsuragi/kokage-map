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
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

import '../../../core/fs/k_file_system.dart';
import '../../../core/map_layout.dart';
import '../../../core/terrain/contour_tiles.dart';
import '../../../core/terrain/dem_grid.dart';
import '../../../core/terrain/dem_tiles.dart';
import '../../../core/terrain/gpu/terrain_gpu.dart';
import '../../../core/terrain/terrain_appearance.dart';
import '../../../core/terrain/terrain_camera.dart';
import '../../../core/terrain/terrain_frame.dart';
import '../../../core/terrain/terrain_lifted.dart';
import '../../../core/terrain/terrain_mesh.dart';
import '../../../core/terrain/terrain_scene.dart';
import '../../../core/terrain/terrain_worker.dart';
import '../../../core/terrain/terrain_world.dart';
import '../../../core/terrain/terrain_world_painter.dart';
import '../../../core/terrain/web_mercator.dart';
import '../../../devices/base/device_tool.dart';
import '../../../i18n/strings.g.dart';
import '../../../interfaces/map_state_interface.dart';
import '../../../interfaces/terrain_projection.dart';
import '../../../models/basemap_provider.dart';
import '../../../models/map_style_group.dart';
import '../../../models/nodes/external_overlay_image_node.dart';
import '../../../models/nodes/overlay_image_node.dart';
import '../../../models/party/party_room.dart';
import '../../../providers/party_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/tool_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../services/basemap_service.dart';
import '../../../tools/gps_tool.dart';
import '../../../tools/map_tool.dart';
import '../../../tools/overlay_transform_tool.dart';
import '../../../tutorial/tutorial.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/global_drawing_state.dart';
import '../../layer_style_settings_screen.dart';
import '../feature_geojson_cache.dart';
import 'terrain_texture_paint.dart';

part 'terrain_map_layer_bake.dart';
part 'terrain_map_layer_camera.dart';
part 'terrain_map_layer_controls.dart';
part 'terrain_map_layer_drive.dart';
part 'terrain_map_layer_gestures.dart';
part 'terrain_map_layer_scene.dart';

/// 地図面（v2: タイルの世界）。地図はこれだけ（MapLibre は 2026-10-04 に外した）
///
/// シーン（[FeatureGeoJsonCache] の GeoJSON と [MapStyleGroup]）を地形の上に描く（flutter_gpu、無い環境は純 Dart）。設計は `docs/technical/terrain-3d.md` の「v2: タイルの世界」。
///
/// - 世界は [TerrainWorld]（DEM タイルのストリーミング）。カメラが動くと見える範囲 + 余白のタイルを揃え、
///   届いたものから描く。読み込みで画面は止まらない
/// - フィーチャはタイルごとに計算メッシュへ貼り付けてキャッシュ。パンで貼り直さない
/// - 2D は真上から見ているだけ（コンパスのタップで切り替え）。カメラは `RMapController` に覚えさせる
/// - `IMapState.offsetToLatLng` / `latLngToOffset` は [TerrainProjection] としてここを通る
/// - 操作: 1 本指 = 回転と傾き、2 本指 = 平面移動と拡縮（ユーザーの指定）
class TerrainMapLayer extends ConsumerStatefulWidget {
  const TerrainMapLayer({
    super.key,
    required this.mapState,
    required this.baseMapService,
    required this.geoJson,
    required this.sceneRevision,
    required this.styleGroups,
    required this.location,
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

  /// 現在位置。変わったら描き直す（ページは組み立て直さない）
  final ValueListenable<LatLng?> location;

  /// 今日の GPS 軌跡（未 Consolidation 分。Consolidation 済みはレイヤ経由で届く）
  final List<LatLng> Function() gpsTrack;

  /// 端末の向き（度）。現在位置の扇（2D のコンパス扇と同じ）
  final ValueListenable<double?>? heading;

  /// 投影の登録 / 解除（3D に入るとき / 出るとき）
  final void Function(TerrainProjection? projection) onProjectionChanged;

  /// コンパス扇と画面外インジケータの追従用（map_page_state_base のもの）
  final ValueNotifier<double> mapBearingNotifier;
  final ValueNotifier<int> cameraTickNotifier;

  @override
  ConsumerState<TerrainMapLayer> createState() => _TerrainMapLayerState();
}

class _TerrainMapLayerState extends ConsumerState<TerrainMapLayer>
    with
        SingleTickerProviderStateMixin,
        _TerrainDrive,
        _TerrainGestures,
        _TerrainScenes,
        _TerrainBakes,
        _TerrainCameraControl {
  /// 入ったときの傾き。起動時は真上（ユーザー 2026-09-11 決定。2D と同じ絵で始まり、傾けたい人が傾ける）
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
  static final _tileImages = TileImageCache(capacity: 256); // 256² RGBA × 256 ≈ 64MB（細かい段は 1 タイル 16 枚 × 層）

  @override
  late final TerrainCamera _camera;
  @override
  late final TerrainWorld _world;
  late final TerrainFramePlanner _planner;
  @override
  late final TerrainWorldPainter _painter;

  /// 地形・面・線を描く GPU 経路（flutter_gpu）。用意できるまで／web では null（純 Dart 経路）
  @override
  TerrainGpuWorldRenderer? _gpu;
  @override
  TerrainFramePlan? _lastPlan;

  final _repaint = ValueNotifier<int>(0);
  @override
  Size _size = Size.zero;
  String _attribution = '';

  /// いま貼っている基図（設定で変わる）
  BaseMapProvider? _basemap;

  /// 一番下の見えているレイヤ（基図）
  BaseMapProvider? _currentBasemap() {
    final layers = widget.baseMapService.activeLayers;
    return layers.isNotEmpty ? layers.first.$1 : null;
  }

  /// 背景地図レイヤの署名（変わったらテクスチャを貼り直す）: 各層の id・不透明度・合成モード
  String _textureLayersKey() =>
      [for (final (p, l) in widget.baseMapService.activeLayers) '${p.id}:${l.opacity}:${l.blend.name}'].join(',');
  String _textureKey = '';

  /// テクスチャに合成する層（設定の背景地図レイヤ、下から上へ。等高線もその 1 つで、生成プロバイダのタイルは
  /// キャッシュに無ければ [_renderContourTile] が作る）
  List<TextureLayer> _layerFetchers() {
    final svc = widget.baseMapService;
    return [
      for (final (p, l) in svc.activeLayers) ((z, x, y) => svc.getTile(p, z, x, y), l.opacity / 100, l.blend.mode),
    ];
  }

  /// 等高線タイルを作る（`contour_tiles.dart`）。テクスチャの段 z の 1 段下の DEM タイルの、該当する 1/4 を描く。
  /// DEM の段が足りなければ（z > 18）さらに上の段から
  Future<Uint8List?> _renderContourTile(int z, int x, int y) async {
    final zDem = math.min(z - 1, _world.maxZoom);
    final k = z - zDem;
    if (zDem < _world.minZoom || k < 1 || k > 4) return null;
    final key = TileKey(zDem, x >> k, y >> k);
    final dem = await _world.demFor(key);
    if (dem == null || !mounted) return null;
    final cells = WebMercator.tileSize >> k;
    final mask = (1 << k) - 1;
    final args = ContourTileArgs(
      heights: dem.heights,
      cols: dem.cols,
      rows: dem.rows,
      cellSize: dem.cellSize,
      col0: (x & mask) * cells,
      row0: WebMercator.tileSize - ((y & mask) + 1) * cells, // 行は南が 0
      cells: cells,
      interval: ContourTiles.intervalForZoom(z),
      alpha: z <= 13 ? 0.55 : 1.0, // 粗い段は薄く（親タイルの継ぎはぎがうるさくない）
    );
    return TerrainWorker.instance.run(renderContourTilePng, args);
  }

  /// 地図面に出す出典。普段は出さず（出典は設定の「地図・タイル」にまとめた。ユーザー 2026-09-13）、
  /// OpenStreetMap が見えているときだけ出す（OSM の表示ガイドラインは対話型地図では地図上のクレジットを求める。
  /// 地理院タイルと Terrain Tiles は「出典を明示」で、置き場所は問わない）
  String _osmAttribution() => {
        for (final (p, _) in widget.baseMapService.activeLayers)
          if (p.type == BaseMapType.openStreetMap) p.attribution,
      }.join(' / ');

  /// 基図の設定が変わった（地形のテクスチャを貼り直す）
  void _onBasemapChanged() {
    final key = _textureLayersKey();
    if (key == _textureKey) return;
    _textureKey = key;
    _basemap = _currentBasemap();
    _attribution = _osmAttribution();
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
  /// 1 フレームのメッシュ生成に使う時間。超えたぶんは手持ちの段か穴埋めで繋いで次のフレームに回す
  /// （新しいタイルが 5 枚同時に届くと 20ms × 5 で 1 フレーム 100ms になっていた）
  static const _meshBudgetMs = 20;
  final Stopwatch _meshSw = Stopwatch();
  int _frameMs = 0;

  int _worldRevisionSeen = -1;

  /// 2D モード（真上固定。1 本指 = 移動、2 本指 = 移動・拡縮・回転。3D 導入前のパンと同じ）。
  /// 中身は 3D を真上から見ているだけ。3D モードは 1 本指 = 回転・傾き、2 本指 = 移動・拡縮。
  /// 起動は 2D（真上）。切替はコンパスのタップ（ユーザー 2026-09-13）
  @override
  bool _flat = true;

  /// ペン選択中: 真上に寄せて 1 本指をツール（描画）に渡す。離れたら元の傾きに戻す（2D モードなら真上のまま）
  @override
  bool _penLock = false;
  @override
  double? _pitchBeforePen;

  @override
  void initState() {
    super.initState();
    // web: 右ドラッグ = 回転なので、ブラウザのコンテキストメニューを地図の間だけ止める
    // （右ボタンを離すたびにメニューが出ていた。ユーザー 2026-09-12）
    if (kIsWeb) BrowserContextMenu.disableContextMenu();
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
    _textureKey = _textureLayersKey();
    _attribution = _osmAttribution();
    widget.baseMapService.addListener(_onBasemapChanged);
    widget.baseMapService.registerTileGenerator(BaseMapProvider.contourOverlay.id, _renderContourTile);
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
      ..textureLayers = _layerFetchers
      ..addListener(_onWorldChanged)
      ..textureDecorator = _decorateTexture
      ..onTextureApplied = _onTextureApplied;
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
    TerrainAppearance.revision.addListener(_onAppearanceChanged);
    widget.heading?.addListener(_onHeading);
    widget.location.addListener(_scheduleRefresh);
    // 描きかけの線・面・点（ペン・GPS 測量）。地図ページは組み直さないのでここで聞く
    GlobalDrawingState.instance.addListener(_scheduleRefresh);
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
      debugPrint('[3D] GPU で描く（${kIsWeb ? 'WebGL2' : 'flutter_gpu'}）');
      _scheduleRefresh();
    } catch (e) {
      debugPrint('[3D] flutter_gpu 不可（純 Dart で描く）: $e');
    }
  }

  /// 1 本指を取るツール（真上ロックの対象）
  static bool _toolTakesDrag(String toolName) =>
      toolName == 'Pen' || toolName == 'Overlay Transform' || toolName == 'Edit';

  /// 購読している外部機器ツール
  DeviceTool? _listenedDevice;

  /// ツールが変わった: 1 本指を取るツールなら真上に寄せて 1 本指を渡す。離れたら傾きを戻す
  void _onToolChanged(String toolName) {
    // 外部機器ツールは計測のたびに notify するので、その間だけ購読する
    final tool = ref.read(currentToolProvider);
    if (!identical(tool, _listenedDevice)) {
      _listenedDevice?.removeListener(_scheduleRefresh);
      _listenedDevice = tool is DeviceTool ? tool : null;
      _listenedDevice?.addListener(_scheduleRefresh);
    }
    final pen = _toolTakesDrag(toolName);
    // 地物の編集は 2D に固定（真上から見ないと頂点の位置がずれて見える）。抜けても 2D のまま
    if (toolName == 'Edit') {
      _flat = true;
      _camera.perspective = false;
      _pitchBeforePen = 0;
    }
    if (pen && !_penLock) {
      _penLock = true;
      _pitchBeforePen = _camera.pitch;
      _animateTo(pitch: 0);
    } else if (!pen && _penLock) {
      _penLock = false;
      _toolDrag = false;
      _animateTo(pitch: _flat ? 0 : (_pitchBeforePen ?? _defaultPitchDeg * math.pi / 180));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 画面密度 2 以上なら、細かい段（z15 以上 = テクスチャ z17 以上）だけテクスチャを 2 段上で作る（1024²）。
    // 読み込み済みのタイルは貼り直さない（密度は途中で変わらない）
    final dpr = MediaQuery.devicePixelRatioOf(context);
    _world.textureZoomOffsetFor = (z) => dpr >= 2 && z >= 15 ? 2 : 1;
  }

  @override
  void dispose() {
    if (kIsWeb) BrowserContextMenu.enableContextMenu();
    _listenedDevice?.removeListener(_scheduleRefresh);
    widget.baseMapService.removeListener(_onBasemapChanged);
    widget.baseMapService.unregisterTileGenerator(BaseMapProvider.contourOverlay.id, _renderContourTile);
    _anim.dispose();
    _disposeBakes();
    _stopDrive();
    widget.heading?.removeListener(_onHeading);
    widget.location.removeListener(_scheduleRefresh);
    GlobalDrawingState.instance.removeListener(_scheduleRefresh);
    widget.sceneRevision.removeListener(_onSceneRevision);
    TerrainAppearance.revision.removeListener(_onAppearanceChanged);
    widget.onProjectionChanged(null);
    // 最後のカメラを覚えさせる（次に組み立てるときの初期値）
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
    // 親の setState は全部ここに来るので、毎回 1 回だけ予約する
    _scheduleRefresh();
  }

  bool _refreshScheduled = false;

  /// 次のフレームの頭で 1 回だけ描き直す。タイル到着・メッシュ完成・シーン更新など
  /// 非同期のきっかけはすべてここを通す（同期に呼ぶと到着のたびに連鎖して止まる）
  @override
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

  /// 向きが 5° の刻みをまたいだときだけ描き直す（現在位置の扇は 5° 刻みで作るので、それ未満の変化では絵が変わらない）
  int? _headingBucket;
  void _onHeading() {
    final h = widget.heading?.value;
    final bucket = h == null ? null : (h / 5).round();
    if (bucket == _headingBucket) return;
    _headingBucket = bucket;
    _scheduleRefresh();
  }

  void _onWorldChanged() {
    _scheduleRefresh();
    _scheduleBakeCheck();
  }

  // ── フレームの組み立て ──────────────────────────────

  /// 見える範囲のタイルを揃え、描けるものを描画順に painter へ渡す
  @override
  void _refresh() {
    if (_size == Size.zero) return;
    _syncOverlays();
    _syncSelectionFill();
    final sw = Stopwatch()..start();
    _meshBuilds = 0;
    _placeholders = 0;
    _startSceneFrame();
    _meshSw.reset();
    _frameMs = DateTime.now().millisecondsSinceEpoch;
    _camera.viewport = _size;
    final plan = _planner.plan(_camera, _size, gesturing: _gesturing);
    final planMs = sw.elapsedMilliseconds;
    _lastPlan = plan;
    if (_world.revision != _worldRevisionSeen) {
      // タイルの出入り: 消えたタイルのぶんだけ捨てる（縁が変わったタイルはキーが変わるので自然に入れ替わる）
      _pruneScenes();
      _pruneMeshes();
      // GPU 側のテクスチャは生きているタイルの世代だけ残す（`ui.Image` を手放した後の唯一の実体なので時間では捨てない）
      final gpu = _gpu;
      if (gpu != null) {
        // 新しい世代の転送が終わるまでは前の世代も生かしておく（web）。終わったら捨てる
        gpu.pruneTextures({
          for (final t in _world.tiles) ...[
            t.textureKey,
            if (t.previousTextureKey != null && !gpu.isTextureReady(t.textureKey)) t.previousTextureKey!,
          ],
        });
      }
      _worldRevisionSeen = _world.revision;
    }
    final drawables = <TerrainTileDrawable>[];
    for (final tile in plan.tiles) {
      final step = plan.stepFor(tile);
      final skirt = _skirtOf(tile);
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

  /// タイルの縁の垂れ（タイル幅の 3%）
  static double _skirtOf(TerrainTile tile) => tile.key.span * 0.03;

  /// 一度でも全面が揃ったか（揃うまで背景は透明）
  bool _everCovered = false;
  int _meshBuilds = 0;
  @override
  int _placeholders = 0;
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
        return _drawable(tile, tile.placeholderBuilder(chunkSize: _world.chunkSize, skirtDepth: _skirtOf(tile)), 16);
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
      previousTextureKey: tile.previousTextureKey,
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

  void _notifyCamera() {
    widget.mapBearingNotifier.value = _camera.bearing * 180 / math.pi;
    widget.cameraTickNotifier.value++;
    // 組み立て直すときの初期値・ホルダー経由の camera として覚えさせる
    widget.mapState.mapController.rememberCamera(_centerLatLng(), _camera.zoom, _camera.bearing * 180 / math.pi);
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
    // チュートリアル: 章に入るたびに 2D・北が上に戻す（1 章で 3D にすると、次の章も斜めの眺めで始まっていた）
    ref.listen(tutorialProvider, (prev, s) {
      if (s == null || s.menu || s.index != 0) return;
      if (prev != null && !prev.menu && prev.chapter == s.chapter) return;
      _resetToFlatNorth();
    });
    final desktop = kIsWeb || (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS);
    final editing = ref.watch(currentToolProvider).name == 'Edit';
    final toolbarLeft = MapLayout.resolve(ref.watch(mapLayoutPresetSettingProvider), MediaQuery.sizeOf(context)).toolbarLeft;
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
                    child: Stack(
                      children: [
                        // web の WebGL2 は自前の canvas に描く（platform view）。その上に点とラベルを Canvas で
                        if (_gpu?.platformViewType case final viewType?)
                          Positioned.fill(child: IgnorePointer(child: HtmlElementView(viewType: viewType))),
                        CustomPaint(painter: _painter, child: const SizedBox.expand()),
                      ],
                    ),
                  ),
                ),
              ),
              ),
            ),
            // コンパス: 方位に合わせて回る。タップで 2D ⇄ 3D、ダブルタップで北を上に、長押しで眺めモード
            // （地物の編集中は地図の上のボタンを出さない。2D 固定で、地図は形を直すためだけに使う）
            if (!editing)
            Positioned(
              right: 8,
              top: 8,
              child: ValueListenableBuilder<double>(
                valueListenable: widget.mapBearingNotifier,
                builder: (_, bearingDeg, _) => _CompassButton(
                  key: TutorialTargets.compassButton,
                  bearingDeg: bearingDeg,
                  pitchDeg: _camera.pitch * 180 / math.pi,
                  flat: _flat,
                  perspective: _camera.perspective,
                  onPressed: _toggleMode,
                  onDoubleTap: _resetNorth,
                  onLongPress: _flat ? null : _togglePerspective,
                ),
              ),
            ),
            // 拡大縮小（desktop）とドライブ（debug）。左下のフローティングボタン列の反対側に置く
            // （左利きではフローティングボタン列が右下に来て重なっていた）
            if (!editing)
            Positioned(
              right: toolbarLeft ? 8 : null,
              left: toolbarLeft ? null : 8,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!kReleaseMode) ...[
                    // 台本でカメラを動かして被覆率とフレーム時間を [3D] drive ログに出す（debug / profile）
                    _ZoomButton(
                      icon: _drive == null ? Icons.route : Icons.stop,
                      tooltip: 'ドライブ',
                      onPressed: () {
                        final starting = _drive == null;
                        setState(starting ? _startDrive : _stopDrive);
                        ref.read(mapFlashProvider.notifier).show(starting ? t.map.flash.driveStart : t.map.flash.driveStop);
                      },
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
            if (_attribution.isNotEmpty)
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
