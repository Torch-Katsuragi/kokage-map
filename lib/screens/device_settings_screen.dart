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
import 'package:permission_handler/permission_handler.dart';

import '../devices/base/device_service.dart';
import '../devices/trupulse/trupulse_providers.dart';
import '../i18n/strings.g.dart';
import '../utils/app_logger.dart';
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

  @override
  void initState() {
    super.initState();
    _services = [ref.read(trupulseServiceProvider)];
    for (final s in _services) {
      s.addListener(_onServiceChanged);
    }
    _scan();
  }

  @override
  void dispose() {
    for (final s in _services) {
      s.removeListener(_onServiceChanged);
    }
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  Future<bool> _ensureBluetoothPermissions() async {
    if (await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted) {
      return true;
    }
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final ok = (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
        (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t.devices.bluetoothPermission),
      ));
    }
    return ok;
  }

  Future<void> _scan() async {
    setState(() => _isScanning = true);
    try {
      if (!await _ensureBluetoothPermissions()) return;

      final isEnabled =
          await FlutterBluetoothSerial.instance.isEnabled ?? false;
      if (!isEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(t.devices.enableBluetooth),
          ));
        }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.devices.scanError(error: e.toString()))),
        );
      }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.devices.connectionFailed(error: e.toString()))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectedServices =
        _services.where((s) => s.isConnected).toList();
    final connectingServices =
        _services.where((s) => s.isConnecting).toList();

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
          if (connectedServices.isNotEmpty || connectingServices.isNotEmpty)
            SettingsSection(
              title: t.devices.connected,
              icon: Icons.bluetooth_connected,
              iconColor: Colors.blue,
              children: [
                for (final s in [...connectingServices, ...connectedServices])
                  ListTile(
                    leading: Icon(
                      Icons.bluetooth_connected,
                      color: s.isConnected ? Colors.blue : Colors.orange,
                    ),
                    title: Text(s.deviceTypeName),
                    subtitle: Text(s.isConnecting
                        ? t.devices.connecting
                        : t.devices.connected),
                    trailing: s.isConnected
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
                        allServices: _services,
                        onConnect: (svc) => _connect(svc, device),
                      ),
                  ],
          ),

          // Help
          SettingsSection(
            title: 'Info',
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
  final List<ExternalDeviceService> allServices;
  final void Function(ExternalDeviceService) onConnect;

  const _DeviceTile({
    required this.device,
    required this.service,
    required this.allServices,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = service?.isConnected ?? false;
    final isConnecting = service?.isConnecting ?? false;
    final isCompatible = service != null;

    return ListTile(
      leading: Icon(
        isCompatible ? Icons.sensors : Icons.bluetooth,
        color: isConnected
            ? Colors.blue
            : isCompatible
                ? Colors.green
                : Colors.grey,
      ),
      title: Text(device.name ?? t.common.unknown),
      subtitle: Text(
        isConnected
            ? t.devices.connectedType(type: service!.deviceTypeName)
            : isCompatible
                ? t.devices.compatible(type: service!.deviceTypeName)
                : device.address,
      ),
      trailing: isConnected
          ? const Icon(Icons.check_circle, color: Colors.blue)
          : isConnecting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : isCompatible
                  ? TextButton(
                      onPressed: () => onConnect(service!),
                      child: Text(t.devices.connect),
                    )
                  : _buildManualConnectMenu(context),
    );
  }

  Widget? _buildManualConnectMenu(BuildContext context) {
    if (allServices.isEmpty) return null;
    if (allServices.length == 1) {
      return TextButton(
        onPressed: () => onConnect(allServices.first),
        child: Text(t.devices.tryConnect, style: const TextStyle(fontSize: 12)),
      );
    }
    return PopupMenuButton<ExternalDeviceService>(
      itemBuilder: (_) => [
        for (final s in allServices)
          PopupMenuItem(value: s, child: Text(t.devices.connectAs(type: s.deviceTypeName))),
      ],
      onSelected: onConnect,
      child: Text(t.devices.tryConnect, style: const TextStyle(fontSize: 12, color: Colors.blue)),
    );
  }
}
