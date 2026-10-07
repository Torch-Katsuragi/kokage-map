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
/// パーティ位置共有: 中核ストア
///
/// 役割（InternalGpsLocationStore の「双子」）:
///   - 受信: [PeerSource] から他メンバーの位置を受け取り、自分を除いた
///     スナップショット [peersStream] を配信。地図のWidgetLayerマーカーが購読する。
///   - 送信: 自分のGPS（[ownPositions]）を [PublishThrottle] で間引いて publish。
///     送信は online の時のみ（圏外＝送信ゼロ）。
///   - 復帰時 gap backfill: [PartyConnectionMonitor.onRecovered] を契機に、
///     最新位置を即送信し、圏外区間の軌跡を publishTrack する。
///
/// Firebase には直接依存しない（[PeerSource] 経由）。Riverpod provider 化は
/// 配線フェーズで行う。
library;

import 'dart:async';

import 'package:latlong2/latlong.dart';

import '../../models/gps_position_record.dart';
import '../../models/party/peer_position.dart';
import '../../models/party/peer_track.dart';
import '../../utils/app_logger.dart';
import 'party_connection_monitor.dart';
import 'peer_source.dart';
import 'publish_throttle.dart';

/// 圏外区間の軌跡（gap backfill用）
class GapTrack {
  /// 間引き済みのエンコード済みポリライン
  final String encodedPolyline;
  final int fromMs;
  final int toMs;

  const GapTrack({
    required this.encodedPolyline,
    required this.fromMs,
    required this.toMs,
  });
}

/// 指定区間 [fromMs, toMs] の自分の軌跡を返す（無ければ null）
typedef GapProvider = Future<GapTrack?> Function(int fromMs, int toMs);

/// パーティ位置共有ストア
class PartyLocationStore {
  static const String _logTag = 'PartyLocationStore';

  final PeerSource peerSource;
  final PartyConnectionMonitor monitor;

  /// 自分のGPSストリーム（InternalGpsLocationStore.positionStream を注入）
  final Stream<GpsPositionRecord> ownPositions;

  /// 自分のuid（自身をピア一覧から除外するため）
  final String selfUid;

  final PublishThrottle throttle;

  /// gap backfill 用の軌跡取得（GpsHistoryRecorder をラップして注入, 任意）
  final GapProvider? gapProvider;

  /// バッテリー残量取得（%, 任意）
  final int? Function()? batteryProvider;

  /// 時刻ソース（テスト差し替え用）
  final DateTime Function() _clock;

