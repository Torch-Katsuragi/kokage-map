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
  /// テクスチャに描き込む（真上からの投影。ユーザー 2026-09-12「重いときはクラスタ省略でなく投影で」）。
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
      for (final g in widget.scene.styleGroups)
        '${g.key} ${g.fillHex} ${g.fillOpacity} ${g.outlineHex} ${g.outlineOpacity} ${g.borderWidth} '
            '${g.lineHex} ${g.lineWidth} ${g.pointHex} ${g.pointSize}',
    ].join('|');
  }

  /// 最後に焼いたときの描く順の世代（`MapScene.drawOrderRevision`）
  int? _bakedDrawOrder;

  /// 焼き込みの台帳: 世代（フィーチャの一覧が変わるたびに進む）・タイルごとの焼いた世代・変わった範囲。
  /// 世代が古く、その後の変化が掛かるタイルだけ焼き直す（[_checkBakes]）。
  /// ⚠ 以前は「一覧が変わった瞬間に読み込み済みのタイル」だけ焼き直していたので、その瞬間に読み込み中だった親タイルは
  ///   フィーチャ無しのテクスチャのまま残り、寄せる最中に親と子が入れ替わるたびにフィーチャが出たり消えたりした
  ///   （ユーザー 2026-09-13「地形読み込み中だけフィーチャが表示されたりされなかったり」。web で目立つ）。
  /// 記録中の GPS 軌跡は 20 秒ごとに伸びるので、全部焼き直すと 46 枚 × 40〜90ms が毎回来る
  /// GPS の揺れ数 m のような 1 texel に届かない線の伸びは、貯めて届いたら焼く（texel はテクスチャを作る段で決まる）
  late final FeatureBakeLedger _bakes = FeatureBakeLedger(
    fillsOnlyAbove: kBakeMaxZoom,
    texelOf: (k) => WebMercator.metersPerPixel(k.z + _world.textureZoomOffsetFor(k.z)),
  );

  void _onTextureApplied(TileKey key) => _bakes.applied(key);

  Timer? _bakeCheckTimer;

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
    final g = widget.scene.features;
    final rev = g.contentRevision;
    // 色や濃さだけ変えたときは地物の署名（形とスタイルの鍵）が変わらないので、スタイルの中身でも見る。
    // 塗りはどの段もテクスチャに描くので、変われば全部焼き直す
    final styleSig = _styleSignature();
    if (_bakedStyleSignature != null && _bakedStyleSignature != styleSig) _bakes.addEvent(null);
    _bakedStyleSignature = styleSig;
    // 描く順（レイヤの並び）が変わったら、面の塗りとオーバーレイ画像の重なりが変わるので一度だけ全部焼き直す
    final order = widget.scene.drawOrderRevision;
    if (_bakedDrawOrder != null && _bakedDrawOrder != order) _bakes.addEvent(null);
    _bakedDrawOrder = order;
    if (_bakedContentRevision != rev) {
      _bakedContentRevision = rev;
      ui.Rect? merc(ui.Rect? ll) => ll == null
          ? null
          : ui.Rect.fromLTRB(
              WebMercator.xFromLon(ll.left),
              WebMercator.yFromLat(ll.top),
              WebMercator.xFromLon(ll.right),
              WebMercator.yFromLat(ll.bottom),
            );
      _bakes.addEvent(
        merc(g.lastChangeLonLat)?.inflate(50),
        fills: g.lastChangeHasFills,
        extension: merc(g.lastChangeExtension),
      );
    }
    _scheduleBakeCheck();
    _scheduleRefresh();
  }

  /// 古い世代で焼かれた（またはフィーチャが届く前に焼かれた）タイルを見つけて焼き直す（400ms にまとめる）
  void _scheduleBakeCheck() {
    _bakeCheckTimer?.cancel();
    _bakeCheckTimer = Timer(const Duration(milliseconds: 400), _checkBakes);
  }

  void _checkBakes() {
    if (!mounted) return;
    final gen = _bakes.gen;
    final stale = _bakes.takeStale([for (final t in _world.tiles) t.key]);
    if (stale.isEmpty) return;
    final deferred = _bakes.lastDeferred;
    unawaited(_world.retexture(where: stale.contains).then((_) {
      if (!mounted) return;
      // 途中で別の作り直しに打ち切られた分は要求を取り下げ、少し置いてまた見る
      final left = _bakes.withdrawUnapplied(stale, gen, _world.has);
      // 実際に貼った枚数（打ち切り・見送りは別に）
      final done = stale.where((k) => (_bakes.baked[k] ?? -1) >= gen).length;
      debugPrint('[3D] bake: $done 枚を世代 $gen で焼き直した'
          '${left > 0 ? '（打ち切り $left 枚）' : ''}${deferred > 0 ? '（1 texel 未満で見送り $deferred 枚）' : ''}');
      if (left > 0) _scheduleBakeCheck();
    }));
  }

  // ── オーバーレイ画像 ─────────────────────────────────

  /// 選んだ面が変わったら、前と今の範囲のテクスチャを作り直す（塗りはテクスチャに描くので地形に埋もれない）。
  /// 枠線は今までどおり地形に沿わせた線ですぐ出るので、塗りが少し遅れて付いても選んだことは伝わる
  void _syncSelectionFill() {
    final sel = widget.scene.features.selectedPolygons;
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
    final nodes = widget.scene.overlayImages;
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
        if (im == null) return;
        // 読んでいる間に地図が閉じた（原寸の画像なので GC を待たずに手放す）
        if (!mounted) {
          im.dispose();
          return;
        }
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
      if (n is ExternalOverlayImageNode) {
        // QGIS / GDAL のラスタは GDAL が作った PNG キャッシュ（web も `fs` で読める所に置く）
        final png = n.cachedPngPath;
        if (png == null) return null;
        path = png;
      } else if (kIsWeb) {
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

  /// テクスチャの上描き: オーバーレイ画像と面の塗りをレイヤの並びで混ぜて重ね、引いた段はその上に枠線・線・点
  /// （[demZoom] はタイルの段、range はテクスチャの段）。
  ///
  /// QGIS と同じく、レイヤ一覧で上にあるものほど手前（[composeTextureDraws]）。線・点・枠線・ラベルはいつも一番上
  /// （寄った段では地形に沿わせた形として持ち上げるので、テクスチャの重なりには入らない）
  void _decorateTexture(ui.Canvas canvas, TileRange range, int demZoom) {
    final frame = TextureFrame(range);
    final off = range.z - demZoom;
    final sw = Stopwatch()..start();
    final g = widget.scene.features;
    final groups = _styleGroupsByKey();
    final def = _defaultStyle();
    TerrainFeatureStyle styleOf(geo.Feature f) => switch (f.properties[kStyleProp]) {
          final String k => groups[k] ?? def,
          _ => def,
        };

    // 面の塗りとオーバーレイ画像（段の小さい＝一覧で下のものから）
    final overlays = <(OverlayImageNode, ui.Image)>[
      if (_overlayImages.isNotEmpty)
        for (final n in widget.scene.overlayImages)
          if (_overlayImages[n.filePath] case final im?) (n, im),
    ];
    final fillIdx = g.polygons.isEmpty ? const <int>[] : _featureIndexes(g.polygons, frame.mercator);
    final ranks = g.polygonRanks;
    final steps = composeTextureDraws(
      fillRanks: [for (final i in fillIdx) i < ranks.length ? ranks[i] : 0],
      overlayRanks: [for (final (n, _) in overlays) widget.scene.drawRankOf(n)],
    );
    for (final step in steps) {
      switch (step) {
        case OverlayDraw(:final overlay):
          final (n, im) = overlays[overlay];
          paintOverlayImage(canvas, frame, im, n.cornerCoordinates);
        case FillRun(:final from, :final to):
          paintPolygonFills(canvas, frame, polygons: g.polygons, indexes: fillIdx.sublist(from, to), styleOf: styleOf);
      }
    }

    // 引いた段は枠線・線・点も描く（寄った段は塗りだけ。塗りを地形に沿わせた板にすると、尾根で地形に
    // 突き抜けられて下の地図が白く抜けた。ユーザー 2026-10-02。枠線・線・点は形のまま持ち上げる）
    if (demZoom <= kBakeMaxZoom) _bakeFeatures(canvas, frame, styleOf);
    if (sw.elapsedMilliseconds > 30) {
      debugPrint('[3D] bake z$demZoom ${frame.range.x0},${frame.range.y0}: '
          '面 ${fillIdx.length} 件・オーバーレイ ${overlays.length} 枚 ${sw.elapsedMilliseconds}ms');
    }
    // どの世代のフィーチャで焼いたか（テクスチャの範囲 → タイルのキー）。確定はタイルに貼ったとき（[_onTextureApplied]）
    _bakes.composed(TileKey(demZoom, range.x0 >> off, range.y0 >> off));
    paintSelectionFill(
      canvas,
      frame,
      selected: widget.scene.features.selectedPolygons,
      indexesIn: _featureIndexes,
      color: layerStyleSettings.getColor(selectedColorDef).withValues(alpha: 0.4),
    );
  }

  /// 引いた段のフィーチャの塗り以外（枠線・線・点）をテクスチャに描く（真上からの投影。座標は範囲左上原点のピクセル）。
  /// 塗りは [_decorateTexture] がオーバーレイ画像と混ぜて先に描いている。
  ///
  /// 太さは画面で見える太さに合わせる。テクスチャは表示の段とほぼ同じ段で作るので、テクスチャの 1 px ≒ 画面の 1 px。
  /// 以前は設定の半分にしていて、引くほど細く薄れて地物を見失った（ユーザー 2026-10-02。MapLibre の頃は画面の px で
  /// 一定の太さだったので、引いても色の塊として見えていた）
  void _bakeFeatures(ui.Canvas canvas, TextureFrame frame, TerrainFeatureStyle Function(geo.Feature f) styleOf) {
    final g = widget.scene.features;
    if (g.polygons.isEmpty && g.polylines.isEmpty && g.markers.isEmpty) return;
    paintFeatures(
      canvas,
      frame,
      polygons: g.polygons,
      polylines: g.polylines,
      markers: g.markers,
      indexesIn: _featureIndexes,
      styleOf: styleOf,
      fills: false,
    );
  }
}
