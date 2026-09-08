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
import 'web_mercator.dart';

/// XYZ タイルの番号
@immutable
class TileKey {
  const TileKey(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  TileKey get east => TileKey(z, x + 1, y);

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
  Future<TerrainMeshBuilder> builderFor(int step, {int chunkSize = 32}) {
    final ready = builders[step];
    if (ready != null) return Future.value(ready);
    return _building[step] ??= compute(
      TerrainMeshBuilder.buildInIsolate,
      TerrainMeshBuilderArgs(
        dem: bordered,
        textureWidth: textureWidth,
        textureHeight: textureHeight,
        chunkSize: chunkSize,
        step: step,
      ),
    ).then((b) {
      // 作っている間に縁が変わっていたら捨てる（呼び出し側が作り直す）
      if (identical(_building[step], null)) return b;
      _building.remove(step);
      builders[step] = b;
      return b;
    });
  }

  void dispose() {
    texture?.dispose();
    texture = null;
  }
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
  }) : _imageCache = imageCache ?? TileImageCache(capacity: 256);

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
  final Set<TileKey> _pending = {};
  final List<TileKey> _queue = [];
  int _active = 0;
  int _clock = 0;

  /// タイルの追加・削除・縁の更新で上がる（描画側の再構築の合図）
  int revision = 0;

  /// 読み込みの失敗（直近）。表示用
  String? lastError;

  int get loadedCount => _tiles.length;
  int get pendingCount => _pending.length;

  /// 表示ズームから DEM のズーム（1 段荒い = 1 セルが画面 2px）
  int demZoomFor(double zoom) =>
      (zoom.round() - 1).clamp(demSource.minZoom, demSource.maxZoom);

  TerrainTile? tile(TileKey key) {
    final t = _tiles[key];
    if (t != null) t.lastUsed = ++_clock;
    return t;
  }

  bool has(TileKey key) => _tiles.containsKey(key);

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
  void ensure(TileRange range, {required double centerX, required double centerY}) {
    final wanted = <TileKey>[];
    for (var y = range.y0; y <= range.y1; y++) {
      for (var x = range.x0; x <= range.x1; x++) {
        final key = TileKey(range.z, x, y);
        if (_tiles.containsKey(key)) {
          _tiles[key]!.lastUsed = ++_clock;
        } else if (!_pending.contains(key)) {
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
    // 古い待ち行列は捨てて、今見えているものを優先
    _queue
      ..removeWhere((k) => !_pending.contains(k) || true)
      ..addAll(wanted);
    for (final k in wanted) {
      _pending.add(k);
    }
    _pump();
    _evict(keep: range);
  }

  void _pump() {
    while (_active < concurrency && _queue.isNotEmpty) {
      final key = _queue.removeAt(0);
      if (!_pending.contains(key)) continue;
      _active++;
      unawaited(_load(key).whenComplete(() {
        _active--;
        _pending.remove(key);
        _pump();
      }));
    }
  }

  Future<void> _load(TileKey key) async {
    try {
      final range = TileRange(z: key.z, x0: key.x, y0: key.y, x1: key.x, y1: key.y);
      final dem = await DemTileLoader(source: demSource, fetcher: demFetcher).load(range);
      final texRange = range.zoomIn(textureZoomOffset);
      final tex = await RasterTileComposer(fetcher: textureFetcher, imageCache: _imageCache).compose(texRange);
      if (!_pending.contains(key)) {
        tex.dispose();
        return;
      }
      final tile = TerrainTile(key: key, raw: dem)
        ..texture = tex
        ..textureWidth = tex.width
        ..textureHeight = tex.height
        ..lastUsed = ++_clock;
      _tiles[key] = tile;
      _refreshBorders(key);
      revision++;
      notifyListeners();
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
    final victims = _tiles.values.where((t) {
      final k = t.key;
      return !(k.z == keep.z && k.x >= keep.x0 && k.x <= keep.x1 && k.y >= keep.y0 && k.y <= keep.y1);
    }).toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    for (final v in victims) {
      if (_tiles.length <= maxTiles) break;
      _tiles.remove(v.key);
      v.dispose();
    }
    revision++;
  }

  /// 読み込み済みのタイルを描画順（奥 → 手前）で返す
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

  /// 読み込み済みタイルの標高の範囲（無ければ null）
  (double, double)? get heightRange {
    var minH = double.infinity, maxH = -double.infinity;
    for (final t in _tiles.values) {
      for (final h in t.raw.heights) {
        if (h < minH) minH = h;
        if (h > maxH) maxH = h;
      }
    }
    return minH.isFinite ? (minH, maxH) : null;
  }

  void clear() {
    for (final t in _tiles.values) {
      t.dispose();
    }
    _tiles.clear();
    _pending.clear();
    _queue.clear();
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
