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
// こかげマップ: `.qgs` の `<renderer-v2>` とシンボルを読む
//
// 単一シンボルは `QgsImporter.readStyle` が [QgsSymbolReader.read] で読む。
// 分類（categorizedSymbol）・段階（graduatedSymbol）・ルール（RuleRenderer）は
// [QgsRendererReader.read] が [QgisRenderer] にする。どちらも読むだけで、`.qgs` は書き換えない。

import 'package:flutter/material.dart' show Color;
import 'package:xml/xml.dart';

import '../../models/kmeta.dart';
import '../../models/qgis_renderer.dart';

/// px ⇄ mm（QGISのシンボル単位はMM）。96dpi 相当。[[qgs_writer]] の逆。
const double kQgsMmToPx = 96 / 25.4;

/// `<symbol>` → 見た目
abstract final class QgsSymbolReader {
  /// [symbol] の見た目。[opacity] はレイヤの不透明度（`<layerOpacity>`）。読めない形なら null。
  ///
  /// > [!NOTE] 拾うのはシンボルレイヤ 1 枚ぶん
  /// > 面は SimpleFill（無ければ輪郭だけの SimpleLine）、線は SimpleLine、点は SimpleMarker を優先し、
  /// > 無ければ先頭のレイヤ。重ね合わせ・破線・点の形は受け皿が無いので読まない。
  /// > シンボルとレイヤの不透明度は面の塗りと輪郭の不透明度に掛ける（線・点は不透明度を持たない）
  static KMetaLayerStyle? read(XmlElement symbol, {double opacity = 1}) {
    final layers = [
      for (final l in symbol.findElements('layer'))
        if (l.getAttribute('enabled') != '0') l,
    ];
    if (layers.isEmpty) return null;
    XmlElement? byClass(String cls) => layers.where((l) => l.getAttribute('class') == cls).firstOrNull;
    final alpha = (double.tryParse(symbol.getAttribute('alpha') ?? '') ?? 1) * opacity;

    switch (symbol.getAttribute('type')) {
      case 'marker':
        final props = readProps(byClass('SimpleMarker') ?? layers.first);
        if (props.isEmpty) return null;
        return KMetaLayerStyle(
          pointColor: color(props['color']),
          // QGIS の size は直径(MM)。こかげマップ は半径感覚の px
          pointSize: px(props['size'], divideBy: 2),
        );
      case 'line':
        final props = readProps(byClass('SimpleLine') ?? layers.first);
        if (props.isEmpty) return null;
        return KMetaLayerStyle(
          lineColor: color(props['line_color'] ?? props['color']),
          lineWidth: props['line_style'] == 'no' ? 0 : px(props['line_width'] ?? props['width']),
        );
      case 'fill':
        final fillLayer = byClass('SimpleFill');
        final outlineOnly = fillLayer == null ? byClass('SimpleLine') : null;
        if (outlineOnly != null) {
          final props = readProps(outlineOnly);
          final stroke = props['line_color'] ?? props['color'];
          return KMetaLayerStyle(
            polygonFillOpacity: 0,
            polygonBorderColor: color(stroke),
            polygonBorderOpacity: _times(alphaOf(stroke), alpha, hidden: props['line_style'] == 'no'),
            polygonBorderWidth: px(props['line_width'] ?? props['width']),
          );
        }
        final props = readProps(fillLayer ?? layers.first);
        if (props.isEmpty) return null;
        final stroke = props['outline_color'] ?? props['border_color'];
        return KMetaLayerStyle(
          polygonFillColor: color(props['color']),
          polygonFillOpacity: _times(alphaOf(props['color']), alpha, hidden: props['style'] == 'no'),
          polygonBorderColor: color(stroke),
          polygonBorderOpacity: _times(alphaOf(stroke), alpha, hidden: props['outline_style'] == 'no'),
          polygonBorderWidth: px(props['outline_width'] ?? props['border_width']),
        );
      default:
        return null;
    }
  }

  /// 色のアルファ × 不透明度。描かない設定（`style="no"`）なら 0。どちらも既定なら null（＝書かない）
  static double? _times(double? colorAlpha, double opacity, {bool hidden = false}) {
    if (hidden) return 0;
    if (colorAlpha == null && opacity == 1) return null;
    return (colorAlpha ?? 1) * opacity;
  }

  /// シンボルレイヤのプロパティを読む。
  ///
  /// ⚠ QGIS 3.x は `<Option name= value=>`、それ以前は `<prop k= v=>`。
  /// **両方読む。** 他人のファイルは古い形式で来る。
  static Map<String, String> readProps(XmlElement symbolLayer) {
    final props = <String, String>{};

    // 旧形式（QGIS 3.x より前）。`<layer>` の直下に並ぶ
    for (final prop in symbolLayer.findElements('prop')) {
      final k = prop.getAttribute('k');
      final v = prop.getAttribute('v');
      if (k != null && v != null) props[k] = v;
    }

    // 新形式。`<layer>` の**直下の** `<Option type="Map">` の子だけを見る。
    //
    // ⚠ 再帰で拾ってはいけない。QGIS は `<layer>` の中に
    //   `<data_defined_properties>` も書き、そこにも `name="name"` などの
    //   `<Option>` が入っている。まとめて読むと本物の値を上書きしてしまう
    //   （QGIS 3.44 の実出力で確認）。
    for (final map in symbolLayer.findElements('Option')) {
      if (map.getAttribute('type') != 'Map') continue;
      for (final option in map.findElements('Option')) {
        final name = option.getAttribute('name');
        final value = option.getAttribute('value');
        if (name != null && value != null) props[name] = value;
      }
    }
    return props;
  }

