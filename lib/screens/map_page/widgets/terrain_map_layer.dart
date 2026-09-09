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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../../core/terrain/dem_grid.dart';
import '../../../core/terrain/dem_tiles.dart';
import '../../../core/terrain/terrain_camera.dart';
import '../../../core/terrain/terrain_frame.dart';
import '../../../core/terrain/terrain_mesh.dart';
import '../../../core/terrain/terrain_painter.dart';
import '../../../core/terrain/terrain_scene.dart';
import '../../../core/terrain/terrain_world.dart';
import '../../../core/terrain/terrain_world_painter.dart';
import '../../../core/terrain/web_mercator.dart';
import '../../../i18n/strings.g.dart';
import '../../../interfaces/map_state_interface.dart';
import '../../../interfaces/terrain_projection.dart';
import '../../../models/basemap_provider.dart';
import '../../../models/party/party_room.dart';
import '../../../providers/party_providers.dart';
import '../../../providers/tool_providers.dart';
import '../../../services/basemap_service.dart';
import '../../../services/map_source_manager.dart';
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
  _TileScene({required this.key, required this.lines, required this.polygons, required this.points, required this.labels});

  /// 何から作ったか（GeoJSON リストの同一性・選択・軌跡の点数・パーティ・現在位置）
  final List<Object?> key;
  final List<LiftedPolyline> lines;
  final List<LiftedPolygon> polygons;
  final List<TerrainPoint> points;
  final List<TerrainLabel> labels;
}

