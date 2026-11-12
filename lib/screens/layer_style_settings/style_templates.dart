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
/// ワンタップで縁取り・破線・ハッチング等を設定できるスタイルテンプレート定義と選択 UI
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/settings_schema.dart';
import '../../core/terrain/fill_pattern_painter.dart';
import '../../i18n/strings.g.dart';
import '../../models/geometry_type.dart';
import '../../models/qgis_symbol.dart';
import '../../widgets/settings_widgets.dart';
import 'symbol_style_defs.dart';

/// 点・線・面のスタイルテンプレート基底クラス
sealed class StyleTemplate {
  const StyleTemplate({
    required this.id,
    required this.geometryType,
    required this.labelBuilder,
  });

  final String id;
  final GeometryType geometryType;
  final String Function() labelBuilder;

  String get label => labelBuilder();

  /// [store] にテンプレートの各プロパティを書き込む
  Future<void> applyToStore(SettingsStore store);

  /// 現在の [store] の値がこのテンプレートと一致するか
  bool matchesStore(SettingsStore store);
}

bool _close(double a, double b) => (a - b).abs() < 1e-4;

/// 点レイヤ用のスタイルテンプレート
final class PointStyleTemplate extends StyleTemplate {
  const PointStyleTemplate({
    required super.id,
    required super.labelBuilder,
    required this.shape,
    required this.size,
    required this.color,
    this.opacity = 1.0,
    this.outlineEnabled = true,
    this.outlineColor = const Color(0xFFFFFFFF),
    this.outlineWidth = 1.5,
  }) : super(geometryType: GeometryType.point);

  final PointMarkerShape shape;
  final double size;
  final Color color;
  final double opacity;
  final bool outlineEnabled;
  final Color outlineColor;
  final double outlineWidth;

  @override
  Future<void> applyToStore(SettingsStore store) async {
    await store.setString(pointShapeDef, shape.id);
    await store.setDouble(pointSizeDef, size);
    await store.setColor(pointColorDef, color);
    await store.setDouble(pointOpacityDef, opacity);
    await store.setBool(pointOutlineEnabledDef, outlineEnabled);
    await store.setColor(pointOutlineColorDef, outlineColor);
    await store.setDouble(pointOutlineWidthDef, outlineWidth);
  }

  @override
  bool matchesStore(SettingsStore store) {
    final curOutline = store.getBool(pointOutlineEnabledDef);
    if (PointMarkerShape.fromId(store.getString(pointShapeDef)) != shape) return false;
    if (!_close(store.getDouble(pointSizeDef), size)) return false;
    if (store.getColor(pointColorDef).toARGB32() != color.toARGB32()) return false;
    if (!_close(store.getDouble(pointOpacityDef), opacity)) return false;
    if (curOutline != outlineEnabled) return false;
    if (outlineEnabled) {
      if (store.getColor(pointOutlineColorDef).toARGB32() != outlineColor.toARGB32()) return false;
      if (!_close(store.getDouble(pointOutlineWidthDef), outlineWidth)) return false;
    }
    return true;
  }
}

/// 線レイヤ用のスタイルテンプレート
final class LineStyleTemplate extends StyleTemplate {
  const LineStyleTemplate({
    required super.id,
    required super.labelBuilder,
    required this.dash,
    required this.width,
    required this.color,
    this.opacity = 1.0,
    this.casingEnabled = false,
    this.casingColor = const Color(0xFFFFFFFF),
    this.casingWidth = 2.0,
  }) : super(geometryType: GeometryType.linestring);

  final LineDashPattern dash;
  final double width;
  final Color color;
  final double opacity;
  final bool casingEnabled;
  final Color casingColor;
  final double casingWidth;

  @override
  Future<void> applyToStore(SettingsStore store) async {
    await store.setString(lineDashDef, dash.id);
    await store.setDouble(lineWidthDef, width);
    await store.setColor(lineColorDef, color);
    await store.setDouble(lineOpacityDef, opacity);
    await store.setBool(lineCasingEnabledDef, casingEnabled);
    await store.setColor(lineCasingColorDef, casingColor);
    await store.setDouble(lineCasingWidthDef, casingWidth);
  }

