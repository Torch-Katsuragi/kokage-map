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
/// 統合設定画面（カテゴリー一覧）。各カテゴリーの画面は `settings/` と各 `*_settings_screen.dart`
library;

import 'package:flutter/material.dart';

import '../core/platform_capabilities.dart';
import '../i18n/strings.g.dart';
import '../tutorial/tutorial.dart';
import 'basemap_settings_screen.dart';
import 'device_settings_screen.dart';
import 'gps_settings_screen.dart';
import 'layer_style_settings_screen.dart';
import 'settings/app_info_screen.dart';
import 'settings/feedback_screen.dart';
import 'settings/general_settings_screen.dart';
import 'settings/sync_settings_screen.dart';
import 'terrain_settings_screen.dart';

// ホーム画面が読むので、ここからも出す
export 'settings/general_settings_screen.dart' show kGlobalFolderCustomPathKey;

/// 設定カテゴリー定義
enum SettingsCategory {
  general,
  basemap,
  gps,
  devices,
  layerStyle,
  terrain,
  sync,
  feedback,
  appInfo,
}

extension SettingsCategoryExt on SettingsCategory {
  String get title => switch (this) {
    SettingsCategory.general => t.settings.categories.general,
    SettingsCategory.basemap => t.settings.categories.basemap,
    SettingsCategory.gps => t.settings.categories.gps,
    SettingsCategory.devices => t.settings.categories.devices,
    SettingsCategory.layerStyle => t.settings.categories.layerStyle,
    SettingsCategory.terrain => t.settings.categories.terrain,
    SettingsCategory.sync => t.settings.categories.sync,
    SettingsCategory.feedback => t.settings.categories.feedback,
    SettingsCategory.appInfo => t.settings.categories.appInfo,
  };

  IconData get icon => switch (this) {
    SettingsCategory.general => Icons.settings,
    SettingsCategory.basemap => Icons.map,
    SettingsCategory.gps => Icons.gps_fixed,
    SettingsCategory.devices => Icons.bluetooth_connected,
    SettingsCategory.layerStyle => Icons.palette,
    SettingsCategory.terrain => Icons.terrain,
    SettingsCategory.sync => Icons.sync,
    SettingsCategory.feedback => Icons.feedback,
    SettingsCategory.appInfo => Icons.info_outline,
  };

  String get description => switch (this) {
    SettingsCategory.general => t.settings.categories.generalDesc,
    SettingsCategory.basemap => t.settings.categories.basemapDesc,
    SettingsCategory.gps => t.settings.categories.gpsDesc,
    SettingsCategory.devices => t.settings.categories.devicesDesc,
    SettingsCategory.layerStyle => t.settings.categories.layerStyleDesc,
    SettingsCategory.terrain => t.settings.categories.terrainDesc,
    SettingsCategory.sync => t.settings.categories.syncDesc,
    SettingsCategory.feedback => t.settings.categories.feedbackDesc,
    SettingsCategory.appInfo => t.settings.categories.appInfoDesc,
  };
}

/// 統合設定画面
/// 
/// レスポンシブ対応:
/// - 横幅が狭い場合: カテゴリーリストのみ表示 -> 遷移
/// - 横幅が広い場合: 左にカテゴリーリスト、右に詳細画面 (Split View)
class SettingsScreen extends StatefulWidget {
  final SettingsCategory initialCategory;

  const SettingsScreen({
    super.key,
    this.initialCategory = SettingsCategory.basemap,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsCategory _selectedCategory;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 横幅600以上をワイド画面（Split View）とする
        final isWide = constraints.maxWidth >= 600;
        return isWide ? _buildWideLayout() : _buildNarrowLayout();
      },
    );
  }

  List<SettingsCategory> get _visibleCategories => SettingsCategory.values
      .where((c) =>
          (c != SettingsCategory.sync && c != SettingsCategory.devices) ||
          _isMobile)
      .toList();

  static bool get _isMobile => PlatformCapabilities.isMobile;

  /// チュートリアルの案内先（地図・タイル と Drive同期）
  static GlobalKey? _tutorialKey(SettingsCategory c) => switch (c) {
        SettingsCategory.basemap => TutorialTargets.basemapSetting,
        SettingsCategory.sync => TutorialTargets.syncSetting,
        _ => null,
      };

  /// 狭い画面（スマホ等）用レイアウト
  Widget _buildNarrowLayout() {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.settings.title),
      ),
      body: ListView(
        children: _visibleCategories.map((category) {
          return ListTile(
            key: _tutorialKey(category),
            leading: Icon(category.icon, color: Colors.blueGrey),
            title: Text(category.title),
            subtitle: Text(category.description, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => _buildSettingsContent(category, isEmbedded: false),
                ),
              );
            },
          );
        }).toList(),
      ),
    );
  }

  /// 広い画面（タブレット・PC等）用レイアウト
  Widget _buildWideLayout() {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          // 左側: カテゴリーリスト
          SizedBox(
            width: 280,
            child: Column(
              children: [
                AppBar(
                  title: Text(t.settings.title),
                  elevation: 0,
                  backgroundColor: Colors.transparent,
                  foregroundColor: scheme.onSurface,
                  automaticallyImplyLeading: true, // 戻るボタンを表示
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: _visibleCategories.map((category) {
                      final isSelected = category == _selectedCategory;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: isSelected
                            ? BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              )
                            : null,
                        child: ListTile(
                          key: _tutorialKey(category),
                          leading: Icon(
                            category.icon,
                            color: isSelected ? scheme.onPrimaryContainer : Colors.blueGrey,
                          ),
                          title: Text(
                            category.title,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected ? scheme.onPrimaryContainer : null,
                            ),
                          ),
                          onTap: () {
                            setState(() => _selectedCategory = category);
                          },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          
          // 境界線
          const VerticalDivider(width: 1),
          
          // 右側: 詳細コンテンツ
          Expanded(
            child: Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: _buildSettingsContent(_selectedCategory, isEmbedded: true),
            ),
          ),
        ],
      ),
    );
  }

  /// カテゴリーに対応する設定画面を返す
  Widget _buildSettingsContent(SettingsCategory category, {required bool isEmbedded}) {
    // Note: キーを付与することで、カテゴリー切り替え時にWidgetを再構築させる
    // これによりスクロール位置や状態のリセットが適切に行われる
    final key = ValueKey('settings_${category.name}');
    return switch (category) {
      SettingsCategory.general => GeneralSettingsScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.basemap => BaseMapSettingsScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.gps => GpsSettingsScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.devices => DeviceSettingsScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.layerStyle => LayerStyleSettingsScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.terrain => TerrainSettingsScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.sync => SyncSettingsScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.feedback => FeedbackScreen(key: key, isEmbedded: isEmbedded),
      SettingsCategory.appInfo => AppInfoScreen(key: key, isEmbedded: isEmbedded),
    };
  }
}
