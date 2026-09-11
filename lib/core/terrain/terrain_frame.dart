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
import 'dart:ui';

import 'dem_tiles.dart';
import 'terrain_camera.dart';
import 'terrain_world.dart';
import 'web_mercator.dart';

/// 1 フレームぶんの計画: どの段をどの範囲で、何枚をどの間引きで描くか
class TerrainFramePlan {
  const TerrainFramePlan({
    required this.demZoom,
    required this.range,
    required this.prefetch,
    required this.baseStep,
    required this.tiles,
    required this.coverage,
  });

  final int demZoom;

  /// 画面に掛かる理想のタイル範囲
  final TileRange range;

  /// 先読みの範囲（1 周り外）
  final TileRange prefetch;

  /// 理想の段の間引き段数（親は減らし、子は増やす → [stepFor]）
  final int baseStep;

  /// 描画順に並んだタイル（手持ちで最良の被覆）
  final List<TerrainTile> tiles;
  final CoverageReport coverage;

  /// タイルごとの間引き段数。粗い親ほど画面上のセルが大きいので間引きを減らす
  int stepFor(TerrainTile tile) {
    final diff = demZoom - tile.key.z;
    return diff >= 0 ? math.max(1, baseStep >> diff) : math.min(16, baseStep << -diff);
  }
}

/// カメラと世界から 1 フレームの計画を立て、読み込みを進める
///
/// `TerrainMapLayer` とシミュレーションテストが同じ規則を使うためにここに置く。
/// 規則:
/// - DEM の段は表示ズームの 1 段下（1 セル = 画面 2px）
/// - 読み込みは 親の段（粗い方から [ancestorLevels] 段、余白つき）→ 画面に掛かる分 → 1 周り外 の順
/// - 間引きは「画面に掛かるタイル数 × (256/step)² ≤ 予算」を満たす最小の step
/// - 描くのは手持ちで最良の被覆（理想 → 親 → 子）
class TerrainFramePlanner {
  TerrainFramePlanner(
    this.world, {
    this.staticCellBudget = 100000,
    this.gestureCellBudget = 40000,
    this.ancestorLevels = 4,
    this.prefetchMargin = 1,
    this.maxCoreTiles = 10,
  });

  final TerrainWorld world;
  final int staticCellBudget;
  final int gestureCellBudget;
  final int ancestorLevels;
  final int prefetchMargin;

  /// 画面に掛かる理想タイルの上限。超えるなら段を下げる（傾けるほど画面が広いので粗くなる）
  final int maxCoreTiles;

  int? _lastZoom;

  /// 画面に掛かるタイル枚数の見積もり（段 [z]）。**回転に依らない**
  ///
  /// 画面の地上面積（幅 / 倍率 × 高さ / 倍率 / cos(pitch)）をタイルの面積で割る。
  /// 外接矩形のタイル範囲で数えると、斜め向きのとき枚数が最大 2 倍に膨れて段が 45° ごとに
  /// 切り替わり、地形全体が作り直されて荒ぶる（シミュレーションで一周に 8 回）
  static double visibleTileCount(TerrainCamera camera, Size size, int z) {
    final span = WebMercator.tileSpan(z);
    final w = size.width / camera.scale / span;
    final h = size.height / camera.scale / math.max(0.08, math.cos(camera.pitch)) / span; // 85° まで
    return (w + 1) * (h + 1);
  }

  /// 理想の段: 表示ズーム −1 から始め、画面に掛かるタイルが [maxCoreTiles] を超える間は下げる。
  /// 前回の段と 1 つ違いで枚数が許容内なら前回を使う（境目で往復しない）
  int demZoomFor(TerrainCamera camera, Size size) {
    var z = world.demZoomFor(camera.zoom);
    while (z > world.minZoom && visibleTileCount(camera, size, z) > maxCoreTiles) {
      z--;
    }
    final prev = _lastZoom;
    if (prev != null && (prev - z).abs() == 1) {
      if (prev < z) {
        // 粗い段に居た: 理想の段の枚数が上限すれすれの間だけ留まる（境目で往復しない。
        // 広く取ると 1 段寄っても粗いままになる）
        if (visibleTileCount(camera, size, z) > maxCoreTiles * 0.85) z = prev;
      } else if (visibleTileCount(camera, size, prev) <= maxCoreTiles) {
        // 細かい段に居た: 枚数が許容内なら留まる（寄っている最中に粗くしない）
        z = prev;
      }
    }
    _lastZoom = z;
    return z;
  }