  /// QGIS の `R,G,B,A`（各0-255）
  ///
  /// ⚠ QGIS 3.44 は後ろに浮動小数表記を足してくる:
  /// `30,144,255,255,rgb:0.1176471,0.5647059,1,1`。先頭4つだけ見ればよい。
  static Color? color(String? value) {
    if (value == null) return null;
    final parts = value.split(',');
    if (parts.length < 3) return null;
    final rgb = [
      for (final part in parts.take(3)) int.tryParse(part.trim()) ?? 0,
    ];
    // アルファは別途 opacity として持つので、色は不透明にしておく
    return Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
  }

  /// `R,G,B,A` のAを 0..1 で返す
  static double? alphaOf(String? value) {
    if (value == null) return null;
    final parts = value.split(',');
    if (parts.length < 4) return null;
    final a = int.tryParse(parts[3].trim());
    return a == null ? null : a / 255;
  }

  static double? px(String? mm, {double divideBy = 1}) {
    if (mm == null) return null;
    final value = double.tryParse(mm.trim());
    if (value == null) return null;
    return value * kQgsMmToPx / divideBy;
  }
}

/// `<renderer-v2>`（分類・段階・ルール）→ [QgisRenderer]
abstract final class QgsRendererReader {
  /// [maplayer] のレンダラ。描き分けでなければ（単一シンボル・未対応の種類）null
  static QgisRenderer? read(XmlElement maplayer) {
    final renderer = maplayer.findElements('renderer-v2').firstOrNull;
    final kind = QgisRendererKind.fromQgisType(renderer?.getAttribute('type'));
    if (renderer == null || kind == null) return null;

    final opacity = double.tryParse(maplayer.getElement('layerOpacity')?.innerText.trim() ?? '') ?? 1;
    final symbols = <String, XmlElement>{
      for (final s in renderer.getElement('symbols')?.findElements('symbol') ?? const <XmlElement>[])
        s.getAttribute('name') ?? '': s,
    };
    KMetaLayerStyle? styleOf(String? name) {
      final s = name == null ? null : symbols[name];
      return s == null ? null : QgsSymbolReader.read(s, opacity: opacity);
    }

    bool render(XmlElement e) => e.getAttribute('render') != 'false';

    switch (kind) {
      case QgisRendererKind.categorized:
        return QgisRenderer(
          kind: kind,
          attr: renderer.getAttribute('attr'),
          classes: [
            for (final c in renderer.getElement('categories')?.findElements('category') ?? const <XmlElement>[])
              QgisRendererClass(
                label: c.getAttribute('label') ?? '',
                style: styleOf(c.getAttribute('symbol')),
                render: render(c),
                values: _categoryValues(c),
              ),
          ],
        );
      case QgisRendererKind.graduated:
        return QgisRenderer(
          kind: kind,
          attr: renderer.getAttribute('attr'),
          classes: [
            for (final r in renderer.getElement('ranges')?.findElements('range') ?? const <XmlElement>[])
              QgisRendererClass(
                label: r.getAttribute('label') ?? '',
                style: styleOf(r.getAttribute('symbol')),
                render: render(r),
                lower: double.tryParse(r.getAttribute('lower') ?? ''),
                upper: double.tryParse(r.getAttribute('upper') ?? ''),
              ),
          ],
        );
      case QgisRendererKind.rule:
        final classes = <QgisRendererClass>[];
        QgisRule rule(XmlElement e) {
          final symbol = e.getAttribute('symbol');
          int? classIndex;
          if (symbol != null && symbols.containsKey(symbol)) {
            classIndex = classes.length;
            classes.add(QgisRendererClass(
              label: e.getAttribute('label') ?? e.getAttribute('filter') ?? '',
              style: styleOf(symbol),
            ));
          }
          final filter = e.getAttribute('filter');
          return QgisRule(
            filter: filter,
            isElse: filter?.trim().toUpperCase() == 'ELSE',
            active: e.getAttribute('active') != '0',
            classIndex: classIndex,
            children: [for (final c in e.findElements('rule')) rule(c)],
          );
        }

        final root = renderer.getElement('rules');
        final rules = [for (final e in root?.findElements('rule') ?? const <XmlElement>[]) rule(e)];
        return QgisRenderer(kind: kind, classes: classes, rules: rules);
    }
  }

  /// 分類の値。`type="NULL"` や空は「その他の値すべて」（空のリスト）。
  /// QGIS 3.36 からの複数値の項目（`<val>` の並び）も読む
  static List<String?> _categoryValues(XmlElement c) {
    final vals = c.findElements('val').toList();
    if (vals.isNotEmpty) {
      return [
        for (final v in vals)
          if (v.getAttribute('type') != 'NULL') v.getAttribute('value'),
      ];
    }
    if (c.getAttribute('type') == 'NULL') return const [];
    final value = c.getAttribute('value');
    return value == null || value.isEmpty ? const [] : [value];
  }
}
