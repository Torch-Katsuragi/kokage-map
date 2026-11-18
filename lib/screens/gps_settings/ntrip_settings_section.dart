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

/// GPS 設定画面内の内蔵 NTRIP クライアント設定セクション＆マウントポイント選択ダイアログ
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/ntrip_config.dart';
import '../../providers/gps_providers.dart';
import '../../providers/notification_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/gps_manager_service.dart';
import '../../services/ntrip/ntrip_client_service.dart';
import '../../widgets/settings_widgets.dart';

class NtripSettingsSection extends ConsumerStatefulWidget {
  const NtripSettingsSection({super.key});

  @override
  ConsumerState<NtripSettingsSection> createState() => _NtripSettingsSectionState();
}

class _NtripSettingsSectionState extends ConsumerState<NtripSettingsSection> {
  final NtripClientService _ntrip = NtripClientService.instance;
  final GpsManagerService _gps = GpsManagerService();

  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _mountCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;

  bool _obscurePassword = true;
  bool _fetchingMountpoints = false;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(ntripConfigSettingProvider);
    _hostCtrl = TextEditingController(text: cfg.host);
    _portCtrl = TextEditingController(text: '${cfg.port}');
    _mountCtrl = TextEditingController(text: cfg.mountpoint);
    _userCtrl = TextEditingController(text: cfg.username);
    _passCtrl = TextEditingController(text: cfg.password);
    _ntrip.addListener(_onChanged);
    _gps.addListener(_onChanged);
  }

  @override
  void dispose() {
    _ntrip.removeListener(_onChanged);
    _gps.removeListener(_onChanged);
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _mountCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  NtripConfig _collectFormConfig() {
    final current = ref.read(ntripConfigSettingProvider);
    final parsedPort = int.tryParse(_portCtrl.text.trim()) ?? current.port;
    return current.copyWith(
      host: _hostCtrl.text.trim(),
      port: parsedPort.clamp(1, 65535),
      mountpoint: _mountCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text,
    );
  }

  Future<NtripConfig> _persistFormConfig() async {
    final next = _collectFormConfig();
    await ref.read(ntripConfigSettingProvider.notifier).set(next);
    return next;
  }

  void _notify(String title, NotificationLevel level) {
    if (!mounted) return;
    ref.read(notificationCenterProvider.notifier).add(title: title, level: level);
  }

  Future<void> _fillRtk2goPreset() async {
    _hostCtrl.text = 'rtk2go.com';
    _portCtrl.text = '2101';
    final next = _collectFormConfig().copyWith(useTls: false);
    await ref.read(ntripConfigSettingProvider.notifier).set(next);
    _notify(t.ntrip.rtk2goHint, NotificationLevel.info);
  }

  Future<void> _toggleConnection() async {
    if (_ntrip.isActive) {
      await _ntrip.disconnect();
      return;
    }
    final cfg = await _persistFormConfig();
    if (!cfg.isConfigured) {
      _notify(t.ntrip.errInvalidConfig, NotificationLevel.warning);
      return;
    }
    await _ntrip.connect(cfg);
  }

  LatLng? _referenceLocation() {
    final cam = ref.read(mapControllerHolderProvider)?.camera.center;
    return _gps.currentInfo.positionOr(cam);
  }

  Future<void> _browseMountpoints() async {
    final cfg = await _persistFormConfig();
    if (!cfg.canFetchMountpoints) {
      _notify(t.ntrip.errInvalidConfig, NotificationLevel.warning);
      return;
    }
    setState(() => _fetchingMountpoints = true);
    try {
      final list = await _ntrip.fetchMountpoints(cfg);
      if (!mounted) return;
      final here = _referenceLocation();
      final sorted = [...list]..sort((a, b) {
          final da = a.distanceKmFrom(here);
          final db = b.distanceKmFrom(here);
          if (da != null && db != null) return da.compareTo(db);
          if (da != null) return -1;
          if (db != null) return 1;
          return a.mountpoint.compareTo(b.mountpoint);
        });

      final picked = await showDialog<NtripMountpoint>(
        context: context,
        builder: (_) => _MountpointPickerDialog(
          mountpoints: sorted,
          referenceLocation: here,
        ),
      );
      if (picked != null && mounted) {
        _mountCtrl.text = picked.mountpoint;
        final updated = _collectFormConfig().copyWith(
          mountpoint: picked.mountpoint,
          sendGga: picked.requiresNmea ? true : cfg.sendGga,
        );
        await ref.read(ntripConfigSettingProvider.notifier).set(updated);
      }
    } catch (e) {
      _notify(t.ntrip.statusError(message: '$e'), NotificationLevel.error);
    } finally {
      if (mounted) setState(() => _fetchingMountpoints = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(ntripConfigSettingProvider);
    final n = t.ntrip;
    final status = _ntrip.status;
    final kb = (_ntrip.receivedBytes / 1024.0).toStringAsFixed(1);
    final msgTypes = _ntrip.messageTypes;

    final (statusColor, statusIcon, statusLabel) = switch (status) {
      NtripStatus.streaming => (Colors.green.shade700, Icons.cell_tower, n.statusStreaming),
      NtripStatus.connecting => (Colors.blue.shade700, Icons.sync, n.statusConnecting),
      NtripStatus.reconnecting => (
          Colors.orange.shade800,
          Icons.sync_problem,
          n.statusReconnecting(seconds: '${_ntrip.reconnectDelaySeconds}'),
        ),
      NtripStatus.error => (
          Colors.red.shade700,
          Icons.error_outline,
          n.statusError(message: _ntrip.errorMessage ?? ''),
        ),
      NtripStatus.disconnected => (Colors.grey.shade700, Icons.portable_wifi_off, n.statusDisconnected),
    };

    return SettingsSection(
      title: n.title,
      icon: Icons.cell_tower,
      iconColor: Colors.teal,
      children: [
        SettingsDescription(n.description),
        const SizedBox(height: 8),

        // ライブ状態カード ＋ 開始／停止ボタン
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: statusColor.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(statusIcon, size: 20, color: statusColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      statusLabel,
                      style: TextStyle(fontWeight: FontWeight.bold, color: statusColor),
                    ),
                  ),
                ],
              ),
              if (status == NtripStatus.streaming || _ntrip.receivedBytes > 0) ...[
                const SizedBox(height: 6),
                Text(
                  n.statsSummary(kb: kb, frames: '${_ntrip.validRtcmFrames}'),
                  style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                ),
                if (msgTypes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      n.msgTypes(types: msgTypes.join(', ')),
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                  ),
              ],
              if (_ntrip.isActive && !_gps.isExternalConnected)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 14, color: Colors.orange.shade800),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          n.gnssWarning,
                          style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _toggleConnection,
                  icon: Icon(_ntrip.isActive ? Icons.stop : Icons.play_arrow),
                  label: Text(_ntrip.isActive ? n.disconnect : n.connect),
                  style: settingsButtonStyle(
                    _ntrip.isActive ? Colors.red.shade600 : Colors.teal,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.public, size: 16),
              label: Text(n.rtk2goPreset, style: const TextStyle(fontSize: 12.5)),
              onPressed: _fillRtk2goPreset,
            ),
          ),
        ),

        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostCtrl,
                  decoration: InputDecoration(
                    labelText: n.host,
                    hintText: n.hostHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => unawaited(_persistFormConfig()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _portCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: n.port,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => unawaited(_persistFormConfig()),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _mountCtrl,
                  decoration: InputDecoration(
                    labelText: n.mountpoint,
                    hintText: n.mountpointHint,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => unawaited(_persistFormConfig()),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _fetchingMountpoints ? null : _browseMountpoints,
                icon: _fetchingMountpoints
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore, size: 18),
                label: Text(n.browseMountpoints),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _userCtrl,
            decoration: InputDecoration(
              labelText: n.username,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => unawaited(_persistFormConfig()),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _passCtrl,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              labelText: n.password,
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off, size: 18),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            onChanged: (_) => unawaited(_persistFormConfig()),
          ),
        ),

        const SizedBox(height: 6),
        SettingsSwitchTile(
          title: n.useTls,
          value: cfg.useTls,
          onChanged: (v) =>
              ref.read(ntripConfigSettingProvider.notifier).set(_collectFormConfig().copyWith(useTls: v)),
        ),
        SettingsSwitchTile(
          title: n.sendGga,
          subtitle: n.sendGgaDesc,
          value: cfg.sendGga,
          onChanged: (v) =>
              ref.read(ntripConfigSettingProvider.notifier).set(_collectFormConfig().copyWith(sendGga: v)),
        ),
        SettingsCollapsibleChild(
          visible: cfg.sendGga,
          child: SettingsTile(
            title: n.ggaInterval,
            trailing: DropdownButton<int>(
              value: NtripConfig.ggaIntervalOptions.contains(cfg.ggaIntervalSeconds)
                  ? cfg.ggaIntervalSeconds
                  : 10,
              items: [
                for (final sec in NtripConfig.ggaIntervalOptions)
                  DropdownMenuItem(value: sec, child: Text(t.trackRecording.seconds(n: '$sec'))),
              ],
              onChanged: (sec) {
                if (sec != null) {
                  ref
                      .read(ntripConfigSettingProvider.notifier)
                      .set(_collectFormConfig().copyWith(ggaIntervalSeconds: sec));
                }
              },
            ),
          ),
        ),
        SettingsSwitchTile(
          title: n.autoConnect,
          subtitle: n.autoConnectDesc,
          value: cfg.autoConnectWithGnss,
          onChanged: (v) => ref
              .read(ntripConfigSettingProvider.notifier)
              .set(_collectFormConfig().copyWith(autoConnectWithGnss: v)),
        ),
      ],
    );
  }
}

