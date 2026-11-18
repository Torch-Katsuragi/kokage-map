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

/// 外部計測機器（外部GNSS・測距器・NTRIP）の永続接続・切断ログ表示セクション
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../providers/notification_providers.dart';
import '../services/device_connection_log_service.dart';
import 'settings_widgets.dart';

class DeviceConnectionLogSection extends ConsumerWidget {
  const DeviceConnectionLogSection({
    super.key,
    this.logService,
    this.maxVisibleEntries = 50,
  });

  final DeviceConnectionLogService? logService;
  final int maxVisibleEntries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = logService ?? DeviceConnectionLogService.instance;
    final tr = t.devices.connectionLog;

    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final entries = svc.events.take(maxVisibleEntries).toList();
        return SettingsSection(
          title: tr.title,
          icon: Icons.history,
          iconColor: Colors.teal,
          collapsible: true,
          trailing: entries.isEmpty
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const Key('copy_device_connection_log'),
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: tr.copy,
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: svc.exportAsText()),
                        );
                        ref.read(notificationCenterProvider.notifier).add(
                              title: tr.copied,
                              level: NotificationLevel.success,
                            );
                      },
                    ),
                    IconButton(
                      key: const Key('clear_device_connection_log'),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: tr.clear,
                      visualDensity: VisualDensity.compact,
                      onPressed: svc.clear,
                    ),
                  ],
                ),
          children: entries.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      tr.empty,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ]
              : [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final ev = entries[index];
                        final visual = _eventVisual(ev);
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(visual.icon, size: 15, color: visual.color),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          visual.label,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                            color: visual.color,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            ev.deviceName,
                                            style: const TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Text(
                                          ev.formatTimestampLocal(),
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontFamily: 'monospace',
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (ev.detail != null &&
                                        ev.detail!.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 1),
                                        child: Text(
                                          ev.detail!,
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            color: Colors.black54,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
        );
      },
    );
  }

  static ({IconData icon, Color color, String label}) _eventVisual(
    DeviceConnectionEvent ev,
  ) {
    final tr = t.devices.connectionLog;
    return switch (ev.type) {
      DeviceConnectionEventType.connected => (
          icon: Icons.check_circle_outline,
          color: Colors.green.shade700,
          label: tr.evConnected,
        ),
      DeviceConnectionEventType.disconnected => (
          icon: Icons.link_off,
          color: Colors.red.shade700,
          label: tr.evDisconnected,
        ),
      DeviceConnectionEventType.reconnecting => (
          icon: Icons.bluetooth_searching,
          color: Colors.orange.shade800,
          label: tr.evReconnecting,
        ),
      DeviceConnectionEventType.reconnectFailed => (
          icon: Icons.error_outline,
          color: Colors.red.shade800,
          label: tr.evReconnectFailed,
        ),
      DeviceConnectionEventType.fallbackInternal => (
          icon: Icons.swap_horiz,
          color: Colors.amber.shade900,
          label: tr.evFallbackInternal,
        ),
      DeviceConnectionEventType.resumedExternal => (
          icon: Icons.satellite_alt,
          color: Colors.teal.shade700,
          label: tr.evResumedExternal,
        ),
    };
  }
}
