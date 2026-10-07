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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import '../../services/google_drive/auto_sync_service.dart';
import '../../services/google_drive/google_drive_service.dart';
import '../../widgets/settings_widgets.dart';

/// Drive同期設定画面
class SyncSettingsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;
  const SyncSettingsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  final GoogleDriveService _driveService = GoogleDriveService();
  bool _autoSyncEnabled = true;
  int _intervalMinutes = kAutoSyncDefaultInterval;
  bool _isAccountLoading = false;

  /// 同期間隔の選択肢（分）
  static const _intervalChoices = [1, 3, 5, 10, 30];

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

  /// アカウント操作の間はぐるぐるを出す
  Future<void> _withAccountLoading(Future<void> Function() action) async {
    setState(() => _isAccountLoading = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _isAccountLoading = false);
    }
  }

  Future<void> _handleSignIn() => _withAccountLoading(() async {
        if (!await _driveService.signIn()) _showAuthError();
      });

  Future<void> _handleSwitchAccount() => _withAccountLoading(() async {
        if (!await _driveService.switchAccount()) _showAuthError();
      });

  /// サインイン／アカウント切替の失敗を出す
  ///
  /// 本当のユーザーキャンセルなら `errorMessage` が null なので何も出さない。
  void _showAuthError() {
    final message = _driveService.authState.errorMessage;
    if (message == null || !mounted) return;
    ref.read(notificationCenterProvider.notifier).add(title: message, level: NotificationLevel.error);
  }

  Future<void> _handleSignOut() async {
    final confirmed = await showSettingsConfirmDialog(
      context,
      icon: const Icon(Icons.logout, color: Colors.orange, size: 36),
      title: t.drive.signOut,
      message: t.drive.signOutConfirm,
      confirmLabel: t.drive.signOut,
    );
    if (!confirmed) return;
    await _withAccountLoading(_driveService.signOut);
  }

  Future<void> _setInterval(int? minutes) async {
    if (minutes == null) return;
    setState(() => _intervalMinutes = minutes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kAutoSyncIntervalKey, minutes);
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.settings.autoSync;
    return SettingsScaffold(
      title: t.settings.categories.sync,
      isEmbedded: widget.isEmbedded,
      body: ListenableBuilder(
        listenable: _driveService.authState,
        builder: (context, _) {
          return SettingsBody(
            sections: [
              _buildAccountSection(),
              SettingsSection(
                title: tr.title,
                icon: Icons.sync,
                iconColor: Colors.blue,
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.wifi, color: Colors.blue),
                    title: Text(tr.wifiAutoSync),
                    subtitle: Text(tr.wifiAutoSyncDesc),
                    value: _autoSyncEnabled,
                    onChanged: (v) async {
                      setState(() => _autoSyncEnabled = v);
                      await AutoSyncService.instance.setEnabled(v);
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.timer, color: Colors.blueGrey),
                    title: Text(tr.interval),
                    subtitle: Text(tr.everyMinutes(minutes: _intervalMinutes)),
                    trailing: DropdownButton<int>(
                      value: _intervalMinutes,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final m in _intervalChoices)
                          DropdownMenuItem(
                            value: m,
                            child: Text(tr.minutes(count: m)),
                          ),
                      ],
                      onChanged: _setInterval,
                    ),
                  ),
                ],
              ),
              SettingsInfoSection(tr.infoText),
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
                style: settingsButtonStyle(Colors.blue),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
