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
/// パーティ位置共有: 接続ステートマシン
///
/// 設計思想（docs/technical/location-sharing.md §5）:
///   - 途絶中はほっとく: 圏外が続いたら [PeerSource.goOffline] でSDKの
///     再接続リトライを止め、電池・電波を温存する。
///   - 復帰の瞬間を的確に察知: OSのインターフェイス復帰イベントで goOnline し、
///     サーバー接続（.info/connected）が true に跳ねた瞬間を recovered として通知。
///   - 統合的: サーバー障害・トンネル・圏外いずれも serverConnected=false の
///     同一経路で扱う。
///
/// 純Dartで完結し、connectivity_plus / Firebase に直接依存しない
/// （ブール2系列のストリームと online/offline 要求コールバックを注入）。
library;

import 'dart:async';

/// 接続状態
enum PartyConnectionState {
  /// 圏外（インターフェイス無し）。SDKは goOffline 済み。
  offline,

  /// インターフェイスはあるが、まだサーバー未接続。
  connecting,

  /// サーバー接続確立。位置を publish できる。
  online,
}

/// online/offline 要求のコールバック
typedef ConnectionRequest = Future<void> Function();

/// 遅延実行タイマのファクトリ（テストで差し替え可能）
typedef DelayedTimerFactory = Timer Function(Duration delay, void Function() callback);

/// 接続ステートマシン
class PartyConnectionMonitor {
  /// インターフェイス有無のストリーム（connectivity_plus由来を想定）
  final Stream<bool> hasInterface;

  /// サーバー接続のストリーム（[PeerSource.serverConnected] 由来）
  final Stream<bool> serverConnected;

  /// オンライン要求（goOnline 相当）
  final ConnectionRequest requestOnline;

  /// オフライン要求（goOffline 相当）
  final ConnectionRequest requestOffline;

  /// インターフェイス喪失からこの時間継続したら goOffline する（瞬断での無駄な
  /// goOffline/goOnline 往復を避けるためのデバウンス）。
  final Duration sustainedOfflineDelay;

  final DelayedTimerFactory _timerFactory;

  PartyConnectionMonitor({
    required this.hasInterface,
    required this.serverConnected,
    required this.requestOnline,
    required this.requestOffline,
    this.sustainedOfflineDelay = const Duration(seconds: 20),
    DelayedTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new;

  bool _hasInterface = false;
  bool _serverConnected = false;
  bool _started = false;
  bool _sdkOnline = false;

  Timer? _offlineTimer;
  StreamSubscription<bool>? _ifSub;
  StreamSubscription<bool>? _srvSub;

  PartyConnectionState _state = PartyConnectionState.offline;

  final StreamController<PartyConnectionState> _stateController =
      StreamController<PartyConnectionState>.broadcast();
  final StreamController<void> _recoveredController =
      StreamController<void>.broadcast();

  /// 現在の状態
  PartyConnectionState get state => _state;

  /// 状態遷移のストリーム
  Stream<PartyConnectionState> get stateStream => _stateController.stream;

  /// 「復帰の瞬間」（offline/connecting → online）の通知ストリーム。
  /// gap backfill のトリガーに使う。
  Stream<void> get onRecovered => _recoveredController.stream;

  /// 監視開始
  void start() {
    if (_started) return;
    _started = true;
    _ifSub = hasInterface.listen(_onInterfaceChanged);
    _srvSub = serverConnected.listen(_onServerChanged);
  }

  void _onInterfaceChanged(bool has) {
    if (has == _hasInterface) return;
    _hasInterface = has;
    if (has) {
      // インターフェイス復帰 → goOffline予約をキャンセルし、オンライン要求。
      _offlineTimer?.cancel();
      _offlineTimer = null;
      if (!_sdkOnline) {
        _sdkOnline = true;
        unawaited(requestOnline());
      }
    } else {
      // インターフェイス喪失 → 一定時間継続したら goOffline（ほっとく）。
      _offlineTimer?.cancel();
      _offlineTimer = _timerFactory(sustainedOfflineDelay, _goOfflineNow);
    }
    _recompute();
  }

  void _goOfflineNow() {
    _offlineTimer = null;
    if (_sdkOnline) {
      _sdkOnline = false;
      unawaited(requestOffline());
    }
    // サーバー接続も論理的に落ちたとみなす。
    _serverConnected = false;
    _recompute();
  }

  void _onServerChanged(bool connected) {
    if (connected == _serverConnected) return;
    _serverConnected = connected;
    _recompute();
  }

  void _recompute() {
    final PartyConnectionState next;
    if (_serverConnected) {
      next = PartyConnectionState.online;
    } else if (_hasInterface) {
      next = PartyConnectionState.connecting;
    } else {
      next = PartyConnectionState.offline;
    }
    if (next == _state) return;
    final wasOnline = _state == PartyConnectionState.online;
    _state = next;
    _stateController.add(next);
    // 復帰の瞬間: online へ遷移したら通知。
    if (next == PartyConnectionState.online && !wasOnline) {
      _recoveredController.add(null);
    }
  }

  /// リソース解放
  Future<void> dispose() async {
    _offlineTimer?.cancel();
    await _ifSub?.cancel();
    await _srvSub?.cancel();
    await _stateController.close();
    await _recoveredController.close();
  }
}
