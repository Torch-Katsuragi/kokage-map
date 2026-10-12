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
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'terrain_world.dart';
import 'web_mercator.dart';

/// フィーチャが変わるたびに世代を進め、変わった範囲に掛かる古い世代のタイルだけ焼き直す。
///
/// 引いた段（[fillsOnlyAbove] 以下）は面・線・点を全部、寄った段は面の塗りだけテクスチャに焼くので、
/// 線・点だけの変化（GPS 軌跡の統合など）は寄った段を焼き直さない（2026-10-12。置いたままで 20 秒ごとに 6 枚焼き直していた）。
///
/// 線の後ろに点を足しただけの変化（[addEvent] の `extension`）は、そのタイルのテクスチャの 1 texel に届かなければ
/// 焼き直さず、タイルごとの「まだ焼いていない範囲」に貯める（2026-10-12。置いたままの GPS の揺れ数 m で z5〜z8 を焼き直していた）。
/// 線は丸い端・丸い継ぎ目で描くので、足した区間で塗りが変わるのは前の端点から足した点までの距離の内側だけ（線の太さに依らない）。
/// 貯めた範囲の対角が 1 texel を超えたら焼く。寄れば細かいタイルは今の中身で新しく焼かれるので、見える所はずれない
class FeatureBakeLedger {
  FeatureBakeLedger({required this.fillsOnlyAbove, double Function(TileKey k)? texelOf})
      : texelOf = texelOf ?? ((k) => k.span / (WebMercator.tileSize * 2));

  /// この段より細かいタイルは面の塗りだけを焼く
  final int fillsOnlyAbove;

  /// タイルのテクスチャの 1 texel の幅（Mercator）。既定はテクスチャを 1 段上（512²）で作るとき
  final double Function(TileKey k) texelOf;

  /// 焼き込みの世代。フィーチャの一覧が変わるたびに進む
  int gen = 0;

  /// フィーチャが変わった出来事（世代, 範囲 Mercator。null は全部, 面の塗りを含むか, 線を伸ばしただけならその区間の範囲）
  final List<(int, Rect?, bool, Rect?)> _events = [];
  static const eventsKept = 64;

  /// タイルごとの焼いた世代（貼ったときに確定）
  final Map<TileKey, int> baked = {};

  /// 1 texel に届かず焼き直しを見送った変化の範囲（Mercator）と、どの世代までを含むか。
  /// その世代以降に描いたテクスチャを貼れば消す
  final Map<TileKey, (Rect, int)> pending = {};

  /// 直近の [takeStale] で 1 texel に届かず見送ったタイルの数（ログ用）
  int lastDeferred = 0;

  /// 描いたがまだ貼っていないテクスチャの世代。作り直しが打ち切られると絵は捨てられるので、描いただけでは焼いた扱いにしない
  final Map<TileKey, int> _composed = {};

  /// 焼き直しを頼んだ世代（頼んだまま貼られていないタイルを二重に頼まない）
  final Map<TileKey, int> _requested = {};

  /// 世代を進め、変わった範囲 [where]（Mercator。null は全部）を記録する。[fills] は面の塗りが変わったか。
  /// [extension] は線の後ろに点を足しただけのときの、前の最後の点から足した点までの範囲（Mercator。[where] の膨らませる前）。
  /// これがあれば 1 texel に届かないタイルは焼き直しを見送れる。描いた・消した・属性やスタイルを変えたときは渡さない（必ず焼く）
  void addEvent(Rect? where, {bool fills = true, Rect? extension}) {
    gen++;
    final all = fills || where == null;
    _events.add((gen, where, all, all ? null : extension));
    if (_events.length > eventsKept) _events.removeRange(0, _events.length - eventsKept);
  }

  static bool _hits(TileKey k, Rect r) =>
      k.west < r.right && k.west + k.span > r.left && k.south < r.bottom && k.south + k.span > r.top;

