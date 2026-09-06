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
// こかげマップ: 画面外ターゲットを指す縁インジケータの幾何計算
//
// 地図ウィジェットに依存しない純粋な計算だけを置く（ユニットテスト対象）。

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 縁インジケータの配置結果
class EdgeIndicatorPlacement {
  /// 矢印の中心位置（ビューポート座標）
  final Offset position;

  /// 矢印の向き（ラジアン）。0 = 右向き、正で時計回り（Flutter の画面座標系）
  final double angle;

  const EdgeIndicatorPlacement(this.position, this.angle);

  @override
  String toString() =>
      'EdgeIndicatorPlacement(${position.dx.toStringAsFixed(1)}, '
      '${position.dy.toStringAsFixed(1)}, ${(angle * 180 / math.pi).toStringAsFixed(1)}°)';
}

/// [viewport] の外にある [target] を指す矢印の配置を求める。
///
/// - [target] が見えていれば（[visibleMargin] ぶん広げたビューポートに入っていれば）null
/// - [obscured] はパネル等で隠れている縁の幅。その内側を「見える範囲」として扱い、
///   矢印もその範囲の縁に置く
/// - [inset] は縁から矢印中心までの距離
///
/// 矢印は「見える範囲の中心 → target」の半直線と、[inset] だけ縮めた矩形との交点に置く。
/// これで「矢印の方向へ地図をずらせば target に近づく」が成り立つ。
EdgeIndicatorPlacement? computeEdgeIndicator(
  Size viewport,
  Offset target, {
  double inset = 28,
  double visibleMargin = 0,
  EdgeInsets obscured = EdgeInsets.zero,
}) {
  if (!target.dx.isFinite || !target.dy.isFinite) return null;

  final visible = Rect.fromLTRB(
    obscured.left,
    obscured.top,
    viewport.width - obscured.right,
    viewport.height - obscured.bottom,
  );
  if (visible.width <= 0 || visible.height <= 0) return null;

  // 見えているなら矢印は要らない
  if (visible.inflate(visibleMargin).contains(target)) return null;

  final inner = visible.deflate(inset);
  if (inner.width <= 0 || inner.height <= 0) return null;

  final center = visible.center;
  final d = target - center;
  if (d.distanceSquared == 0) return null;

  // 半直線と inner 矩形の交点: 各軸で縁に届くまでのパラメータ t の小さい方
  final halfW = inner.width / 2;
  final halfH = inner.height / 2;
  final tx = d.dx == 0 ? double.infinity : halfW / d.dx.abs();
  final ty = d.dy == 0 ? double.infinity : halfH / d.dy.abs();
  final t = math.min(tx, ty);

  return EdgeIndicatorPlacement(
    center + d * t,
    math.atan2(d.dy, d.dx),
  );
}
