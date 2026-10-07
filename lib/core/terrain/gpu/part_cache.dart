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
// こかげマップ: 地物の束を GPU のバッファに上げたもののキャッシュ（flutter_gpu 版・WebGL2 版で共通）

/// 1 つの束（リスト）を上げたバッファの列。リストが伸びたぶんだけ後ろに足す
class GpuParts<B> {
  final List<B> parts = [];

  /// 上げ終えた要素の数
  int packed = 0;
  int lastGrowMs = 0;
  int lastUsed = 0;
}

/// 地物の束（静的シーンのリスト）→ GPU のバッファ。キーはリストの**同一性**。
///
/// 静的シーンは数フレームかけて育つので、伸びたぶんだけ [pack] して足す（全部を上げ直さない）。
/// 育ち切って 1 秒伸びなければ 1 本に上げ直し、描画の呼び出しを減らす
class GpuPartCache<T, B> {
  GpuPartCache(this._release);

  /// バッファを手放す（flutter_gpu は GC 任せで何もしない、WebGL は deleteBuffer）
  final void Function(B) _release;
  final Map<List<T>, GpuParts<B>> _map = Map.identity();

  int get length => _map.length;

  /// [list] のバッファ。上げ直したときはかかった時間も返す
  (GpuParts<B>, Duration?) partsFor(List<T> list, int nowMs, B? Function(List<T> list, int from) pack) {
    final parts = _map[list] ??= GpuParts<B>();
    Duration? took;
    if (list.length > parts.packed) {
      final sw = Stopwatch()..start();
      final p = pack(list, parts.packed);
      if (p != null) parts.parts.add(p);
      parts.packed = list.length;
      parts.lastGrowMs = nowMs;
      took = sw.elapsed;
    } else if (parts.parts.length > 1 && nowMs - parts.lastGrowMs > 1000) {
      final sw = Stopwatch()..start();
      parts.parts.forEach(_release);
      final p = pack(list, 0);
      parts.parts
        ..clear()
        ..addAll([?p]);
      took = sw.elapsed;
    }
    parts.lastUsed = nowMs;
    return (parts, took);
  }

  /// [maxAgeMs] より長く描いていない束を手放す
  void sweep(int nowMs, int maxAgeMs) {
    _map.removeWhere((_, v) {
      if (nowMs - v.lastUsed <= maxAgeMs) return false;
      v.parts.forEach(_release);
      return true;
    });
  }

  void clear() {
    for (final v in _map.values) {
      v.parts.forEach(_release);
    }
    _map.clear();
  }
}