  PartyLocationStore({
    required this.peerSource,
    required this.monitor,
    required this.ownPositions,
    required this.selfUid,
    this.throttle = const PublishThrottle(),
    this.gapProvider,
    this.batteryProvider,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  Map<String, PeerPosition> _peers = const {};
  final StreamController<Map<String, PeerPosition>> _peersController =
      StreamController<Map<String, PeerPosition>>.broadcast();

  Map<String, List<PeerTrack>> _tracks = const {};
  final StreamController<Map<String, List<PeerTrack>>> _tracksController =
      StreamController<Map<String, List<PeerTrack>>>.broadcast();

  /// ゴーストモード（自分の位置を共有しない＝他メンバーから見えない）
  bool _ghost = false;
  final StreamController<bool> _ghostController =
      StreamController<bool>.broadcast();

  LatLng? _lastSent;
  DateTime? _lastSentAt;
  GpsPositionRecord? _lastOwn;

  /// online を離れた時刻（圏外開始）。gap backfill の起点に使う。
  int? _offlineSinceMs;

  /// 一度でも online に到達したか（初回接続では gap backfill しないため）
  bool _wasOnline = false;

  bool _started = false;
  StreamSubscription<Map<String, PeerPosition>>? _peersSub;
  StreamSubscription<Map<String, List<PeerTrack>>>? _tracksSub;
  StreamSubscription<GpsPositionRecord>? _ownSub;
  StreamSubscription<void>? _recoveredSub;
  StreamSubscription<PartyConnectionState>? _stateSub;

  /// 他メンバーの最新位置（自分を除く）
  Stream<Map<String, PeerPosition>> get peersStream => _peersController.stream;

  /// 現在のピアスナップショット（同期アクセス）
  Map<String, PeerPosition> get peers => _peers;

  /// 他メンバーの圏外区間軌跡（自分を除く）
  Stream<Map<String, List<PeerTrack>>> get tracksStream =>
      _tracksController.stream;

  /// 現在の軌跡スナップショット（同期アクセス）
  Map<String, List<PeerTrack>> get tracks => _tracks;

  /// ゴーストモードの状態変化
  Stream<bool> get ghostStream => _ghostController.stream;

  /// ゴーストモード中か（同期アクセス）
  bool get ghost => _ghost;

  /// 開始
  void start() {
    if (_started) return;
    _started = true;

    _peersSub = peerSource.peers.listen(_onPeers);
    _tracksSub = peerSource.tracks.listen(_onTracks);
    _ownSub = ownPositions.listen(_onOwnPosition);
    _recoveredSub = monitor.onRecovered.listen((_) => _onRecovered());
    _stateSub = monitor.stateStream.listen(_onStateChanged);
    monitor.start();
  }

  void _onPeers(Map<String, PeerPosition> incoming) {
    final next = Map<String, PeerPosition>.from(incoming)..remove(selfUid);
    _peers = next;
    _peersController.add(next);
  }

  void _onTracks(Map<String, List<PeerTrack>> incoming) {
    final next = Map<String, List<PeerTrack>>.from(incoming)..remove(selfUid);
    _tracks = next;
    _tracksController.add(next);
  }

  void _onStateChanged(PartyConnectionState state) {
    if (state == PartyConnectionState.online) {
      _wasOnline = true;
      return;
    }
    // 一度 online を経験した後に離れた最初の瞬間を圏外起点として記録。
    // 初回接続前（_wasOnline=false）は gap backfill 対象にしない。
    if (_wasOnline && _offlineSinceMs == null) {
      _offlineSinceMs = _clock().millisecondsSinceEpoch;
    }
  }

  /// ゴーストモードを切り替える。
  ///
  /// ON: 以後の送信を止め、サーバー上の自分の位置を即削除（他メンバーから消える）。
  /// OFF: online かつ直近の自位置があれば即再送信して姿を戻す。
  Future<void> setGhost(bool on) async {
    if (_ghost == on) return;
    _ghost = on;
    _ghostController.add(on);
    if (on) {
      // 次回復帰時に必ず再送信されるよう、送信履歴をリセット。
      _lastSent = null;
      _lastSentAt = null;
      try {
        await peerSource.clearPosition();
      } catch (e) {
        AppLogger.debug('$_logTag: clearPosition失敗: $e');
      }
    } else {
      // 解除時、online なら直近位置を即送信して即座に姿を戻す。
      final own = _lastOwn;
      if (own != null && monitor.state == PartyConnectionState.online) {
        _publish(own, _clock());
      }
    }
  }

  void _onOwnPosition(GpsPositionRecord rec) {
    _lastOwn = rec;
    // ゴーストモード中は送信しない（位置取得・記録自体は継続）。
    if (_ghost) return;
    // 送信は online の時のみ（圏外は送信ゼロ）。
    if (monitor.state != PartyConnectionState.online) return;
    _maybePublish(rec);
  }

  void _maybePublish(GpsPositionRecord rec) {
    final now = _clock();
    final current = LatLng(rec.latitude, rec.longitude);
    final moving =
        (rec.speed ?? 0) >= throttle.movingSpeedThreshold;
    final should = throttle.shouldPublish(
      current: current,
      now: now,
      last: _lastSent,
      lastSentAt: _lastSentAt,
      moving: moving,
      battery: batteryProvider?.call(),
    );
    if (!should) return;
    _publish(rec, now);
  }

  void _publish(GpsPositionRecord rec, DateTime now) {
    _lastSent = LatLng(rec.latitude, rec.longitude);
    _lastSentAt = now;
    final pos = PeerPosition(
      uid: selfUid,
      latitude: rec.latitude,
      longitude: rec.longitude,
      altitude: rec.altitude,
      accuracy: rec.accuracy,
      bearing: rec.bearing,
      speed: rec.speed,
      serverTimeMs: 0, // 送信側（PeerSource）がサーバー時刻を付与
      battery: batteryProvider?.call(),
    );
    unawaited(
      peerSource.publishPosition(pos).catchError((Object e) {
        AppLogger.debug('$_logTag: publishPosition失敗: $e');
      }),
    );
  }

  /// 「復帰の瞬間」: 最新位置を即送信し、圏外区間を backfill する。
  Future<void> _onRecovered() async {
    // ゴーストモード中は復帰時も送信・backfillしない（姿を見せない）。
    if (_ghost) {
      _offlineSinceMs = null;
      return;
    }
    final now = _clock();
    // 1. 最新位置を最優先で送信。
    final own = _lastOwn;
    if (own != null) {
      _publish(own, now);
    }
    // 2. 圏外区間の軌跡を backfill。
    final since = _offlineSinceMs;
    final provider = gapProvider;
    if (since != null && provider != null) {
      try {
        final gap = await provider(since, now.millisecondsSinceEpoch);
        if (gap != null && gap.encodedPolyline.isNotEmpty) {
          await peerSource.publishTrack(
            encodedPolyline: gap.encodedPolyline,
            fromMs: gap.fromMs,
            toMs: gap.toMs,
          );
        }
      } catch (e) {
        AppLogger.debug('$_logTag: gap backfill失敗: $e');
      }
    }
    _offlineSinceMs = null;
  }

  /// リソース解放
  Future<void> dispose() async {
    await _peersSub?.cancel();
    await _tracksSub?.cancel();
    await _ownSub?.cancel();
    await _recoveredSub?.cancel();
    await _stateSub?.cancel();
    await _peersController.close();
    await _tracksController.close();
    await _ghostController.close();
  }
}
