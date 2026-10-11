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
/// 地点への誘導（「ここへ案内」）の状態
///
/// 目標はメモリにだけ持つ（keepAlive）。裏に回って戻っても残り、アプリを起動し直すと消える。
/// 位置は地図ページが既存の GPS の更新から [Guidance.updatePosition] で流す（自前のタイマーやストリームは持たない）
library;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../utils/navigation_math.dart';
import 'notification_providers.dart';
import 'ui_state_providers.dart';

part 'guidance_providers.g.dart';

/// 案内の行き先
@immutable
class GuidanceTarget {
  const GuidanceTarget({required this.point, required this.label, this.peerUid});

  final LatLng point;

  /// 見出しに出す名前（地物の種類・メンバー名・座標など）
  final String label;

  /// パーティのメンバーへ向かうときの uid（その人が動くと [point] も付いて動く）
  final String? peerUid;

  GuidanceTarget withPoint(LatLng p) => GuidanceTarget(point: p, label: label, peerUid: peerUid);

  @override
  bool operator ==(Object other) =>
      other is GuidanceTarget && other.point == point && other.label == label && other.peerUid == peerUid;

  @override
  int get hashCode => Object.hash(point, label, peerUid);
}

/// 案内の今の状態。位置が入るのは案内している間だけ
@immutable
class GuidanceState {
  const GuidanceState({this.target, this.here, this.accuracy, this.courseDeg, this.arrived = false});

  final GuidanceTarget? target;

  /// 今の位置（取れていなければ null）
  final LatLng? here;

  /// GPS の精度（m）
  final double? accuracy;

  /// 進行方向（真北から時計回りの度。歩いているときだけ）
  final double? courseDeg;

  /// 到着の半径に入った（通知済み）
  final bool arrived;

  bool get active => target != null;

  /// 目標までの距離（m）
  double? get distance {
    final h = here, t = target;
    return h == null || t == null ? null : NavigationMath.distanceMeters(h, t.point);
  }

  /// 目標の方位（真北から時計回りの度）
  double? get bearing {
    final h = here, t = target;
    return h == null || t == null ? null : NavigationMath.bearingDeg(h, t.point);
  }

  GuidanceState copyWith({GuidanceTarget? target, LatLng? here, double? accuracy, double? courseDeg, bool? arrived}) =>
      GuidanceState(
        target: target ?? this.target,
        here: here ?? this.here,
        accuracy: accuracy ?? this.accuracy,
        courseDeg: courseDeg ?? this.courseDeg,
        arrived: arrived ?? this.arrived,
      );
}

@Riverpod(keepAlive: true)
class Guidance extends _$Guidance {
  // 案内していない間も最後の位置だけは覚えておく（「いちばん近い頂点」を選ぶとき・始めた瞬間の表示に使う）
  LatLng? _here;
  double? _accuracy;
  double? _course;

  /// 最後に届いた位置（案内していなくても）
  LatLng? get lastPosition => _here;

  @override
  GuidanceState build() => const GuidanceState();

  /// [target] へ案内を始める（案内中なら行き先を差し替える）
  void start(GuidanceTarget target) {
    final wasActive = state.active;
    state = GuidanceState(target: target, here: _here, accuracy: _accuracy, courseDeg: _course);
    if (!wasActive) ref.read(mapFlashProvider.notifier).show(t.guidance.flashStart);
    _checkArrival();
  }

  /// 案内をやめる
  void stop() {
    if (!state.active) return;
    state = const GuidanceState();
    ref.read(mapFlashProvider.notifier).show(t.guidance.flashStop);
  }

  /// GPS の更新ごとに地図ページが呼ぶ。案内していなければ覚えるだけ
  void updatePosition(LatLng here, {double? accuracy, double? courseDeg}) {
    _here = here;
    _accuracy = accuracy;
    _course = courseDeg;
    if (!state.active) return;
    if (state.here == here && state.accuracy == accuracy && state.courseDeg == courseDeg) return;
    state = GuidanceState(
      target: state.target,
      here: here,
      accuracy: accuracy,
      courseDeg: courseDeg,
      arrived: state.arrived,
    );
    _checkArrival();
  }

  /// 行き先の位置だけ動かす（パーティのメンバーが動いたとき）
  void moveTarget(LatLng point) {
    final t0 = state.target;
    if (t0 == null || t0.point == point) return;
    state = state.copyWith(target: t0.withPoint(point));
    _checkArrival();
  }

  void _checkArrival() {
    final d = state.distance;
    if (d == null) return;
    if (!state.arrived && NavigationMath.isArrived(d, state.accuracy)) {
      state = state.copyWith(arrived: true);
      ref.read(notificationCenterProvider.notifier).add(
            title: t.guidance.arrived(name: state.target!.label),
            detail: t.guidance.arrivedDetail(
              distance: d.toStringAsFixed(1),
              radius: NavigationMath.arrivalRadius(state.accuracy).toStringAsFixed(0),
            ),
            level: NotificationLevel.success,
          );
    } else if (state.arrived && NavigationMath.shouldRearm(d, state.accuracy)) {
      state = state.copyWith(arrived: false);
    }
  }
}
