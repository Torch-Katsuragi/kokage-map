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
/// QGIS 分類レンダラ読み取り専用バナーと、背景地図付き折りたたみスタイルプレビュー
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/settings_schema.dart';
import '../../i18n/strings.g.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/qgis_renderer.dart';
import '../../widgets/qgis_renderer_legend.dart';
import '../../widgets/settings_widgets.dart';
import 'label_style_defs.dart';
import 'symbol_style_defs.dart';

/// QGIS レンダラ種別名を画面用の表示名に変換する
String qgisRendererLabel(String type) => switch (type) {
      'categorizedSymbol' => t.styleScreen.qgisRendererCategorized,
      'graduatedSymbol' => t.styleScreen.qgisRendererGraduated,
      'RuleRenderer' => t.styleScreen.qgisRendererRule,
      _ => type,
    };

/// スタイル画面上部に差し込むカスタムセクション群を構築する
/// （QGIS 分類レンダラ案内バナー・凡例・View 継承説明・背景地図付きプレビュー）
List<Widget> buildStyleHeaderAndPreviewSections({
  required SettingsStore store,
  required bool isGlobalMode,
  required bool isViewMode,
  required LayerNode? targetLayer,
  required String? qgisRenderer,
  required QgisRenderer? qgisRendererDef,
}) =>
    [
      if (qgisRenderer != null)
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(t.styleScreen.qgisStyle(kind: qgisRendererLabel(qgisRenderer))),
          subtitle: Text(t.styleScreen.qgisStyleHint),
        ),
      if (qgisRendererDef != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: QgisRendererLegend(renderer: qgisRendererDef),
        ),
      if (isViewMode)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            t.styleScreen.followingLayer,
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
        ),
      StylePreviewSection(
        store: store,
        isGlobalMode: isGlobalMode,
        targetLayer: targetLayer,
      ),
    ];

/// 背景地図の上に点・線・面・ラベルを重ねて見せる折りたたみプレビューセクション
class StylePreviewSection extends StatelessWidget {
  const StylePreviewSection({
    super.key,
    required this.store,
    required this.isGlobalMode,
    required this.targetLayer,
  });

  final SettingsStore store;
  final bool isGlobalMode;
  final LayerNode? targetLayer;

