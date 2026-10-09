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
part of 'terrain_map_layer.dart';

/// タイルのシーンのキャッシュのキー: (タイル, step, 縁の組み合わせ, 高さの出どころの段)。近似 → 本物の差し替えで作り直す
typedef _SceneKey = (TileKey, int, int, int);

/// スタイル表と既定のスタイルとラベルの属性から、タイルのメッシュに貼る [TerrainSceneBuilder] を作る
typedef _SceneBuilderFor = TerrainSceneBuilder Function(
    Map<String, TerrainFeatureStyle> styles, TerrainFeatureStyle defaultStyle, String labelProp);

/// タイルのシーン（メッシュに貼り付けたフィーチャ）の組み立て。
///
/// 静的な部分（フィーチャ・頂点・写真・選択）は時間を分けて育て、動的な部分（軌跡・パーティ・現在位置・描きかけ）は
/// 鍵が変わるたびに作り直す。スタイルの組み立てとフィーチャの bbox 索引もここ（焼き込みと共用）
mixin _TerrainScenes on ConsumerState<TerrainMapLayer> {
  TerrainWorld get _world;
  bool get _gesturing;
  int get _bakeGen;
  int? get _bakedContentRevision;
  bool _touchedSince(TileKey k, int since);
  void _scheduleRefresh();

  final Map<_SceneKey, _TileScene> _scenes = {};
  final Map<_SceneKey, _TileScene> _staticScenes = {};
  final Map<_SceneKey, _TileScene> _dynamicScenes = {};
  final Map<_SceneKey, _StaticProgress> _staticProgress = {};
  int _sceneBuilds = 0;

  /// 1 フレームに育てる静的な貼り付けの枚数と上限（ジェスチャ中は控えめに、静止中は速く）
  int _staticBuilds = 0;
  int get _staticBudget => _gesturing ? 2 : 3;

  /// 1 フレームの貼り付けに使う時間（タイル合計）
  Duration get _sliceBudget => _gesturing ? const Duration(milliseconds: 4) : const Duration(milliseconds: 12);
  final Stopwatch _staticSw = Stopwatch();

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

  /// フレームの頭: 今フレームの貼り付けの枚数と時間を数え直す
  void _startSceneFrame() {
    _sceneBuilds = 0;
    _staticBuilds = 0;
    _staticSw
      ..reset()
      ..start();
  }

  /// 消えたタイルのぶんだけ捨てる（縁が変わったタイルはキーが変わるので自然に入れ替わる）
  void _pruneScenes() {
    _scenes.removeWhere((k, _) => !_world.has(k.$1));
    _staticScenes.removeWhere((k, _) => !_world.has(k.$1));
    _staticProgress.removeWhere((k, _) => !_world.has(k.$1));
    _dynamicScenes.removeWhere((k, _) => !_world.has(k.$1));
  }

  /// 地形の見た目（色分け）の設定が変わった。合成を捨てる
  void _onAppearanceChanged() {
    _scenes.clear();
    _scheduleRefresh();
  }

  bool _hasStaticScene(TerrainTile tile, int step) =>
      _staticScenes.containsKey((tile.key, step, tile.borderMask, tile.sourceZoom));

  // ── スタイル ─────────────────────────────────────

  TerrainFeatureStyle _styleFromGroup(MapStyleGroup g) => TerrainFeatureStyle(
        lineColor: TerrainFeatureStyle.fromHex(g.lineHex),
        lineWidth: g.lineWidth,
        fillColor: TerrainFeatureStyle.fromHex(g.fillHex, g.fillOpacity),
        outlineColor: TerrainFeatureStyle.fromHex(g.outlineHex, g.outlineOpacity),
        outlineWidth: g.borderWidth,
        pointColor: TerrainFeatureStyle.fromHex(g.pointHex),
        pointSize: g.pointSize,
      );

  /// View 固有スタイルをキーで引ける形に
  Map<String, TerrainFeatureStyle> _styleGroupsByKey() =>
      {for (final sg in widget.styleGroups()) sg.key: _styleFromGroup(sg)};

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

  /// 選択の枠線・線・点のスタイル（選んだ面の塗りはテクスチャに描くので、ここは塗らない）
  TerrainFeatureStyle _selectedStyle(TerrainFeatureStyle base) {
    final s = layerStyleSettings;
    final color = s.getColor(selectedColorDef);
    final k = s.getDouble(selectedMultiplierDef);
    return TerrainFeatureStyle(
      lineColor: color,
      lineWidth: base.lineWidth * k,
      fillColor: Colors.transparent,
      outlineColor: color,
      outlineWidth: base.outlineWidth * k,
      pointColor: color,
      pointSize: base.pointSize * k,
    );
  }

  // ── シーン（タイル単位の貼り付け） ─────────────────

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
    final loc = widget.location.value;
    final cacheKey = (tile.key, step, tile.borderMask, tile.sourceZoom);
    final staticKey = <Object?>[
      g.polylines, g.polygons, g.markers, g.selectedPolylines, g.selectedPolygons, g.selectedMarkers, g.images, g.selectedImages,
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
          styleKeyProp: kStyleProp,
          labelProp: labelProp,
          labelTextStyle: labelStyle,
          polygonClipCells: clipCells,
        );

    // 静的な部分。1 回あたり数 ms ずつ育てる（1 タイル 1 万面を一度に持ち上げると 0.5〜1 秒止まる）
    var stat = _staticScenes[cacheKey];
    // 線・面・点の一覧が組み直されても、変わった範囲（`_bakeEvents`）がこのタイルに掛からなければ作り直さない。
    // GPS 軌跡の統合で 20 秒ごとに一覧が変わり、そのたびに見えている全タイルの 1.5 万面を持ち上げ直していた（2026-10-06）。
    // 選択・頂点・写真が変わったときと、今の一覧の変化がまだ記録されていないときは作り直す
    if (stat != null &&
        stat.complete &&
        !_sameKey(stat.key, staticKey) &&
        stat.key.length == staticKey.length &&
        _sameKey(stat.key.sublist(3), staticKey.sublist(3)) &&
        g.contentRevision == _bakedContentRevision &&
        !_touchedSince(tile.key, stat.gen)) {
      stat
        ..key = staticKey
        ..gen = _bakeGen;
    }
    if (stat == null || !_sameKey(stat.key, staticKey)) {
      if (_staticBuilds >= _staticBudget) {
        // 今フレームは見送り。手持ちがあれば古いものを使い、無ければ空
        _scheduleRefresh();
        stat ??= _TileScene(key: const [], lines: const [], polygons: const [], points: const [], labels: const []);
      } else {
        stat = _TileScene(key: staticKey, gen: _bakeGen, lines: [], polygons: [], points: [], labels: [], complete: false);
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
      dynamicPoints: stat.photoPoints.isEmpty ? dyn.points : [...stat.photoPoints, ...dyn.points],
      points: stat.points,
      // 動的なラベルが無ければ静的のリストをそのまま（同一性を保つ → 描画側のラベル投影キャッシュが効く）
      labels: dyn.labels.isEmpty ? stat.labels : [...stat.labels, ...dyn.labels],
      complete: stat.complete,
    );
    // 静的シーンが育ち切るまでは合成も作り直す（点・ラベルは合成時に写すため）
    if (stat.complete) _scenes[cacheKey] = scene;
    return scene;
  }

  /// 引いた段で点をまとめた印の数のラベル
  static const _clusterLabelStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3F51B5));

  /// フィーチャ本体・頂点・写真・選択を [scene] に足す。1 回に [_sliceBudget] まで（残りは次の呼び出し）
  void _advanceStatic(
    TerrainTile tile,
    int step,
    _TileScene scene,
    _StaticProgress progress,
    FeatureGeoJsonCache g,
    _SceneBuilderFor builder,
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
    final groups = _styleGroupsByKey();
    // 粗く間引いたタイル（セルが 30m 以上）で面が多いときはラベルを省く（判定はデータ全体の面数。タイルごとに変えると継ぎ接ぎになる）。
    // ⚠ 輪郭は省かないこと。以前はここで輪郭も省いていたが、焼き込む段（z13 以下）は面をそもそも持ち上げないので、
    // 省かれるのは焼き込まない z14 以上のタイルを中間の段（14.6 など）で間引いたときだけだった。塗りの無い面
    // （森林簿の小班 1.5 万面）がその段でだけ丸ごと消えていた（2026-10-06、Fold）
    final coarse = tile.bordered.cellSize * step >= 30;
    final dense = coarse && g.polygons.length > 2000;
    void add(TerrainScene s, {bool withLabels = true}) {
      // 選択の線より手前（下）に入れる
      final at = scene.lines.length - progress.selectedLines;
      scene.lines.insertAll(at, [...s.outlines, ...s.lines]);
      scene.polygons.addAll(s.polygons);
      scene.points.addAll(s.points);
      if (withLabels) scene.labels.addAll(s.labels);
    }

    if (progress.phase == 0) {
      // 選択（先に見せたい）・頂点・写真は少ないので一度に
      add(
        // 選んだ面の塗りはテクスチャに描くので、ここは枠線だけ（平らな板の塗りは尾根で地形に埋もれていた）
        builder({for (final e in groups.entries) e.key: _selectedStyle(e.value)}, _selectedStyle(defaultStyle),
                '__no_label__')
            .build(lines: g.selectedPolylines, polygons: g.selectedPolygons, points: g.selectedMarkers, clipRect: clip),
        withLabels: false,
      );
      progress.selectedLines = scene.lines.length;
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
      // 写真はレイヤ一覧と同じカメラの印で（ただの黄色い丸では地物の点と見分けにくかった。ユーザー 2026-10-02）。
      // 選んだ写真は選択の色。記号を描くので GPU の点ではなく画面に描く点（[photoPoints]）にする
      final selImages = Set<geo.Feature>.identity()..addAll(g.selectedImages);
      final selColor = layerStyleSettings.getColor(selectedColorDef);
      for (final (images, color) in [
        ([for (final f in g.images) if (!selImages.contains(f)) f], const Color(0xFFF9A825)),
        (g.selectedImages, selColor),
      ]) {
        if (images.isEmpty) continue;
        final s = builder(const {}, TerrainFeatureStyle(
          lineColor: color, lineWidth: 1, fillColor: color, outlineColor: color,
          outlineWidth: 1, pointColor: color, pointSize: 13,
        ), 'name').build(points: images, clipRect: clip);
        for (final p in s.points) {
          scene.photoPoints.add(TerrainPoint(x: p.x, y: p.y, color: color, sizePx: 13, icon: Icons.photo_camera));
        }
        scene.labels.addAll(s.labels);
      }
      // 点フィーチャ。焼き込む段はテクスチャに描いてあるので持ち上げない。
      // それ以外の引いた段では格子（画面 60px 相当）でまとめて数を出す（1 万点を 1 点ずつ描かない）
      final baked = _TerrainBakes._bakesFeatures(tile.key);
      final pointScene = baked
          ? TerrainScene.empty
          : builder(groups, defaultStyle, FeatureGeoJsonInput.labelPropKey).build(points: g.markers, clipRect: clip);
      if (baked) {
        // テクスチャ側で描いてある
      } else if (coarse && pointScene.points.length > 50) {
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
          scene.labels.add(TerrainLabel(x: cx, y: cy, text: '${ps.length}', style: _clusterLabelStyle, markerGap: 14));
        }
      } else {
        add(pointScene); // 引いた段でも点が少なければラベルは出す（多ければ上でまとめている）
      }
      final worldClip = clip.shift(Offset(tile.bordered.originX, tile.bordered.originY));
      progress.polygonIdx = baked ? const [] : _featureIndexes(g.polygons, worldClip);
      progress.lineIdx = baked ? const [] : _featureIndexes(g.polylines, worldClip);
      progress.phase = 1;
      if (over()) return;
    }
    // 面（引いた段ではラベル無し）。塗りはテクスチャに描いてある（[_decorateTexture]）。ここは枠線とラベル
    final polygonIdx = progress.polygonIdx!;
    final outlines = progress.phase == 1
        ? builder({for (final e in groups.entries) e.key: e.value.withoutFill()}, defaultStyle.withoutFill(),
            FeatureGeoJsonInput.labelPropKey)
        : null;
    while (progress.phase == 1) {
      if (progress.polygon >= polygonIdx.length) {
        progress.phase = 2;
        break;
      }
      final end = math.min(progress.polygon + progress.chunk, polygonIdx.length);
      final t0 = sw.elapsedMicroseconds;
      add(
        outlines!.build(polygons: [for (var i = progress.polygon; i < end; i++) g.polygons[polygonIdx[i]]], clipRect: clip),
        withLabels: !dense,
      );
      progress.tune(end - progress.polygon, sw.elapsedMicroseconds - t0);
      progress.polygon = end;
      if (over()) return;
    }
    // 線
    final lineIdx = progress.lineIdx!;
    final lines = progress.phase == 2 ? builder(groups, defaultStyle, FeatureGeoJsonInput.labelPropKey) : null;
    while (progress.phase == 2) {
      if (progress.line >= lineIdx.length) {
        progress.phase = 3;
        break;
      }
      final end = math.min(progress.line + progress.chunk, lineIdx.length);
      final t0 = sw.elapsedMicroseconds;
      add(lines!.build(lines: [for (var i = progress.line; i < end; i++) g.polylines[lineIdx[i]]], clipRect: clip));
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

  /// 描きかけの線・面の範囲（Mercator m）。点の数と最後の点が同じなら前の結果を使う
  (int, int, LatLng?, Rect?)? _strokeCache;
  Rect? _strokeBounds(GlobalDrawingState d) {
    final line = d.drawingLine;
    final poly = d.drawingPolygon;
    final last = line.isNotEmpty ? line.last : (poly.isNotEmpty ? poly.last : null);
    final c = _strokeCache;
    if (c != null && c.$1 == line.length && c.$2 == poly.length && c.$3 == last) return c.$4;
    Rect? r;
    for (final p in [...line, ...poly]) {
      final q = Offset(WebMercator.xFromLon(p.longitude), WebMercator.yFromLat(p.latitude));
      r = r == null ? Rect.fromPoints(q, q) : r.expandToInclude(Rect.fromPoints(q, q));
    }
    r = r?.inflate(5);
    _strokeCache = (line.length, poly.length, last, r);
    return r;
  }

  /// [pts] を結ぶ線のフィーチャ（[closed] なら始点に戻る）
  static geo.Feature<geo.Geometry> _lineFeature(List<LatLng> pts, {bool closed = false}) => geo.Feature<geo.Geometry>(
        geometry: geo.LineString.from([
          for (final p in pts) geo.Geographic(lon: p.longitude, lat: p.latitude),
          if (closed) geo.Geographic(lon: pts.first.longitude, lat: pts.first.latitude),
        ]),
      );

  /// 今日の GPS 軌跡・パーティ・現在位置（GPS の更新ごとに作り直す。軽い）
  _TileScene _buildDynamic(
    List<Object?> key,
    List<LatLng> track,
    PartySessionState session,
    LatLng? loc,
    DemGrid dem,
    _SceneBuilderFor builder,
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
    // [p] のタイル内の座標（タイルの外なら null）
    Offset? at(LatLng p) {
      final o = Offset(WebMercator.xFromLon(p.longitude) - dem.originX, WebMercator.yFromLat(p.latitude) - dem.originY);
      return clip.contains(o) ? o : null;
    }

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
            _lineFeature(track),
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
                  _lineFeature(t.points),
        ],
        clipRect: clip,
      ),
    );
    // 3. 現在位置（青）と端末の向き（画面上の 60° の扇。2D と同じ。描くのは painter の `_paintHeadingFan`）
    if (loc != null) {
      if (at(loc) case final o?) {
        // 半透明: 不透明だと真下の点や短い線を隠す（2026-09-01 実機で確認）
        points.add(TerrainPoint(x: o.dx, y: o.dy, color: Colors.blue.withValues(alpha: 0.55), sizePx: 9, headingDeg: headingDeg));
      }
    }
    // 4. 描画中の線・面・点（ペン）。2D の描画プレビューと同じ赤
    final drawing = GlobalDrawingState.instance;
    const drawStyle = TerrainFeatureStyle(
      lineColor: Colors.red, lineWidth: 3, fillColor: Color(0x33FF0000),
      outlineColor: Colors.red, outlineWidth: 2, pointColor: Colors.red, pointSize: 8,
    );
    // 描きかけの線の範囲に掛からないタイルでは組まない（指を動かすたびに全タイルで線全体を持ち上げ直していた）
    final strokeBox = _strokeBounds(drawing);
    final strokeHere = strokeBox != null && strokeBox.overlaps(clip.shift(Offset(dem.originX, dem.originY)));
    if (strokeHere && (drawing.drawingLine.length >= 2 || drawing.drawingPolygon.length >= 2)) {
      add(
        builder(const {}, drawStyle, '__no_label__').build(
          lines: [
            if (drawing.drawingLine.length >= 2)
              _lineFeature(drawing.drawingLine),
            if (drawing.drawingPolygon.length >= 2)
              _lineFeature(drawing.drawingPolygon, closed: true),
          ],
          clipRect: clip,
        ),
      );
    }
    final survey = tool is GpsTool;
    if (survey && strokeHere) {
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
    } else if (!survey) {
      for (final p in [
        if (strokeHere) ...drawing.drawingLine,
        if (strokeHere) ...drawing.drawingPolygon,
        if (drawing.pointPreview != null) drawing.pointPreview!,
      ]) {
        if (at(p) case final o?) points.add(TerrainPoint(x: o.dx, y: o.dy, color: Colors.red, sizePx: 6));
      }
      // 1 点目の目印（白い輪）: 線・面を描き始めた直後
      final first = drawing.drawingLine.length == 1
          ? drawing.drawingLine.first
          : drawing.drawingPolygon.length == 1
              ? drawing.drawingPolygon.first
              : null;
      if (first != null) {
        if (at(first) case final o?) {
          points
            ..add(TerrainPoint(x: o.dx, y: o.dy, color: Colors.white, sizePx: 14))
            ..add(TerrainPoint(x: o.dx, y: o.dy, color: Colors.red, sizePx: 8));
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
              _lineFeature(n.cornerCoordinates, closed: true),
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
        if (at(handle) case final o?) points.add(TerrainPoint(x: o.dx, y: o.dy, color: Colors.blue, sizePx: 10));
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
        if (at(deviceStation) case final o?) points.add(TerrainPoint(x: o.dx, y: o.dy, color: Colors.orange, sizePx: 12));
      }
    }
    return _TileScene(key: key, lines: lines, polygons: polygons, points: points, labels: labels);
  }
}

