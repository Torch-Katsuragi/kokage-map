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
// こかげマップ: QGIS の描き分けの凡例（色見本とラベル）

import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../models/kmeta.dart';
import '../models/qgis_renderer.dart';

/// 分類・段階・ルールの凡例。描かない項目（QGIS でチェックを外したもの）は薄く打ち消し線で出す
class QgisRendererLegend extends StatelessWidget {
  const QgisRendererLegend({super.key, required this.renderer, this.dense = false});

  final QgisRenderer renderer;

  /// レイヤ一覧の行の下に出す小さい版
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = (dense ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium) ?? const TextStyle();
    final swatch = dense ? 12.0 : 16.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (renderer.evaluator == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(t.styleScreen.qgisLegendFallback, style: textStyle.copyWith(color: theme.colorScheme.error)),
          ),
        for (final c in renderer.classes)
          Padding(
            padding: EdgeInsets.symmetric(vertical: dense ? 1 : 2),
            child: Row(
              children: [
                SizedBox(
                  width: swatch,
                  height: swatch,
                  child: CustomPaint(painter: _SwatchPainter(c.style, enabled: c.render)),
                ),
                SizedBox(width: dense ? 6 : 8),
                Expanded(
                  child: Text(
                    c.label.isEmpty ? '—' : c.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: c.render
                        ? textStyle
                        : textStyle.copyWith(
                            color: theme.disabledColor,
                            decoration: TextDecoration.lineThrough,
                          ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.style, {required this.enabled});

  final KMetaLayerStyle? style;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final s = style;
    final dim = enabled ? 1.0 : 0.3;
    if (s == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.grey.withValues(alpha: 0.3 * dim));
      return;
    }
    if (s.polygonFillColor != null || s.polygonBorderColor != null || s.polygonFillOpacity != null) {
      final rect = (Offset.zero & size).deflate(1);
      final fill = s.polygonFillColor ?? Colors.grey;
      canvas.drawRect(rect, Paint()..color = fill.withValues(alpha: (s.polygonFillOpacity ?? 1) * dim));
      final borderOpacity = s.polygonBorderOpacity ?? 1;
      if (borderOpacity > 0) {
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = (s.polygonBorderColor ?? Colors.black).withValues(alpha: borderOpacity * dim),
        );
      }
      return;
    }
    if (s.lineColor != null) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        Paint()
          ..color = s.lineColor!.withValues(alpha: dim)
          ..strokeWidth = (s.lineWidth ?? 2).clamp(1, size.height / 2),
      );
      return;
    }
    canvas.drawCircle(
      size.center(Offset.zero),
      (s.pointSize ?? size.width / 3).clamp(2, size.width / 2),
      Paint()..color = (s.pointColor ?? Colors.grey).withValues(alpha: dim),
    );
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.style != style || old.enabled != enabled;
}
