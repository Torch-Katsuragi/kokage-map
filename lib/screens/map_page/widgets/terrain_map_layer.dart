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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';

import '../../../core/terrain/dem_grid.dart';
import '../../../core/terrain/dem_tiles.dart';
import '../../../core/terrain/terrain_camera.dart';
import '../../../core/terrain/terrain_mesh.dart';
import '../../../core/terrain/terrain_painter.dart';
import '../../../core/terrain/terrain_scene.dart';
import '../../../core/terrain/web_mercator.dart';
import '../../../interfaces/map_state_interface.dart';
import '../../../interfaces/terrain_projection.dart';
import '../../../providers/tool_providers.dart';
import '../../../services/basemap_service.dart';
import '../../../services/map_source_manager.dart';
import '../../../utils/app_logger.dart';
import '../../layer_style_settings_screen.dart';
import '../feature_geojson_cache.dart';

/// 3D 地形モードの地図面
///
/// MapLibre の地図の上に重ね、同じシーン（[FeatureGeoJsonCache] の GeoJSON と
/// [MapStyleGroup]）を純 Dart の地形描画系で描く。設計は `docs/technical/scene-model.md`。
///
/// - 入るとき: MapLibre のカメラ（center / zoom / bearing）を引き継ぎ、45° 傾ける
/// - 出るとき: 自分のカメラを MapLibre に書き戻す（真上に戻る = 真上ロック）
/// - 3D 中の `IMapState.offsetToLatLng` / `latLngToOffset` は [TerrainProjection] としてここを通る。
///   選択ツールはそのまま動く（当たり判定は LatLng 空間の距離計算）
/// - DEM は AWS Terrain Tiles（キー不要）、背景は `BaseMapService.getTile`（キャッシュ込み）
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

class _TerrainMapLayerState extends ConsumerState<TerrainMapLayer> implements TerrainProjection {
  static const _gestureCellBudget = 40000;
  static const _defaultPitchDeg = 45.0;

