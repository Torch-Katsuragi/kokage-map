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
/// パーティ位置共有: バッテリー残量モニタ
///
/// battery_plus の残量取得は非同期だが、[PartyLocationStore] の `batteryProvider`
/// は同期（送信判定の都度すぐ値が要る）。そのため最新残量をキャッシュして
/// 同期で返す。更新契機は (1) start時、(2) 充放電状態の変化、(3) 定期更新。
/// 送信ペイロードに載せる値＋低残量時の送信間引き（[PublishThrottle]）に使う。
library;

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';

import '../../utils/app_logger.dart';

/// バッテリー残量を同期取得できるようキャッシュするモニタ
class BatteryMonitor {
  static const String _logTag = 'BatteryMonitor';

  /// 定期更新の間隔（残量はゆっくり変化するので長めで電池に優しく）
  static const Duration _pollInterval = Duration(minutes: 3);

  final Battery _battery;

  BatteryMonitor({Battery? battery}) : _battery = battery ?? Battery();

  int? _level;
  StreamSubscription<BatteryState>? _stateSub;
  Timer? _timer;
  bool _started = false;

  /// 直近のバッテリー残量（%, 0-100）。未取得・非対応なら null。
  int? get level => _level;

  /// 監視を開始（初回残量を即取得）。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _refresh();
    // 初回取得を待つ間に dispose された（すぐ退出した）なら、購読もタイマーも張らない。
    if (!_started) return;
    // 充放電状態が変わったタイミングで残量を取り直す。
    _stateSub = _battery.onBatteryStateChanged.listen(
      (_) => _refresh(),
      onError: (Object e) => AppLogger.debug('$_logTag: state購読エラー: $e'),
    );
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      final lv = await _battery.batteryLevel;
      // battery_plus は非対応時に負値や例外を返しうるので妥当値のみ採用。
      if (lv >= 0 && lv <= 100) _level = lv;
    } catch (e) {
      AppLogger.debug('$_logTag: 残量取得失敗: $e');
    }
  }

  /// リソース解放。
  Future<void> dispose() async {
    await _stateSub?.cancel();
    _timer?.cancel();
    _stateSub = null;
    _timer = null;
    _started = false;
  }
}
