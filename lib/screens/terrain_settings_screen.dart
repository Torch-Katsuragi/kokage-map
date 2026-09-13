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
// こかげマップ: 地形の見た目の設定（色分け・等高線）。値は `TerrainAppearance` に写して描画側が読む

import 'package:flutter/material.dart';

import '../core/settings_schema.dart';
import '../core/terrain/terrain_appearance.dart';
import '../i18n/strings.g.dart';
import '../widgets/settings_widgets.dart';

final terrainColorModeDef = IntDef(
  key: 'terrain_color_mode',
  title: t.terrainSettings.colorMode,
  description: t.terrainSettings.colorModeDesc,
  defaultValue: 0,
  min: 0,
  max: 2,
  formatter: (v) => switch (v) {
    1 => t.terrainSettings.colorSlope,
    2 => t.terrainSettings.colorElevation,
    _ => t.terrainSettings.colorNone,
  },
);
final terrainColorStrengthDef = DoubleDef(
  key: 'terrain_color_strength',
  title: t.terrainSettings.colorStrength,
  description: t.terrainSettings.colorStrengthDesc,
  defaultValue: 0.7,
  min: 0,
  max: 1,
  divisions: 10,
  formatter: (v) => '${(v * 100).toInt()}%',
);
final terrainColorLowDef = ColorDef(key: 'terrain_color_low', title: t.terrainSettings.colorLow, defaultArgb: 0xFF2E7D32);
final terrainColorMidDef = ColorDef(key: 'terrain_color_mid', title: t.terrainSettings.colorMid, defaultArgb: 0xFFFFF176);
final terrainColorHighDef = ColorDef(key: 'terrain_color_high', title: t.terrainSettings.colorHigh, defaultArgb: 0xFFB71C1C);
final terrainSlopeMaxDef = DoubleDef(
  key: 'terrain_slope_max',
  title: t.terrainSettings.slopeMax,
  description: t.terrainSettings.slopeMaxDesc,
  defaultValue: 45,
  min: 10,
  max: 80,
  divisions: 14,
  formatter: (v) => '${v.toInt()}°',
);
final terrainContoursDef = SwitchDef(
  key: 'terrain_contours',
  title: t.terrainSettings.contours,
  description: t.terrainSettings.contoursDesc,
  defaultValue: false,
  icon: Icons.stacked_line_chart,
);
final terrainContourIntervalDef = IntDef(
  key: 'terrain_contour_interval',
  title: t.terrainSettings.contourInterval,
  description: t.terrainSettings.contourIntervalDesc,
  defaultValue: 0, // 0 = 自動
  min: 0,
  max: 50,
  formatter: (v) => v == 0 ? t.terrainSettings.contourAuto : '$v m',
);
final terrainContourMajorDef = IntDef(
  key: 'terrain_contour_major',
  title: t.terrainSettings.contourMajor,
  description: t.terrainSettings.contourMajorDesc,
  defaultValue: 5,
  min: 2,
  max: 10,
  formatter: (v) => t.terrainSettings.everyN(n: v),
);
final terrainContourColorDef = ColorDef(key: 'terrain_contour_color', title: t.terrainSettings.contourColor, defaultArgb: 0xCC6D4C41);
final terrainContourWidthDef = DoubleDef(
  key: 'terrain_contour_width',
  title: t.terrainSettings.contourWidth,
  defaultValue: 1,
  min: 0.5,
  max: 3,
  divisions: 5,
  formatter: (v) => '${v.toStringAsFixed(1)} px',
);

final terrainSettings = SettingsStore([
  SettingSectionDef(
    id: 'color',
    title: t.terrainSettings.colorSection,
    icon: Icons.gradient,
    iconColor: Colors.green,
    items: [
      terrainColorModeDef,
      terrainColorStrengthDef,
      terrainColorLowDef,
      terrainColorMidDef,
      terrainColorHighDef,
      terrainSlopeMaxDef,
    ],
  ),
  SettingSectionDef(
    id: 'contours',
    title: t.terrainSettings.contourSection,
    icon: Icons.stacked_line_chart,
    iconColor: Colors.brown,
    items: [
      terrainContoursDef,
      terrainContourIntervalDef,
      terrainContourMajorDef,
      terrainContourColorDef,
      terrainContourWidthDef,
    ],
  ),
]);

/// ストアの値を描画側のスナップショットに写す（起動時と変更のたび）
void syncTerrainAppearance() {
  final s = terrainSettings;
  TerrainAppearance.colorMode = TerrainColorMode.values[s.getInt(terrainColorModeDef).clamp(0, 2)];
  TerrainAppearance.colorStrength = s.getDouble(terrainColorStrengthDef);
  TerrainAppearance.low = s.getColor(terrainColorLowDef);
  TerrainAppearance.mid = s.getColor(terrainColorMidDef);
  TerrainAppearance.high = s.getColor(terrainColorHighDef);
  TerrainAppearance.slopeMaxDeg = s.getDouble(terrainSlopeMaxDef);
  TerrainAppearance.contours = s.getBool(terrainContoursDef);
  TerrainAppearance.contourIntervalM = s.getInt(terrainContourIntervalDef).toDouble();
  TerrainAppearance.contourMajorEvery = s.getInt(terrainContourMajorDef);
  TerrainAppearance.contourColor = s.getColor(terrainContourColorDef);
  TerrainAppearance.contourWidthPx = s.getDouble(terrainContourWidthDef);
  TerrainAppearance.bump();
}

class TerrainSettingsScreen extends StatelessWidget {
  const TerrainSettingsScreen({super.key, this.isEmbedded = false});

  final bool isEmbedded;

  @override
  Widget build(BuildContext context) {
    return DataDrivenSettingsScreen(
      title: t.terrainSettings.title,
      store: terrainSettings,
      isEmbedded: isEmbedded,
      onValueChanged: syncTerrainAppearance,
      onReset: () async {
        await terrainSettings.resetAll();
        syncTerrainAppearance();
      },
    );
  }
}
