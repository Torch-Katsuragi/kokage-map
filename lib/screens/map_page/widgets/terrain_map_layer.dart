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

import '../../../core/terrain/dem_tiles.dart';
import '../../../core/terrain/terrain_camera.dart';
import '../../../core/terrain/terrain_frame.dart';
import '../../../core/terrain/terrain_mesh.dart';
import '../../../core/terrain/terrain_painter.dart';
import '../../../core/terrain/terrain_scene.dart';
import '../../../core/terrain/terrain_world.dart';
import '../../../core/terrain/terrain_world_painter.dart';
import '../../../core/terrain/web_mercator.dart';
import '../../../interfaces/map_state_interface.dart';
import '../../../interfaces/terrain_projection.dart';
import '../../../models/basemap_provider.dart';
import '../../../models/party/party_room.dart';
import '../../../providers/party_providers.dart';
import '../../../providers/tool_providers.dart';
import '../../../services/basemap_service.dart';
import '../../../services/map_source_manager.dart';
import '../../../utils/app_logger.dart';
import '../../layer_style_settings_screen.dart';
import '../feature_geojson_cache.dart';

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

class _TileScene {
  _TileScene({required this.key, required this.lines, required this.polygons, required this.points, required this.labels});

  /// 何から作ったか（GeoJSON リストの同一性・選択・軌跡の点数・パーティ・現在位置）
  final List<Object?> key;
  final List<LiftedPolyline> lines;
  final List<LiftedPolygon> polygons;
  final List<TerrainPoint> points;
  final List<TerrainLabel> labels;
}

class _TerrainMapLayerState extends ConsumerState<TerrainMapLayer> implements TerrainProjection {
  static const _defaultPitchDeg = 45.0;

  /// 標高タイルを背景地図と同じ経路（キャッシュ → ネット → 祖先タイルから切り出し）で取るための擬似プロバイダ。
  /// 背景地図の一覧には出さない。祖先タイルからの切り出しは DEM では「粗い標高」になるが、無いよりよい
  static const _terrainProvider = BaseMapProvider(
    id: 'aws_terrarium',
    name: 'Terrain Tiles',
    description: 'AWS Terrain Tiles (Terrarium)',
    urlTemplate: 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
    maxZoom: 15,
    attribution: 'Terrain Tiles (Mapzen / AWS Open Data)',
    type: BaseMapType.terrain,
    icon: Icons.terrain,
  );

  /// デコード済みタイル画像。3D を出入りしても使い回す（256 枚 ≒ 64MB 上限）
  static final _tileImages = TileImageCache(capacity: 256);

  late final TerrainCamera _camera;
  late final TerrainWorld _world;
  late final TerrainFramePlanner _planner;
  late final TerrainWorldPainter _painter;
  TerrainFramePlan? _lastPlan;

  // ドライブモード（debug のみ）: 台本でカメラを動かし、被覆率とフレーム時間をログに出す
  Ticker? _drive;
  Timer? _stallProbe;
  (double, double, double, double) _driveOrigin = (0, 0, 0, 0); // centerX, centerY, zoom, bearing
  Duration _driveStart = Duration.zero;
  Duration _driveLastLog = Duration.zero;
  final List<int> _driveUiMs = [];
  final List<int> _driveRasterMs = [];
  int _driveGapFrames = 0;
  int _driveFrames = 0;
  TimingsCallback? _driveTimings;
  final _repaint = ValueNotifier<int>(0);
  Size _size = Size.zero;
  String _attribution = '';
  bool _gesturing = false;

