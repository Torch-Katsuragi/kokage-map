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
/// 外部計測機器の接続管理画面
///
/// ペアリング済み Bluetooth デバイスを一覧表示し、
/// 対応する [ExternalDeviceService] への接続/切断を行う。
library;
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../devices/base/device_service.dart';
import '../devices/trupulse/trupulse_detail_screen.dart';
import '../devices/trupulse/trupulse_providers.dart';
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../providers/notification_providers.dart';
import '../services/gps_manager_service.dart';
import '../utils/app_logger.dart';
import '../utils/app_permissions.dart';
import '../widgets/device_connection_log_section.dart';
import '../widgets/settings_widgets.dart';

class DeviceSettingsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;
  const DeviceSettingsScreen({super.key, this.isEmbedded = false});

  @override
  ConsumerState<DeviceSettingsScreen> createState() =>
      _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends ConsumerState<DeviceSettingsScreen> {
  List<BluetoothDevice> _bondedDevices = [];
  bool _isScanning = false;

  late final List<ExternalDeviceService> _services;
  final GpsManagerService _gpsManager = GpsManagerService();

  static const List<String> _gnssKeywords = [
    'GNSS',
    'GPS',
    'RTK',
    'DROGGER',
    'DG-PRO',
    'RZS',
    'RWP',
    'GARMIN',
    'GLO',
    'UBLOX',
    'ZED',
    'BAD ELF',
    'TRIMBLE',
    'TOPCON',
    'SOKKIA',
    'LEICA',
    'SEPTENTRIO',
    'EMLID',
    'REACH',
    'QSTARZ',
  ];

  @override
  void initState() {
    super.initState();
    _services = [ref.read(trupulseServiceProvider)];
    for (final s in _services) {
      s.addListener(_onServiceChanged);
    }
    _gpsManager.addListener(_onServiceChanged);
    _scan();
  }

  @override
  void dispose() {
    for (final s in _services) {
      s.removeListener(_onServiceChanged);
    }
    _gpsManager.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  /// 通知センターに出す（画面が閉じていれば何もしない）
  void _showMessage(String message) {
    if (!mounted) return;
    ref.read(notificationCenterProvider.notifier).add(title: message, level: NotificationLevel.warning);
  }

  Future<bool> _ensureBluetoothPermissions() async {
    if (await AppPermissions.bluetoothGranted()) return true;
    final ok = await AppPermissions.requestBluetooth();
    if (!ok) _showMessage(t.devices.bluetoothPermission);
    return ok;
  }

  Future<void> _scan() async {
    setState(() => _isScanning = true);
    try {
      if (!await _ensureBluetoothPermissions()) return;

      final isEnabled =
          await FlutterBluetoothSerial.instance.isEnabled ?? false;
      if (!isEnabled) {
        _showMessage(t.devices.enableBluetooth);
        return;
      }
      final devices =
          await FlutterBluetoothSerial.instance.getBondedDevices();
      AppLogger.debug(
        '[DeviceSettings] ${devices.length} bonded devices: '
        '${devices.map((d) => "${d.name}(${d.address})").join(", ")}',
      );
      if (mounted) setState(() => _bondedDevices = devices);
    } catch (e) {
      AppLogger.debug('[DeviceSettings] scan error: $e');
      _showMessage(t.devices.scanError(error: e.toString()));
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  ExternalDeviceService? _matchingService(BluetoothDevice device) {
    final name = device.name?.toUpperCase() ?? '';
    // TruPulse: "TruPulse 360R", "LTI TruPulse", "TP360R" etc.
    if (name.contains('TRUPULSE') || name.contains('TP360') || name.contains('LTI')) {
      return ref.read(trupulseServiceProvider);
    }
    return null;
  }

  bool _looksLikeGnssDevice(BluetoothDevice device) {
    if (_matchingService(device) != null) return false;
    final name = device.name?.toUpperCase() ?? '';
    return _gnssKeywords.any(name.contains);
  }

  bool _isConnectedAsExternalGnss(BluetoothDevice device) =>
      _gpsManager.currentSource == GpsSourceType.external &&
      _gpsManager.selectedGnssDevice?.address == device.address &&
      _gpsManager.isExternalConnected;

  bool _isConnectingAsExternalGnss(BluetoothDevice device) =>
      _gpsManager.currentSource == GpsSourceType.external &&
      _gpsManager.selectedGnssDevice?.address == device.address &&
      _gpsManager.isExternalConnecting;

  Future<void> _connectExternalGnss(BluetoothDevice device) async {
    AppLogger.debug(
      '[DeviceSettings] connecting ${device.name}(${device.address}) as External GNSS',
    );
    try {
      await _gpsManager.switchGpsSource(GpsSourceType.external, device);
      if (!mounted) return;
      ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.switchedTo(name: device.name ?? t.gps.externalGnssName),
            level: NotificationLevel.success,
          );
    } catch (e) {
      AppLogger.debug('[DeviceSettings] GNSS connection failed: $e');
      _showMessage(t.devices.connectionFailed(error: e.toString()));
    }
  }

  Future<void> _disconnectExternalGnss() async {
    try {
      await _gpsManager.switchGpsSource(GpsSourceType.internal);
      if (!mounted) return;
      ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.switchedTo(name: GpsSourceType.internal.displayName),
            level: NotificationLevel.info,
          );
    } catch (e) {
      _showMessage(t.gps.switchError(error: e.toString()));
    }
  }

  Future<void> _connect(
      ExternalDeviceService service, BluetoothDevice device) async {
    AppLogger.debug(
      '[DeviceSettings] connecting ${device.name}(${device.address}) '
      'to ${service.deviceTypeName}',
    );
    try {
      await service.connectToDevice(device);
      AppLogger.debug('[DeviceSettings] connected successfully');
    } catch (e) {
      AppLogger.debug('[DeviceSettings] connection failed: $e');
      _showMessage(t.devices.connectionFailed(error: e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectedServices =
        _services.where((s) => s.isConnected).toList();
    final connectingServices =
        _services.where((s) => s.isConnecting || s.isReconnecting).toList();
    final gnssConnected = _gpsManager.isExternalConnected;
    final gnssConnecting =
        _gpsManager.isExternalConnecting || _gpsManager.isExternalReconnecting;
    final gnssDeviceName = _gpsManager.selectedGnssDevice?.name ?? t.gps.externalGnssName;

    return SettingsScaffold(
      title: t.devices.title,
      isEmbedded: widget.isEmbedded,
      actions: [
        IconButton(
          icon: _isScanning
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          tooltip: t.devices.scan,
          onPressed: _isScanning ? null : _scan,
        ),
      ],
      body: SettingsBody(
        sections: [
          // Connected devices
          if (connectedServices.isNotEmpty ||
              connectingServices.isNotEmpty ||
              gnssConnected ||
              gnssConnecting)
            SettingsSection(
              title: t.devices.connected,
              icon: Icons.bluetooth_connected,
              iconColor: Colors.blue,
              children: [
                if (gnssConnected || gnssConnecting)
                  ListTile(
                    leading: Icon(
                      Icons.satellite_alt,
                      color: gnssConnected ? Colors.blue : Colors.orange,
                    ),
                    title: Text('$gnssDeviceName (${t.gps.externalGnssName})'),
                    subtitle: Text(
                      _gpsManager.isExternalReconnecting
                          ? t.devices.reconnecting
                          : (gnssConnecting ? t.devices.connecting : t.devices.connected),
                    ),
                    trailing: (gnssConnected || _gpsManager.isExternalReconnecting)
                        ? TextButton(
                            onPressed: _disconnectExternalGnss,
                            child: Text(t.devices.disconnect),
                          )
                        : const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  ),
                for (final s in [...connectingServices, ...connectedServices])
                  ListTile(
                    leading: Icon(
                      Icons.bluetooth_connected,
                      color: s.isConnected ? Colors.blue : Colors.orange,
                    ),
                    title: Text(s.deviceTypeName),
                    subtitle: Text(s.isReconnecting
                        ? t.devices.reconnecting
                        : (s.isConnecting ? t.devices.connecting : t.devices.connected)),
                    trailing: (s.isConnected || s.isReconnecting)
                        ? TextButton(
                            onPressed: s.disconnect,
                            child: Text(t.devices.disconnect),
                          )
                        : const SizedBox.square(
                            dimension: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),

          // Paired devices
          SettingsSection(
            title: t.devices.pairedDevices,
            icon: Icons.bluetooth,
            iconColor: Colors.blueGrey,
              children: _bondedDevices.isEmpty
                ? [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        t.devices.noPairedDevices,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ]
                : [
                    for (final device in _bondedDevices)
                      _DeviceTile(
                        device: device,
                        service: _matchingService(device),
                        looksLikeGnss: _looksLikeGnssDevice(device),
                        isGnssConnected: _isConnectedAsExternalGnss(device),
                        isGnssConnecting: _isConnectingAsExternalGnss(device),
                        allServices: _services,
                        onConnect: (svc) => _connect(svc, device),
                        onConnectGnss: () => _connectExternalGnss(device),
                      ),
                  ],
          ),

          // Backsight tolerance settings
          const TruPulseBacksightToleranceSection(),

          // Persistent connection / disconnection event log
          const DeviceConnectionLogSection(),

          // Help
          SettingsSection(
            title: t.settings.info,
            icon: Icons.info_outline,
            iconColor: Colors.grey,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  t.devices.supportedInfo,
                  style: const TextStyle(height: 1.5, color: Colors.grey),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final BluetoothDevice device;
  final ExternalDeviceService? service;
  final bool looksLikeGnss;
  final bool isGnssConnected;
  final bool isGnssConnecting;
  final List<ExternalDeviceService> allServices;
  final void Function(ExternalDeviceService) onConnect;
  final VoidCallback onConnectGnss;

  const _DeviceTile({
    required this.device,
    required this.service,
    this.looksLikeGnss = false,
    this.isGnssConnected = false,
    this.isGnssConnecting = false,
    required this.allServices,
    required this.onConnect,
    required this.onConnectGnss,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = (service?.isConnected ?? false) || isGnssConnected;
    final isConnecting = (service?.isConnecting ?? false) || isGnssConnecting;
    final compatibleType = service?.deviceTypeName ?? (looksLikeGnss ? t.gps.externalGnssName : null);
    final connectedType = isGnssConnected ? t.gps.externalGnssName : service?.deviceTypeName;

    return ListTile(
      leading: Icon(
        looksLikeGnss || isGnssConnected
            ? Icons.satellite_alt
            : service != null
                ? Icons.sensors
                : Icons.bluetooth,
        color: isConnected
            ? Colors.blue
            : compatibleType != null
                ? Colors.green
                : Colors.grey,
      ),
      title: Text(device.name ?? t.common.unknown),
      subtitle: Text(
        isConnected && connectedType != null
            ? t.devices.connectedType(type: connectedType)
            : compatibleType != null
                ? t.devices.compatible(type: compatibleType)
                : device.address,
      ),
      trailing: isConnected
          ? const Icon(Icons.check_circle, color: Colors.blue)
          : isConnecting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : service != null
                  ? TextButton(
                      onPressed: () => onConnect(service!),
                      child: Text(t.devices.connect),
                    )
                  : looksLikeGnss
                      ? TextButton(
                          onPressed: onConnectGnss,
                          child: Text(t.devices.connect),
                        )
                      : _buildManualConnectMenu(context),
    );
  }

  Widget _buildManualConnectMenu(BuildContext context) {
    return PopupMenuButton<Object>(
      itemBuilder: (_) => [
        PopupMenuItem<Object>(
          value: 'gnss',
          child: Text(t.devices.connectAs(type: t.gps.externalGnssName)),
        ),
        for (final s in allServices)
          PopupMenuItem<Object>(
            value: s,
            child: Text(t.devices.connectAs(type: s.deviceTypeName)),
          ),
      ],
      onSelected: (target) {
        if (target == 'gnss') {
          onConnectGnss();
        } else if (target is ExternalDeviceService) {
          onConnect(target);
        }
      },
      child: Text(t.devices.tryConnect, style: const TextStyle(fontSize: 12, color: Colors.blue)),
    );
  }
}