  late final TerrainCamera _camera;
  DemGrid? _dem;
  ui.Image? _texture;
  int _textureWidth = 1;
  int _textureHeight = 1;
  String _status = '';
  String _attribution = '';
  final Map<int, TerrainMeshBuilder> _builders = {};
  int _coarseStep = 2;
  TerrainMesh? _mesh;
  TerrainPainter? _painter;
  final _repaint = ValueNotifier<int>(0);
  final Map<int, _SceneBundle> _sceneByStep = {};
  Size _size = Size.zero;
  int _generation = 0;
  TileRange? _loadedRange;
  bool _loading = false;

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
    widget.sceneRevision.addListener(_onSceneRevision);
    widget.onProjectionChanged(this);
    _loadTerrain();
  }

  @override
  void dispose() {
    _generation++;
    widget.sceneRevision.removeListener(_onSceneRevision);
    widget.onProjectionChanged(null);
    // 真上に戻して MapLibre へ書き戻す
    final c = _centerLatLng();
    widget.mapState.mapController.moveAndRotate(c, _camera.zoom, _camera.bearing * 180 / math.pi);
    _repaint.dispose();
    _texture?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerrainMapLayer old) {
    super.didUpdateWidget(old);
    if (old.currentLocation != widget.currentLocation) {
      _applyScene();
    }
  }

  LatLng _centerLatLng() =>
      LatLng(WebMercator.latFromY(_camera.centerY), WebMercator.lonFromX(_camera.centerX));

  // ── DEM とテクスチャ ────────────────────────────────

  Future<void> _loadTerrain() async {
    final gen = ++_generation;
    final center = _centerLatLng();
    // 表示ズームより 1 段荒い DEM を 2×2 枚。zoom 16 なら z15（4.8m/px・2.4km 四方・512²）
    final z = (_camera.zoom.round() - 1).clamp(DemTileSource.aws.minZoom + 8, DemTileSource.aws.maxZoom);
    final range = TileRange.around(center.longitude, center.latitude, z, 2);
    _loading = true;
    setState(() => _status = '標高タイル取得中…');
    try {
      final dem = await DemTileLoader(source: DemTileSource.aws).load(
        range,
        onProgress: (d, t) {
          if (mounted && gen == _generation) setState(() => _status = '標高タイル $d/$t');
        },
      );
      if (!mounted || gen != _generation) return;
      _loadedRange = range;
      var minH = double.infinity;
      var maxH = -double.infinity;
      for (final h in dem.heights) {
        if (h < minH) minH = h;
        if (h > maxH) maxH = h;
      }
      AppLogger.debug('[3D] DEM z$z ${range.x0}-${range.x1}/${range.y0}-${range.y1} '
          '標高 ${minH.toStringAsFixed(0)}〜${maxH.toStringAsFixed(0)}m 中心 ${center.latitude},${center.longitude}');
      _dem = dem;
      _camera.zScale = WebMercator.zScaleAt(center.latitude);
      final cells = (dem.cols - 1) * (dem.rows - 1);
      _coarseStep = math.max(2, math.sqrt(cells / _gestureCellBudget).ceil());
      _builders.clear();
      _sceneByStep.clear();

      // 背景地図: アクティブなプロバイダを opacity で重ねる（MapLibre と同じ式）
      final layers = widget.baseMapService.activeLayerConfig;
      if (layers.isEmpty) throw StateError('背景地図が選ばれていません');
      final texZoom = z + 2;
      final texRange = range.zoomIn(2);
      final composer = RasterTileComposer(fetcher: (tz, tx, ty) => widget.baseMapService.getTile(layers.first.$1, tz, tx, ty));
      _attribution = layers.map((l) => l.$1.attribution).join(' / ');
      _attribution = '$_attribution / ${DemTileSource.aws.attribution}';
      final tex = await composer.composeLayers(
        texRange,
        [
          for (final (p, opacity) in layers)
            // maxZoom を超えるぶんは getTile が祖先タイルから切り出す
            ((tz, tx, ty) => widget.baseMapService.getTile(p, tz, tx, ty), opacity),
        ],
        onProgress: (d, t) {
          if (mounted && gen == _generation) setState(() => _status = '地図タイル $d/$t');
        },
      );
      if (!mounted || gen != _generation) {
        tex.dispose();
        return;
      }
      _texture?.dispose();
      _texture = tex;
      _textureWidth = tex.width;
      _textureHeight = tex.height;
      _builders.clear();
      AppLogger.debug('[3D] DEM z$z ${dem.cols}x${dem.rows} texture z$texZoom ${tex.width}x${tex.height}');
      setState(() => _status = '');
      _rebuildMesh();
    } catch (e) {
      AppLogger.debug('[3D] 地形の取得に失敗: $e');
      if (mounted) setState(() => _status = '地形を取得できませんでした: $e');
    } finally {
      _loading = false;
    }
  }

  /// カメラ中心が読み込み済み DEM の内側 60% から外れたら、その周りを読み直す
  ///
  /// 古い DEM は新しいものが届くまで描き続ける（LOD と同じで「見えたまま」を優先）。
  void _reloadTerrainIfNeeded() {
    final r = _loadedRange;
    if (r == null || _loading) return;
    final w = r.widthMeters;
    final h = r.heightMeters;
    final cx = r.west + w / 2;
    final cy = r.south + h / 2;
    final outside = (_camera.centerX - cx).abs() > w * 0.3 || (_camera.centerY - cy).abs() > h * 0.3;
    // ズームが 2 段以上変わったら解像度も合わせ直す
    final zoomDrift = (_camera.zoom.round() - 1 - r.z).abs() >= 2;
    if (outside || zoomDrift) _loadTerrain();
  }

  TerrainMeshBuilder _builderFor(int step) => _builders[step] ??= TerrainMeshBuilder(
        _dem!,
        textureWidth: _textureWidth,
        textureHeight: _textureHeight,
        step: step,
      );

  // ── シーン ──────────────────────────────────────────

  void _onSceneRevision() {
    _sceneByStep.clear();
    _applyScene();
  }

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

  _SceneBundle _buildScene(TerrainMesh mesh) {
    final defaultStyle = _defaultStyle();
    final groups = {for (final g in widget.styleGroups()) g.key: _styleFromGroup(g)};
    final labelStyle = TextStyle(
      fontSize: layerStyleSettings.getDouble(labelFontSizeDef),
      color: layerStyleSettings.getColor(labelColorDef),
    );
    final normal = TerrainSceneBuilder(
      mesh: mesh,
      stylesByKey: groups,
      defaultStyle: defaultStyle,
      styleKeyProp: MapSourceManager.kStyleProp,
      labelProp: FeatureGeoJsonInput.labelPropKey,
      labelTextStyle: labelStyle,
    ).build(
      lines: widget.geoJson.polylines,
      polygons: widget.geoJson.polygons,
      points: widget.geoJson.markers,
    );
    final selStyle = _selectedStyle(defaultStyle);
    final selected = TerrainSceneBuilder(
      mesh: mesh,
      stylesByKey: {for (final e in groups.entries) e.key: _selectedStyle(e.value)},
      defaultStyle: selStyle,
      styleKeyProp: MapSourceManager.kStyleProp,
      labelProp: '__no_label__',
    ).build(
      lines: widget.geoJson.selectedPolylines,
      polygons: widget.geoJson.selectedPolygons,
      points: widget.geoJson.selectedMarkers,
    );
    // 写真: 琥珀色の点 + 名前
    final photos = TerrainSceneBuilder(
      mesh: mesh,
      stylesByKey: const {},
      defaultStyle: const TerrainFeatureStyle(
        lineColor: Colors.amber,
        lineWidth: 1,
        fillColor: Colors.amber,
        outlineColor: Colors.amber,
        outlineWidth: 1,
        pointColor: Colors.amber,
        pointSize: 7,
      ),
      labelProp: 'name',
      labelTextStyle: labelStyle,
    ).build(points: widget.geoJson.images);
    // GPS 軌跡: MapLibre 側の k-gps-track-line と同じ見た目（青緑・細め）
    final track = widget.gpsTrack();
    final trackScene = track.length < 2
        ? TerrainScene.empty
        : TerrainSceneBuilder(
            mesh: mesh,
            stylesByKey: const {},
            defaultStyle: const TerrainFeatureStyle(
              lineColor: Color(0xCC00897B),
              lineWidth: 3,
              fillColor: Color(0x00000000),
              outlineColor: Color(0x00000000),
              outlineWidth: 0,
              pointColor: Color(0xFF00897B),
              pointSize: 4,
            ),
          ).build(
            lines: [
              geo.Feature<geo.Geometry>(
                geometry: geo.LineString.from([
                  for (final p in track) geo.Geographic(lon: p.longitude, lat: p.latitude),
                ]),
              ),
            ],
          );
    return _SceneBundle(normal: normal, selected: selected, photos: photos, track: trackScene);
  }

  void _applyScene() {
    final mesh = _mesh;
    final painter = _painter;
    if (mesh == null || painter == null || _dem == null) return;
    final bundle = _sceneByStep[mesh.step] ??= _buildScene(mesh);
    final dem = _dem!;
    final loc = widget.currentLocation;
    painter
      ..mesh = mesh
      ..lines = [
        ...bundle.track.lines,
        ...bundle.normal.outlines,
        ...bundle.normal.lines,
        ...bundle.selected.outlines,
        ...bundle.selected.lines,
      ]
      ..polygons = [...bundle.normal.polygons, ...bundle.selected.polygons]
      ..points = [
        ...bundle.normal.points,
        ...bundle.photos.points,
        ...bundle.selected.points,
        if (loc != null)
          TerrainPoint(
            x: WebMercator.xFromLon(loc.longitude) - dem.originX,
            y: WebMercator.yFromLat(loc.latitude) - dem.originY,
            color: Colors.blue,
            sizePx: 9,
          ),
      ]
      ..labels = [...bundle.normal.labels, ...bundle.photos.labels];
    _repaint.value++;
  }

  void _rebuildMesh({bool coarse = false}) {
    if (_dem == null) return;
    final step = coarse ? _coarseStep : 1;
    final mesh = _builderFor(step).build(_camera);
    _mesh = mesh;
    _painter ??= TerrainPainter(
      mesh: mesh,
      camera: _camera,
      texture: _texture,
      lines: const [],
      labels: const [],
      repaint: _repaint,
    );
    _painter!
      ..mesh = mesh
      ..texture = _texture;
    _applyScene();
    _notifyCamera();
  }

  void _notifyCamera() {
    widget.mapBearingNotifier.value = _camera.bearing * 180 / math.pi;
    widget.cameraTickNotifier.value++;
  }

  // ── TerrainProjection ───────────────────────────────

  @override
  LatLng? unproject(Offset screen) {
    final painter = _painter;
    final dem = _dem;
    if (painter == null || dem == null || _size == Size.zero) return null;
    final p = painter.unproject(screen, _size);
    if (p == null) return null;
    return LatLng(WebMercator.latFromY(p.dy + dem.originY), WebMercator.lonFromX(p.dx + dem.originX));
  }

  @override
  Offset project(LatLng latLng) {
    final painter = _painter;
    final dem = _dem;
    if (painter == null || dem == null) return Offset(_size.width / 2, _size.height / 2);
    final x = WebMercator.xFromLon(latLng.longitude) - dem.originX;
    final y = WebMercator.yFromLat(latLng.latitude) - dem.originY;
    final z = dem.elevationAt(x + dem.originX, y + dem.originY);
    final pc = _camera.project(
      _camera.centerX - dem.originX,
      _camera.centerY - dem.originY,
      dem.elevationAt(_camera.centerX, _camera.centerY),
    );
    return painter.toScreen(x, y, z, _size, pc);
  }

  // ── ジェスチャ ──────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _scaleStart = _camera.scale;
    _bearingStart = _camera.bearing;
    _pitchStart = _camera.pitch;
    _focalStart = d.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      _camera.scale = (_scaleStart * d.scale).clamp(
        TerrainCamera.scaleForZoom(8),
        TerrainCamera.scaleForZoom(22),
      );
      _camera.bearing = _bearingStart - d.rotation;
      final dy = d.focalPoint.dy - _focalStart.dy;
      _camera.pitch = (_pitchStart - dy * 0.004).clamp(0.0, 70 * math.pi / 180);
      _rebuildMesh(coarse: true);
    } else {
      final move = _camera.unprojectPan(d.focalPointDelta);
      _camera.centerX -= move.dx;
      _camera.centerY -= move.dy;
      _repaint.value++;
      _notifyCamera();
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _rebuildMesh();
    _reloadTerrainIfNeeded();
  }

  void _onTapUp(TapUpDetails d) {
    // 選択などは既存のツールに任せる（投影は TerrainProjection 経由でここを通る）
    ref.read(currentToolProvider).onTap(d, widget.mapState);
  }

  // ── UI ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ready = _dem != null && _painter != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Stack(
          children: [
            if (ready)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onScaleEnd: _onScaleEnd,
                  onTapUp: _onTapUp,
                  child: ClipRect(
                    // 下の MapLibre を隠す地色の上に地形を描く（painter は child の下に描かれるので入れ子にしない）
                    child: ColoredBox(
                      color: const Color(0xFFE6E6E6),
                      child: CustomPaint(painter: _painter, child: const SizedBox.expand()),
                    ),
                  ),
                ),
              ),
            if (ready)
              Positioned(
                left: 6,
                bottom: 4,
                child: Text(
                  _attribution,
                  style: const TextStyle(fontSize: 10, color: Colors.black87, backgroundColor: Colors.white70),
                ),
              ),
            if (_status.isNotEmpty)
              Positioned(
                left: 8,
                top: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(_status, style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SceneBundle {
  const _SceneBundle({
    required this.normal,
    required this.selected,
    required this.photos,
    required this.track,
  });

  final TerrainScene normal;
  final TerrainScene selected;
  final TerrainScene photos;
  final TerrainScene track;
}