  @override
  bool matchesStore(SettingsStore store) {
    final curCasing = store.getBool(lineCasingEnabledDef);
    if (LineDashPattern.fromId(store.getString(lineDashDef)) != dash) return false;
    if (!_close(store.getDouble(lineWidthDef), width)) return false;
    if (store.getColor(lineColorDef).toARGB32() != color.toARGB32()) return false;
    if (!_close(store.getDouble(lineOpacityDef), opacity)) return false;
    if (curCasing != casingEnabled) return false;
    if (casingEnabled) {
      if (store.getColor(lineCasingColorDef).toARGB32() != casingColor.toARGB32()) return false;
      if (!_close(store.getDouble(lineCasingWidthDef), casingWidth)) return false;
    }
    return true;
  }
}

/// 面レイヤ用のスタイルテンプレート
final class PolygonStyleTemplate extends StyleTemplate {
  const PolygonStyleTemplate({
    required super.id,
    required super.labelBuilder,
    required this.fillPattern,
    required this.fillColor,
    required this.fillOpacity,
    this.patternSpacing = 8.0,
    required this.borderWidth,
    this.borderDash = LineDashPattern.solid,
    required this.borderColor,
    this.borderOpacity = 1.0,
    this.borderCasingEnabled = false,
    this.borderCasingColor = const Color(0xFFFFFFFF),
    this.borderCasingWidth = 2.0,
  }) : super(geometryType: GeometryType.polygon);

  final PolygonFillPattern fillPattern;
  final Color fillColor;
  final double fillOpacity;
  final double patternSpacing;
  final double borderWidth;
  final LineDashPattern borderDash;
  final Color borderColor;
  final double borderOpacity;
  final bool borderCasingEnabled;
  final Color borderCasingColor;
  final double borderCasingWidth;

  @override
  Future<void> applyToStore(SettingsStore store) async {
    await store.setString(polygonFillPatternDef, fillPattern.id);
    await store.setColor(polygonFillColorDef, fillColor);
    await store.setDouble(polygonFillOpacityDef, fillOpacity);
    await store.setDouble(polygonPatternSpacingDef, patternSpacing);
    await store.setDouble(polygonBorderWidthDef, borderWidth);
    await store.setString(polygonBorderDashDef, borderDash.id);
    await store.setColor(polygonBorderColorDef, borderColor);
    await store.setDouble(polygonBorderOpacityDef, borderOpacity);
    await store.setBool(polygonBorderCasingEnabledDef, borderCasingEnabled);
    await store.setColor(polygonBorderCasingColorDef, borderCasingColor);
    await store.setDouble(polygonBorderCasingWidthDef, borderCasingWidth);
  }

  @override
  bool matchesStore(SettingsStore store) {
    if (PolygonFillPattern.fromId(store.getString(polygonFillPatternDef)) != fillPattern) return false;
    if (fillPattern != PolygonFillPattern.none) {
      if (store.getColor(polygonFillColorDef).toARGB32() != fillColor.toARGB32()) return false;
      if (!_close(store.getDouble(polygonFillOpacityDef), fillOpacity)) return false;
    }
    if (fillPattern.isHatchOrDots && !_close(store.getDouble(polygonPatternSpacingDef), patternSpacing)) {
      return false;
    }
    if (!_close(store.getDouble(polygonBorderWidthDef), borderWidth)) return false;
    if (borderWidth > 0) {
      if (LineDashPattern.fromId(store.getString(polygonBorderDashDef)) != borderDash) return false;
      if (store.getColor(polygonBorderColorDef).toARGB32() != borderColor.toARGB32()) return false;
      if (!_close(store.getDouble(polygonBorderOpacityDef), borderOpacity)) return false;
      final curCasing = store.getBool(polygonBorderCasingEnabledDef);
      if (curCasing != borderCasingEnabled) return false;
      if (borderCasingEnabled) {
        if (store.getColor(polygonBorderCasingColorDef).toARGB32() != borderCasingColor.toARGB32()) return false;
        if (!_close(store.getDouble(polygonBorderCasingWidthDef), borderCasingWidth)) return false;
      }
    }
    return true;
  }
}

