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
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/map_layout.dart';
import '../../core/platform_capabilities.dart';
import '../../core/role_preset.dart';
import '../../i18n/strings.g.dart';
import '../../main.dart' show kAppLocaleKey;
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import '../../providers/project_providers.dart';
import '../../providers/role_preset_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/global_folder_locator.dart';
import '../../tutorial/tutorial.dart';
import '../../utils/app_permissions.dart';
import '../../utils/folder_utils.dart';
import '../../widgets/settings_widgets.dart';

/// グローバルフォルダのカスタムパス用SharedPreferencesキー
const kGlobalFolderCustomPathKey = 'global_folder_custom_path';

/// 一般設定画面（言語・UIサイズ・画面の配置・グローバルフォルダ・権限）
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
    final p = await AppPermissions.current();
    if (mounted) {
      setState(() {
        _storageGranted = p.storage;
        _locationGranted = p.location;
        _bluetoothGranted = p.bluetooth;
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

  String _localeName(AppLocale locale) => switch (locale) {
        AppLocale.en => t.settings.general.languageNames.en,
        AppLocale.ja => t.settings.general.languageNames.ja,
      };

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: t.settings.globalFolder.selectFolder,
    );
    if (dir == null) return;

    // 含有関係チェック（プロジェクトフォルダが開いている場合）
    final projectDir = ref.read(projectRootDirProvider);
    if (projectDir != null) {
      final warning = checkContainmentRelation(dir, projectDir);
      if (warning != null && mounted) {
        final proceed = await showSettingsConfirmDialog(
          context,
          icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
          title: t.settings.globalFolder.containmentWarning,
          message: warning,
          confirmLabel: t.settings.globalFolder.useAnyway,
        );
        if (!proceed) return;
      }
    }

    await _applyCustomPath(dir, t.settings.globalFolder.updated);
  }

  Future<void> _resetToDefault() => _applyCustomPath(null, t.settings.globalFolder.resetDone);

  /// カスタムパスを保存して実行中のプロバイダに反映する（null なら既定に戻す）
  Future<void> _applyCustomPath(String? dir, String message) async {
    final prefs = await SharedPreferences.getInstance();
    if (dir == null) {
      await prefs.remove(kGlobalFolderCustomPathKey);
    } else {
      await prefs.setString(kGlobalFolderCustomPathKey, dir);
    }
    setState(() => _customPath = dir);
    ref.read(globalFolderPathProvider.notifier).set(dir ?? _defaultPath);

    ref.read(notificationCenterProvider.notifier).add(
          title: message,
          level: NotificationLevel.info,
        );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: t.settings.general.title,
      isEmbedded: widget.isEmbedded,
      isLoading: _isLoading,
      body: SettingsBody(
        sections: [
          _buildRolePresetSection(),
          _buildLanguageSection(),

          // チュートリアル（練習用の地図。ホームに戻ってから始める）
          if (fs.hasRealPaths)
            SettingsSection(
              title: t.tutorial.settingsTitle,
              icon: Icons.school_outlined,
              iconColor: Colors.teal,
              children: [
                ListTile(
                  leading: const Icon(Icons.play_arrow),
                  title: Text(t.tutorial.start),
                  subtitle: Text(t.tutorial.settingsSubtitle),
                  onTap: () {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    tutorialRequests.request();
                  },
                ),
              ],
            ),

          _buildUiScaleSection(),
          _buildLayoutSection(),

          if (_hasGlobalFolder) ...[
            _buildGlobalFolderSection(),
            SettingsInfoSection(t.settings.globalFolder.infoText),
          ],

          // 権限管理セクション（Android/iOS時のみ）
          if (_isMobileDevice) _buildPermissionSection(),
        ],
      ),
    );
  }

  /// 用途プリセット（現場別レシピ＋ボタン表示の引き算調整）セクション
  Widget _buildRolePresetSection() {
    final activePreset = ref.watch(rolePresetSettingProvider);
    final uiConfig = ref.watch(uiVisibilitySettingProvider);
    final rp = t.rolePreset;
    final isUiCustomized = uiConfig != activePreset.recipe.ui;

    Future<void> selectPreset(RolePreset preset) async {
      await ref.read(rolePresetSettingProvider.notifier).apply(preset);
      if (!mounted) return;
      ref.read(notificationCenterProvider.notifier).add(
            title: rp.applied(name: preset.title),
            level: NotificationLevel.info,
          );
    }

    return SettingsSection(
      title: rp.title,
      icon: Icons.tune,
      iconColor: Colors.teal,
      children: [
        SettingsDescription(rp.description),
        const SizedBox(height: 8),
        for (final preset in RolePreset.values)
          _buildRolePresetTile(
            preset,
            isSelected: preset == activePreset,
            isCustomized: preset == activePreset && isUiCustomized,
            onTap: () => selectPreset(preset),
          ),
        if (isUiCustomized)
          Padding(
            padding: const EdgeInsets.only(right: 12, top: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => selectPreset(activePreset),
                icon: const Icon(Icons.restore, size: 18),
                label: Text(rp.reapply),
              ),
            ),
          ),
        const Divider(height: 16),
        ExpansionTile(
          leading: const Icon(Icons.visibility_outlined, color: Colors.blueGrey),
          title: Text(rp.customizeTitle, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: Text(rp.customizeDesc, style: const TextStyle(fontSize: 12)),
          children: [
            SwitchListTile(
              dense: true,
              title: Text(rp.showPenTool),
              subtitle: Text(rp.showPenToolDesc),
              value: uiConfig.showPenTool,
              onChanged: (v) =>
                  ref.read(uiVisibilitySettingProvider.notifier).updateConfig((c) => c.copyWith(showPenTool: v)),
            ),
            SwitchListTile(
              dense: true,
              title: Text(rp.showGpsTool),
              subtitle: Text(rp.showGpsToolDesc),
              value: uiConfig.showGpsTool,
              onChanged: (v) =>
                  ref.read(uiVisibilitySettingProvider.notifier).updateConfig((c) => c.copyWith(showGpsTool: v)),
            ),
            SwitchListTile(
              dense: true,
              title: Text(rp.showMeasureTool),
              subtitle: Text(rp.showMeasureToolDesc),
              value: uiConfig.showMeasureTool,
              onChanged: (v) =>
                  ref.read(uiVisibilitySettingProvider.notifier).updateConfig((c) => c.copyWith(showMeasureTool: v)),
            ),
            SwitchListTile(
              dense: true,
              title: Text(rp.showAttributeTableButton),
              subtitle: Text(rp.showAttributeTableButtonDesc),
              value: uiConfig.showAttributeTableButton,
              onChanged: (v) => ref
                  .read(uiVisibilitySettingProvider.notifier)
                  .updateConfig((c) => c.copyWith(showAttributeTableButton: v)),
            ),
            SwitchListTile(
              dense: true,
              title: Text(rp.showAdvancedSettings),
              subtitle: Text(rp.showAdvancedSettingsDesc),
              value: uiConfig.showAdvancedSettings,
              onChanged: (v) => ref
                  .read(uiVisibilitySettingProvider.notifier)
                  .updateConfig((c) => c.copyWith(showAdvancedSettings: v)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRolePresetTile(
    RolePreset preset, {
    required bool isSelected,
    required bool isCustomized,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isSelected ? preset.color.withValues(alpha: 0.08) : scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSelected ? preset.color : Colors.grey.withValues(alpha: 0.25),
          width: isSelected ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: preset.color.withValues(alpha: 0.15),
          child: Icon(preset.icon, color: preset.color, size: 22),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                preset.title,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                ),
              ),
            ),
            if (isCustomized) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  t.rolePreset.customizedBadge,
                  style: const TextStyle(fontSize: 11, color: Colors.deepOrange, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(preset.description, style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 4),
            Text(
              preset.summary,
              style: TextStyle(fontSize: 11.5, color: preset.color, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        trailing: Icon(
          isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: isSelected ? preset.color : Colors.grey,
        ),
        onTap: onTap,
      ),
    );
  }

  /// 言語設定セクション
  Widget _buildLanguageSection() {
    final currentLocale = LocaleSettings.currentLocale;
    return SettingsSection(
      title: t.settings.general.language,
      icon: Icons.language,
      iconColor: Colors.indigo,
      children: [
        SettingsDescription(t.settings.general.languageDesc),
        const SizedBox(height: 8),
        for (final locale in AppLocale.values)
          _buildLocaleTile(locale, isSelected: locale == currentLocale),
      ],
    );
  }

  Widget _buildLocaleTile(AppLocale locale, {required bool isSelected}) {
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
  }

  /// 画面の配置（プリセット）
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
        SettingsDescription(tr.layoutDesc),
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

  /// UIサイズ調整セクション
  Widget _buildUiScaleSection() {
    final scaleLevel = ref.watch(uiScaleLevelProvider);
    final tr = t.settings.general;
    final labels = [
      tr.uiScaleLabels.k0,
      tr.uiScaleLabels.k1,
      tr.uiScaleLabels.k2,
      tr.uiScaleLabels.k3,
      tr.uiScaleLabels.k4,
      tr.uiScaleLabels.k5,
      tr.uiScaleLabels.k6,
    ];
    final names = [
      tr.uiScaleNames.k0,
      tr.uiScaleNames.k1,
      tr.uiScaleNames.k2,
      tr.uiScaleNames.k3,
      tr.uiScaleNames.k4,
      tr.uiScaleNames.k5,
      tr.uiScaleNames.k6,
    ];
    final primary = Theme.of(context).colorScheme.primary;

    return SettingsSection(
      title: tr.uiScale,
      icon: Icons.format_size,
      iconColor: Colors.teal,
      children: [
        SettingsDescription(tr.uiScaleDesc),
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
                  color: primary,
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
            children: List.generate(labels.length, (i) {
              final isSelected = i == scaleLevel;
              return Text(
                labels[i],
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? primary : Colors.grey[500],
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  /// グローバルフォルダセクション
  Widget _buildGlobalFolderSection() {
    final tr = t.settings.globalFolder;
    return SettingsSection(
      title: tr.title,
      icon: Icons.folder_special,
      iconColor: Colors.blue,
      children: [
        SettingsDescription(tr.description),
        const SizedBox(height: 12),
        ListTile(
          leading: Icon(
            _isCustom ? Icons.folder : Icons.folder_outlined,
            color: _isCustom ? Colors.blue : Colors.blueGrey,
          ),
          title: Text(_isCustom ? tr.customPath : tr.defaultPath),
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
                  label: Text(tr.changeFolder),
                  style: settingsButtonStyle(Colors.blue),
                ),
              ),
              if (_isCustom) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _resetToDefault,
                  icon: const Icon(Icons.restore),
                  label: Text(t.common.reset),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 権限管理セクション
  Widget _buildPermissionSection() {
    final permissions = [
      (Icons.folder, Colors.orange, t.onboarding.storageTitle, _storageGranted),
      (Icons.gps_fixed, Colors.green, t.onboarding.locationTitle, _locationGranted),
      (Icons.bluetooth, Colors.blue, t.onboarding.bluetoothTitle, _bluetoothGranted),
    ];
    return SettingsSection(
      title: t.home.permissionRequired,
      icon: Icons.security,
      iconColor: Colors.deepPurple,
      children: [
        for (final (icon, color, title, granted) in permissions) ...[
          _buildPermissionTile(icon: icon, iconColor: color, title: title, isGranted: granted),
          const Divider(),
        ],
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
            style: settingsButtonStyle(Colors.deepPurple),
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required bool isGranted,
  }) {
    final color = isGranted ? Colors.green : Colors.red;
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isGranted ? Icons.check_circle : Icons.cancel, color: color, size: 20),
          const SizedBox(width: 4),
          Text(
            isGranted ? t.permissions.granted : t.permissions.denied,
            style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
