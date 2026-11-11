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
/// ラベル表示・書式・色・縁取り・不透明度のスタイル設定定義
library;

import 'package:flutter/material.dart';

import '../../core/settings_schema.dart';
import '../../i18n/strings.g.dart';
import 'symbol_style_defs.dart';

final labelEnabledDef = SwitchDef(
  key: 'layer_style_label_enabled',
  title: t.styleScreen.showLabel,
  description: t.styleScreen.showLabelDesc,
  defaultValue: true,
  icon: Icons.text_fields,
  kmetaGetter: (k) => k.labelEnabled,
);

/// ラベルの中身（QGIS の式。`label_expression.dart`）。
/// 画面には出さず、`labelExpressionTileDef` が組み立てダイアログ経由で書き換える
final labelPropertyDef = StringDef(
  key: 'layer_style_label_property',
  title: t.styleScreen.labelExpression,
  defaultValue: 'name',
  kmetaGetter: (k) => k.labelProperty,
);

final labelFontSizeDef = DoubleDef(
  key: 'layer_style_label_font_size',
  title: t.styleScreen.fontSize,
  defaultValue: 12.0,
  min: 8,
  max: 24,
  divisions: 16,
  formatter: formatStylePx,
  kmetaGetter: (k) => k.labelFontSize,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);

final labelColorDef = ColorDef(
  key: 'layer_style_label_color',
  title: t.styleScreen.textColor,
  defaultArgb: 0xFF000000,
  kmetaGetter: (k) => k.labelColor,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);

final labelHaloColorDef = ColorDef(
  key: 'layer_style_label_halo_color',
  title: t.styleScreen.haloColor,
  defaultArgb: 0xFFFFFFFF,
  kmetaGetter: (k) => k.labelHaloColor,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);

final labelOpacityDef = createStyleOpacityDef(
  key: 'layer_style_label_opacity',
  title: t.styleScreen.labelOpacity,
  defaultValue: 1.0,
  kmetaGetter: (k) => k.labelOpacity,
  visibleWhen: (s) => s.getBool(labelEnabledDef),
);

/// ラベル設定セクション定義を構築する
SettingSectionDef buildLabelStyleSectionDef(CustomDef labelExpressionTileDef) => SettingSectionDef(
      id: StyleSection.label,
      title: t.styleScreen.label,
      icon: Icons.label_outline,
      collapsible: true,
      initiallyExpanded: true,
      items: [
        labelEnabledDef,
        labelExpressionTileDef,
        labelFontSizeDef,
        labelColorDef,
        labelHaloColorDef,
        labelOpacityDef,
      ],
    );
