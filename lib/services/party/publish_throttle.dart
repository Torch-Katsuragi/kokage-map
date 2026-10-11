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
/// パーティ位置共有: 送信レート制御（電池配慮）
///
/// 設計（docs/technical/location-sharing.md §8 電池）:
///   - 距離主導（移動 [distanceThresholdM] ごと）＋ ハートビート上限。
///   - 移動中は [heartbeatMoving]、停止中は [heartbeatStationary] に1回は送る。
///   - 低バッテリー時は距離しきい値を広げ、ハートビートを延ばす。
///   - `/live/{uid}` は上書きなので、中間点は溜めず「最新1点」だけ送る。
library;

import 'package:latlong2/latlong.dart';

import '../../utils/geodesic.dart';

/// 送信判定ロジック（純粋関数的・状態は呼び出し側が保持）
class PublishThrottle {
  /// 送信を発火する移動距離（メートル）
  final double distanceThresholdM;

  /// 移動中のハートビート間隔
  final Duration heartbeatMoving;

  /// 停止中のハートビート間隔
  final Duration heartbeatStationary;

  /// この速度（m/s）以上を「移動中」とみなす
  final double movingSpeedThreshold;

  /// この残量（%）以下を「低バッテリー」とみなす
  final int lowBatteryThreshold;

  /// 低バッテリー時に距離しきい値・ハートビートへ掛ける倍率
  final double lowBatteryFactor;

  const PublishThrottle({
    this.distanceThresholdM = 25,
    this.heartbeatMoving = const Duration(seconds: 75),
    this.heartbeatStationary = const Duration(minutes: 3),
    this.movingSpeedThreshold = 0.6,
    this.lowBatteryThreshold = 20,
    this.lowBatteryFactor = 2.0,
  });

  /// 新しい位置 [current] を送信すべきか判定する。
  ///
  /// [last] / [lastSentAt] は前回送信した位置・時刻（未送信なら null）。
  /// [moving] は移動中か（速度由来）。[battery] は残量（%, 任意）。
  bool shouldPublish({
    required LatLng current,
    required DateTime now,
    LatLng? last,
    DateTime? lastSentAt,
    bool moving = false,
    int? battery,
  }) {
    // 初回は必ず送る。
    if (last == null || lastSentAt == null) return true;

    final low = battery != null && battery <= lowBatteryThreshold;
    final factor = low ? lowBatteryFactor : 1.0;

    // 距離条件
    final movedM = Geodesic.distance(last, current);
    if (movedM >= distanceThresholdM * factor) return true;

    // ハートビート条件
    final heartbeat = moving ? heartbeatMoving : heartbeatStationary;
    final elapsed = now.difference(lastSentAt);
    if (elapsed >= heartbeat * factor) return true;

    return false;
  }
}
