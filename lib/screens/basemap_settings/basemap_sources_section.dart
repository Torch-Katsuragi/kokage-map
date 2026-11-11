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
/// 背景地図・地形（DEM）の出典表示セクション
library;

import 'package:flutter/material.dart';

import '../../core/terrain/dem_tiles.dart' show DemTileSource;
import '../../core/terrain/terrain_appearance.dart';
import '../../i18n/strings.g.dart';
import '../../services/basemap_service.dart';
import '../../widgets/settings_widgets.dart';

/// 出典セクション（地図面に出すのをやめてここにまとめた。OSM だけは地図面にも出す）
class BasemapSourcesSection extends StatelessWidget {
  const BasemapSourcesSection({super.key, required this.service});

  final BaseMapService service;

  @override
  Widget build(BuildContext context) {
    final basemaps = {
      for (final (p, _) in service.activeLayers)
        if (p.attribution.isNotEmpty) p.attribution else if (p.isCustom) p.name,
    };
    final dems = {
      for (final s in DemTileSource.cascadeFor(highPrecision: TerrainAppearance.highPrecision)) s.attribution,
    };
    return SettingsSection(
      title: t.basemap.sources.title,
      icon: Icons.public,
      iconColor: Colors.green,
      collapsible: true,
      initiallyExpanded: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(t.basemap.sources.hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        ListTile(
          leading: const Icon(Icons.map, color: Colors.green),
          title: Text(t.basemap.sources.basemap),
          subtitle: Text(basemaps.isEmpty ? '—' : basemaps.join('\n')),
        ),
        ListTile(
          leading: const Icon(Icons.terrain, color: Colors.green),
          title: Text(t.basemap.sources.elevation),
          subtitle: Text(dems.join('\n')),
        ),
      ],
    );
  }
}
