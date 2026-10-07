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
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/terrain/dem_tiles.dart';
import '../../i18n/strings.g.dart';
import '../../models/basemap_provider.dart';
import '../../widgets/settings_widgets.dart';

/// アプリ情報画面
class AppInfoScreen extends StatefulWidget {
  final bool isEmbedded;

  const AppInfoScreen({
    super.key,
    this.isEmbedded = false,
  });

  @override
  State<AppInfoScreen> createState() => _AppInfoScreenState();
}

class _AppInfoScreenState extends State<AppInfoScreen> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _packageInfo = info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.settings.appInfo;
    final info = _packageInfo;
    return SettingsScaffold(
      title: tr.title,
      isEmbedded: widget.isEmbedded,
      body: SettingsBody(
        sections: [
          SettingsSection(
            title: t.common.appName,
            icon: Icons.map,
            iconColor: Colors.blue,
            children: [
              ListTile(
                leading: const Icon(Icons.numbers, color: Colors.blueGrey),
                title: Text(tr.version),
                subtitle: Text(
                  info != null
                      ? '${info.version} (${tr.buildLabel(number: info.buildNumber)})'
                      : t.common.loading,
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.android, color: Colors.green),
                title: Text(tr.packageName),
                subtitle: Text(info?.packageName ?? t.common.loading),
              ),
            ],
          ),
          SettingsSection(
            title: tr.overview,
            icon: Icons.description,
            iconColor: Colors.teal,
            children: [SettingsParagraph(tr.overviewText)],
          ),
          SettingsSection(
            title: tr.licenses,
            icon: Icons.gavel,
            iconColor: Colors.orange,
            children: [
              ListTile(
                leading: const Icon(Icons.open_in_new, color: Colors.blue),
                title: Text(tr.openSourceLicenses),
                subtitle: Text(tr.openSourceLicensesDesc),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  showLicensePage(
                    context: context,
                    applicationName: t.common.appName,
                    applicationVersion: info?.version ?? '',
                  );
                },
              ),
            ],
          ),
          // 地図データの出典（全プロバイダ分。いま使っている分は「地図・タイル」の出典に。地図面には OSM のときだけ）
          SettingsSection(
            title: tr.dataSources,
            icon: Icons.public,
            iconColor: Colors.green,
            children: [
              ListTile(
                leading: const Icon(Icons.map, color: Colors.green),
                title: Text(tr.dataSourcesBasemap),
                subtitle: Text({for (final p in BaseMapProvider.availableProviders) if (p.attribution.isNotEmpty) p.attribution}.join('\n')),
              ),
              ListTile(
                leading: const Icon(Icons.terrain, color: Colors.green),
                title: Text(tr.dataSourcesElevation),
                subtitle: Text({for (final s in DemTileSource.defaultCascade) s.attribution}.join('\n')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