  // タイルごとのキャッシュ。キーにビルダー（縁が変わると別物になる）と borderMask を含めるので、
  // タイルが届いても他のタイルのキャッシュは生きたまま
  final Map<TerrainMeshBuilder, (double, double, TerrainMesh)> _meshes = {}; // (bearing, pitch, mesh)
  final Map<(TileKey, int, int), _TileScene> _scenes = {};
  int _worldRevisionSeen = -1;

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
      DemTileSource.aws.attribution,
    ].join(' / ');
    _world = TerrainWorld(
      demSource: DemTileSource.aws,
      demFetcher: (z, x, y) => widget.baseMapService.getTile(_terrainProvider, z, x, y),
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
  }

  @override
  void dispose() {
    _stopDrive();
    widget.sceneRevision.removeListener(_onSceneRevision);
    widget.onProjectionChanged(null);
    // 真上に戻して MapLibre へ書き戻す
    widget.mapState.mapController.moveAndRotate(_centerLatLng(), _camera.zoom, _camera.bearing * 180 / math.pi);
    _world
      ..removeListener(_onWorldChanged)
      ..dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerrainMapLayer old) {
    super.didUpdateWidget(old);
    // build の最中なので、描き直しはフレームの後で（同期に通知すると setState during build）
    if (old.currentLocation != widget.currentLocation) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  LatLng _centerLatLng() =>
      LatLng(WebMercator.latFromY(_camera.centerY), WebMercator.lonFromX(_camera.centerX));

  void _onWorldChanged() {
    if (mounted) _refresh();
  }

  void _onSceneRevision() => _refresh();

  // ── フレームの組み立て ──────────────────────────────

  /// 見える範囲のタイルを揃え、描けるものを描画順に painter へ渡す
  void _refresh() {
    if (_size == Size.zero) return;
    final sw = Stopwatch()..start();
    _meshBuilds = 0;
    final plan = _planner.plan(_camera, _size, gesturing: _gesturing);
    final planMs = sw.elapsedMilliseconds;
    _lastPlan = plan;
    if (_world.revision != _worldRevisionSeen) {
      // タイルの出入り: 消えたタイルのぶんだけ捨てる（縁が変わったタイルはキーが変わるので自然に入れ替わる）
      _scenes.removeWhere((k, _) => !_world.has(k.$1));
      if (_meshes.length > 64) _meshes.clear();
      _worldRevisionSeen = _world.revision;
    }
    final drawables = <TerrainTileDrawable>[];
    for (final tile in plan.tiles) {
      final step = plan.stepFor(tile);
      final skirt = tile.key.span * 0.03; // タイル幅の 3%
      final builder = tile.builders[step];
      if (builder == null) {
        // isolate で作る。できたら描き直す
        tile.builderFor(step, chunkSize: _world.chunkSize, skirtDepth: skirt).then((_) {
          if (mounted) _refresh();
        });
        // できているものがあれば（粗さが違っても）それで繋ぐ
        if (tile.builders.isEmpty) continue;
        final near = tile.builders.keys.reduce((a, b) => (a - step).abs() <= (b - step).abs() ? a : b);
        drawables.add(_drawable(tile, tile.builders[near]!, near));
        continue;
      }
      drawables.add(_drawable(tile, builder, step));
    }
    _painter
      ..tiles = drawables
      ..heightRange = _world.heightRange ?? (0, 1000)
      ..stepMeters = WebMercator.metersPerPixel(plan.demZoom);
    _repaint.value++;
    _notifyCamera();
    if (sw.elapsedMilliseconds > 120) {
      AppLogger.debug('[3D] refresh ${sw.elapsedMilliseconds}ms (plan $planMs, meshes built $_meshBuilds, tiles ${drawables.length})');
    }
  }

  int _meshBuilds = 0;

  TerrainTileDrawable _drawable(TerrainTile tile, TerrainMeshBuilder builder, int step) {
    final cached = _meshes[builder];
    final TerrainMesh mesh;
    if (cached != null && cached.$1 == _camera.bearing && cached.$2 == _camera.pitch) {
      mesh = cached.$3;
    } else {
      mesh = builder.build(_camera);
      _meshBuilds++;
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

  _TileScene _sceneFor(TerrainTile tile, TerrainMesh mesh, int step) {
    final g = widget.geoJson;
    final track = widget.gpsTrack();
    final session = ref.read(partySessionProvider);
    final loc = widget.currentLocation;
    final key = <Object?>[
      g.polylines, g.polygons, g.markers, g.selectedPolylines, g.selectedPolygons, g.selectedMarkers, g.images,
      g.lineVertices, g.polygonVertices, track.length, session, loc,
    ];
    final cacheKey = (tile.key, step, tile.borderMask);
    final cached = _scenes[cacheKey];
    if (cached != null && _sameKey(cached.key, key)) return cached;

    final sw = Stopwatch()..start();
    final dem = mesh.dem;
    final clip = Rect.fromLTWH(0, 0, dem.width, dem.height);
    final clipCells = math.max(1, (20 / (dem.cellSize * step)).round());
    final defaultStyle = _defaultStyle();
    final groups = {for (final sg in widget.styleGroups()) sg.key: _styleFromGroup(sg)};
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
    // 3. 頂点（設定で有効なとき）
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
    // 4. フィーチャ本体
    add(
      builder(groups, defaultStyle, FeatureGeoJsonInput.labelPropKey)
          .build(lines: g.polylines, polygons: g.polygons, points: g.markers, clipRect: clip),
    );
    // 5. 写真（琥珀）
    add(
      builder(const {}, const TerrainFeatureStyle(
        lineColor: Colors.amber, lineWidth: 1, fillColor: Colors.amber, outlineColor: Colors.amber,
        outlineWidth: 1, pointColor: Colors.amber, pointSize: 7,
      ), 'name').build(points: g.images, clipRect: clip),
    );
    // 6. 選択（上に重ねる）
    add(
      builder({for (final e in groups.entries) e.key: _selectedStyle(e.value)}, _selectedStyle(defaultStyle), '__no_label__')
          .build(lines: g.selectedPolylines, polygons: g.selectedPolygons, points: g.selectedMarkers, clipRect: clip),
      withLabels: false,
    );
    // 7. 現在位置（青）
    if (loc != null) {
      final x = WebMercator.xFromLon(loc.longitude) - dem.originX;
      final y = WebMercator.yFromLat(loc.latitude) - dem.originY;
      if (clip.contains(Offset(x, y))) {
        points.add(TerrainPoint(x: x, y: y, color: Colors.blue, sizePx: 9));
      }
    }
    final scene = _TileScene(key: key, lines: lines, polygons: polygons, points: points, labels: labels);
    _scenes[cacheKey] = scene;
    if (sw.elapsedMilliseconds > 20) {
      AppLogger.debug('[3D] tile ${tile.key} step $step 貼り付け ${sw.elapsedMilliseconds}ms '
          '(lines ${lines.length} polys ${polygons.length} pts ${points.length})');
    }
    return scene;
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
    _scaleStart = _camera.scale;
    _bearingStart = _camera.bearing;
    _pitchStart = _camera.pitch;
    _focalStart = d.focalPoint;
  }

  /// 1 本指 = 3D の回転（左右で方位、上下で傾き）。2 本指 = 平面移動と拡縮（松本の指定・2026-09-08）
  void _onScaleUpdate(ScaleUpdateDetails d) {
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
      _camera.pitch = (_pitchStart - delta.dy * 0.004).clamp(0.0, 70 * math.pi / 180);
      _gesturing = true;
    }
    _refresh();
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _gesturing = false;
    _refresh();
  }

  // ── ドライブモード ──────────────────────────────────

  /// 台本: 0〜8s 東へ 3km、8〜16s 引き 4 段、16〜24s 寄り 5 段、24〜32s 一回転、32〜40s 傾け往復、40〜48s 西へ 3km
  void _startDrive() {
    if (!kDebugMode || _drive != null) return;
    _driveOrigin = (_camera.centerX, _camera.centerY, _camera.zoom, _camera.bearing);
    _driveGapFrames = 0;
    _driveFrames = 0;
    _driveUiMs.clear();
    _driveRasterMs.clear();
    _driveTimings = (timings) {
      for (final t in timings) {
        _driveUiMs.add(t.buildDuration.inMilliseconds);
        _driveRasterMs.add(t.rasterDuration.inMilliseconds);
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_driveTimings!);
    var last = DateTime.now();
    _stallProbe = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      final gap = now.difference(last).inMilliseconds;
      if (gap > 400) AppLogger.debug('[3D] stall ${gap}ms (isolate blocked)');
      last = now;
    });
    _drive = Ticker((elapsed) {
      try {
        _driveTick(elapsed);
      } catch (e, st) {
        AppLogger.error('[3D] drive error', e, st);
        _stopDrive();
      }
    })
      ..start();
  }

  void _driveTick(Duration elapsed) {
    final (startX, startY, startZoom, startBearing) = _driveOrigin;
    {
      if (_driveStart == Duration.zero) _driveStart = elapsed;
      final t = (elapsed - _driveStart).inMilliseconds / 1000;
      if (t > 48) {
        _stopDrive();
        return;
      }
      if (t < 8) {
        _camera.centerX = startX + 3000 * (t / 8);
      } else if (t < 16) {
        _camera.zoom = startZoom - 4 * ((t - 8) / 8);
      } else if (t < 24) {
        _camera.zoom = startZoom - 4 + 5 * ((t - 16) / 8);
      } else if (t < 32) {
        _camera.bearing = startBearing + 2 * math.pi * ((t - 24) / 8);
      } else if (t < 40) {
        _camera.pitch = (35 + 35 * math.sin((t - 32) / 8 * 2 * math.pi)) * math.pi / 180;
      } else {
        _camera.centerX = startX + 3000 - 3000 * ((t - 40) / 8);
        _camera.centerY = startY;
      }
      _gesturing = t >= 24 && t < 40;
      _refresh();
      _driveFrames++;
      final plan = _lastPlan;
      if (plan != null && !plan.coverage.full) _driveGapFrames++;
      if (elapsed - _driveLastLog >= const Duration(milliseconds: 500)) {
        _driveLastLog = elapsed;
        String stat(List<int> v) {
          if (v.isEmpty) return '-';
          final s = [...v]..sort();
          return '${s[s.length ~/ 2]}/${s.last}';
        }
        AppLogger.debug('[3D] drive t=${t.toStringAsFixed(1)}s z=${_camera.zoom.toStringAsFixed(2)} '
            'dem=${plan?.demZoom} ${plan?.coverage} tiles=${_world.loadedCount} pending=${_world.pendingCount} '
            'ui=${stat(_driveUiMs)} raster=${stat(_driveRasterMs)} gapFrames=$_driveGapFrames/$_driveFrames');
        _driveUiMs.clear();
        _driveRasterMs.clear();
      }
    }
  }

  void _stopDrive() {
    final d = _drive;
    if (d == null) return;
    d.dispose();
    _drive = null;
    _stallProbe?.cancel();
    _stallProbe = null;
    _driveStart = Duration.zero;
    if (_driveTimings != null) SchedulerBinding.instance.removeTimingsCallback(_driveTimings!);
    _driveTimings = null;
    _gesturing = false;
    AppLogger.debug('[3D] drive end: gapFrames=$_driveGapFrames/$_driveFrames tiles=${_world.loadedCount}');
    if (mounted) _refresh();
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
    ref.listen(partySessionProvider, (_, _) => _refresh());
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _size) {
          _size = size;
          WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
        }
        final loading = _world.pendingCount > 0;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                onTapUp: _onTapUp,
                child: ClipRect(
                  child: ColoredBox(
                    color: const Color(0xFFE6E6E6),
                    child: CustomPaint(painter: _painter, child: const SizedBox.expand()),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 48,
              bottom: 96,
              child: RotatedBox(
                quarterTurns: 3,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                  ),
                  child: Slider(
                    value: _camera.pitch * 180 / math.pi,
                    max: 70,
                    onChanged: (v) {
                      _camera.pitch = v * math.pi / 180;
                      _gesturing = true;
                      _refresh();
                      setState(() {});
                    },
                    onChangeEnd: (_) {
                      _gesturing = false;
                      _refresh();
                    },
                  ),
                ),
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
                  _ZoomButton(icon: Icons.add, tooltip: '拡大', onPressed: () => _zoomBy(1)),
                  const SizedBox(height: 6),
                  _ZoomButton(icon: Icons.remove, tooltip: '縮小', onPressed: () => _zoomBy(-1)),
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
