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
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/map_layout.dart';
import '../core/platform_capabilities.dart';
import '../core/terrain/dem_tiles.dart';
import '../i18n/strings.g.dart';
import '../main.dart' show kAppLocaleKey;
import '../models/app_notification.dart';
import '../models/basemap_provider.dart';
import '../providers/notification_providers.dart';
import '../providers/project_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/global_folder_locator.dart';
import '../services/google_drive/auto_sync_service.dart';
import '../services/google_drive/google_drive_service.dart';
import '../utils/folder_utils.dart';
import '../widgets/settings_widgets.dart';
import 'basemap_settings_screen.dart';
import 'device_settings_screen.dart';
import 'gps_settings_screen.dart';
import 'layer_style_settings_screen.dart';
import 'terrain_settings_screen.dart';
import 'terrain_spike/terrain_spike_screen.dart';

/// グローバルフォルダのカスタムパス用SharedPreferencesキー
const kGlobalFolderCustomPathKey = 'global_folder_custom_path';

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

        if (isWide) {
          return _buildWideLayout();
        } else {
          return _buildNarrowLayout();
        }
      },
    );
  }

  List<SettingsCategory> get _visibleCategories => SettingsCategory.values
      .where((c) =>
          (c != SettingsCategory.sync && c != SettingsCategory.devices) ||
          _isMobile)
      .toList();

  static bool get _isMobile => PlatformCapabilities.isMobile;

  /// 狭い画面（スマホ等）用レイアウト
  Widget _buildNarrowLayout() {
    return Scaffold(
      appBar: AppBar(
        title: Text(t.settings.title),
      ),
      body: ListView(
        children: _visibleCategories.map((category) {
          return ListTile(
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
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
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
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              )
                            : null,
                        child: ListTile(
                          leading: Icon(
                            category.icon,
                            color: isSelected
                                ? Theme.of(context).colorScheme.onPrimaryContainer
                                : Colors.blueGrey,
                          ),
                          title: Text(
                            category.title,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.onPrimaryContainer
                                  : null,
                            ),
                          ),
                          onTap: () {
                            setState(() {
                              _selectedCategory = category;
                            });
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
    
    switch (category) {
      case SettingsCategory.general:
        return GeneralSettingsScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.basemap:
        return BaseMapSettingsScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.gps:
        return GpsSettingsScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.devices:
        return DeviceSettingsScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.layerStyle:
        return LayerStyleSettingsScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.terrain:
        return TerrainSettingsScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.sync:
        return SyncSettingsScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.feedback:
        return FeedbackScreen(key: key, isEmbedded: isEmbedded);
      case SettingsCategory.appInfo:
        return AppInfoScreen(key: key, isEmbedded: isEmbedded);
    }
  }
}

/// フィードバック画面
class FeedbackScreen extends ConsumerWidget {
  final bool isEmbedded;
  
  /// Google Forms フィードバックURL (フルURL)
  static const _feedbackBaseUrl =
      'https://docs.google.com/forms/d/e/1FAIpQLSdPPuWtjW-t4rfdyLF9fCGEcrIMG49hFkV4N3WU4CiidivkLg/viewform';

  /// バージョンフィールドの entry ID
  static const _versionEntryId = 'entry.2058352308';

  /// 端末モデルフィールドの entry ID
  static const _deviceModelEntryId = 'entry.1483381142';

  const FeedbackScreen({
    super.key,
    this.isEmbedded = false,
  });

  /// デバイスモデル名を取得
  Future<String> _getDeviceModel() async {
    final deviceInfo = DeviceInfoPlugin();
    if (PlatformCapabilities.isAndroid) {
      final android = await deviceInfo.androidInfo;
      return '${android.manufacturer} ${android.model}';
    } else if (PlatformCapabilities.isWeb) {
      final web = await deviceInfo.webBrowserInfo;
      return 'Web (${web.browserName.name})';
    }
    return PlatformCapabilities.operatingSystem;
  }

  Future<void> _openFeedbackForm(WidgetRef ref) async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = '${info.version}+${info.buildNumber}';
      final deviceModel = await _getDeviceModel();
      final uri = Uri.parse(_feedbackBaseUrl).replace(
        queryParameters: {
          'usp': 'pp_url',
          _versionEntryId: version,
          _deviceModelEntryId: deviceModel,
        },
      );
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.settings.feedback.browserError,
              level: NotificationLevel.error,
            );
      }
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.settings.feedback.errorOccurred(error: e.toString()),
            level: NotificationLevel.error,
          );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsScaffold(
      title: t.settings.feedback.title,
      isEmbedded: isEmbedded,
      body: SettingsBody(
        sections: [
          SettingsHighlightSection(
            title: t.settings.feedback.callToAction,
            icon: Icons.mail_outline,
            iconColor: Colors.blue,
            backgroundColor: Colors.blue.shade50,
            description: t.settings.feedback.description,
            actionButton: ElevatedButton.icon(
              onPressed: () => _openFeedbackForm(ref),
              icon: const Icon(Icons.open_in_new),
              label: Text(t.settings.feedback.openForm),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          SettingsSection(
            title: t.settings.feedback.feedbackTypes,
            icon: Icons.category,
            iconColor: Colors.orange,
            children: [
              ListTile(
                leading: const Icon(Icons.lightbulb_outline, color: Colors.amber),
                title: Text(t.settings.feedback.featureRequest),
                subtitle: Text(t.settings.feedback.featureRequestDesc),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.bug_report, color: Colors.red),
                title: Text(t.settings.feedback.bugReport),
                subtitle: Text(t.settings.feedback.bugReportDesc),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.thumb_up_outlined, color: Colors.green),
                title: Text(t.settings.feedback.other),
                subtitle: Text(t.settings.feedback.otherDesc),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

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
    return SettingsScaffold(
      title: t.settings.appInfo.title,
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
                title: Text(t.settings.appInfo.version),
                subtitle: Text(
                  _packageInfo != null
                      ? '${_packageInfo!.version} (${t.settings.appInfo.buildLabel(number: _packageInfo!.buildNumber)})'
                      : t.common.loading,
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.android, color: Colors.green),
                title: Text(t.settings.appInfo.packageName),
                subtitle: Text(_packageInfo?.packageName ?? t.common.loading),
              ),
            ],
          ),
          // 開発用（debug / profile ビルドのみ）。文言は i18n に載せない
          if (!kReleaseMode)
            SettingsSection(
              title: '開発',
              icon: Icons.science,
              iconColor: Colors.purple,
              children: [
                ListTile(
                  leading: const Icon(Icons.terrain, color: Colors.purple),
                  title: const Text('3D 描画スパイク'),
                  subtitle: const Text('drawVertices で DEM を描いて fps を測る'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TerrainSpikeScreen()),
                    );
                  },
                ),
              ],
            ),
          SettingsSection(
            title: t.settings.appInfo.overview,
            icon: Icons.description,
            iconColor: Colors.teal,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  t.settings.appInfo.overviewText,
                  style: const TextStyle(height: 1.5),
                ),
              ),
            ],
          ),
          SettingsSection(
            title: t.settings.appInfo.licenses,
            icon: Icons.gavel,
            iconColor: Colors.orange,
            children: [
              ListTile(
                leading: const Icon(Icons.open_in_new, color: Colors.blue),
                title: Text(t.settings.appInfo.openSourceLicenses),
                subtitle: Text(t.settings.appInfo.openSourceLicensesDesc),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  showLicensePage(
                    context: context,
                    applicationName: t.common.appName,
                    applicationVersion: _packageInfo?.version ?? '',
                  );
                },
              ),
            ],
          ),
          // 地図データの出典（地図面の左下にも出しているが、ここにもまとめて載せる）
          SettingsSection(
            title: t.settings.appInfo.dataSources,
            icon: Icons.public,
            iconColor: Colors.green,
            children: [
              ListTile(
                leading: const Icon(Icons.map, color: Colors.green),
                title: Text(t.settings.appInfo.dataSourcesBasemap),
                subtitle: Text({for (final p in BaseMapProvider.availableProviders) p.attribution}.join('\n')),
              ),
              ListTile(
                leading: const Icon(Icons.terrain, color: Colors.green),
                title: Text(t.settings.appInfo.dataSourcesElevation),
                subtitle: Text({for (final s in DemTileSource.defaultCascade) s.attribution}.join('\n')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一般設定画面（PC専用: グローバルフォルダパス設定）

class GeneralSettingsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;
  const GeneralSettingsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<GeneralSettingsScreen> createState() => _GeneralSettingsScreenState();
}

class _GeneralSettingsScreenState extends ConsumerState<GeneralSettingsScreen> {
  String? _customPath;
  String _defaultPath = '';
  bool _isLoading = true;

  // 権限状態（Android用）
  bool _storageGranted = false;
  bool _locationGranted = false;
  bool _bluetoothGranted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // ⚠ web に `getApplicationDocumentsDirectory()` は無く、呼ぶと例外が飛ぶ。
    // 待ち続けて画面がぐるぐるのまま止まるので、ここで分ける。
    if (_hasGlobalFolder) {
      _defaultPath = await GlobalFolderLocator.defaultPath();
      _customPath = prefs.getString(kGlobalFolderCustomPathKey);
    }
    if (_isMobileDevice) {
      await _loadPermissions();
    }
    if (mounted) setState(() => _isLoading = false);
  }

  /// グローバルフォルダ（全プロジェクト共有の保存先）を持てるか。
  ///
  /// web はブラウザが握るので、パスという概念自体が無い。
  static bool get _hasGlobalFolder => PlatformCapabilities.hasLocalFileSystem;

  static bool get _isMobileDevice => PlatformCapabilities.isMobile;

  Future<void> _loadPermissions() async {
    final storage = await Permission.manageExternalStorage.isGranted;
    final location = await Permission.location.isGranted;
    final btScan = await Permission.bluetoothScan.isGranted;
    final btConnect = await Permission.bluetoothConnect.isGranted;

    if (mounted) {
      setState(() {
        _storageGranted = storage;
        _locationGranted = location;
        _bluetoothGranted = btScan && btConnect;
      });
    }
  }

  String get _effectivePath => _customPath ?? _defaultPath;
  bool get _isCustom => _customPath != null;

  Future<void> _changeLocale(AppLocale locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kAppLocaleKey, locale.languageCode);
    await LocaleSettings.instance.setLocale(locale);
    if (mounted) setState(() {});
  }

  String _localeName(AppLocale locale) {
    switch (locale) {
      case AppLocale.en:
        return t.settings.general.languageNames.en;
      case AppLocale.ja:
        return t.settings.general.languageNames.ja;
    }
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Global Folder',
    );
    if (dir == null) return;

    // 含有関係チェック（プロジェクトフォルダが開いている場合）
    final projectDir = ref.read(projectRootDirProvider);
    if (projectDir != null) {
      final warning = checkContainmentRelation(dir, projectDir);
      if (warning != null && mounted) {
        final proceed = await _showContainmentWarning(warning);
        if (!proceed) return;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kGlobalFolderCustomPathKey, dir);
    setState(() => _customPath = dir);

    // 実行中のプロバイダに反映
    ref.read(globalFolderPathProvider.notifier).set(dir);

    ref.read(notificationCenterProvider.notifier).add(
          title: 'Global folder updated. Restart the app to take full effect.',
          level: NotificationLevel.info,
        );
  }

  Future<void> _resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kGlobalFolderCustomPathKey);
    setState(() => _customPath = null);
    ref.read(globalFolderPathProvider.notifier).set(_defaultPath);

    ref.read(notificationCenterProvider.notifier).add(
          title: 'Global folder reset to default. Restart the app to take full effect.',
          level: NotificationLevel.info,
        );
  }

  Future<bool> _showContainmentWarning(String message) async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
        title: const Text('Folder Containment Warning'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Use Anyway'),
          ),
        ],
      ),
    ) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final currentLocale = LocaleSettings.currentLocale;

    return SettingsScaffold(
      title: t.settings.general.title,
      isEmbedded: widget.isEmbedded,
      isLoading: _isLoading,
      body: SettingsBody(
        sections: [
          // 言語設定セクション
          SettingsSection(
            title: t.settings.general.language,
            icon: Icons.language,
            iconColor: Colors.indigo,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  t.settings.general.languageDesc,
                  style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.4),
                ),
              ),
              const SizedBox(height: 8),
              ...AppLocale.values.map((locale) {
                final isSelected = locale == currentLocale;
                return ListTile(
                  leading: Icon(
                    isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: isSelected ? Colors.indigo : Colors.grey,
                  ),
                  title: Text(
                    _localeName(locale),
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(locale.languageCode.toUpperCase()),
                  onTap: () => _changeLocale(locale),
                );
              }),
            ],
          ),

          // UIサイズ調整セクション
          _buildUiScaleSection(),

          // 画面の配置（プリセット）
          _buildLayoutSection(),

          if (_hasGlobalFolder) SettingsSection(
            title: 'Global Folder',
            icon: Icons.folder_special,
            iconColor: Colors.blue,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'The global folder is shared across all projects.\n'
                  'GPS history, shared GeoPackages, and other global data are stored here.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.4),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: Icon(
                  _isCustom ? Icons.folder : Icons.folder_outlined,
                  color: _isCustom ? Colors.blue : Colors.blueGrey,
                ),
                title: Text(_isCustom ? 'Custom Path' : 'Default Path'),
                subtitle: Text(
                  _effectivePath,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _pickFolder,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Change Folder'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    if (_isCustom) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _resetToDefault,
                        icon: const Icon(Icons.restore),
                        label: const Text('Reset'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_hasGlobalFolder) const SettingsSection(
            title: 'Info',
            icon: Icons.info_outline,
            iconColor: Colors.grey,
            children: [
              Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Changing the global folder does not migrate existing data.\n'
                  'The new folder will be created automatically if it does not exist.\n\n'
                  'The global folder and project folder must not overlap '
                  '(one containing the other).',
                  style: TextStyle(height: 1.5, color: Colors.grey),
                ),
              ),
            ],
          ),
          // 権限管理セクション（Android/iOS時のみ）
          if (_isMobileDevice)
            SettingsSection(
              title: t.home.permissionRequired,
              icon: Icons.security,
              iconColor: Colors.deepPurple,
              children: [
                _buildPermissionTile(
                  icon: Icons.folder,
                  iconColor: Colors.orange,
                  title: t.onboarding.storageTitle,
                  isGranted: _storageGranted,
                ),
                const Divider(),
                _buildPermissionTile(
                  icon: Icons.gps_fixed,
                  iconColor: Colors.green,
                  title: t.onboarding.locationTitle,
                  isGranted: _locationGranted,
                ),
                const Divider(),
                _buildPermissionTile(
                  icon: Icons.bluetooth,
                  iconColor: Colors.blue,
                  title: t.onboarding.bluetoothTitle,
                  isGranted: _bluetoothGranted,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await openAppSettings();
                      // 設定画面から戻ったら権限を再チェック
                      await _loadPermissions();
                    },
                    icon: const Icon(Icons.settings),
                    label: Text(t.common.openSettings),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
  Widget _buildLayoutSection() {
    final preset = ref.watch(mapLayoutPresetSettingProvider);
    final tr = t.settings.general;
    final names = {
      MapLayoutPreset.auto: (tr.layoutAuto, tr.layoutAutoDesc),
      MapLayoutPreset.portrait: (tr.layoutPortrait, tr.layoutPortraitDesc),
      MapLayoutPreset.landscape: (tr.layoutLandscape, tr.layoutLandscapeDesc),
      MapLayoutPreset.leftHanded: (tr.layoutLeftHanded, tr.layoutLeftHandedDesc),
    };
    return SettingsSection(
      title: tr.layout,
      icon: Icons.dashboard_customize_outlined,
      iconColor: Colors.deepOrange,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            tr.layoutDesc,
            style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.4),
          ),
        ),
        const SizedBox(height: 4),
        RadioGroup<MapLayoutPreset>(
          groupValue: preset,
          onChanged: (v) {
            if (v != null) ref.read(mapLayoutPresetSettingProvider.notifier).set(v);
          },
          child: Column(
            children: [
              for (final p in MapLayoutPreset.values)
                RadioListTile<MapLayoutPreset>(
                  value: p,
                  dense: true,
                  title: Text(names[p]!.$1),
                  subtitle: Text(names[p]!.$2),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUiScaleSection() {
    final scaleLevel = ref.watch(uiScaleLevelProvider);
    final labels = [
      t.settings.general.uiScaleLabels.k0,
      t.settings.general.uiScaleLabels.k1,
      t.settings.general.uiScaleLabels.k2,
      t.settings.general.uiScaleLabels.k3,
      t.settings.general.uiScaleLabels.k4,
      t.settings.general.uiScaleLabels.k5,
      t.settings.general.uiScaleLabels.k6,
    ];
    final names = [
      t.settings.general.uiScaleNames.k0,
      t.settings.general.uiScaleNames.k1,
      t.settings.general.uiScaleNames.k2,
      t.settings.general.uiScaleNames.k3,
      t.settings.general.uiScaleNames.k4,
      t.settings.general.uiScaleNames.k5,
      t.settings.general.uiScaleNames.k6,
    ];

    return SettingsSection(
      title: t.settings.general.uiScale,
      icon: Icons.format_size,
      iconColor: Colors.teal,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            t.settings.general.uiScaleDesc,
            style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.4),
          ),
        ),
        const SizedBox(height: 12),
        // 現在の選択ラベル
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(names[scaleLevel],
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              Text(
                labels[scaleLevel],
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        // 離散的スライダー
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 6,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
          ),
          child: Slider(
            value: scaleLevel.toDouble(),
            min: 0,
            max: 6,
            divisions: 6,
            onChanged: (v) {
              ref.read(uiScaleLevelProvider.notifier).set(v.round());
            },
          ),
        ),
        // ラベル行
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(7, (i) {
              final isSelected = i == scaleLevel;
              return Text(
                labels[i],
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey[500],
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildPermissionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required bool isGranted,
  }) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isGranted ? Icons.check_circle : Icons.cancel,
            color: isGranted ? Colors.green : Colors.red,
            size: 20,
          ),
          const SizedBox(width: 4),
          Text(
            isGranted ? t.permissions.granted : t.permissions.denied,
            style: TextStyle(
              color: isGranted ? Colors.green : Colors.red,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Drive同期設定画面
class SyncSettingsScreen extends StatefulWidget {
  final bool isEmbedded;
  const SyncSettingsScreen({super.key, this.isEmbedded = false});

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  final GoogleDriveService _driveService = GoogleDriveService();
  bool _autoSyncEnabled = true;
  int _intervalMinutes = kAutoSyncDefaultInterval;
  bool _isAccountLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
    _initDrive();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoSyncEnabled = prefs.getBool(kAutoSyncEnabledKey) ?? true;
      _intervalMinutes =
          prefs.getInt(kAutoSyncIntervalKey) ?? kAutoSyncDefaultInterval;
    });
  }

  Future<void> _initDrive() async {
    await _driveService.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _handleSignIn() async {
    setState(() => _isAccountLoading = true);
    try {
      await _driveService.signIn();
    } finally {
      if (mounted) setState(() => _isAccountLoading = false);
    }
  }

  Future<void> _handleSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.logout, color: Colors.orange, size: 36),
        title: Text(t.drive.signOut),
        content: Text(t.drive.signOutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.drive.signOut),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isAccountLoading = true);
    try {
      await _driveService.signOut();
    } finally {
      if (mounted) setState(() => _isAccountLoading = false);
    }
  }

  Future<void> _handleSwitchAccount() async {
    setState(() => _isAccountLoading = true);
    try {
      await _driveService.switchAccount();
    } finally {
      if (mounted) setState(() => _isAccountLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: t.settings.categories.sync,
      isEmbedded: widget.isEmbedded,
      body: ListenableBuilder(
        listenable: _driveService.authState,
        builder: (context, _) {
          return SettingsBody(
            sections: [
              // Google Account セクション
              _buildAccountSection(),
              // Auto Sync セクション
              SettingsSection(
                title: 'Auto Sync',
                icon: Icons.sync,
                iconColor: Colors.blue,
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.wifi, color: Colors.blue),
                    title: const Text('WiFi Auto Sync'),
                    subtitle: const Text('Sync automatically when connected to WiFi'),
                    value: _autoSyncEnabled,
                    onChanged: (v) async {
                      setState(() => _autoSyncEnabled = v);
                      await AutoSyncService.instance.setEnabled(v);
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.timer, color: Colors.blueGrey),
                    title: const Text('Sync Interval'),
                    subtitle: Text('Every $_intervalMinutes min'),
                    trailing: DropdownButton<int>(
                      value: _intervalMinutes,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 min')),
                        DropdownMenuItem(value: 3, child: Text('3 min')),
                        DropdownMenuItem(value: 5, child: Text('5 min')),
                        DropdownMenuItem(value: 10, child: Text('10 min')),
                        DropdownMenuItem(value: 30, child: Text('30 min')),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        setState(() => _intervalMinutes = v);
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setInt(kAutoSyncIntervalKey, v);
                      },
                    ),
                  ),
                ],
              ),
              const SettingsSection(
                title: 'Info',
                icon: Icons.info_outline,
                iconColor: Colors.grey,
                children: [
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Auto sync runs only over WiFi to save mobile data.\n\n'
                      'When both local and Drive have changes to the same file '
                      '(conflict), sync pauses and shows a warning on the folder. '
                      'Tap the subtitle to resolve manually.',
                      style: TextStyle(height: 1.5, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// Google Account セクション
  Widget _buildAccountSection() {
    final isAuthenticated = _driveService.authState.isAuthenticated;
    final user = _driveService.authState.user;

    return SettingsSection(
      title: t.drive.googleAccount,
      icon: Icons.account_circle,
      iconColor: isAuthenticated ? Colors.green : Colors.grey,
      children: [
        if (_isAccountLoading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (isAuthenticated && user != null) ...[
          // 認証済み: ユーザー情報表示
          ListTile(
            leading: const Icon(Icons.check_circle, color: Colors.green),
            title: Text(
              user.email,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: user.displayName != null
                ? Text(user.displayName!)
                : null,
          ),
          const Divider(),
          // アクションボタン
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _handleSwitchAccount,
                    icon: const Icon(Icons.swap_horiz),
                    label: Text(t.drive.switchAccount),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _handleSignOut,
                    icon: const Icon(Icons.logout, color: Colors.red),
                    label: Text(
                      t.drive.signOut,
                      style: const TextStyle(color: Colors.red),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          // 未認証: サインインボタン
          ListTile(
            leading: const Icon(Icons.cloud_off, color: Colors.grey),
            title: Text(t.drive.notSignedIn),
            subtitle: Text(t.drive.switchAccountDesc),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _handleSignIn,
                icon: const Icon(Icons.login),
                label: Text(t.drive.signInWithGoogle),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