  /// 予算に収まる間引き段数（タイル数 × (256/step)² ≤ 予算）。
  /// [tileCount] は [visibleTileCount] の見積もり（回転に依らない。外接矩形の枚数だと 45° ごとに段数が変わる）
  int stepFor(double tileCount, {required bool gesturing}) {
    final budget = gesturing ? gestureCellBudget : staticCellBudget;
    for (final step in const [1, 2, 4, 8]) {
      if (tileCount * (256 ~/ step) * (256 ~/ step) <= budget) return step;
    }
    return 16;
  }

  /// 直近の [plan] の内訳（ms）。引っかかりの切り分け用
  String lastTiming = '';

  /// 直前に描いたタイル（画面の標高の幅を取るため）
  List<TerrainTile> _lastTiles = const [];

  /// 画面に掛かる標高の幅。直前に描いたタイルから取る（読み込み済み全部から取ると、遠くの粗い親の
  /// 高低差で画面範囲が水増しされ、枚数が上限を超え続けて細かい段に上がれない）
  double _screenHeightRange() {
    var lo = double.infinity, hi = -double.infinity;
    for (final t in _lastTiles) {
      final (a, b) = t.raw.heightRange;
      if (a < lo) lo = a;
      if (b > hi) hi = b;
    }
    return lo.isFinite ? (hi - lo).clamp(100, 2000).toDouble() : 600;
  }

  TerrainFramePlan plan(TerrainCamera camera, Size size, {bool gesturing = false}) {
    final sw = Stopwatch()..start();
    final bounds = world.groundBounds(camera, size, heightRange: _screenHeightRange());
    final zD = demZoomFor(camera, size);
    final range = TerrainWorld.tileRangeFor(bounds, zD);
    final prefetch = TerrainWorld.tileRangeFor(bounds, zD, margin: prefetchMargin);
    // 読み込み順: 1 段上の親（核の範囲だけ）→ 理想の段の核 → 1 周り外 → さらに上の親（余白つき、近い段から）。
    // 1 段上の親は 1/4 の枚数で画面を覆えるので最初に取る（見た目が最短で埋まる）。
    // さらに上の親は「引いたとき」と圏外の近似のためで、急ぎではない。
    // ⚠ 以前は一番粗い親から 4 段ぶん（余白つきで 40 枚超）を核より先に読んでいて、一気に寄ると
    //   中間の段を順に読み終えるまで理想の段が来なかった（松本 2026-09-11「4,5,6,7,8,9 と順番に読んでいる」）
    final tBounds = sw.elapsedMilliseconds;
    final parents = world.ancestorRanges(range, levels: ancestorLevels, margin: 0).reversed.toList(); // 近い段から
    final order = [
      ...parents.take(1), // 1 段上（核の範囲）
      range,
      ...parents.skip(1), // さらに上（核の範囲だけ。1〜2 枚ずつで安い。引いたときの中心を先に押さえる）
      ...world.ancestorRanges(prefetch, levels: ancestorLevels).reversed, // 余白つきの親（引いたときの縁。近い段から）
      prefetch, // 1 周り外（寄ったまま動いたときの縁）
    ];
    var first = true;
    for (final r in order) {
      world.ensure(r, centerX: camera.centerX, centerY: camera.centerY, replaceQueue: first);
      first = false;
    }
    // 寄る方向の先読み: 手が空いているときだけ、画面の内側半分（1 段寄ったときに見える範囲）を 1 段細かい段で読んでおく
    final inner = Rect.fromCenter(center: bounds.center, width: bounds.width / 2, height: bounds.height / 2);
    final children = zD < world.maxZoom ? TerrainWorld.tileRangeFor(inner, zD + 1) : null;
    if (children != null && world.pendingCount == 0) {
      world.ensure(children, centerX: camera.centerX, centerY: camera.centerY, replaceQueue: false);
    }
    final tEnsure = sw.elapsedMilliseconds;
    world.trim(keep: prefetch, ancestorLevels: ancestorLevels, alsoKeep: [?children]);
    final tTrim = sw.elapsedMilliseconds;
    final tiles = world.coverSet(range, camera);
    _lastTiles = tiles;
    final tCover = sw.elapsedMilliseconds;
    final coverage = world.coverage(range);
    lastTiming = 'bounds $tBounds ensure ${tEnsure - tBounds} trim ${tTrim - tEnsure} cover ${tCover - tTrim} report ${sw.elapsedMilliseconds - tCover}';
    return TerrainFramePlan(
      demZoom: zD,
      range: range,
      prefetch: prefetch,
      baseStep: stepFor(visibleTileCount(camera, size, zD), gesturing: gesturing),
      tiles: tiles,
      coverage: coverage,
    );
  }
}
