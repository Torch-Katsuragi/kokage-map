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

import '../core/terrain/fill_pattern_painter.dart';
import '../core/terrain/svg_marker_atlas.dart';
import '../i18n/strings.g.dart';
import '../models/kmeta.dart';
import '../models/qgis_renderer.dart';

/// 分類・段階・ルールの凡例。描かない項目（QGIS でチェックを外したもの）は薄く打ち消し線で出す
class QgisRendererLegend extends StatelessWidget {
  const QgisRendererLegend({super.key, required this.renderer, this.dense = false, this.maxItems});

  final QgisRenderer renderer;

  /// レイヤ一覧の行の下に出す小さい版
  final bool dense;

  /// これより多い項目は「…ほか N 件」に畳む（レイヤ一覧が凡例で埋まらないように）
  final int? maxItems;

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
        for (final c in renderer.classes.take(_shown))
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
        if (_shown < renderer.classes.length)
          Text('… +${renderer.classes.length - _shown}', style: textStyle.copyWith(color: theme.hintColor)),
      ],
    );
  }

  int get _shown {
    final max = maxItems;
    final n = renderer.classes.length;
    // 1 件だけ畳むなら畳まずに出す
    return max == null || n <= max + 1 ? n : max;
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.style, {required this.enabled})
      : super(repaint: SvgMarkerCache.instance.revision);

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
    final sl = s.symbolLayers;
    if (s.polygonFillColor != null ||
        s.polygonBorderColor != null ||
        s.polygonFillOpacity != null ||
        s.polygonFillPattern != null ||
        (sl != null && (sl.fills.isNotEmpty || sl.outlineStrokes.isNotEmpty))) {
      final rect = (Offset.zero & size).deflate(1);
      final path = Path()..addRect(rect);
      final fillCol = (s.polygonFillColor ?? Colors.grey).withValues(alpha: (s.polygonFillOpacity ?? 1) * dim);
      final fills = buildEffectivePolygonFills(
        fillColor: fillCol,
        pattern: PolygonFillPattern.fromId(s.polygonFillPattern),
        spacingPx: (s.polygonPatternSpacing ?? 6.0).clamp(3.0, 8.0),
        lineWidthPx: (s.polygonPatternLineWidth ?? 1.2).clamp(0.8, 2.0),
        symbolLayers: sl,
      );
      canvas.save();
      canvas.clipRect(rect);
      drawPolygonFillLayers(
        canvas,
        path,
        [
          for (final f in fills)
            switch (f.kind) {
              FillLayerKind.solid => f.withOpacityFactor(dim),
              FillLayerKind.linePattern => ResolvedFillLayer.linePattern(
                  color: f.color.withValues(alpha: f.color.a * dim),
                  angleDeg: f.angleDeg,
                  spacingPx: f.spacingPx.clamp(3.0, 8.0),
                  lineWidthPx: f.lineWidthPx.clamp(0.8, 2.0),
                  offsetPx: f.offsetPx,
                  dashArray: f.dashArray,
                ),
              FillLayerKind.pointPattern => ResolvedFillLayer.pointPattern(
                  color: f.color.withValues(alpha: f.color.a * dim),
                  dxPx: f.dxPx.clamp(3.0, 8.0),
                  dyPx: f.dyPx.clamp(3.0, 8.0),
                  pointRadiusPx: f.pointRadiusPx.clamp(0.8, 2.0),
                  pointShape: f.pointShape,
                  pointSvgContent: f.pointSvgContent,
                ),
            },
        ],
      );
      canvas.restore();
      final borderOpacity = s.polygonBorderOpacity ?? 1;
      if (borderOpacity > 0 && (s.polygonBorderWidth ?? 1) > 0) {
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
    if (s.lineColor != null || (sl != null && sl.strokes.isNotEmpty)) {
      final path = Path()
        ..moveTo(0, size.height / 2)
        ..lineTo(size.width, size.height / 2);
      final strokes = buildEffectiveLineStrokes(
        lineColor: (s.lineColor ?? Colors.blue).withValues(alpha: (s.lineOpacity ?? 1) * dim),
        lineWidth: (s.lineWidth ?? 2).clamp(1, size.height * 0.45),
        dash: LineDashPattern.fromId(s.lineDash),
        casingEnabled: s.lineCasingEnabled ?? false,
        casingColor: (s.lineCasingColor ?? Colors.white).withValues(alpha: dim),
        casingWidth: (s.lineCasingWidth ?? 1.5).clamp(0.5, 2.0),
        symbolLayers: sl,
      );
      drawLineStrokeLayers(
        canvas,
        path,
        [
          for (final st in strokes)
            ResolvedLineStroke(
              color: st.color.withValues(alpha: st.color.a * dim),
              widthPx: st.widthPx.clamp(1.0, size.height * 0.7),
              dashArray: st.dashArray == null ? null : [for (final d in st.dashArray!) (d * 0.5).clamp(1.5, 6.0)],
            ),
        ],
      );
      return;
    }
    final marker = (sl != null && sl.markers.isNotEmpty) ? sl.markers.last : null;
    final shape = marker?.shape ?? PointMarkerShape.fromId(s.pointShape);
    final fillCol = (marker?.color ?? s.pointColor ?? Colors.grey).withValues(alpha: (s.pointOpacity ?? 1) * dim);
    final outOn = s.pointOutlineEnabled ?? true;
    final outW = marker != null ? marker.outlineWidthPx.clamp(0.0, 1.5) : (outOn ? 1.0 : 0.0);
    final outCol = (marker?.outlineColor ?? s.pointOutlineColor ?? Colors.white).withValues(alpha: dim);
    drawPointOrSvgMarker(
      canvas,
      size.center(Offset.zero),
      (s.pointSize ?? size.width / 3).clamp(2.5, size.width / 2 - 1),
      svgContent: marker?.svgContent,
      shape: shape,
      fillColor: fillCol,
      outlineColor: outCol,
      outlineWidth: outW,
      angleDeg: marker?.angleDeg ?? s.pointAngle ?? 0.0,
      opacity: dim,
    );
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.style != style || old.enabled != enabled;
}
