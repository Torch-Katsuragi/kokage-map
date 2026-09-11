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
import 'dart:isolate';

/// 地形まわりの重い計算（DEM の組み立て・メッシュの前計算）を流す常駐 isolate の小さなプール
///
/// `compute` は呼ぶたびに isolate を起動する。引いた瞬間に 40 枚ぶん同時に起動すると
/// debug では 1 本 30MB 超・起動 1 秒超で、メモリが 1GB 以上膨らんだ（Pixel 9 で実測）。
/// ここでは [size] 本を起動したまま使い回し、順番に流す（io 実装。web は `terrain_worker_web.dart`）
class TerrainWorker {
  TerrainWorker({this.size = 2});

  static final TerrainWorker instance = TerrainWorker();

  final int size;
  final List<_Worker> _workers = [];
  int _next = 0;

  /// [fn] は静的関数か top-level 関数（isolate へ送れるもの）。[arg] と戻り値は isolate 間で送れる型
  Future<R> run<Q, R>(R Function(Q) fn, Q arg) async {
    if (_workers.isEmpty) {
      for (var i = 0; i < size; i++) {
        _workers.add(_Worker());
      }
    }
    // 空いているものを優先、無ければ順番に
    final w = _workers.firstWhere((w) => w.pending == 0, orElse: () => _workers[_next++ % _workers.length]);
    return w.run(fn, arg);
  }

  int get pending => _workers.fold(0, (n, w) => n + w.pending);

  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
  }
}

class _Worker {
  Future<SendPort>? _port;
  Isolate? _isolate;
  final _receive = ReceivePort();
  final _waiting = <int, Completer<Object?>>{};
  int _seq = 0;

  int get pending => _waiting.length;

  Future<SendPort> _start() async {
    final ready = Completer<SendPort>();
    _receive.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
        return;
      }
      final (int id, Object? result, Object? error) = msg as (int, Object?, Object?);
      final c = _waiting.remove(id);
      if (c == null) return;
      if (error != null) {
        c.completeError(error);
      } else {
        c.complete(result);
      }
    });
    _isolate = await Isolate.spawn(_main, _receive.sendPort, debugName: 'terrain-worker');
    return ready.future;
  }

  Future<R> run<Q, R>(R Function(Q) fn, Q arg) async {
    final port = await (_port ??= _start());
    final id = _seq++;
    final c = Completer<Object?>();
    _waiting[id] = c;
    port.send((id, fn, arg));
    return (await c.future) as R;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _receive.close();
    for (final c in _waiting.values) {
      c.completeError(StateError('TerrainWorker disposed'));
    }
    _waiting.clear();
  }

  static void _main(SendPort reply) {
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);
    inbox.listen((msg) {
      final (int id, Function fn, Object? arg) = msg as (int, Function, Object?);
      try {
        // fn は run<Q, R> の R Function(Q) を Function に落として運んでいる（isolate の境界で型は消える）
        // ignore: avoid_dynamic_calls
        reply.send((id, fn(arg), null));
      } catch (e) {
        reply.send((id, null, '$e'));
      }
    });
  }
}