/// 点レイヤ用の組み込みテンプレート一覧
final List<PointStyleTemplate> pointStyleTemplates = [
  PointStyleTemplate(
    id: 'point_standard',
    labelBuilder: () => t.styleScreen.templatePointStandard,
    shape: PointMarkerShape.circle,
    size: 6.0,
    color: const Color(0xFFF44336),
    outlineWidth: 1.5,
  ),
  PointStyleTemplate(
    id: 'point_survey',
    labelBuilder: () => t.styleScreen.templatePointSurvey,
    shape: PointMarkerShape.triangle,
    size: 8.0,
    color: const Color(0xFFE53935),
    outlineWidth: 2.0,
  ),
  PointStyleTemplate(
    id: 'point_star',
    labelBuilder: () => t.styleScreen.templatePointStar,
    shape: PointMarkerShape.star,
    size: 9.0,
    color: const Color(0xFFFFB300),
    outlineColor: const Color(0xFF3E2723),
    outlineWidth: 1.5,
  ),
  PointStyleTemplate(
    id: 'point_facility',
    labelBuilder: () => t.styleScreen.templatePointFacility,
    shape: PointMarkerShape.square,
    size: 7.0,
    color: const Color(0xFF1E88E5),
    outlineWidth: 1.5,
  ),
  PointStyleTemplate(
    id: 'point_tree',
    labelBuilder: () => t.styleScreen.templatePointTree,
    shape: PointMarkerShape.diamond,
    size: 7.0,
    color: const Color(0xFF2E7D32),
    outlineWidth: 1.5,
  ),
  PointStyleTemplate(
    id: 'point_hazard',
    labelBuilder: () => t.styleScreen.templatePointHazard,
    shape: PointMarkerShape.cross2,
    size: 8.0,
    color: const Color(0xFFD32F2F),
    outlineWidth: 2.0,
  ),
];

/// 線レイヤ用の組み込みテンプレート一覧
final List<LineStyleTemplate> lineStyleTemplates = [
  LineStyleTemplate(
    id: 'line_standard',
    labelBuilder: () => t.styleScreen.templateLineStandard,
    dash: LineDashPattern.solid,
    width: 3.0,
    color: const Color(0xFF4CAF50),
  ),
  LineStyleTemplate(
    id: 'line_road_cased',
    labelBuilder: () => t.styleScreen.templateLineRoadCased,
    dash: LineDashPattern.solid,
    width: 4.0,
    color: const Color(0xFFEF6C00),
    casingEnabled: true,
    casingColor: const Color(0xFFFFFFFF),
    casingWidth: 2.5,
  ),
  LineStyleTemplate(
    id: 'line_arterial',
    labelBuilder: () => t.styleScreen.templateLineArterial,
    dash: LineDashPattern.solid,
    width: 4.0,
    color: const Color(0xFFFDD835),
    casingEnabled: true,
    casingColor: const Color(0xFF212121),
    casingWidth: 2.0,
  ),
  LineStyleTemplate(
    id: 'line_trail_dashed',
    labelBuilder: () => t.styleScreen.templateLineTrailDashed,
    dash: LineDashPattern.dash,
    width: 3.0,
    color: const Color(0xFF6D4C41),
    casingEnabled: true,
    casingColor: const Color(0xFFFFFFFF),
    casingWidth: 2.0,
  ),
  LineStyleTemplate(
    id: 'line_boundary',
    labelBuilder: () => t.styleScreen.templateLineBoundary,
    dash: LineDashPattern.dashDot,
    width: 2.0,
    color: const Color(0xFFE53935),
    casingEnabled: true,
    casingColor: const Color(0xFFFFFFFF),
    casingWidth: 1.5,
  ),
  LineStyleTemplate(
    id: 'line_stream',
    labelBuilder: () => t.styleScreen.templateLineStream,
    dash: LineDashPattern.solid,
    width: 3.0,
    color: const Color(0xFF0288D1),
    casingEnabled: true,
    casingColor: const Color(0xFFFFFFFF),
    casingWidth: 2.0,
  ),
];

