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
// こかげマップ: 地図の PDF 出力の凡例（見えているレイヤ・View・QGIS の描き分けの項目）
import 'package:flutter/painting.dart' show Color;

import '../../models/geometry_type.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/layer_node.dart';
import '../../screens/layer_style_settings_screen.dart';

/// 凡例の 1 行
class MapPdfLegendItem {
  const MapPdfLegendItem({required this.label, this.swatch, this.depth = 0});

  final String label;

  /// 色見本（`QgisSwatchPainter` で描く。描く種類は埋まっている項目で決まる: 面 → 線 → 点）。
  /// null は見出し（QGIS の描き分けのあるレイヤ名）
  final KMetaLayerStyle? swatch;

  /// 字下げの段（View・分類の項目は 1）
  final int depth;

  @override
  String toString() => '${'  ' * depth}$label${swatch == null ? ' (見出し)' : ''}';
}

/// 凡例を作る材料（レイヤ 1 つぶん）。`LayerNode` から [MapPdfLegendLayer.fromLayer] で作る
class MapPdfLegendLayer {
  const MapPdfLegendLayer({required this.name, required this.geometry, this.style, this.views = const []});

  final String name;
  final GeometryType geometry;

  /// レイヤのスタイル（kmeta）
  final KMetaLayerStyle? style;

  /// 見えている View（既定の View だけなら空）。スタイルはレイヤのものと合成済み
  final List<({String name, KMetaLayerStyle? style})> views;

  static MapPdfLegendLayer? fromLayer(LayerNode layer) {
    final geometry = switch (layer) {
      PointLayerNode() => GeometryType.point,
      LineLayerNode() => GeometryType.linestring,
      PolygonLayerNode() => GeometryType.polygon,
      _ => null,
    };
    if (geometry == null) return null;
    final layerStyle = layer.kmetaStyleIfLoaded;
    final views = layer.views;
    final onlyDefault = views.isEmpty || (views.length == 1 && views.first.isDefaultView);
    return MapPdfLegendLayer(
      name: layer.name,
      geometry: geometry,
      style: layerStyle,
      views: onlyDefault
          ? const []
          : [
              for (final v in views)
                if (v.visible) (name: v.displayName, style: v.style == null ? layerStyle : v.style!.mergeWith(layerStyle)),
            ],
    );
  }
}

/// 色の解決（View・レイヤ・アプリ全体の設定の順）。既定は地図と同じ `layerStyleSettings`
typedef MapPdfColorResolver = ({
  Color Function(KMetaLayerStyle? s) point,
  double Function(KMetaLayerStyle? s) pointSize,
  Color Function(KMetaLayerStyle? s) line,
  double Function(KMetaLayerStyle? s) lineWidth,
  Color Function(KMetaLayerStyle? s) fill,
  double Function(KMetaLayerStyle? s) fillOpacity,
  Color Function(KMetaLayerStyle? s) border,
  double Function(KMetaLayerStyle? s) borderOpacity,
});

MapPdfColorResolver get defaultMapPdfColorResolver {
  final s = layerStyleSettings;
  return (
    point: (k) => s.resolveColor(pointColorDef, k),
    pointSize: (k) => s.resolveDouble(pointSizeDef, k),
    line: (k) => s.resolveColor(lineColorDef, k),
    lineWidth: (k) => s.resolveDouble(lineWidthDef, k),
    fill: (k) => s.resolveColor(polygonFillColorDef, k),
    fillOpacity: (k) => s.resolveDouble(polygonFillOpacityDef, k),
    border: (k) => s.resolveColor(polygonBorderColorDef, k),
    borderOpacity: (k) => s.resolveDouble(polygonBorderOpacityDef, k),
  );
}

/// 凡例を組み立てる。
///
/// - 単一シンボルのレイヤは 1 行（種類の見本を地図の色で）
/// - View があれば、レイヤ名の見出しの下に見えている View を 1 行ずつ
/// - QGIS の描き分け（分類・段階・ルール）なら、見出しの下に描く項目だけ（チェックを外した項目は地図に無いので出さない）
List<MapPdfLegendItem> buildMapPdfLegend(Iterable<MapPdfLegendLayer> layers, {MapPdfColorResolver? resolver}) {
  final r = resolver ?? defaultMapPdfColorResolver;

  KMetaLayerStyle swatch(GeometryType g, KMetaLayerStyle? s) => switch (g) {
        GeometryType.point => KMetaLayerStyle(pointColor: r.point(s), pointSize: r.pointSize(s)),
        GeometryType.linestring => KMetaLayerStyle(lineColor: r.line(s), lineWidth: r.lineWidth(s)),
        GeometryType.polygon => KMetaLayerStyle(
            polygonFillColor: r.fill(s),
            polygonFillOpacity: r.fillOpacity(s),
            polygonBorderColor: r.border(s),
            polygonBorderOpacity: r.borderOpacity(s),
          ),
      };

  /// QGIS の描き分けの項目（[base] は項目のシンボルに無い値の受け皿）
  List<MapPdfLegendItem> classes(GeometryType g, KMetaLayerStyle base, int depth) {
    final def = base.qgisRendererDef!;
    return [
      for (final c in def.classes)
        if (c.render)
          MapPdfLegendItem(
            label: c.label.isEmpty ? '—' : c.label,
            swatch: swatch(g, c.style == null ? base : c.style!.mergeWith(base)),
            depth: depth,
          ),
    ];
  }

  final out = <MapPdfLegendItem>[];
  for (final layer in layers) {
    final g = layer.geometry;
    if (layer.views.isNotEmpty) {
      out.add(MapPdfLegendItem(label: layer.name));
      for (final v in layer.views) {
        final s = v.style;
        if (s?.qgisRendererDef != null) {
          out.add(MapPdfLegendItem(label: v.name, depth: 1));
          out.addAll(classes(g, s!, 2));
        } else {
          out.add(MapPdfLegendItem(label: v.name, swatch: swatch(g, s), depth: 1));
        }
      }
      continue;
    }
    final s = layer.style;
    if (s?.qgisRendererDef != null) {
      out.add(MapPdfLegendItem(label: layer.name));
      out.addAll(classes(g, s!, 1));
    } else {
      out.add(MapPdfLegendItem(label: layer.name, swatch: swatch(g, s)));
    }
  }
  return out;
}
