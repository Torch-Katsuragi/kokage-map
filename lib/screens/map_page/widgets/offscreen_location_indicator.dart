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
// こかげマップ: 画面外にある現在位置の方向を地図の縁に示す矢印
//
// 現在位置が見えていないときだけ、ビューポートの縁に小さな三角矢印を出す。
// 矢印の方向へ地図をずらせば現在位置に戻れる。タップで直接ジャンプ。

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../../core/constants.dart';
import '../../../core/r_map_controller.dart';
import '../../../utils/edge_indicator_geometry.dart';

class OffscreenLocationIndicator extends StatelessWidget {
  /// 指し示す地点。null なら何も描かない
  final LatLng? location;

  final RMapController mapController;

  /// カメラが動いたことを知らせる Listenable（毎フレーム再計算するため）
  final Listenable repaint;

  /// 矢印タップ時の処理（現在位置へのジャンプ）
  final VoidCallback onTap;

  /// パネル等で隠れている縁。その内側を「見える範囲」として扱う
  final EdgeInsets obscured;

  /// アクセシビリティ用ラベル
  final String? semanticsLabel;

  /// 3D 中の投影（地形の高さで持ち上げた画面座標）。null を返したら MapLibre の投影
  final Offset? Function(LatLng)? project;

  const OffscreenLocationIndicator({
    super.key,
    required this.location,
    required this.mapController,
    required this.repaint,
    required this.onTap,
    this.obscured = EdgeInsets.zero,
    this.semanticsLabel,
    this.project,
  });

  /// 縁から矢印中心までの距離
  static const double _inset = 30;

  /// 現在位置マーカーの半径ぶん。ここまでは「見えている」扱い
  static const double _visibleMargin = 32;

  /// タップ領域の一辺
  static const double _hitSize = 48;

  /// 矢印本体の一辺
  static const double _arrowSize = 26;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ListenableBuilder(
          listenable: repaint,
          builder: (context, _) {
            final placement = _placement(constraints.biggest);
            if (placement == null) return const SizedBox.shrink();

            return Stack(
              children: [
                Positioned(
                  left: placement.position.dx - _hitSize / 2,
                  top: placement.position.dy - _hitSize / 2,
                  width: _hitSize,
                  height: _hitSize,
                  child: Semantics(
                    button: true,
                    label: semanticsLabel,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onTap,
                      child: Center(
                        child: Transform.rotate(
                          angle: placement.angle,
                          child: const CustomPaint(
                            size: Size.square(_arrowSize),
                            painter: _ArrowPainter(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  EdgeIndicatorPlacement? _placement(Size viewport) {
    final loc = location;
    if (loc == null) return null;
    Offset? screen = project?.call(loc);
    if (screen == null) {
      // raw が無い間（スタイル読込前・3D 中）は toScreenLocation が使えない
      if (mapController.raw == null) return null;
      try {
        screen = mapController.toScreenLocation(loc);
      } on Object {
        return null;
      }
    }

    return computeEdgeIndicator(
      viewport,
      screen,
      inset: _inset,
      visibleMargin: _visibleMargin,
      obscured: obscured,
    );
  }
}

/// 右向き（+x）の三角矢印。回転は呼び出し側の Transform.rotate で行う
class _ArrowPainter extends CustomPainter {
  const _ArrowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 先端を右に、根元に浅い切り込みを入れた矢じり形
    final path = Path()
      ..moveTo(w, h / 2)
      ..lineTo(w * 0.12, h * 0.06)
      ..lineTo(w * 0.36, h / 2)
      ..lineTo(w * 0.12, h * 0.94)
      ..close();

    canvas.drawShadow(path, Colors.black, 3, false);
    canvas.drawPath(
      path,
      Paint()
        ..color = MapColors.currentLocation
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter oldDelegate) => false;
}