/// 面レイヤ用の組み込みテンプレート一覧
final List<PolygonStyleTemplate> polygonStyleTemplates = [
  PolygonStyleTemplate(
    id: 'poly_standard',
    labelBuilder: () => t.styleScreen.templatePolyStandard,
    fillPattern: PolygonFillPattern.solid,
    fillColor: const Color(0xFF2E7D32),
    fillOpacity: 0.2,
    borderWidth: 2.0,
    borderColor: const Color(0xFF1B5E20),
  ),
  PolygonStyleTemplate(
    id: 'poly_hollow_cased',
    labelBuilder: () => t.styleScreen.templatePolyHollowCased,
    fillPattern: PolygonFillPattern.none,
    fillColor: const Color(0xFFE53935),
    fillOpacity: 0.2,
    borderWidth: 2.5,
    borderColor: const Color(0xFFE53935),
    borderCasingEnabled: true,
    borderCasingColor: const Color(0xFFFFFFFF),
    borderCasingWidth: 2.0,
  ),
  PolygonStyleTemplate(
    id: 'poly_slash_work',
    labelBuilder: () => t.styleScreen.templatePolySlashWork,
    fillPattern: PolygonFillPattern.slash,
    fillColor: const Color(0xFF1976D2),
    fillOpacity: 0.7,
    patternSpacing: 10.0,
    borderWidth: 2.0,
    borderColor: const Color(0xFF0D47A1),
  ),
  PolygonStyleTemplate(
    id: 'poly_cross_hazard',
    labelBuilder: () => t.styleScreen.templatePolyCrossHazard,
    fillPattern: PolygonFillPattern.cross,
    fillColor: const Color(0xFFD32F2F),
    fillOpacity: 0.8,
    patternSpacing: 10.0,
    borderWidth: 2.0,
    borderColor: const Color(0xFFB71C1C),
    borderCasingEnabled: true,
    borderCasingColor: const Color(0xFFFFFFFF),
    borderCasingWidth: 1.5,
  ),
  PolygonStyleTemplate(
    id: 'poly_backslash_plan',
    labelBuilder: () => t.styleScreen.templatePolyBackslashPlan,
    fillPattern: PolygonFillPattern.backslash,
    fillColor: const Color(0xFFEF6C00),
    fillOpacity: 0.7,
    patternSpacing: 10.0,
    borderWidth: 2.0,
    borderDash: LineDashPattern.dash,
    borderColor: const Color(0xFFE65100),
  ),
  PolygonStyleTemplate(
    id: 'poly_dots_zone',
    labelBuilder: () => t.styleScreen.templatePolyDotsZone,
    fillPattern: PolygonFillPattern.dots,
    fillColor: const Color(0xFF388E3C),
    fillOpacity: 0.7,
    patternSpacing: 8.0,
    borderWidth: 1.5,
    borderColor: const Color(0xFF2E7D32),
  ),
  PolygonStyleTemplate(
    id: 'poly_grid_area',
    labelBuilder: () => t.styleScreen.templatePolyGridArea,
    fillPattern: PolygonFillPattern.grid,
    fillColor: const Color(0xFF5E35B1),
    fillOpacity: 0.7,
    patternSpacing: 10.0,
    borderWidth: 2.0,
    borderColor: const Color(0xFF4527A0),
  ),
];

/// 指定ジオメトリ種別のスタイルテンプレート一覧を返す
List<StyleTemplate> styleTemplatesFor(GeometryType geometryType) => switch (geometryType) {
      GeometryType.point => pointStyleTemplates,
      GeometryType.linestring => lineStyleTemplates,
      GeometryType.polygon => polygonStyleTemplates,
    };