/// タイル 1 枚ぶんの貼り付け済みフィーチャ（step ごと）
class _TileScene {
  _TileScene({
    required this.key,
    this.gen = 0,
    required this.lines,
    required this.polygons,
    required this.points,
    required this.labels,
    this.dynamicLines = const [],
    this.dynamicPolygons = const [],
    this.dynamicPoints = const [],
    this.staticSource,
    this.complete = true,
    List<TerrainPoint>? photoPoints,
  }) : photoPoints = photoPoints ?? [];

  /// 写真の印（カメラの記号を描くので、静的な点と分けて画面に描く）
  final List<TerrainPoint> photoPoints;

  /// 何から作ったか（GeoJSON リストの同一性・選択・軌跡の点数・パーティ・現在位置など）。静的シーンは、範囲外の変化だけなら作り直さずに鍵を差し替えて使い続ける
  List<Object?> key;

  /// 作ったときの焼き込みの世代（`_bakeGen`）。この後の変化の範囲がタイルに掛からなければ使い続けてよい
  int gen;

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

  /// 線の並びの末尾にある選択の線の数。選択は先に作るが、あとから足す地物の線はこの手前に差し込む
  /// （後ろに足すと地物の線が選択の上に描かれていた）
  int selectedLines = 0;

  /// このタイルに掛かるフィーチャの番号（bbox で先に絞る。1 万面を 40 枚のタイルで毎回総当たりしない）
  List<int>? polygonIdx;
  List<int>? lineIdx;

  /// 1 回の持ち上げに渡すフィーチャ数。直前の実測から 2ms ぶんに合わせる（寄った段の面は 1 つが重い）
  int chunk = 64;

  void tune(int n, int micros) {
    chunk = (n * 2000 / math.max(micros, 50)).round().clamp(8, 1000);
  }
}
