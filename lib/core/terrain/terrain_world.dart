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
  TerrainTile({required this.key, required this.raw});

  final TileKey key;

  /// 生の DEM（256×256・格子点はピクセル中心）。標高の問い合わせと当たり判定はこれ
  final DemGrid raw;

  /// 東と北の隣を 1 行・1 列借りた 257×257。描画メッシュとフィーチャの貼り付けはこれ
  /// （タイル境界の 1 セル幅の隙間を塞ぐため）。隣が無ければ自分の縁を延ばす
  late DemGrid bordered = _makeBordered(null, null, null);

  /// 隣の有無の組み合わせ（東・北・北東）。変わったら [bordered] とビルダーを作り直す
  int borderMask = 0;

  ui.Image? texture;
  int textureWidth = 1;
  int textureHeight = 1;

  /// step ごとの描画メッシュ（isolate で作る）。隣が届いて縁が変わったら作り直す
  final Map<int, TerrainMeshBuilder> builders = {};
  final Map<int, Future<TerrainMeshBuilder>> _building = {};

  /// 直近に使われた時刻（LRU）
  int lastUsed = 0;

  double get width => bordered.width;
  double get height => bordered.height;

  /// 隣の縁を借りて 257×257 を作る
  DemGrid _makeBordered(TerrainTile? east, TerrainTile? north, TerrainTile? northEast) {
    final n = raw.cols; // 256
    final out = Float32List((n + 1) * (n + 1));
    for (var r = 0; r < n; r++) {
      final src = r * n;
      final dst = r * (n + 1);
      out.setRange(dst, dst + n, raw.heights, src);
      out[dst + n] = east != null ? east.raw.heightAtIndex(0, r) : raw.heightAtIndex(n - 1, r);
    }
    final top = n * (n + 1);
    for (var c = 0; c < n; c++) {
      out[top + c] = north != null ? north.raw.heightAtIndex(c, 0) : raw.heightAtIndex(c, n - 1);
    }
    out[top + n] = northEast != null
        ? northEast.raw.heightAtIndex(0, 0)
        : (north != null ? north.raw.heightAtIndex(n - 1, 0) : (east != null ? east.raw.heightAtIndex(0, n - 1) : raw.heightAtIndex(n - 1, n - 1)));
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
  bool updateBorder(TerrainTile? east, TerrainTile? north, TerrainTile? northEast) {
    final mask = (east != null ? 1 : 0) | (north != null ? 2 : 0) | (northEast != null ? 4 : 0);
    if (mask == borderMask && builders.isNotEmpty) return false;
    if (mask == borderMask) return false;
    borderMask = mask;
    bordered = _makeBordered(east, north, northEast);
    builders.clear();
    _building.clear();
    return true;
  }

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
      while (builders.length > 2) {
        final far = builders.keys.where((k) => k != step).reduce((a, c) => (a - step).abs() >= (c - step).abs() ? a : c);
        builders.remove(far);
      }
      return b;
    });
  }

  void dispose() {
    texture?.dispose();
    texture = null;
  }
}

/// タイル 1 枚の読み込み（テストで差し替える）
typedef TileLoader = Future<TerrainTile?> Function(TileKey key);

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
    required this.demSource,
    required this.demFetcher,
    required this.textureFetcher,
    this.textureZoomOffset = 1,
    this.maxTiles = 40,
    this.concurrency = 4,
    this.chunkSize = 32,
    TileImageCache? imageCache,
    TileLoader? tileLoader,
  })  : _imageCache = imageCache ?? TileImageCache(capacity: 256),
        _tileLoader = tileLoader;

  /// タイル 1 枚の読み込み（DEM とテクスチャ）。テストでは擬似タイルを遅延つきで返す
  final TileLoader? _tileLoader;

  final DemTileSource demSource;
  final TileFetcher demFetcher;
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
      (zoom.round() - 1).clamp(demSource.minZoom, demSource.maxZoom);

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
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
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
    bool evict = true,
    bool replaceQueue = true,
  }) {
    final wanted = <TileKey>[];
    for (var y = range.y0; y <= range.y1; y++) {
      for (var x = range.x0; x <= range.x1; x++) {
        final key = TileKey(range.z, x, y);
        if (_tiles.containsKey(key)) {
          _tiles[key]!.lastUsed = ++_clock;
        } else if (!_inFlight.contains(key)) {
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
    if (evict) _evict(keep: range);
  }

  void _pump() {
    while (_inFlight.length < concurrency && _queue.isNotEmpty) {
      final key = _queue.removeAt(0);
      if (_inFlight.contains(key) || _tiles.containsKey(key)) continue;
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
    final dem = await DemTileLoader(source: demSource, fetcher: demFetcher).load(range);
    final demMs = sw.elapsedMilliseconds;
    final texRange = range.zoomIn(textureZoomOffset);
    final tex = await RasterTileComposer(fetcher: textureFetcher, imageCache: _imageCache).compose(texRange);
    if (sw.elapsedMilliseconds > 800) debugPrint('[3D] tile $key load ${sw.elapsedMilliseconds}ms (dem $demMs)');
    return TerrainTile(key: key, raw: dem)
      ..texture = tex
      ..textureWidth = tex.width
      ..textureHeight = tex.height;
  }

  Future<void> _load(TileKey key) async {
    try {
      final tile = await (_tileLoader ?? _defaultLoad)(key);
      if (tile == null) return;
      if (_tiles.containsKey(key)) {
        tile.dispose();
        return;
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

  void _evict({required TileRange keep}) {
    if (_tiles.length <= maxTiles) return;
    // 見えている範囲と、その親（2 段）は残す
    bool kept(TileKey k) {
      var r = keep;
      for (var i = 0; i <= 2; i++) {
        if (k.z == r.z && k.x >= r.x0 && k.x <= r.x1 && k.y >= r.y0 && k.y <= r.y1) return true;
        if (r.z == 0) break;
        r = TileRange(z: r.z - 1, x0: r.x0 >> 1, y0: r.y0 >> 1, x1: r.x1 >> 1, y1: r.y1 >> 1);
      }
      return false;
    }
    final victims = _tiles.values.where((t) => !kept(t.key)).toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    for (final v in victims) {
      if (_tiles.length <= maxTiles) break;
      _tiles.remove(v.key);
      v.dispose();
    }
    revision++;
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
    for (var i = 0; i < levels && r.z > demSource.minZoom; i++) {
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
      ensure(ranges[i], centerX: centerX, centerY: centerY, evict: false, replaceQueue: replaceQueue && i == 0);
    }
  }

  /// 上限を超えたぶんを、核（[keep] とその親 [ancestorLevels] 段、余白込み）以外の古いものから捨てる
  void trim({required TileRange keep, int ancestorLevels = 3, int margin = 1}) {
    if (_tiles.length <= maxTiles) return;
    final core = [keep, ...ancestorRanges(keep, levels: ancestorLevels, margin: margin)];
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
    TerrainTile? best;
    for (final t in _tiles.values) {
      if (best != null && t.key.z <= best.key.z) continue;
      final b = t.key.bounds;
      if (x >= b.left && x < b.right && y >= b.top && y < b.bottom) best = t;
    }
    return best?.raw.elevationAt(x, y);
  }

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
