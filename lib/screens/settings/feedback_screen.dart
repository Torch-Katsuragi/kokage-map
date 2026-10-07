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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import '../../widgets/settings_widgets.dart';

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
    void error(String title) => ref.read(notificationCenterProvider.notifier).add(
          title: title,
          level: NotificationLevel.error,
        );
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
      if (!launched) error(t.settings.feedback.browserError);
    } catch (e) {
      error(t.settings.feedback.errorOccurred(error: e.toString()));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tr = t.settings.feedback;
    return SettingsScaffold(
      title: tr.title,
      isEmbedded: isEmbedded,
      body: SettingsBody(
        sections: [
          SettingsHighlightSection(
            title: tr.callToAction,
            icon: Icons.mail_outline,
            iconColor: Colors.blue,
            backgroundColor: Colors.blue.shade50,
            description: tr.description,
            actionButton: ElevatedButton.icon(
              onPressed: () => _openFeedbackForm(ref),
              icon: const Icon(Icons.open_in_new),
              label: Text(tr.openForm),
              style: settingsButtonStyle(
                Colors.blue,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          SettingsSection(
            title: tr.feedbackTypes,
            icon: Icons.category,
            iconColor: Colors.orange,
            children: [
              ListTile(
                leading: const Icon(Icons.lightbulb_outline, color: Colors.amber),
                title: Text(tr.featureRequest),
                subtitle: Text(tr.featureRequestDesc),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.bug_report, color: Colors.red),
                title: Text(tr.bugReport),
                subtitle: Text(tr.bugReportDesc),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.thumb_up_outlined, color: Colors.green),
                title: Text(tr.other),
                subtitle: Text(tr.otherDesc),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
