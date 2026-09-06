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
// こかげマップ: 地図の「任意の地点へジャンプ」を一箇所に集める mixin
//
// 起動時の現在位置ジャンプ・ドロワーからのジャンプ・属性テーブルからのジャンプ・
// 画面外インジケータのタップは、すべてここを通す。

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../providers/notification_providers.dart';
import '../map_page_state_base.dart';

mixin MapJumpMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  /// ズーム未指定で地図がまだ無いときに使うズーム（起動時の現在位置ジャンプと同じ）
  static const double defaultJumpZoom = 16.0;

  /// パネル等で隠れている地図の縁。ジャンプ先はこの内側の中心に置く。
  ///
  /// 既定はゼロ。ドロワーを持つ画面側でオーバーライドする。
  /// （ドロワーが開いたまま「現在位置へ」を押すと、ビューポートの中心＝ドロワーの
  /// 真下に着地して見えない、という事故を防ぐ）
  EdgeInsets get jumpObscuredInsets => EdgeInsets.zero;

  /// 任意の地点へ移動する。
  ///
  /// [zoom] 省略時は現在のズームを維持する（地図が未生成なら [defaultJumpZoom]）。
  /// [animate] を false にすると瞬時に移動する。
  /// 着地点は [jumpObscuredInsets] を除いた「見える範囲」の中心に寄せる
  /// （地図が未生成で投影できないときは寄せずに中心へ）。
  ///
  /// Returns: 即座に反映できたら true。地図が未生成で保留された場合は false
  /// （保留分は地図の生成後に実行されるので、呼び出しは失われない）。
  Future<bool> jumpTo(LatLng target, {double? zoom, bool animate = true}) async {
    final attached = mapController.raw != null;
    final currentZoom = attached ? mapController.camera.zoom : null;
    final z = zoom ?? currentZoom ?? defaultJumpZoom;
    final center = attached
        ? _centerForVisibleArea(target, fromZoom: currentZoom!, toZoom: z)
        : target;

    if (!animate || !mapController.isAttached) {
      return mapController.move(center, z);
    }
    await mapController.animateTo(center: center, zoom: z);
    return true;
  }

  /// [target] が「見える範囲」の中心に来るようなカメラ中心を求める。
  ///
  /// 見える範囲の中心 V はビューポート中心 C から
  /// ((left-right)/2, (top-bottom)/2) ずれている。target を V に置くには
  /// カメラ中心を target から (C-V) ぶん画面上でずらした地点にすればよい。
  /// ズームが変わる場合は、いまのズームでの画素数に換算してから投影する
  /// （1画素あたりの距離は 2^(from-to) 倍）。
  LatLng _centerForVisibleArea(
    LatLng target, {
    required double fromZoom,
    required double toZoom,
  }) {
    final o = jumpObscuredInsets;
    if (o == EdgeInsets.zero) return target;
    try {
      final shiftAtTarget = Offset((o.right - o.left) / 2, (o.bottom - o.top) / 2);
      final shiftNow = shiftAtTarget * math.pow(2, fromZoom - toZoom).toDouble();
      final screen = mapController.toScreenLocation(target);
      return mapController.toLngLat(screen + shiftNow);
    } on Object {
      // 投影に失敗したら寄せない（着地はする）
      return target;
    }
  }

  /// 現在位置へ移動する。未取得なら通知して false を返す。
  Future<bool> jumpToCurrentLocation({double? zoom, bool animate = true}) async {
    final loc = currentLocation;
    if (loc == null) {
      ref.read(notificationCenterProvider.notifier).add(
        title: t.map.jump.noLocation,
        level: NotificationLevel.warning,
      );
      return false;
    }
    return jumpTo(loc, zoom: zoom, animate: animate);
  }
}
