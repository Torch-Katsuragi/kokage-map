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
import 'dart:math';

import 'package:flutter/material.dart';

/// コンパス方向を示す扇形を描画するCustomPainter
class CompassFanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = Colors.lightBlue.withValues(alpha: 0.3)
          ..style = PaintingStyle.fill;

    final strokePaint =
        Paint()
          ..color = Colors.lightBlue.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // 扇形の角度（60度の扇形）
    const sweepAngle = 60 * pi / 180; // 60度をラジアンに変換
    const startAngle = -sweepAngle / 2; // 中心から左右30度ずつ

    // 扇形のパスを作成
    final path = Path();
    path.moveTo(center.dx, center.dy); // 中心から開始
    path.arcTo(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
    );
    path.close();

    // 扇形を描画
    canvas.drawPath(path, paint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