class _TerrainMapLayerState extends ConsumerState<TerrainMapLayer>
    with SingleTickerProviderStateMixin, _TerrainDrive
    implements TerrainProjection {
  static const _defaultPitchDeg = 45.0;

  /// 傾きの上限。正射影では 90° で地面が線に潰れる（横顔になる）ので手前で止める。
  /// 寝かせるほど画面に掛かる地面が広がり、計画が段を下げて粗くなる（枚数は上限内に収まる）
  static const _maxPitchDeg = 85.0;

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
  @override
  TerrainFramePlan? _lastPlan;

  final _repaint = ValueNotifier<int>(0);
  Size _size = Size.zero;
  String _attribution = '';
  @override
  bool _gesturing = false;

  // タイルごとのキャッシュ。キーにビルダー（縁が変わると別物になる）と borderMask を含めるので、
  // タイルが届いても他のタイルのキャッシュは生きたまま
  final Map<TerrainMeshBuilder, (double, double, TerrainMesh)> _meshes = {}; // (bearing, pitch, mesh)
  // キー: (タイル, step, 縁の組み合わせ, 高さの出どころの段)。近似 → 本物の差し替えで作り直す
  final Map<(TileKey, int, int, int), _TileScene> _scenes = {};
  final Map<(TileKey, int, int, int), _TileScene> _staticScenes = {};
  final Map<(TileKey, int, int, int), _TileScene> _dynamicScenes = {};

  /// 1 フレームに作る静的な貼り付けの枚数と上限
  int _staticBuilds = 0;
  static const _staticBudget = 2;
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
    final layers = widget.baseMapService.activeLayerConfig;
    final basemap = layers.isNotEmpty ? layers.first.$1 : null;
    _attribution = [
      if (basemap != null) basemap.attribution,
      ...{for (final s in DemTileSource.defaultCascade) s.attribution},
    ].join(' / ');
    _world = TerrainWorld(
      demSources: DemTileSource.defaultCascade,
      demFetcher: (source, z, x, y) => widget.baseMapService.getTile(_terrainProviders[source.id]!, z, x, y),
      textureFetcher: basemap == null
          ? (z, x, y) async => null
          : (z, x, y) => widget.baseMapService.getTile(basemap, z, x, y),
      imageCache: _tileImages,
    )..addListener(_onWorldChanged);
    _planner = TerrainFramePlanner(_world);
    _painter = TerrainWorldPainter(
      camera: _camera,
      tiles: const [],
      elevationAt: (x, y) => _world.elevationAt(x, y),
      heightRange: (0, 1000),
      stepMeters: 10,
      repaint: _repaint,
    );
    widget.sceneRevision.addListener(_onSceneRevision);
    widget.onProjectionChanged(this);
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 350))
      ..addListener(_onAnimTick)
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed && mounted) setState(() {});
      });
    if (ref.read(currentToolProvider).name == 'Pen') {
      _penLock = true;
      _pitchBeforePen = _camera.pitch;
      _camera.pitch = 0;
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
    _anim.forward(from: 0);
  }

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
  void _resetView() => _animateTo(bearing: 0, pitch: 0);

  /// ツールが変わった: ペンなら真上に寄せて 1 本指を描画に渡す。離れたら傾きを戻す
  void _onToolChanged(String toolName) {
    final pen = toolName == 'Pen';
    if (pen && !_penLock) {
      _penLock = true;
      _pitchBeforePen = _camera.pitch;
      _animateTo(pitch: 0);
    } else if (!pen && _penLock) {
      _penLock = false;
      _toolDrag = false;
      _animateTo(pitch: _pitchBeforePen ?? _defaultPitchDeg * math.pi / 180);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _stopDrive();
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
    final sw = Stopwatch()..start();
    _meshBuilds = 0;
    _placeholders = 0;
    _sceneBuilds = 0;
    _staticBuilds = 0;
    final plan = _planner.plan(_camera, _size, gesturing: _gesturing);
    final planMs = sw.elapsedMilliseconds;
    _lastPlan = plan;
    if (_world.revision != _worldRevisionSeen) {
      // タイルの出入り: 消えたタイルのぶんだけ捨てる（縁が変わったタイルはキーが変わるので自然に入れ替わる）
      _scenes.removeWhere((k, _) => !_world.has(k.$1));
      _staticScenes.removeWhere((k, _) => !_world.has(k.$1));
      _dynamicScenes.removeWhere((k, _) => !_world.has(k.$1));
      _pruneMeshes();
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
    _painter
      ..tiles = drawables
      ..heightRange = _world.heightRange ?? (0, 1000)
      ..stepMeters = WebMercator.metersPerPixel(plan.demZoom);
    _repaint.value++;
    _notifyCamera();
    if (!_everCovered && plan.coverage.full && drawables.isNotEmpty) {
      _everCovered = true;
      if (mounted) setState(() {});
    }
    if (sw.elapsedMilliseconds > 120) {
      AppLogger.debug('[3D] refresh ${sw.elapsedMilliseconds}ms (plan $planMs [${_planner.lastTiming}], meshes built $_meshBuilds, '
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
      return true;
    });
  }

  TerrainTileDrawable _drawable(TerrainTile tile, TerrainMeshBuilder builder, int step) {
    final cached = _meshes[builder];
    final TerrainMesh mesh;
    if (cached != null && cached.$1 == _camera.bearing && cached.$2 == _camera.pitch) {
      mesh = cached.$3;
    } else {
      mesh = builder.build(_camera);
      _meshBuilds++;
      // 古いメッシュの Vertices は native 側にあり GC を待つと溜まるので、その場で返す
      cached?.$3.dispose();
      _meshes[builder] = (_camera.bearing, _camera.pitch, mesh);
    }
    final scene = _sceneFor(tile, mesh, step);
    return TerrainTileDrawable(
      originX: tile.bordered.originX,
      originY: tile.bordered.originY,
      mesh: mesh,
      texture: tile.texture,
      lines: scene.lines,
      polygons: scene.polygons,
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
    final dynamicKey = <Object?>[track.length, session, loc, drawing.drawingLine.length, drawing.drawingPolygon.length, drawing.pointPreview];
    final key = <Object?>[...staticKey, ...dynamicKey];
    final cached = _scenes[cacheKey];
    if (cached != null && _sameKey(cached.key, key)) return cached;

    final dem = mesh.dem;
    final clip = Rect.fromLTWH(0, 0, dem.width, dem.height);
    final clipCells = math.max(1, (20 / (dem.cellSize * step)).round());
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

    // 静的な部分
    var stat = _staticScenes[cacheKey];
    if (stat == null || !_sameKey(stat.key, staticKey)) {
      if (_staticBuilds >= _staticBudget) {
        // 今フレームは見送り。手持ちがあれば古いものを使い、無ければ空
        _scheduleRefresh();
        stat ??= _TileScene(key: const [], lines: const [], polygons: const [], points: const [], labels: const []);
      } else {
        _staticBuilds++;
        _sceneBuilds++;
        stat = _buildStatic(tile, step, staticKey, g, builder, clip);
        _staticScenes[cacheKey] = stat;
      }
    }
    // 動的な部分
    var dyn = _dynamicScenes[cacheKey];
    if (dyn == null || !_sameKey(dyn.key, dynamicKey)) {
      dyn = _buildDynamic(dynamicKey, track, session, loc, dem, builder, clip);
      _dynamicScenes[cacheKey] = dyn;
    }
    final scene = _TileScene(
      key: key,
      lines: [...dyn.lines, ...stat.lines],
      polygons: [...dyn.polygons, ...stat.polygons],
      points: [...stat.points, ...dyn.points],
      labels: [...stat.labels, ...dyn.labels],
    );
    _scenes[cacheKey] = scene;
    return scene;
  }

  /// フィーチャ本体・頂点・写真・選択（GeoJSON のリストが同じ限り作り直さない）
  _TileScene _buildStatic(
    TerrainTile tile,
    int step,
    List<Object?> key,
    FeatureGeoJsonCache g,
    TerrainSceneBuilder Function(Map<String, TerrainFeatureStyle>, TerrainFeatureStyle, String) builder,
    Rect clip,
  ) {
    final sw = Stopwatch()..start();
    final defaultStyle = _defaultStyle();
    final groups = {for (final sg in widget.styleGroups()) sg.key: _styleFromGroup(sg)};
    final lines = <LiftedPolyline>[];
    final polygons = <LiftedPolygon>[];
    final points = <TerrainPoint>[];
    final labels = <TerrainLabel>[];
    void add(TerrainScene s, {bool withLabels = true}) {
      lines
        ..addAll(s.outlines)
        ..addAll(s.lines);
      polygons.addAll(s.polygons);
      points.addAll(s.points);
      if (withLabels) labels.addAll(s.labels);
    }

    // 1. 頂点（設定で有効なとき）
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
    // 2. フィーチャ本体
    add(
      builder(groups, defaultStyle, FeatureGeoJsonInput.labelPropKey)
          .build(lines: g.polylines, polygons: g.polygons, points: g.markers, clipRect: clip),
    );
    // 3. 写真（琥珀）
    add(
      builder(const {}, const TerrainFeatureStyle(
        lineColor: Colors.amber, lineWidth: 1, fillColor: Colors.amber, outlineColor: Colors.amber,
        outlineWidth: 1, pointColor: Colors.amber, pointSize: 7,
      ), 'name').build(points: g.images, clipRect: clip),
    );
    // 4. 選択（上に重ねる）
    add(
      builder({for (final e in groups.entries) e.key: _selectedStyle(e.value)}, _selectedStyle(defaultStyle), '__no_label__')
          .build(lines: g.selectedPolylines, polygons: g.selectedPolygons, points: g.selectedMarkers, clipRect: clip),
      withLabels: false,
    );
    if (sw.elapsedMilliseconds > 20) {
      AppLogger.debug('[3D] tile ${tile.key} step $step 貼り付け ${sw.elapsedMilliseconds}ms '
          '(lines ${lines.length} polys ${polygons.length} pts ${points.length})');
    }
    return _TileScene(key: key, lines: lines, polygons: polygons, points: points, labels: labels);
  }

  /// 今日の GPS 軌跡・パーティ・現在位置（GPS の更新ごとに作り直す。軽い）
  _TileScene _buildDynamic(
    List<Object?> key,
    List<LatLng> track,
    PartySessionState session,
    LatLng? loc,
    DemGrid dem,
    TerrainSceneBuilder Function(Map<String, TerrainFeatureStyle>, TerrainFeatureStyle, String) builder,
    Rect clip,
  ) {
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
    // 3. 現在位置（青）
    if (loc != null) {
      final x = WebMercator.xFromLon(loc.longitude) - dem.originX;
      final y = WebMercator.yFromLat(loc.latitude) - dem.originY;
      if (clip.contains(Offset(x, y))) {
        points.add(TerrainPoint(x: x, y: y, color: Colors.blue, sizePx: 9));
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
    for (final p in [
      ...drawing.drawingLine,
      ...drawing.drawingPolygon,
      if (drawing.pointPreview != null) drawing.pointPreview!,
    ]) {
      final x = WebMercator.xFromLon(p.longitude) - dem.originX;
      final y = WebMercator.yFromLat(p.latitude) - dem.originY;
      if (clip.contains(Offset(x, y))) points.add(TerrainPoint(x: x, y: y, color: Colors.red, sizePx: 6));
    }
    return _TileScene(key: key, lines: lines, polygons: polygons, points: points, labels: labels);
  }

  void _notifyCamera() {
    widget.mapBearingNotifier.value = _camera.bearing * 180 / math.pi;
    widget.cameraTickNotifier.value++;
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
  void _onPointer(PointerEvent e) {
    if (!_penLock) return;
    final tool = ref.read(currentToolProvider);
    if (e is PointerDownEvent || e is PointerMoveEvent) {
      tool.addPointerToBuffer(e.localPosition);
    } else if (e is PointerUpEvent) {
      tool.clearPointerBuffer();
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
        final loading = _world.pendingCount > 0;
        return Stack(
          children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: _onPointer,
                onPointerMove: _onPointer,
                onPointerUp: _onPointer,
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
                  if (kDebugMode) ...[
                    // 台本でカメラを動かして被覆率とフレーム時間を [3D] drive ログに出す
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
                    child: Text('地形 ${_world.loadedCount} 枚 / 読み込み中 ${_world.pendingCount}', style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