/// スタイル画面に表示するスタイルテンプレート選択セクション
class StyleTemplateSection extends StatelessWidget {
  const StyleTemplateSection({
    super.key,
    required this.geometryType,
    required this.store,
    required this.hasCustomSymbolLayers,
    required this.onSelect,
  });

  final GeometryType geometryType;
  final SettingsStore store;
  final bool hasCustomSymbolLayers;
  final ValueChanged<StyleTemplate> onSelect;

  @override
  Widget build(BuildContext context) {
    final templates = styleTemplatesFor(geometryType);
    final scheme = Theme.of(context).colorScheme;
    return SettingsSection(
      title: t.styleScreen.templates,
      icon: Icons.palette_outlined,
      iconColor: Colors.teal,
      collapsible: true,
      initiallyExpanded: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tpl in templates)
                _TemplateChip(
                  key: ValueKey('style_template_${tpl.id}'),
                  template: tpl,
                  selected: !hasCustomSymbolLayers && tpl.matchesStore(store),
                  colorScheme: scheme,
                  onTap: () => onSelect(tpl),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TemplateChip extends StatelessWidget {
  const _TemplateChip({
    super.key,
    required this.template,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  final StyleTemplate template;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? colorScheme.primaryContainer.withValues(alpha: 0.55) : colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? colorScheme.primary : colorScheme.outlineVariant,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 24,
                decoration: BoxDecoration(
                  // 白縁取り（#FFFFFF）も見分けやすい淡い地図地色
                  color: const Color(0xFFDCE3D6),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.black12, width: 0.5),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3.5),
                  child: CustomPaint(
                    painter: _TemplateSwatchPainter(template),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                template.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TemplateSwatchPainter extends CustomPainter {
  const _TemplateSwatchPainter(this.template);

  final StyleTemplate template;

  @override
  void paint(Canvas canvas, Size size) {
    switch (template) {
      case final PointStyleTemplate p:
        drawPointOrSvgMarker(
          canvas,
          Offset(size.width / 2, size.height / 2),
          math.min(p.size, 7.5),
          shape: p.shape,
          fillColor: p.color.withValues(alpha: p.opacity),
          outlineColor: p.outlineColor.withValues(alpha: p.opacity),
          outlineWidth: p.outlineEnabled ? p.outlineWidth : 0,
        );
      case final LineStyleTemplate l:
        final path = Path()
          ..moveTo(3, size.height - 5)
          ..quadraticBezierTo(size.width * 0.45, 4, size.width - 3, size.height * 0.45);
        final strokes = buildEffectiveLineStrokes(
          lineColor: l.color.withValues(alpha: l.opacity),
          lineWidth: math.min(l.width, 3.5),
          dash: l.dash,
          casingEnabled: l.casingEnabled,
          casingColor: l.casingColor,
          casingWidth: math.min(l.casingWidth, 2.0),
        );
        drawLineStrokeLayers(canvas, path, strokes);
      case final PolygonStyleTemplate g:
        final rect = Rect.fromLTWH(4, 3, size.width - 8, size.height - 6);
        final path = Path()..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(2)));
        final fills = buildEffectivePolygonFills(
          fillColor: g.fillColor.withValues(alpha: g.fillOpacity),
          pattern: g.fillPattern,
          spacingPx: math.min(g.patternSpacing, 7.0),
        );
        drawPolygonFillLayers(canvas, path, fills);
        if (g.borderWidth > 0 && g.borderOpacity > 0) {
          final borderStrokes = buildEffectiveLineStrokes(
            lineColor: g.borderColor.withValues(alpha: g.borderOpacity),
            lineWidth: math.min(g.borderWidth, 2.0),
            dash: g.borderDash,
            casingEnabled: g.borderCasingEnabled,
            casingColor: g.borderCasingColor,
            casingWidth: math.min(g.borderCasingWidth, 1.5),
          );
          drawLineStrokeLayers(canvas, path, borderStrokes);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _TemplateSwatchPainter old) => old.template.id != template.id;
}
