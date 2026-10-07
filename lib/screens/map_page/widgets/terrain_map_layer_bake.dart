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

/// 地形のテクスチャに描くもの（フィーチャの焼き込み・オーバーレイ画像・選んだ面の塗り）と、その焼き直しの管理。
///
/// フィーチャが変わるたびに焼き込みの世代を進め、変わった範囲に掛かる古い世代のタイルだけ焼き直す（[_checkBakes]）
mixin _TerrainBakes on ConsumerState<TerrainMapLayer> {
  TerrainWorld get _world;
  void _scheduleRefresh();
  Float64List _bboxes(List<geo.Feature<geo.Geometry>> fs);
  List<int> _featureIndexes(List<geo.Feature<geo.Geometry>> fs, Rect clip);
  TerrainFeatureStyle _defaultStyle();
  Map<String, TerrainFeatureStyle> _styleGroupsByKey();

  /// 引いた段の焼き込み: この段以下のタイルは、フィーチャ（面・線・点）を形として持ち上げず、
  /// テクスチャに描き込む（真上からの投影。松本 2026-09-12「重いときはクラスタ省略でなく投影で」）。
  /// 引いた段なので傾けても粗さは目立たず、描画は基図と同じ 1 枚のテクスチャで済む。
  /// 選択・頂点・写真は形のまま（少ないし、光らせたい）。ヒットテストはデータから引くので影響しない
  static const kBakeMaxZoom = 13;
  static bool _bakesFeatures(TileKey key) => key.z <= kBakeMaxZoom;

  /// 最後にテクスチャへ焼き込んだフィーチャの中身の世代（`FeatureGeoJsonCache.contentRevision`）。
  /// ⚠ リストの同一性で比べると、GPS 軌跡の統合などで中身が同じまま全件が組み直されるたびに全部焼き直していた
  int? _bakedContentRevision;

  /// 最後に焼いたときのスタイルの中身（[_onSceneRevision]）
  String? _bakedStyleSignature;
  String _styleSignature() {
    final d = _defaultStyle();
    return [
      '${d.fillColor.toARGB32()} ${d.outlineColor.toARGB32()} ${d.lineColor.toARGB32()} ${d.pointColor.toARGB32()} '
          '${d.outlineWidth} ${d.lineWidth} ${d.pointSize}',
      for (final g in widget.styleGroups())
        '${g.key} ${g.fillHex} ${g.fillOpacity} ${g.outlineHex} ${g.outlineOpacity} ${g.borderWidth} '
            '${g.lineHex} ${g.lineWidth} ${g.pointHex} ${g.pointSize}',
    ].join('|');
  }

  /// 焼き込みの世代。フィーチャの一覧が変わるたびに進む。タイルごとに「どの世代で焼いたか」を [_bakedGen] に記録し、
  /// 世代が古いタイルは焼き直す（[_checkBakes]）。
  /// ⚠ 以前は「一覧が変わった瞬間に読み込み済みのタイル」だけ焼き直していたので、その瞬間に読み込み中だった親タイルは
  ///   フィーチャ無しのテクスチャのまま残り、寄せる最中に親と子が入れ替わるたびにフィーチャが出たり消えたりした
  ///   （松本 2026-09-13「地形読み込み中だけフィーチャが表示されたりされなかったり」。web で目立つ）
  int _bakeGen = 0;
  final Map<TileKey, int> _bakedGen = {};

  /// 描いたがまだ貼っていないテクスチャの世代。作り直しが打ち切られると絵は捨てられるので、ここに描いただけでは
  /// 焼いたことにしない（スタイルを戻してすぐ消灯すると、古い色のタイルが焼いた扱いで残っていた。2026-10-02）
  final Map<TileKey, int> _composedGen = {};

  void _onTextureApplied(TileKey key) {
    final g = _composedGen.remove(key);
    if (g != null) _bakedGen[key] = g;
  }

  /// 焼き直しを頼んだ世代（頼んだまま貼られていないタイルを二重に頼まない）
  final Map<TileKey, int> _bakeRequested = {};
  Timer? _bakeCheckTimer;

  /// フィーチャが変わった出来事（世代, 範囲 Mercator。null は全部）。この範囲に掛かる、古い世代のタイルだけ焼き直す
  /// （記録中の GPS 軌跡は 30 秒ごとに伸びるので、全部焼き直すと 46 枚 × 40〜90ms が毎回来る）
  final List<(int, ui.Rect?)> _bakeEvents = [];
  static const _bakeEventsKept = 64;

  // オーバーレイ画像（GeoTIFF など）: 地形のテクスチャに焼く
  final Map<String, ui.Image> _overlayImages = {};
  final Set<String> _overlayLoading = {};
  String _overlayKey = '';

  /// 次の作り直しで触る範囲（Mercator）。前回と今回のオーバーレイの四隅を含む。null なら全部
  Rect? _overlayBounds;
  Timer? _retextureTimer;
  Rect? _lastOverlayBounds;

  /// 選んだ面の塗り（テクスチャに描く）: いま描いてある選択と、その範囲（Mercator）
  List<geo.Feature<geo.Geometry>> _selFillDrawn = const [];
  Rect? _selFillBounds;

  /// シーン（GeoJSON・スタイル）が変わった: 中身かスタイルが変わっていれば焼き込みの世代を進める
  void _onSceneRevision() {
    final g = widget.geoJson;
    final rev = g.contentRevision;
    // 色や濃さだけ変えたときは地物の署名（形とスタイルの鍵）が変わらないので、スタイルの中身でも見る。
    // 塗りはどの段もテクスチャに描くので、変われば全部焼き直す
    final styleSig = _styleSignature();
    if (_bakedStyleSignature != null && _bakedStyleSignature != styleSig) _addBakeEvent(null);
    _bakedStyleSignature = styleSig;
    if (_bakedContentRevision != rev) {
      _bakedContentRevision = rev;
      final ll = g.lastChangeLonLat;
      _addBakeEvent(ll == null
          ? null
          : ui.Rect.fromLTRB(
              WebMercator.xFromLon(ll.left),
              WebMercator.yFromLat(ll.top),
              WebMercator.xFromLon(ll.right),
              WebMercator.yFromLat(ll.bottom),
            ).inflate(50));
    }
    _scheduleBakeCheck();
    _scheduleRefresh();
  }

  /// 世代を進め、変わった範囲 [where]（Mercator。null は全部）を記録する（古いものから [_bakeEventsKept] 件まで）
  void _addBakeEvent(ui.Rect? where) {
    _bakeGen++;
    _bakeEvents.add((_bakeGen, where));
    if (_bakeEvents.length > _bakeEventsKept) _bakeEvents.removeRange(0, _bakeEvents.length - _bakeEventsKept);
  }

  /// [since] の世代より後の変化（`_bakeEvents`）が [k] のタイルに掛かるか。記録より古ければ掛かる扱い（安全側）
  bool _touchedSince(TileKey k, int since) {
    final oldest = _bakeEvents.isEmpty ? _bakeGen : _bakeEvents.first.$1;
    if (since < oldest - 1) return true;
    for (final (g, r) in _bakeEvents) {
      if (g <= since) continue;
      if (r == null) return true;
      if (k.west < r.right && k.west + k.span > r.left && k.south < r.bottom && k.south + k.span > r.top) return true;
    }
    return false;
  }

  /// 古い世代で焼かれた（またはフィーチャが届く前に焼かれた）タイルを見つけて焼き直す（400ms にまとめる）
  void _scheduleBakeCheck() {
    _bakeCheckTimer?.cancel();
    _bakeCheckTimer = Timer(const Duration(milliseconds: 400), _checkBakes);
  }

  void _checkBakes() {
    if (!mounted) return;
    final gen = _bakeGen;
    final live = {for (final t in _world.tiles) t.key};
    _bakedGen.removeWhere((k, _) => !live.contains(k));
    _bakeRequested.removeWhere((k, _) => !live.contains(k));
    final stale = <TileKey>{
      for (final k in live)
        if (_bakedGen[k] != gen && _bakeRequested[k] != gen && _touchedSince(k, _bakedGen[k] ?? -1)) k,
    };
    // 触れていないタイルは今の世代で焼けているのと同じ扱い（次の出来事まで見ない）
    for (final k in live) {
      if (!stale.contains(k) && _bakedGen.containsKey(k) && _bakedGen[k] != gen && _bakeRequested[k] != gen) {
        _bakedGen[k] = gen;
      }
    }
    if (stale.isEmpty) return;
    for (final k in stale) {
      _bakeRequested[k] = gen;
    }
    debugPrint('[3D] bake: ${stale.length} 枚を世代 $gen で焼き直す');
    unawaited(_world.retexture(where: stale.contains).then((_) {
      if (!mounted) return;
      // 途中で別の作り直しに打ち切られた分は要求を取り下げ、少し置いてまた見る
      var left = false;
      for (final k in stale) {
        if (_bakedGen[k] != gen && _world.has(k)) {
          _bakeRequested.remove(k);
          left = true;
        }
      }
      if (left) _scheduleBakeCheck();
    }));
  }

  // ── オーバーレイ画像 ─────────────────────────────────

  /// 選んだ面が変わったら、前と今の範囲のテクスチャを作り直す（塗りはテクスチャに描くので地形に埋もれない）。
  /// 枠線は今までどおり地形に沿わせた線ですぐ出るので、塗りが少し遅れて付いても選んだことは伝わる
  void _syncSelectionFill() {
    final sel = widget.geoJson.selectedPolygons;
    if (identical(sel, _selFillDrawn)) return;
    _selFillDrawn = sel;
    Rect? b;
    final boxes = _bboxes(sel);
    for (var i = 0; i < sel.length; i++) {
      if (boxes[i * 4].isNaN) continue;
      final r = Rect.fromLTRB(boxes[i * 4], boxes[i * 4 + 1], boxes[i * 4 + 2], boxes[i * 4 + 3]);
      b = b == null ? r : b.expandToInclude(r);
    }
    final prev = _selFillBounds;
    _selFillBounds = b;
    final dirty = prev == null ? b : (b == null ? prev : prev.expandToInclude(b));
    if (dirty == null) return;
    // オーバーレイの作り直しが控えていれば一緒に（作り直しは新しい呼び出しが古い方を止めるので）
    _retextureTimer?.cancel();
    final within = _overlayBounds == null ? dirty : _overlayBounds!.expandToInclude(dirty);
    _overlayBounds = null;
    _world.retexture(within: within.inflate(10));
  }

  /// 見えているオーバーレイ画像の集合・位置が変わったら、画像を読み、テクスチャを作り直す（400ms にまとめる）
  void _syncOverlays() {
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
    // 見えなくなったオーバーレイの画像は手放す（原寸の画像を地図を閉じるまで抱えていた）
    final live = {for (final n in nodes) n.filePath};
    _overlayImages.removeWhere((path, im) {
      if (live.contains(path)) return false;
      im.dispose();
      return true;
    });
    for (final n in nodes) {
      if (_overlayImages.containsKey(n.filePath) || _overlayLoading.contains(n.filePath)) continue;
      _overlayLoading.add(n.filePath);
      _loadOverlayImage(n).then((im) {
        _overlayLoading.remove(n.filePath);
        if (im == null || !mounted) return;
        _overlayImages[n.filePath] = im;
        _scheduleRetexture();
      });
    }
    _scheduleRetexture();
  }

  /// オーバーレイ画像を読む。Android は TIFF の PNG キャッシュ（`imageUrl`）、web は `fs` で元ファイルを読んで
  /// TIFF なら `package:image` で解く（PNG キャッシュはアプリのキャッシュ領域に書くので web には無い）
  Future<ui.Image?> _loadOverlayImage(OverlayImageNode n) async {
    try {
      final String path;
      if (kIsWeb) {
        path = n.getAbsoluteFilePath() ?? n.filePath;
      } else {
        final url = n.imageUrl;
        path = url.startsWith('file:///') ? Uri.parse(url).toFilePath() : url;
      }
      final bytes = await fs.readAsBytes(path);
      final lower = path.toLowerCase();
      if (lower.endsWith('.tif') || lower.endsWith('.tiff')) {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) return null;
        final rgba = decoded.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(rgba, decoded.width, decoded.height, ui.PixelFormat.rgba8888, c.complete);
        return await c.future;
      }
      return await decodeImageFromList(bytes);
    } catch (e) {
      AppLogger.debug('[3D] overlay ${n.filePath} を読めない: $e');
      return null;
    }
  }

  /// オーバーレイ画像が変わった範囲のテクスチャを作り直す（400ms にまとめる）。フィーチャの焼き直しは [_checkBakes]
  void _scheduleRetexture() {
    _retextureTimer?.cancel();
    _retextureTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _world.retexture(within: _overlayBounds);
      _overlayBounds = null;
    });
  }

  /// タイマーを止め、読んだオーバーレイ画像を手放す（dispose から）
  void _disposeBakes() {
    _retextureTimer?.cancel();
    _bakeCheckTimer?.cancel();
    for (final im in _overlayImages.values) {
      im.dispose();
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _overlayKey = ''; // ホットリロードでオーバーレイを同期し直す
  }

  /// テクスチャの上描き: オーバーレイ画像と、引いた段のフィーチャの焼き込み（[demZoom] はタイルの段、range はテクスチャの段）
  void _decorateTexture(ui.Canvas canvas, TileRange range, int demZoom) {
    final frame = TextureFrame(range);
    if (_overlayImages.isNotEmpty) {
      for (final n in widget.mapState.overlayImageNodes) {
        final im = _overlayImages[n.filePath];
        if (im != null) paintOverlayImage(canvas, frame, im, n.cornerCoordinates);
      }
    }
    final off = range.z - demZoom;
    // 引いた段は面・線・点を全部、寄った段は面の塗りだけ描く（塗りを地形に沿わせた板にすると、尾根で地形に
    // 突き抜けられて下の地図が白く抜けた。松本 2026-10-02。枠線・線・点は形のまま持ち上げる）
    _bakeFeatures(canvas, frame, demZoom, fillsOnly: demZoom > kBakeMaxZoom);
    // どの世代のフィーチャで焼いたか（テクスチャの範囲 → タイルのキー）。確定はタイルに貼ったとき（[_onTextureApplied]）
    _composedGen[TileKey(demZoom, range.x0 >> off, range.y0 >> off)] = _bakeGen;
    paintSelectionFill(
      canvas,
      frame,
      selected: widget.geoJson.selectedPolygons,
      indexesIn: _featureIndexes,
      color: layerStyleSettings.getColor(selectedColorDef).withValues(alpha: 0.4),
    );
  }

  /// 引いた段のフィーチャをテクスチャに描く（真上からの投影。座標は範囲左上原点のピクセル）。
  ///
  /// 太さは画面で見える太さに合わせる。テクスチャは表示の段とほぼ同じ段で作るので、テクスチャの 1 px ≒ 画面の 1 px。
  /// 以前は設定の半分にしていて、引くほど細く薄れて地物を見失った（松本 2026-10-02。MapLibre の頃は画面の px で
  /// 一定の太さだったので、引いても色の塊として見えていた）
  void _bakeFeatures(ui.Canvas canvas, TextureFrame frame, int demZoom, {bool fillsOnly = false}) {
    final g = widget.geoJson;
    if (g.polygons.isEmpty && (fillsOnly || (g.polylines.isEmpty && g.markers.isEmpty))) return;
    final groups = _styleGroupsByKey();
    final def = _defaultStyle();
    final sw = Stopwatch()..start();
    final n = paintFeatures(
      canvas,
      frame,
      polygons: g.polygons,
      polylines: g.polylines,
      markers: g.markers,
      indexesIn: _featureIndexes,
      styleOf: (f) => switch (f.properties[kStyleProp]) {
        final String k => groups[k] ?? def,
        _ => def,
      },
      fillsOnly: fillsOnly,
    );
    if (sw.elapsedMilliseconds > 30) {
      debugPrint('[3D] bake z$demZoom ${frame.range.x0},${frame.range.y0}: $n 件 ${sw.elapsedMilliseconds}ms');
    }
  }
}
