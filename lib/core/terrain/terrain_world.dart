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
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'dem_grid.dart';
import 'dem_tiles.dart';
import 'terrain_camera.dart';
import 'terrain_mesh.dart';
import 'terrain_worker.dart';
import 'web_mercator.dart';

/// XYZ タイルの番号
@immutable
class TileKey {
  const TileKey(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  TileKey get east => TileKey(z, x + 1, y);

  /// 親（1 段粗い）
  TileKey get parent => TileKey(z - 1, x >> 1, y >> 1);

  /// 子 4 枚（1 段細かい）。北西・北東・南西・南東
  List<TileKey> get children => [
        TileKey(z + 1, x * 2, y * 2),
        TileKey(z + 1, x * 2 + 1, y * 2),
        TileKey(z + 1, x * 2, y * 2 + 1),
        TileKey(z + 1, x * 2 + 1, y * 2 + 1),
      ];

  /// 北隣（タイル y は南向きに増える）
  TileKey get north => TileKey(z, x, y - 1);
  TileKey get northEast => TileKey(z, x + 1, y - 1);

  double get west => WebMercator.tileWest(x, z);
  double get south => WebMercator.tileNorth(y + 1, z);
  double get span => WebMercator.tileSpan(z);
  ui.Rect get bounds => ui.Rect.fromLTWH(west, south, span, span);

  @override
  bool operator ==(Object other) => other is TileKey && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

/// 世界の 1 タイル（計算メッシュ = 生の DEM、描画メッシュ = 間引いたビルダー）
class TerrainTile {
  TerrainTile({required this.key, required this.raw, int? sourceZoom}) : sourceZoom = sourceZoom ?? key.z;

  final TileKey key;

  /// 高さの出どころの段。[key] の段より粗ければ親から補間した近似（本物が取れたら差し替える）
  final int sourceZoom;

  bool get approximate => sourceZoom < key.z;

  /// 生の DEM（256×256・格子点はピクセル中心）。標高の問い合わせと当たり判定はこれ
  final DemGrid raw;

  /// 東と北の隣を 1 行・1 列借りた 257×257。描画メッシュとフィーチャの貼り付けはこれ
  /// （タイル境界の 1 セル幅の隙間を塞ぐため）。隣が無ければ自分の縁を延ばす
  late DemGrid bordered = _makeBordered(null, null, null);

  /// 隣の有無の組み合わせ（東・北・北東）。変わったら [bordered] とビルダーを作り直す
  int borderMask = 0;

  /// 背景のテクスチャ（`Picture.toImage` 由来）。GPU 経路はミップ付きの複製を作った後に [releaseImage] で手放す
  ui.Image? get texture => _texture;
  set texture(ui.Image? v) {
    _texture = v;
    if (v != null) {
      previousTextureKey = textureKey;
      textureKey = Object();
    }
  }

  ui.Image? _texture;

  /// テクスチャの世代の識別子（画像を差し替えるたびに新しくなる。GPU 側のキャッシュのキー）
  Object textureKey = Object();

  /// 1 つ前の世代のキー。web は新しい画像の GPU 転送が非同期なので、終わるまで前の世代を描く
  /// （無いと差し替えのたびに基図ごと白く抜ける）。転送が終わったら GPU 側が捨ててよい
  Object? previousTextureKey;
  int textureWidth = 1;
  int textureHeight = 1;

  /// `ui.Image` を捨てる（GPU 側に複製がある間だけ。[textureKey] は変えないので GPU 側のキャッシュはそのまま効く）
  void releaseImage() {
    _texture?.dispose();
    _texture = null;
  }

  /// step ごとの描画メッシュ（isolate で作る）。隣が届いて縁が変わったら作り直す
  final Map<int, TerrainMeshBuilder> builders = {};
  final Map<int, Future<TerrainMeshBuilder>> _building = {};

  /// 直近に使われた時刻（LRU）
  int lastUsed = 0;

  double get width => bordered.width;
  double get height => bordered.height;

  /// 縁を借りてよい隣か。自分より粗い近似（親から補間したタイル）の縁は借りない。
  /// 借りると本物の自分の縁が近似の高さに引っ張られて段差（断層）になる（2026-09-12 松本の再報告）。
  /// 近似の隣が本物に差し替わったら [updateBorder] が借り直す
  bool _canBorrow(TerrainTile? t) => t != null && t.sourceZoom >= sourceZoom;

  /// 直近の縁の段差（m）。debug の記録用（[seamThresholdM] 超なら `[3D] seam` ログ）
  double lastSeamM = 0;
  static const seamThresholdM = 20.0;

  /// 隣の縁を借りて 257×257 を作る
  DemGrid _makeBordered(TerrainTile? eastIn, TerrainTile? northIn, TerrainTile? northEastIn) {
    final east = _canBorrow(eastIn) ? eastIn : null;
    final north = _canBorrow(northIn) ? northIn : null;
    final northEast = _canBorrow(northEastIn) ? northEastIn : null;
    final n = raw.cols; // 256
    final out = Float32List((n + 1) * (n + 1));
    var seam = 0.0;
    for (var r = 0; r < n; r++) {
      final src = r * n;
      final dst = r * (n + 1);
      out.setRange(dst, dst + n, raw.heights, src);
      final own = raw.heightAtIndex(n - 1, r);
      final v = east != null ? east.raw.heightAtIndex(0, r) : own;
      out[dst + n] = v;
      final d = (v - own).abs();
      if (d > seam) seam = d;
    }
    final top = n * (n + 1);
    for (var c = 0; c < n; c++) {
      final own = raw.heightAtIndex(c, n - 1);
      final v = north != null ? north.raw.heightAtIndex(c, 0) : own;
      out[top + c] = v;
      final d = (v - own).abs();
      if (d > seam) seam = d;
    }
    out[top + n] = northEast != null
        ? northEast.raw.heightAtIndex(0, 0)
        : (north != null ? north.raw.heightAtIndex(n - 1, 0) : (east != null ? east.raw.heightAtIndex(0, n - 1) : raw.heightAtIndex(n - 1, n - 1)));
    lastSeamM = seam;
    if (kDebugMode && seam > seamThresholdM) {
      debugPrint(
        '[3D] seam $key: 借りた縁と自分の縁の差 ${seam.toStringAsFixed(0)}m '
        '(self z$sourceZoom, east z${eastIn?.sourceZoom}, north z${northIn?.sourceZoom})',
      );
    }
    return DemGrid(
      cols: n + 1,
      rows: n + 1,
      originX: raw.originX,
      originY: raw.originY,
      cellSize: raw.cellSize,
      heights: out,
    );
  }

  /// 隣の状態を反映する。縁が変わったら true（ビルダーを作り直す必要あり）
  TerrainTile? _eastRef, _northRef, _northEastRef;

  bool updateBorder(TerrainTile? east, TerrainTile? north, TerrainTile? northEast) {
    final mask = (east != null ? 1 : 0) | (north != null ? 2 : 0) | (northEast != null ? 4 : 0);
    // 隣が同じ物なら何もしない。隣が近似 → 本物に差し替わったときは同じ mask でも縁を借り直す
    if (mask == borderMask && identical(east, _eastRef) && identical(north, _northRef) && identical(northEast, _northEastRef)) {
      return false;
    }
    _eastRef = east;
    _northRef = north;
    _northEastRef = northEast;
    borderMask = mask;
    bordered = _makeBordered(east, north, northEast);
    builders.clear();
    _building.clear();
    return true;
  }

  /// その場で作る粗いビルダー（16 間引き = 16×16 セル、1ms 程度）。
  /// 細かい段が isolate から届くまでの穴埋め。読み込み済みのタイルは常に何かしら描ける
  TerrainMeshBuilder placeholderBuilder({int chunkSize = 32, double skirtDepth = 0}) =>
      builders[16] ??= TerrainMeshBuilder(
        bordered,
        textureWidth: textureWidth,
        textureHeight: textureHeight,
        chunkSize: chunkSize,
        step: 16,
        skirtDepth: skirtDepth,
      );

  /// step のビルダーを isolate で作る（進行中なら同じ Future）
  Future<TerrainMeshBuilder> builderFor(int step, {int chunkSize = 32, double skirtDepth = 0}) {
    final ready = builders[step];
    if (ready != null) return Future.value(ready);
    return _building[step] ??= TerrainWorker.instance.run(
      TerrainMeshBuilder.buildInIsolate,
      TerrainMeshBuilderArgs(
        dem: bordered,
        textureWidth: textureWidth,
        textureHeight: textureHeight,
        chunkSize: chunkSize,
        step: step,
        skirtDepth: skirtDepth,
      ),
    ).then((b) {
      // 作っている間に縁が変わっていたら捨てる（呼び出し側が作り直す）
      if (identical(_building[step], null)) return b;
      _building.remove(step);
      builders[step] = b;
      // 持つのは 2 段まで（1 段 数 MB）。新しい段から一番遠いものを捨てる
      while (builders.keys.where((k) => k != 16).length > 2) {
        final far = builders.keys.where((k) => k != step && k != 16).reduce((a, c) => (a - step).abs() >= (c - step).abs() ? a : c);
        builders.remove(far);
      }
      return b;
    });
  }

  void dispose() {
    releaseImage();
  }
}

/// タイル 1 枚の読み込み（テストで差し替える）
typedef TileLoader = Future<TerrainTile?> Function(TileKey key);

/// 標高タイルのバイト列の取得（ソースごと）
typedef DemFetcher = Future<Uint8List?> Function(DemTileSource source, int z, int x, int y);

/// 被覆の内訳（検証用）
class CoverageReport {
  const CoverageReport({required this.ideal, required this.exact, required this.byAncestor, required this.byChild});

  /// 理想のタイル数と、それぞれ何で埋まったか
  final int ideal;
  final int exact;
  final int byAncestor;
  final int byChild;

  int get covered => exact + byAncestor + byChild;
  double get ratio => ideal == 0 ? 1 : covered / ideal;
  bool get full => covered >= ideal;

  @override
  String toString() => 'cover ${(ratio * 100).toStringAsFixed(0)}% (exact $exact ancestor $byAncestor child $byChild / $ideal)';
}

/// 見渡す限り 1 面の世界（DEM タイルのストリーミング）
///
/// - カメラの見える範囲 + 余白のタイルを非同期に読み、届いたら [revision] を上げる。フレームは止めない
/// - タイルは LRU で [maxTiles] 枚まで。遠いものから捨てる
/// - 標高の問い合わせは読み込み済みの最も細かいタイルで答える（計算メッシュ）
/// - 描画順はタイルの象限走査（奥の行 → 手前、行内も奥 → 手前）。タイル内はチャンクの象限走査
class TerrainWorld extends ChangeNotifier {
  TerrainWorld({
    required this.demSources,
    required this.demFetcher,
    required this.textureFetcher,
    this.textureZoomOffset = 1,
    this.maxTiles = 40,
    this.concurrency = 4,
    this.chunkSize = 32,
    TileImageCache? imageCache,
    this._tileLoader,
  })  : _imageCache = imageCache ?? TileImageCache(capacity: 256);

  /// タイル 1 枚の読み込み（DEM とテクスチャ）。テストでは擬似タイルを遅延つきで返す
  final TileLoader? _tileLoader;

  /// 標高タイルの出どころ。細かい方から順に試す（[DemTileSource.defaultCascade]）
  final List<DemTileSource> demSources;

  /// (ソース, z, x, y) → PNG のバイト列。無ければ null
  final DemFetcher demFetcher;

  /// テクスチャに上描きする手（オーバーレイ画像）。変えたら [retexture]
  TextureDecorator? textureDecorator;

  /// 段の範囲は連なり全体で見る（一番細かいソースの maxZoom まで）
  int get minZoom => demSources.map((s) => s.minZoom).reduce(math.min);
  int get maxZoom => demSources.map((s) => s.maxZoom).reduce(math.max);
  final TileFetcher textureFetcher;

  /// テクスチャは DEM より何段細かいラスタで作るか（1 = 512²）
  final int textureZoomOffset;
  final int maxTiles;
  final int concurrency;
  final int chunkSize;
  final TileImageCache _imageCache;

  final LinkedHashMap<TileKey, TerrainTile> _tiles = LinkedHashMap();

  /// 読み込み中（isolate や通信の最中）。待ち行列とは別
  final Set<TileKey> _inFlight = {};

  /// 待ち行列（優先順）。`ensure` のたびに作り直す
  List<TileKey> _queue = [];
  int _clock = 0;

  /// タイルの追加・削除・縁の更新で上がる（描画側の再構築の合図）
  int revision = 0;

  /// 読み込みの失敗（直近）。表示用
  String? lastError;

  int get loadedCount => _tiles.length;
  int get pendingCount => _inFlight.length + _queue.length;

  /// 表示ズームから DEM のズーム（1 段荒い = 1 セルが画面 2px）
  int demZoomFor(double zoom) =>
      (zoom.round() - 1).clamp(minZoom, maxZoom);

  TerrainTile? tile(TileKey key) {
    final t = _tiles[key];
    if (t != null) t.lastUsed = ++_clock;
    return t;
  }

  bool has(TileKey key) => _tiles.containsKey(key);

  /// 読み込み済みのタイル（順序は到着順）
  Iterable<TerrainTile> get tiles => _tiles.values;

  /// テスト用: 読み込みを通さずにタイルを置く
  @visibleForTesting
  void addTileForTest(TerrainTile tile) {
    _tiles[tile.key] = tile;
    _refreshBorders(tile.key);
    revision++;
  }

  /// カメラの見える地面の範囲（Mercator）
  ///
  /// 画面の 4 隅を「カメラ中心の高さの平面」に落とした矩形を、標高の幅ぶん視線方向に伸ばす
  /// （傾けているとき、高い所は視点側に、低い所は奥にずれる）。
  ui.Rect groundBounds(TerrainCamera camera, ui.Size size, {double heightRange = 1500}) {
    final z0 = elevationAt(camera.centerX, camera.centerY) ?? 0;
    final pc = camera.project(0, 0, z0);
    var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0;
    if (camera.perspective && camera.viewport != ui.Size.zero) {
      // 透視: 4 隅の視線が高さ z0 ± の平面に当たる点。地平線の上を向く隅は靄の先（視点距離 × 4）で打ち切る
      final maxDist = camera.eyeDistance * TerrainCamera.fogEndFactor;
      for (final corner in [
        ui.Offset.zero,
        ui.Offset(size.width, 0),
        ui.Offset(0, size.height),
        ui.Offset(size.width, size.height),
      ]) {
        for (final z in [z0 - heightRange / 2, z0 + heightRange / 2]) {
          final p = camera.groundPointPerspective(corner, z0, z, maxDistance: maxDist);
          minX = math.min(minX, p.dx);
          maxX = math.max(maxX, p.dx);
          minY = math.min(minY, p.dy);
          maxY = math.max(maxY, p.dy);
        }
      }
      return ui.Rect.fromLTRB(camera.centerX + minX, camera.centerY + minY, camera.centerX + maxX, camera.centerY + maxY);
    }
    minX = double.infinity;
    minY = double.infinity;
    maxX = -double.infinity;
    maxY = -double.infinity;
    for (final corner in [
      ui.Offset.zero,
      ui.Offset(size.width, 0),
      ui.Offset(0, size.height),
      ui.Offset(size.width, size.height),
    ]) {
      final projected = ui.Offset(
        pc.dx + (corner.dx - size.width / 2) / camera.scale,
        pc.dy + (corner.dy - size.height / 2) / camera.scale,
      );
      for (final z in [z0 - heightRange / 2, z0 + heightRange / 2]) {
        final p = camera.unprojectAtHeight(projected, z);
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        minY = math.min(minY, p.dy);
        maxY = math.max(maxY, p.dy);
      }
    }
    return ui.Rect.fromLTRB(
      camera.centerX + minX,
      camera.centerY + minY,
      camera.centerX + maxX,
      camera.centerY + maxY,
    );
  }

  /// Mercator の矩形 → ズーム z のタイル範囲（余白 [margin] 枚）
  static TileRange tileRangeFor(ui.Rect bounds, int z, {int margin = 0}) {
    final n = 1 << z;
    final span = WebMercator.tileSpan(z);
    int tx(double x) => ((x + WebMercator.halfCircumference) / span).floor();
    int ty(double y) => ((WebMercator.halfCircumference - y) / span).floor();
    return TileRange(
      z: z,
      x0: (tx(bounds.left) - margin).clamp(0, n - 1),
      x1: (tx(bounds.right) + margin).clamp(0, n - 1),
      y0: (ty(bounds.bottom) - margin).clamp(0, n - 1), // bottom = 北端（Rect の top/bottom は y 昇順）
      y1: (ty(bounds.top) + margin).clamp(0, n - 1),
    );
  }

  /// [range] のタイルを揃える。無いものは中心に近い順に読み始める（非同期・非ブロック）
  ///
  /// [replaceQueue] が true なら古い待ち行列を捨てる（今見えているものを優先）。
  /// 先読み（親の段など）は false で後ろに足す。読み込み中のものは影響を受けない
  void ensure(
    TileRange range, {
    required double centerX,
    required double centerY,
    bool replaceQueue = true,
  }) {
    final wanted = <TileKey>[];
    for (var y = range.y0; y <= range.y1; y++) {
      for (var x = range.x0; x <= range.x1; x++) {
        final key = TileKey(range.z, x, y);
        final have = _tiles[key];
        if (have != null) {
          have.lastUsed = ++_clock;
          // 近似（親から補間）なら本物を取りに行く（失敗直後は待つ）
          if (have.approximate && !_inFlight.contains(key) && !_recentlyFailed(key)) wanted.add(key);
        } else if (!_inFlight.contains(key) && !_recentlyFailed(key)) {
          wanted.add(key);
        }
      }
    }
    double dist(TileKey k) {
      final cx = k.west + k.span / 2;
      final cy = k.south + k.span / 2;
      return (cx - centerX) * (cx - centerX) + (cy - centerY) * (cy - centerY);
    }
    wanted.sort((a, b) => dist(a).compareTo(dist(b)));
    if (replaceQueue) {
      _queue = wanted;
    } else {
      final seen = _queue.toSet();
      _queue.addAll(wanted.where((k) => !seen.contains(k)));
    }
    _pump();
  }

  void _pump() {
    while (_inFlight.length < concurrency && _queue.isNotEmpty) {
      final key = _queue.removeAt(0);
      if (_inFlight.contains(key) || (_tiles[key]?.approximate == false)) continue;
      _inFlight.add(key);
      unawaited(_load(key).whenComplete(() {
        _inFlight.remove(key);
        _pump();
      }));
    }
  }

  Future<TerrainTile?> _defaultLoad(TileKey key) async {
    final range = TileRange(z: key.z, x0: key.x, y0: key.y, x1: key.x, y1: key.y);
    final sw = Stopwatch()..start();
    var dem = await _loadDem(key);
    var sourceZoom = key.z;
    if (dem == null) {
      // 取れない（圏外・遅い）: 親を高さの空間で補間した近似で埋める。本物は後で取り直す
      final approx = await _approximateFromAncestor(key);
      if (approx == null) return null;
      dem = approx.$1;
      sourceZoom = approx.$2;
    }
    final demMs = sw.elapsedMilliseconds;
    final texRange = range.zoomIn(textureZoomOffset);
    final tex = await RasterTileComposer(fetcher: textureFetcher, imageCache: _imageCache)
        .compose(texRange, decorate: textureDecorator);
    if (sw.elapsedMilliseconds > 800) debugPrint('[3D] tile $key load ${sw.elapsedMilliseconds}ms (dem $demMs)');
    return TerrainTile(key: key, raw: dem, sourceZoom: sourceZoom)
      ..texture = tex
      ..textureWidth = tex.width
      ..textureHeight = tex.height;
  }

  /// [key] の DEM を、ソースを細かい方から順に試して取る（その段を持たないソースは飛ばす）
  /// [key] の DEM を、ソースを細かい方から順に重ねて作る。
  /// 細かいソースの無効な点（整備範囲外・水面）は次のソースの値で埋める（同じタイル座標なので点ごとに重ねられる）。
  /// 全部重ねても残った無効値は [fillInvalidHeights] で埋める
  Future<DemGrid?> _loadDem(TileKey key, {bool fillFromAncestor = true}) async {
    final range = TileRange(z: key.z, x0: key.x, y0: key.y, x1: key.x, y1: key.y);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    bool usable(DemTileSource s) {
      if (key.z < s.minZoom || key.z > s.maxZoom) return false;
      final missedAt = _missing['${s.id}/${key.z}/${key.x}/${key.y}'];
      return missedAt == null || nowMs - missedAt >= _missingTtlMs;
    }

    Future<DemGrid?> fetch(DemTileSource s) =>
        DemTileLoader(source: s, fetcher: (z, x, y) => demFetcher(s, z, x, y)).tryLoad(range, fillInvalid: false);
    final sw = Stopwatch()..start();
    // 主力（地理院 1A / 5A / 10B）は同じサーバで安いので**同時に**取る。順に取ると 1 枚 = 往復の合計になる
    // （Pixel 9 で 1 往復 0.4〜1.4 秒 × 3〜4 = 2〜3 秒。同時なら最も遅い 1 往復ぶん）
    final primary = [for (final s in demSources) if (!s.lastResort && usable(s)) s];
    final grids = await Future.wait(primary.map(fetch));
    var merged = _mergeGrids(key, primary, grids, nowMs);
    // 最後の砦（AWS。遠くて 1 秒掛かる）は主力が 1 枚も取れなかった（日本の外）ときだけ。
    // 海や整備範囲の縁の穴は [fillInvalidHeights] で埋める（以前は穴があるたびに AWS を取りに行き、沿岸のタイルが 1 枚 +1 秒だった）
    if (merged == null) {
      final fallback = [for (final s in demSources) if (s.lastResort && usable(s)) s];
      for (final s in fallback) {
        final dem = await fetch(s);
        if (dem != null) {
          merged = dem;
          // 主力が無かったのは通信のせいではない（最後の砦は取れた）ので覚える
          for (final p in primary) {
            _missing['${p.id}/${key.z}/${key.x}/${key.y}'] = nowMs;
          }
          break;
        }
      }
    }
    if (sw.elapsedMilliseconds > 800) {
      debugPrint('[3D] dem $key ${sw.elapsedMilliseconds}ms (${[for (var i = 0; i < primary.length; i++) '${primary[i].id}${grids[i] == null ? '×' : ''}'].join(' ')})');
    }
    if (merged != null) {
      final nan = _countNaN(merged.heights);
      if (nan > 0) {
        // 主力を重ねても残った穴（整備範囲の縁・水面）。行の前の値で埋めると台地や縞になり、
        // 隣のタイルとの縁で数百 m の段差（断層）が出る（2026-09-12 に `[3D] seam` で 329m を観測）。
        // まず親の近似（高さ空間で補間）で埋め、それでも残ればこれまでの埋め方
        final filled = fillFromAncestor ? await _fillFromAncestor(key, merged) : 0;
        final left = _countNaN(merged.heights);
        if (left > 0) fillInvalidHeights(merged.heights);
        if (kDebugMode) debugPrint('[3D] dem $key: 無効 $nan 点（親の近似で $filled、残り $left は前の値）');
      }
    }
    return merged;
  }

  /// [grid] の無効な点を、親から補間した近似で埋める。埋めた点の数を返す
  Future<int> _fillFromAncestor(TileKey key, DemGrid grid) async {
    final approx = await _approximateFromAncestor(key);
    if (approx == null) return 0;
    final src = approx.$1.heights;
    final dst = grid.heights;
    if (src.length != dst.length) return 0;
    var n = 0;
    for (var i = 0; i < dst.length; i++) {
      if (dst[i].isNaN && !src[i].isNaN) {
        dst[i] = src[i];
        n++;
      }
    }
    return n;
  }

  /// 同時に取った格子を細かい順に重ねる（細かいソースの無効な点を次のソースの値で埋める）。
  /// 無かったソースは覚えておく（タイルキャッシュは 404 を覚えないので、毎回ネットに聞くと 1 枚数秒掛かる）。
  /// ⚠ 取れなかった理由は 404 か通信失敗か分からないので、同じタイルで別のソースが取れたとき（= 通信は生きている）だけ覚える
  DemGrid? _mergeGrids(TileKey key, List<DemTileSource> sources, List<DemGrid?> grids, int nowMs) {
    DemGrid? merged;
    for (var i = 0; i < sources.length; i++) {
      final dem = grids[i];
      if (dem == null) continue;
      if (merged == null) {
        merged = dem;
        continue;
      }
      final a = merged.heights;
      final b = dem.heights;
      for (var j = 0; j < a.length; j++) {
        if (a[j].isNaN) a[j] = b[j];
      }
    }
    if (merged != null) {
      for (var i = 0; i < sources.length; i++) {
        if (grids[i] == null) _missing['${sources[i].id}/${key.z}/${key.x}/${key.y}'] = nowMs;
      }
      if (_missing.length > 4096) _missing.clear();
    }
    return merged;
  }

  static int _countNaN(Float32List h) {
    var n = 0;
    for (var i = 0; i < h.length; i++) {
      if (h[i].isNaN) n++;
    }
    return n;
  }

  /// 「無かった」(ソース, タイル) → 覚えた時刻（ms）。圏外の失敗は _failedAt が別に持つ。
  /// 3D に入り直すたびに世界は作り直すので、アプリ全体で持つ。通信の一時的な失敗を永久に覚えないよう期限つき
  static final Map<String, int> _missing = {};
  static const _missingTtlMs = 10 * 60 * 1000;

  /// 親（最大 [maxApproximateLevels] 段上）から補間した近似の DEM と、その親の段
  Future<(DemGrid, int)?> _approximateFromAncestor(TileKey key) async {
    for (var k = 1; k <= maxApproximateLevels && key.z - k >= minZoom; k++) {
      final pz = key.z - k;
      final px = key.x >> k;
      final py = key.y >> k;
      final parent = _tiles[TileKey(pz, px, py)]?.raw ?? await _loadDem(TileKey(pz, px, py), fillFromAncestor: false);
      if (parent == null || parent.cols != WebMercator.tileSize) continue;
      final heights = await TerrainWorker.instance.run(
        upsampleFromParent,
        UpsampleArgs(parent: parent.heights, levels: k, childX: key.x, childY: key.y),
      );
      final mpp = WebMercator.metersPerPixel(key.z);
      return (
        DemGrid(
          cols: WebMercator.tileSize,
          rows: WebMercator.tileSize,
          originX: key.west + mpp / 2,
          originY: key.south + mpp / 2,
          cellSize: mpp,
          heights: heights,
        ),
        pz,
      );
    }
    return null;
  }

  /// 近似に使う親の最大段数
  int maxApproximateLevels = 5;

  int _retextureGen = 0;

  /// 読み込み済みタイルのテクスチャを作り直す（オーバーレイ画像が変わったとき）。
  /// [within]（Mercator）に掛かるタイルだけ。途中で再度呼ばれたら古い方は止まる
  Future<void> retexture({ui.Rect? within, bool Function(TileKey key)? where}) async {
    final gen = ++_retextureGen;
    final targets = [
      for (final t in _tiles.values)
        if ((within == null || _intersects(t.key, within)) && (where == null || where(t.key))) t,
    ];
    for (final tile in targets) {
      if (gen != _retextureGen || !_tiles.containsKey(tile.key)) return;
      final range = TileRange(z: tile.key.z, x0: tile.key.x, y0: tile.key.y, x1: tile.key.x, y1: tile.key.y);
      final tex = await RasterTileComposer(fetcher: textureFetcher, imageCache: _imageCache)
          .compose(range.zoomIn(textureZoomOffset), decorate: textureDecorator);
      if (gen != _retextureGen || !_tiles.containsKey(tile.key)) {
        tex.dispose();
        return;
      }
      tile.texture?.dispose();
      tile
        ..texture = tex
        ..textureWidth = tex.width
        ..textureHeight = tex.height;
      revision++;
      notifyListeners();
    }
  }

  static bool _intersects(TileKey k, ui.Rect r) =>
      k.west < r.right && k.west + k.span > r.left && k.south < r.bottom && k.south + k.span > r.top;

  /// 読み込みに失敗した時刻。しばらく再試行しない（圏外で毎フレーム失敗し続けないように）
  final Map<TileKey, int> _failedAt = {};
  static const _retryAfterMs = 10000;

  /// テスト用: ソースの重ね合わせだけを呼ぶ
  @visibleForTesting
  Future<DemGrid?> debugLoadDem(TileKey key) => _loadDem(key);

  /// テスト用: 失敗の記録を消す（fake_async では DateTime.now が進まない）
  @visibleForTesting
  void debugClearFailures() => _failedAt.clear();

  bool _recentlyFailed(TileKey key) {
    final t = _failedAt[key];
    if (t == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - t < _retryAfterMs) return true;
    _failedAt.remove(key);
    return false;
  }

  Future<void> _load(TileKey key) async {
    try {
      final tile = await (_tileLoader ?? _defaultLoad)(key);
      if (tile == null) {
        _failedAt[key] = DateTime.now().millisecondsSinceEpoch;
        return;
      }
      if (tile.approximate) _failedAt[key] = DateTime.now().millisecondsSinceEpoch; // 本物の取り直しは少し待つ
      final existing = _tiles[key];
      if (existing != null) {
        if (tile.sourceZoom <= existing.sourceZoom) {
          tile.dispose();
          return;
        }
        // 近似 → 本物（または より近い親）に差し替え。古い方のメッシュはレイヤの掃除で返る
        existing.dispose();
      }
      tile.lastUsed = ++_clock;
      _tiles[key] = tile;
      final sw = Stopwatch()..start();
      _refreshBorders(key);
      revision++;
      notifyListeners();
      if (sw.elapsedMilliseconds > 200) debugPrint('[3D] tile $key arrival ${sw.elapsedMilliseconds}ms (borders + listeners)');
    } catch (e) {
      lastError = '$e';
      _failedAt[key] = DateTime.now().millisecondsSinceEpoch;
      debugPrint('[3D] tile $key の読み込みに失敗: $e');
    }
  }

  /// [key] とその西・南・南西のタイルの縁を更新する（このタイルが誰かの東・北・北東になる）
  void _refreshBorders(TileKey key) {
    for (final k in [key, TileKey(key.z, key.x - 1, key.y), TileKey(key.z, key.x, key.y + 1), TileKey(key.z, key.x - 1, key.y + 1)]) {
      final t = _tiles[k];
      if (t == null) continue;
      t.updateBorder(_tiles[k.east], _tiles[k.north], _tiles[k.northEast]);
    }
  }

  /// 理想の範囲を「手持ちで最良のタイル」で埋めて描画順（奥 → 手前）で返す
  ///
  /// 理想のタイルが無ければ、読み込み済みの親（[maxAncestorLevels] 段まで）か、
  /// 読み込み済みの子（1 段）で埋める。ズームが変わった瞬間に何も無くなるのを防ぐ
  /// （タイル地図エンジンの「親子で保持」と同じ）。同じ親は 1 回だけ、最初に出会った位置で描く
  /// （親の領域は子の領域の和なので、奥 → 手前の順序を壊さない）。
  List<TerrainTile> coverSet(TileRange range, TerrainCamera camera, {int maxAncestorLevels = 8}) {
    final out = <TerrainTile>[];
    final emitted = <TileKey>{};
    void emit(TerrainTile t) {
      if (emitted.add(t.key)) out.add(t);
    }

    for (final key in _idealOrder(range, camera)) {
      final exact = _tiles[key];
      if (exact != null) {
        exact.lastUsed = ++_clock;
        emit(exact);
        continue;
      }
      var k = key;
      TerrainTile? ancestor;
      for (var i = 0; i < maxAncestorLevels && k.z > 0; i++) {
        k = k.parent;
        ancestor = _tiles[k];
        if (ancestor != null) break;
      }
      if (ancestor != null) {
        ancestor.lastUsed = ++_clock;
        emit(ancestor);
        continue;
      }
      // 子（1 段）→ 無ければ孫（2 段）で埋める
      for (final c in _childrenInOrder(key, camera)) {
        final t = _tiles[c];
        if (t != null) {
          t.lastUsed = ++_clock;
          emit(t);
          continue;
        }
        for (final g in _childrenInOrder(c, camera)) {
          final gt = _tiles[g];
          if (gt != null) {
            gt.lastUsed = ++_clock;
            emit(gt);
          }
        }
      }
    }
    return out;
  }

  /// 理想の範囲がどれだけ埋まっているか（[coverSet] と同じ規則で数える）
  ///
  /// 子で埋める場合は 4 枚そろって初めて 1 枚ぶんと数える（部分的な子は隙間が出る）
  CoverageReport coverage(TileRange range, {int maxAncestorLevels = 8}) {
    var exact = 0, byAncestor = 0, byChild = 0;
    for (var y = range.y0; y <= range.y1; y++) {
      for (var x = range.x0; x <= range.x1; x++) {
        final key = TileKey(range.z, x, y);
        if (_tiles.containsKey(key)) {
          exact++;
          continue;
        }
        var k = key;
        var found = false;
        for (var i = 0; i < maxAncestorLevels && k.z > 0; i++) {
          k = k.parent;
          if (_tiles.containsKey(k)) {
            found = true;
            break;
          }
        }
        if (found) {
          byAncestor++;
          continue;
        }
        bool coveredBy(TileKey k, int depth) {
          if (_tiles.containsKey(k)) return true;
          if (depth == 0) return false;
          return k.children.every((c) => coveredBy(c, depth - 1));
        }
        if (coveredBy(key, 2)) byChild++;
      }
    }
    return CoverageReport(ideal: range.count, exact: exact, byAncestor: byAncestor, byChild: byChild);
  }

  /// 理想のタイル番号を奥 → 手前の順に
  List<TileKey> _idealOrder(TileRange range, TerrainCamera camera) {
    final eastFar = math.sin(camera.bearing) > 0;
    final northFar = math.cos(camera.bearing) > 0;
    final ys = [for (var y = range.y0; y <= range.y1; y++) y];
    final xs = [for (var x = range.x0; x <= range.x1; x++) x];
    if (!northFar) ys.setAll(0, ys.reversed.toList());
    if (!eastFar) xs.setAll(0, xs.reversed.toList());
    return [for (final y in ys) for (final x in xs) TileKey(range.z, x, y)];
  }

  List<TileKey> _childrenInOrder(TileKey key, TerrainCamera camera) =>
      _idealOrder(TileRange(z: key.z + 1, x0: key.x * 2, y0: key.y * 2, x1: key.x * 2 + 1, y1: key.y * 2 + 1), camera);

  /// 親の段（[levels] 段ぶん）を**粗い方から**読む。ピラミッドは上から埋めるのが定石で、
  /// 一番粗い親 1〜2 枚が届けば画面全体が（粗くても）埋まる。
  /// [replaceQueue] が true なら一番粗い段で待ち行列を置き換える（呼び出し側はこの後に理想の段を足す）
  /// [range] の親の段の範囲を粗い順に返す（最大 [levels] 段、[minZoom] まで）
  ///
  /// 3 段以上上には [margin] 枚の余白を足す。引いている最中に広がる縁を粗い段で先に埋めるため。
  /// 粗い段ほど 1 枚が広いので余白の枚数は少なくて済み、近い段に足すと枚数が嵩む
  List<TileRange> ancestorRanges(TileRange range, {required int levels, int margin = 1, int marginFrom = 2}) {
    final out = <TileRange>[];
    var r = range;
    for (var i = 0; i < levels && r.z > minZoom; i++) {
      r = r.parent;
      out.add(i >= marginFrom ? r.grow(margin) : r);
    }
    return out.reversed.toList();
  }

  /// 親の段を粗い方から順に揃える（[ancestorRanges] の順）。
  /// [replaceQueue] なら一番粗い段でキューを入れ替える（前の景色の残りを捨てる）
  void ensureAncestors(
    TileRange range, {
    required double centerX,
    required double centerY,
    int levels = 2,
    bool replaceQueue = false,
    int margin = 1,
  }) {
    final ranges = ancestorRanges(range, levels: levels, margin: margin);
    for (var i = 0; i < ranges.length; i++) {
      ensure(ranges[i], centerX: centerX, centerY: centerY, replaceQueue: replaceQueue && i == 0);
    }
  }

  /// 上限を超えたぶんを、核（[keep] とその親 [ancestorLevels] 段、余白込み）以外の古いものから捨てる
  void trim({required TileRange keep, int ancestorLevels = 3, int margin = 1, List<TileRange> alsoKeep = const []}) {
    if (_tiles.length <= maxTiles) return;
    final core = [keep, ...ancestorRanges(keep, levels: ancestorLevels, margin: margin), ...alsoKeep];
    bool kept(TileKey k) => core.any((r) => r.contains(k.z, k.x, k.y));
    final victims = _tiles.values.where((t) => !kept(t.key)).toList()..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    var removed = false;
    for (final v in victims) {
      if (_tiles.length <= maxTiles) break;
      _tiles.remove(v.key);
      v.dispose();
      removed = true;
    }
    if (removed) revision++;
  }

  /// 読み込み済みのタイルを描画順（奥 → 手前）で返す（理想の段だけ）
  List<TerrainTile> drawOrder(TileRange range, TerrainCamera camera) {
    final sinB = math.sin(camera.bearing);
    final cosB = math.cos(camera.bearing);
    final eastFar = sinB > 0;
    final northFar = cosB > 0;
    final out = <TerrainTile>[];
    // タイル y は南向きに増える。北が遠いなら y の小さい方から
    final ys = [for (var y = range.y0; y <= range.y1; y++) y];
    final xs = [for (var x = range.x0; x <= range.x1; x++) x];
    if (!northFar) ys.setAll(0, ys.reversed.toList());
    if (!eastFar) xs.setAll(0, xs.reversed.toList());
    for (final y in ys) {
      for (final x in xs) {
        final t = _tiles[TileKey(range.z, x, y)];
        if (t != null) out.add(t);
      }
    }
    return out;
  }

  /// 標高（Mercator 座標）。読み込み済みの最も細かいタイルで答える。無ければ null
  double? elevationAt(double x, double y) {
    // 続けて引くのは同じ辺りが多い（ラベル・点・光線）。前回当たったタイルが一番細かい段なら全タイルを走査しない
    // （1 万ラベル × 40 枚の走査で 1 フレーム 20ms 超えていた）
    if (_finestZFor != revision) {
      _finestZ = -1;
      for (final t in _tiles.values) {
        if (t.key.z > _finestZ) _finestZ = t.key.z;
      }
      _finestZFor = revision;
      _lastHit = null;
    }
    final last = _lastHit;
    if (last != null && last.key.z == _finestZ) {
      final b = last.key.bounds;
      if (x >= b.left && x < b.right && y >= b.top && y < b.bottom) return last.raw.elevationAt(x, y);
    }
    TerrainTile? best;
    for (final t in _tiles.values) {
      if (best != null && t.key.z <= best.key.z) continue;
      final b = t.key.bounds;
      if (x >= b.left && x < b.right && y >= b.top && y < b.bottom) best = t;
    }
    _lastHit = best;
    return best?.raw.elevationAt(x, y);
  }

  TerrainTile? _lastHit;
  int _finestZ = -1;
  int _finestZFor = -1;

  /// 読み込み済みタイルの標高の範囲（無ければ null）。タイルごとの最小・最大を畳むだけ
  ///
  /// ⚠ 以前は毎回 全タイルの全点を走査していて（50 枚で 340 万点）、タイル到着ごとの描き直しが
  /// 連鎖するとイベントループを数十秒独占した（Pixel 9 で実測）
  (double, double)? get heightRange {
    var minH = double.infinity, maxH = -double.infinity;
    for (final t in _tiles.values) {
      final (lo, hi) = t.raw.heightRange;
      if (lo < minH) minH = lo;
      if (hi > maxH) maxH = hi;
    }
    return minH.isFinite ? (minH, maxH) : null;
  }

  void clear() {
    for (final t in _tiles.values) {
      t.dispose();
    }
    _tiles.clear();
    _queue = [];
    revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    clear();
    _imageCache.clear();
    super.dispose();
  }
}
