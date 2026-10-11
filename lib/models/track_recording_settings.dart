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
/// GPS 軌跡の記録の設定と、届いた測位を軌跡に入れるかの判定（設定 → GPS・測位 →「軌跡の記録」）。
///
/// 測位の頻度（OS への位置の要求）はそのまま。届いた測位を間引くだけなので、電池の減りは増えない
library;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geodesic.dart';

/// 軌跡の記録の設定。既定は以前の動き（1 秒ごと・同じ座標だけ捨てる）に、明らかな飛びの除外を足したもの
@immutable
class TrackRecordingSettings {
  const TrackRecordingSettings({
    this.intervalSeconds = 1,
    this.minDistance = 0,
    this.maxSpeedKmh = defaultMaxSpeedKmh,
    this.maxAccuracy = defaultMaxAccuracy,
  });

  static const defaults = TrackRecordingSettings();

  /// 飛びとみなす速さの既定（km/h）。車の移動は残し、マルチパスで数百 m 跳ぶ点を落とす
  static const double defaultMaxSpeedKmh = 200;

  /// 精度の上限の既定（m）。GPS を見失ったときに混じる基地局・Wi-Fi 由来の測位（±数百 m〜）を落とす
  static const double defaultMaxAccuracy = 100;

  /// 選択肢（画面の順）
  static const intervalOptions = [1, 2, 5, 10, 30, 60];
  static const minDistanceOptions = <double>[0, 1, 2, 5, 10, 20];
  static const maxSpeedOptions = <double>[50, 100, 200, 300];
  static const maxAccuracyOptions = <double>[10, 20, 50, 100, 200];

  /// 前の記録からこれ未満の秒数の測位は入れない
  final int intervalSeconds;

  /// 前の記録からこれ未満（m）しか動いていない測位は入れない。0 は「同じ座標だけ捨てる」
  final double minDistance;

  /// 前の記録からこの速さ（km/h）を超えて動いたことになる測位は飛びとして入れない。null は見ない
  final double? maxSpeedKmh;

  /// 精度（m）がこれより悪い測位は入れない。null は見ない
  final double? maxAccuracy;

  TrackRecordingSettings copyWith({
    int? intervalSeconds,
    double? minDistance,
    double? Function()? maxSpeedKmh,
    double? Function()? maxAccuracy,
  }) =>
      TrackRecordingSettings(
        intervalSeconds: intervalSeconds ?? this.intervalSeconds,
        minDistance: minDistance ?? this.minDistance,
        maxSpeedKmh: maxSpeedKmh != null ? maxSpeedKmh() : this.maxSpeedKmh,
        maxAccuracy: maxAccuracy != null ? maxAccuracy() : this.maxAccuracy,
      );

  Map<String, dynamic> toJson() => {
        'intervalSeconds': intervalSeconds,
        'minDistance': minDistance,
        // 「見ない」も残す（キーが無いと既定に戻ってしまう）
        'maxSpeedKmh': maxSpeedKmh ?? 0,
        'maxAccuracy': maxAccuracy ?? 0,
      };

  static TrackRecordingSettings fromJson(Map<dynamic, dynamic> j) {
    double? limit(Object? v, double fallback) {
      if (v is! num) return fallback;
      return v <= 0 ? null : v.toDouble();
    }

    final interval = (j['intervalSeconds'] as num?)?.toInt() ?? 1;
    final distance = (j['minDistance'] as num?)?.toDouble() ?? 0;
    return TrackRecordingSettings(
      intervalSeconds: interval < 1 ? 1 : interval,
      minDistance: distance < 0 ? 0 : distance,
      maxSpeedKmh: limit(j['maxSpeedKmh'], defaultMaxSpeedKmh),
      maxAccuracy: limit(j['maxAccuracy'], defaultMaxAccuracy),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TrackRecordingSettings &&
      other.intervalSeconds == intervalSeconds &&
      other.minDistance == minDistance &&
      other.maxSpeedKmh == maxSpeedKmh &&
      other.maxAccuracy == maxAccuracy;

  @override
  int get hashCode => Object.hash(intervalSeconds, minDistance, maxSpeedKmh, maxAccuracy);
}

/// 測位を軌跡に入れるかの判定の結果
enum TrackFixVerdict {
  accept,

  /// 前の記録から [TrackRecordingSettings.intervalSeconds] 経っていない
  tooSoon,

  /// 前の記録と同じ座標（距離の下限が 0 のとき）
  duplicate,

  /// 前の記録から [TrackRecordingSettings.minDistance] 動いていない
  tooClose,

  /// 精度が [TrackRecordingSettings.maxAccuracy] より悪い
  inaccurate,

  /// 前の記録から [TrackRecordingSettings.maxSpeedKmh] を超える速さで動いたことになる
  jump,
}

/// 届いた測位を軌跡に入れるかを決める（純粋な判定。前の記録は呼ぶ側が持つ）。
///
/// 飛びの判定は「前に記録した点」との比較なので、前の点そのものが飛んでいたと、その後の正しい点がずっと
/// 弾かれてしまう。[maxConsecutiveJumps] 回続けて飛びと判定したら、次は受け入れて基準を移す
class TrackPointFilter {
  TrackPointFilter([this.settings = TrackRecordingSettings.defaults]);

  TrackRecordingSettings settings;

  /// 飛びが何回続いたら受け入れるか
  static const maxConsecutiveJumps = 3;

  /// 止まっていても、これだけ空いたら距離の下限を見ずに 1 点入れる。
  /// 軌跡は 10 分空くと区間を切る（記録と読み出しの両方）ので、立ち止まっているだけで区間が切れないように
  static const keepAlive = Duration(minutes: 5);

  int _jumps = 0;

  /// 飛びが続いている回数（テスト用）
  @visibleForTesting
  int get consecutiveJumps => _jumps;

  /// 新しい区間の始まりなど、前の点と比べない状態に戻す
  void reset() => _jumps = 0;

  /// [position]・[time]・[accuracy] の測位を、前に記録した点（[lastTime]・[lastPosition]、無ければ null）と比べて判定する。
  /// [newSegment] は区間の切れ目（前の点と繋がない）。飛び・距離は見ない
  TrackFixVerdict judge({
    required LatLng position,
    required DateTime time,
    double? accuracy,
    DateTime? lastTime,
    LatLng? lastPosition,
    bool newSegment = false,
  }) {
    final s = settings;
    if (s.maxAccuracy case final max? when accuracy != null && accuracy > max) return TrackFixVerdict.inaccurate;
    if (lastTime == null || lastPosition == null || newSegment) {
      _jumps = 0;
      return TrackFixVerdict.accept;
    }

    final elapsed = time.difference(lastTime);
    if (elapsed.inMilliseconds < s.intervalSeconds * 1000) return TrackFixVerdict.tooSoon;
    if (position == lastPosition) return TrackFixVerdict.duplicate;

    final meters = Geodesic.distance(lastPosition, position);
    if (s.maxSpeedKmh case final max?) {
      final kmh = meters / 1000 / (elapsed.inMilliseconds / 3600000);
      if (kmh > max) {
        if (_jumps < maxConsecutiveJumps) {
          _jumps++;
          return TrackFixVerdict.jump;
        }
        // 飛びが続く: 前の点のほうが飛んでいた（か本当に速く動いた）とみなして受け入れる
      }
    }
    if (meters < s.minDistance && elapsed < keepAlive) return TrackFixVerdict.tooClose;
    _jumps = 0;
    return TrackFixVerdict.accept;
  }
}