  /// [since] の世代より後の変化が [k] のタイルに掛かるか。記録より古ければ掛かる扱い（安全側）。
  /// [forBake] ならテクスチャの焼き込みとして見る（寄った段は面の塗りが変わったときだけ）
  bool touchedSince(TileKey k, int since, {bool forBake = false}) => _touch(k, since, forBake: forBake) != _Touch.none;

  /// 掛かった変化が全部「線を伸ばしただけ」なら、その区間の範囲を合わせて [fine] に入れて返す
  _Touch _touch(TileKey k, int since, {required bool forBake, List<Rect>? fine}) {
    final oldest = _events.isEmpty ? gen : _events.first.$1;
    if (since < oldest - 1) return _Touch.full;
    final fillsOnly = forBake && k.z > fillsOnlyAbove;
    var hit = _Touch.none;
    for (final (g, r, fills, ext) in _events) {
      if (g <= since) continue;
      if (fillsOnly && !fills) continue;
      if (r == null) return _Touch.full;
      if (!_hits(k, r)) continue;
      if (ext == null || fine == null) return _Touch.full;
      fine.add(ext);
      hit = _Touch.extension;
    }
    return hit;
  }

  /// テクスチャを今の世代で描いた（まだ貼っていない）
  void composed(TileKey k) => _composed[k] = gen;

  /// テクスチャを貼った。描いたときの世代で焼けたことにする（見送っていた変化もその世代までなら描けている）
  void applied(TileKey k) {
    final g = _composed.remove(k);
    if (g == null) return;
    baked[k] = g;
    final p = pending[k];
    if (p != null && p.$2 <= g) pending.remove(k);
  }

  /// 生きているタイル [live] のうち焼き直すものを返し、頼んだ扱いにする。
  /// 変化の掛からないタイルは今の世代で焼けているのと同じ扱い（次の出来事まで見ない）。
  /// 線を伸ばしただけの変化は、見送った分と合わせて 1 texel に届かなければ見送る（[pending] に貯める。[lastDeferred]）
  Set<TileKey> takeStale(Iterable<TileKey> live) {
    final alive = live.toSet();
    baked.removeWhere((k, _) => !alive.contains(k));
    _requested.removeWhere((k, _) => !alive.contains(k));
    pending.removeWhere((k, _) => !alive.contains(k));
    final stale = <TileKey>{};
    var deferred = 0;
    for (final k in alive) {
      final b = baked[k];
      if (b == gen || _requested[k] == gen) continue;
      if (b == null) {
        stale.add(k);
        continue;
      }
      final fine = <Rect>[];
      switch (_touch(k, b, forBake: true, fine: fine)) {
        case _Touch.none:
          baked[k] = gen;
        case _Touch.full:
          stale.add(k);
        case _Touch.extension:
          var u = pending[k]?.$1;
          for (final r in fine) {
            u = u == null ? r : u.expandToInclude(r);
          }
          if (subTexel(u!, texelOf(k))) {
            pending[k] = (u, gen);
            baked[k] = gen;
            deferred++;
          } else {
            stale.add(k);
          }
      }
    }
    for (final k in stale) {
      _requested[k] = gen;
    }
    lastDeferred = deferred;
    return stale;
  }

  /// 線を伸ばした範囲 [r]（Mercator）がテクスチャの 1 texel（[texel]、Mercator）に届かないか。
  /// 塗りが変わるのは前の端点から [r] の対角の内側だけなので、対角で比べる
  static bool subTexel(Rect r, double texel) {
    final w = r.width.abs(), h = r.height.abs();
    return math.sqrt(w * w + h * h) < texel;
  }

  /// 頼んだ焼き直しが [requestedGen] で貼られなかった分（打ち切られた）を取り下げる。取り下げた数を返す（1 枚以上ならまた見る）
  int withdrawUnapplied(Iterable<TileKey> stale, int requestedGen, bool Function(TileKey) stillLive) {
    var left = 0;
    for (final k in stale) {
      if (baked[k] != requestedGen && stillLive(k)) {
        _requested.remove(k);
        left++;
      }
    }
    return left;
  }
}

enum _Touch { none, extension, full }
