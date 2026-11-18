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

/// 複数 Bluetooth 機器（外部GNSS ＋ レーザー距離計／TS 等）の接続ハンドシェイク調停器
///
/// Android の Bluetooth Classic ベースバンドは、2台の機器に対する `BluetoothSocket.connect()`
/// （Page Scan ＋ SDP 照会 ＋ RFCOMM 暗号化・Role Switch ネゴシエーション）がミリ秒単位で重なると、
/// 2.4GHz ACL タイムスロット競合でハンドシェイク失敗や既存リンクの巻き添え切断を起こしやすい。
/// 本クラスで発信 `connect` を直列化し、確立直後に短い安定化間隔を空けることで同時接続を安定させる。
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';

class BluetoothConnectionCoordinator {
  static final BluetoothConnectionCoordinator instance =
      BluetoothConnectionCoordinator._internal();
  BluetoothConnectionCoordinator._internal();

  static const String _tag = 'BtCoordinator';

  /// 1台目の RFCOMM 接続完了後、ACL Role Switch・暗号化が落ち着くまで次の接続を待つ間隔
  @visibleForTesting
  Duration settleDelay = const Duration(milliseconds: 600);

  final Queue<Future<void> Function()> _queue = Queue<Future<void> Function()>();
  bool _running = false;
  int _inFlightCount = 0;

  /// 現在進行中＋待機中の接続ハンドシェイク数
  int get inFlightCount => _inFlightCount;
  bool get isBusy => _running;

  /// Bluetooth 発信接続を直列実行し、連続ハンドシェイク間に [settleDelay] を挟む
  /// （Zone をまたぐ Future チェーンを持たないため Widget テストの FakeAsync でも安全に動作する）
  Future<T> runSerializedConnect<T>(
    String label,
    Future<T> Function() connectAction, {
    bool applySettleDelay = true,
  }) {
    final completer = Completer<T>();
    _inFlightCount++;

    _queue.add(() async {
      try {
        AppLogger.debug('$_tag: ハンドシェイク開始 [$label]');
        final value = await connectAction();
        if (!completer.isCompleted) {
          completer.complete(value);
        }
        if (applySettleDelay && settleDelay > Duration.zero) {
          await Future<void>.delayed(settleDelay);
        }
      } catch (e, st) {
        if (!completer.isCompleted) {
          completer.completeError(e, st);
        }
        if (applySettleDelay && settleDelay > Duration.zero) {
          await Future<void>.delayed(
            Duration(
              milliseconds: (settleDelay.inMilliseconds ~/ 2).clamp(0, 500),
            ),
          );
        }
      } finally {
        _inFlightCount--;
      }
    });

    if (!_running) {
      unawaited(_drain());
    }
    return completer.future;
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final next = _queue.removeFirst();
        await next();
      }
    } finally {
      _running = false;
    }
  }

  @visibleForTesting
  void resetForTesting() {
    settleDelay = const Duration(milliseconds: 600);
    _queue.clear();
    _running = false;
    _inFlightCount = 0;
  }
}