  @override
  Widget build(BuildContext context) {
    final layer = targetLayer;
    return SettingsSection(
      title: t.styleScreen.preview,
      icon: Icons.preview,
      iconColor: Colors.purple,
      collapsible: true,
      initiallyExpanded: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 120,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'assets/user_guide/gsi_preview.png',
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                  ),
                  CustomPaint(
                    painter: StylePreviewPainter(
                      showPoint: isGlobalMode || layer is PointLayerNode,
                      showLine: isGlobalMode || layer is LineLayerNode,
                      showPolygon: isGlobalMode || layer is PolygonLayerNode,
                      pointColor: store.getColor(pointColorDef),
                      pointOpacity: store.getDouble(pointOpacityDef),
                      pointSize: store.getDouble(pointSizeDef),
                      lineColor: store.getColor(lineColorDef),
                      lineOpacity: store.getDouble(lineOpacityDef),
                      lineWidth: store.getDouble(lineWidthDef),
                      polygonBorderColor: store.getColor(polygonBorderColorDef),
                      polygonBorderWidth: store.getDouble(polygonBorderWidthDef),
                      polygonFillColor: store.getColor(polygonFillColorDef),
                      polygonFillOpacity: store.getDouble(polygonFillOpacityDef),
                      polygonBorderOpacity: store.getDouble(polygonBorderOpacityDef),
                      labelEnabled: store.getBool(labelEnabledDef),
                      labelFontSize: store.getDouble(labelFontSizeDef),
                      labelColor: store.getColor(labelColorDef),
                      labelHaloColor: store.getColor(labelHaloColorDef),
                      labelOpacity: store.getDouble(labelOpacityDef),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// スタイルプレビュー描画 Painter
class StylePreviewPainter extends CustomPainter {
  final bool showPoint;
  final bool showLine;
  final bool showPolygon;
  final Color pointColor;
  final double pointOpacity;
  final double pointSize;
  final Color lineColor;
  final double lineOpacity;
  final double lineWidth;
  final Color polygonBorderColor;
  final double polygonBorderWidth;
  final Color polygonFillColor;
  final double polygonFillOpacity;
  final double polygonBorderOpacity;
  final bool labelEnabled;
  final double labelFontSize;
  final Color labelColor;
  final Color labelHaloColor;
  final double labelOpacity;

  StylePreviewPainter({
    this.showPoint = true,
    this.showLine = true,
    this.showPolygon = true,
    required this.pointColor,
    required this.pointOpacity,
    required this.pointSize,
    required this.lineColor,
    required this.lineOpacity,
    required this.lineWidth,
    required this.polygonBorderColor,
    required this.polygonBorderWidth,
    required this.polygonFillColor,
    required this.polygonFillOpacity,
    required this.polygonBorderOpacity,
    required this.labelEnabled,
    required this.labelFontSize,
    required this.labelColor,
    required this.labelHaloColor,
    required this.labelOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final allThree = showPoint && showLine && showPolygon;
    final polyCx = allThree ? size.width * 0.75 : size.width * 0.5;
    final polyCy = size.height * 0.5;

    // ポリゴン（六角形）
    if (showPolygon) {
      final polygonPath = Path();
      final rx = allThree ? 35.0 : 64.0;
      final ry = allThree ? 35.0 : 42.0;
      for (int i = 0; i < 6; i++) {
        final angle = (i * 60 - 90) * math.pi / 180;
        final x = polyCx + rx * math.cos(angle);
        final y = polyCy + ry * math.sin(angle);
        if (i == 0) {
          polygonPath.moveTo(x, y);
        } else {
          polygonPath.lineTo(x, y);
        }
      }
      polygonPath.close();
      canvas.drawPath(
        polygonPath,
        Paint()
          ..color = polygonFillColor.withValues(alpha: polygonFillOpacity)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        polygonPath,
        Paint()
          ..color = polygonBorderColor.withValues(alpha: polygonBorderOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = polygonBorderWidth,
      );
    }

    // ライン
    if (showLine) {
      final linePath = Path();
      if (allThree) {
        linePath
          ..moveTo(size.width * 0.35, size.height * 0.7)
          ..quadraticBezierTo(
            size.width * 0.5,
            size.height * 0.2,
            size.width * 0.65,
            size.height * 0.5,
          );
      } else {
        linePath
          ..moveTo(size.width * 0.12, size.height * 0.75)
          ..cubicTo(
            size.width * 0.38,
            size.height * 0.15,
            size.width * 0.62,
            size.height * 0.85,
            size.width * 0.88,
            size.height * 0.25,
          );
      }
      canvas.drawPath(
        linePath,
        Paint()
          ..color = lineColor.withValues(alpha: lineOpacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth
          ..strokeCap = StrokeCap.round,
      );
    }

    // ポイント
    if (showPoint) {
      final pointPaint = Paint()
        ..color = pointColor.withValues(alpha: pointOpacity)
        ..style = PaintingStyle.fill;
      if (allThree) {
        canvas.drawCircle(
          Offset(size.width * 0.15, size.height * 0.5),
          pointSize / 2,
          pointPaint,
        );
      } else {
        for (final pos in [
          Offset(size.width * 0.25, size.height * 0.62),
          Offset(size.width * 0.50, size.height * 0.45),
          Offset(size.width * 0.75, size.height * 0.55),
        ]) {
          canvas.drawCircle(pos, pointSize / 2, pointPaint);
        }
      }
    }

    // ラベル
    if (labelEnabled && labelOpacity > 0) {
      final tp = TextPainter(
        text: TextSpan(
          text: 'ABC',
          style: TextStyle(
            fontSize: labelFontSize,
            color: labelColor.withValues(alpha: labelOpacity),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelCx = allThree ? polyCx : size.width * 0.5;
      final labelCy = allThree ? polyCy : size.height * 0.5;
      final origin = Offset(labelCx - tp.width / 2, labelCy - tp.height / 2);
      final box = Rect.fromLTWH(origin.dx - 2, origin.dy - 1, tp.width + 4, tp.height + 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(3)),
        Paint()..color = labelHaloColor.withValues(alpha: 0.85 * labelOpacity),
      );
      tp.paint(canvas, origin);
    }
  }

  @override
  bool shouldRepaint(covariant StylePreviewPainter old) =>
      old.showPoint != showPoint ||
      old.showLine != showLine ||
      old.showPolygon != showPolygon ||
      old.pointColor != pointColor ||
      old.pointOpacity != pointOpacity ||
      old.pointSize != pointSize ||
      old.lineColor != lineColor ||
      old.lineOpacity != lineOpacity ||
      old.lineWidth != lineWidth ||
      old.polygonBorderColor != polygonBorderColor ||
      old.polygonBorderWidth != polygonBorderWidth ||
      old.polygonFillColor != polygonFillColor ||
      old.polygonFillOpacity != polygonFillOpacity ||
      old.polygonBorderOpacity != polygonBorderOpacity ||
      old.labelEnabled != labelEnabled ||
      old.labelFontSize != labelFontSize ||
      old.labelColor != labelColor ||
      old.labelHaloColor != labelHaloColor ||
      old.labelOpacity != labelOpacity;
}