class _MountpointPickerDialog extends StatefulWidget {
  const _MountpointPickerDialog({
    required this.mountpoints,
    required this.referenceLocation,
  });

  final List<NtripMountpoint> mountpoints;
  final LatLng? referenceLocation;

  @override
  State<_MountpointPickerDialog> createState() => _MountpointPickerDialogState();
}

class _MountpointPickerDialogState extends State<_MountpointPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = [
      for (final m in widget.mountpoints)
        if (q.isEmpty ||
            m.mountpoint.toLowerCase().contains(q) ||
            m.identifier.toLowerCase().contains(q) ||
            m.format.toLowerCase().contains(q) ||
            m.navSystem.toLowerCase().contains(q) ||
            m.country.toLowerCase().contains(q))
          m,
    ];

    return AlertDialog(
      title: Text(t.ntrip.mountpointDialogTitle(count: '${filtered.length}')),
      content: SizedBox(
        width: 420,
        height: 440,
        child: Column(
          children: [
            TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: t.ntrip.mountpointSearchHint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        t.ntrip.mountpointEmpty,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final mp = filtered[index];
                        final distKm = mp.distanceKmFrom(widget.referenceLocation);
                        final tags = [
                          if (distKm != null) t.ntrip.distanceKm(km: distKm.toStringAsFixed(1)),
                          if (mp.format.isNotEmpty) mp.format,
                          if (mp.navSystem.isNotEmpty) mp.navSystem,
                          if (mp.requiresNmea) t.ntrip.vrsTag,
                        ];
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          title: Text(
                            mp.identifier.isNotEmpty
                                ? '${mp.mountpoint} — ${mp.identifier}'
                                : mp.mountpoint,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                          ),
                          subtitle: Text(
                            tags.join(' · '),
                            style: const TextStyle(fontSize: 11.5),
                          ),
                          onTap: () => Navigator.pop(context, mp),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.cancel),
        ),
      ],
    );
  }
}
