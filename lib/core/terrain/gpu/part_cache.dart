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

/// 複数フレーム周回（リング）のバンプアロケータ計画器（純 Dart）。
///
/// 上流 `package:flutter_gpu` の `HostBuffer` はブロック末尾を跨ぐ書き込み
/// （`_offsetCursor + padding < blockLengthInBytes < _offsetCursor + padding + length`）で
/// 新ブロックへの切り替えを行わずに範囲外書き込み例外を投げる不具合があるため、
/// アライメント・ブロック跨ぎ判定・フレーム周回時の既存ブロック再利用を自前で管理する。
class BumpRingPlanner {
  BumpRingPlanner({
    this.frameCount = 4,
    this.blockLengthInBytes = 64 * 1024,
    required int alignment,
  })  : alignment = alignment < 1 ? 1 : alignment,
        _blockSizes = List.generate(frameCount, (_) => <int>[]),
        _blockUsed = List.generate(frameCount, (_) => <int>[]);

  final int frameCount;
  final int blockLengthInBytes;
  final int alignment;

  final List<List<int>> _blockSizes;
  final List<List<int>> _blockUsed;

  int _frame = 0;
  int _block = 0;
  int _offset = 0;

  int get currentFrame => _frame;

  /// フレームの先頭で次のスロットへ進め、使用量を 0 に戻す
  void reset() {
    _frame = (_frame + 1) % frameCount;
    _block = 0;
    _offset = 0;
    final used = _blockUsed[_frame];
    for (var i = 0; i < used.length; i++) {
      used[i] = 0;
    }
  }

  /// [byteLength] バイトの領域を予約する。
  /// 新規確保または拡張が必要な場合は `newBlockSize != null` を返す。
  ({int frame, int blockIndex, int offsetInBytes, int? newBlockSize}) allocate(int byteLength) {
    assert(byteLength > 0);
    final sizes = _blockSizes[_frame];
    final used = _blockUsed[_frame];

    if (sizes.isEmpty) {
      final size = byteLength > blockLengthInBytes ? byteLength : blockLengthInBytes;
      sizes.add(size);
      used.add(byteLength);
      _block = 0;
      _offset = byteLength;
      return (frame: _frame, blockIndex: 0, offsetInBytes: 0, newBlockSize: size);
    }

    final rem = _offset % alignment;
    final aligned = rem == 0 ? _offset : _offset + (alignment - rem);
    if (aligned + byteLength <= sizes[_block]) {
      _offset = aligned + byteLength;
      used[_block] = _offset;
      return (frame: _frame, blockIndex: _block, offsetInBytes: aligned, newBlockSize: null);
    }

    // 現在のブロックに収まらない → 次のブロックへ進める（既に十分な大きさのブロックがあれば再利用）
    _block++;
    final needed = byteLength > blockLengthInBytes ? byteLength : blockLengthInBytes;
    int? newSize;
    if (_block >= sizes.length) {
      sizes.add(needed);
      used.add(byteLength);
      newSize = needed;
    } else if (sizes[_block] < needed) {
      sizes[_block] = needed;
      used[_block] = byteLength;
      newSize = needed;
    } else {
      used[_block] = byteLength;
    }
    _offset = byteLength;
    return (frame: _frame, blockIndex: _block, offsetInBytes: 0, newBlockSize: newSize);
  }

  /// 現在のフレームで書き込みが発生した `(blockIndex, usedBytes)` の一覧（submit 前の flush 用）
  Iterable<(int blockIndex, int usedBytes)> activeBlocks() sync* {
    final used = _blockUsed[_frame];
    for (var i = 0; i < used.length; i++) {
      if (used[i] > 0) yield (i, used[i]);
    }
  }

  /// フレームごとのブロックサイズ表（テスト検証用）
  List<int> blockSizesForFrame(int frame) => List.unmodifiable(_blockSizes[frame]);

  void clear() {
    for (var i = 0; i < frameCount; i++) {
      _blockSizes[i].clear();
      _blockUsed[i].clear();
    }
    _frame = 0;
    _block = 0;
    _offset = 0;
  }
}
