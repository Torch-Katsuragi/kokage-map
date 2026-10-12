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
// こかげマップ: フィーチャの焼き込みの台帳（どのタイルをどの世代で焼いたか・どこが変わったか）
//
// 3D 地図面（`terrain_map_layer_bake.dart`）から切り出した。ウィジェットを立てずに試せるように
import 'dart:ui' show Rect;

import 'terrain_world.dart';

/// フィーチャが変わるたびに世代を進め、変わった範囲に掛かる古い世代のタイルだけ焼き直す。
///
/// 引いた段（[fillsOnlyAbove] 以下）は面・線・点を全部、寄った段は面の塗りだけテクスチャに焼くので、
/// 線・点だけの変化（GPS 軌跡の統合など）は寄った段を焼き直さない（2026-10-12。置いたままで 20 秒ごとに 6 枚焼き直していた）
class FeatureBakeLedger {
  FeatureBakeLedger({required this.fillsOnlyAbove});

  /// この段より細かいタイルは面の塗りだけを焼く
  final int fillsOnlyAbove;

  /// 焼き込みの世代。フィーチャの一覧が変わるたびに進む
  int gen = 0;

  /// フィーチャが変わった出来事（世代, 範囲 Mercator。null は全部, 面の塗りを含むか）
  final List<(int, Rect?, bool)> _events = [];
  static const eventsKept = 64;

  /// タイルごとの焼いた世代（貼ったときに確定）
  final Map<TileKey, int> baked = {};

  /// 描いたがまだ貼っていないテクスチャの世代。作り直しが打ち切られると絵は捨てられるので、描いただけでは焼いた扱いにしない
  final Map<TileKey, int> _composed = {};

  /// 焼き直しを頼んだ世代（頼んだまま貼られていないタイルを二重に頼まない）
  final Map<TileKey, int> _requested = {};

  /// 世代を進め、変わった範囲 [where]（Mercator。null は全部）を記録する。[fills] は面の塗りが変わったか
  void addEvent(Rect? where, {bool fills = true}) {
    gen++;
    _events.add((gen, where, fills || where == null));
    if (_events.length > eventsKept) _events.removeRange(0, _events.length - eventsKept);
  }

  /// [since] の世代より後の変化が [k] のタイルに掛かるか。記録より古ければ掛かる扱い（安全側）。
  /// [forBake] ならテクスチャの焼き込みとして見る（寄った段は面の塗りが変わったときだけ）
  bool touchedSince(TileKey k, int since, {bool forBake = false}) {
    final oldest = _events.isEmpty ? gen : _events.first.$1;
    if (since < oldest - 1) return true;
    final fillsOnly = forBake && k.z > fillsOnlyAbove;
    for (final (g, r, fills) in _events) {
      if (g <= since) continue;
      if (fillsOnly && !fills) continue;
      if (r == null) return true;
      if (k.west < r.right && k.west + k.span > r.left && k.south < r.bottom && k.south + k.span > r.top) return true;
    }
    return false;
  }

  /// テクスチャを今の世代で描いた（まだ貼っていない）
  void composed(TileKey k) => _composed[k] = gen;

  /// テクスチャを貼った。描いたときの世代で焼けたことにする
  void applied(TileKey k) {
    final g = _composed.remove(k);
    if (g != null) baked[k] = g;
  }

  /// 生きているタイル [live] のうち焼き直すものを返し、頼んだ扱いにする。
  /// 変化の掛からないタイルは今の世代で焼けているのと同じ扱い（次の出来事まで見ない）
  Set<TileKey> takeStale(Iterable<TileKey> live) {
    final alive = live.toSet();
    baked.removeWhere((k, _) => !alive.contains(k));
    _requested.removeWhere((k, _) => !alive.contains(k));
    final stale = <TileKey>{
      for (final k in alive)
        if (baked[k] != gen && _requested[k] != gen && touchedSince(k, baked[k] ?? -1, forBake: true)) k,
    };
    for (final k in alive) {
      if (!stale.contains(k) && baked.containsKey(k) && baked[k] != gen && _requested[k] != gen) baked[k] = gen;
    }
    for (final k in stale) {
      _requested[k] = gen;
    }
    return stale;
  }

  /// 頼んだ焼き直しが [requestedGen] で貼られなかった分（打ち切られた）を取り下げる。残りがあれば true（また見る）
  bool withdrawUnapplied(Iterable<TileKey> stale, int requestedGen, bool Function(TileKey) stillLive) {
    var left = false;
    for (final k in stale) {
      if (baked[k] != requestedGen && stillLive(k)) {
        _requested.remove(k);
        left = true;
      }
    }
    return left;
  }
}
