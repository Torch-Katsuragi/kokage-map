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
/// GPS設定画面
///
/// 統合GPS管理サービスを使用してGPSソース（内蔵GPS・外部GNSS）の
/// 切り替えと設定管理を行います。
///
/// Features:
/// - 内蔵GPS・外部GNSS機器の切り替え
/// - 外部GNSS機器のスキャンと接続
/// - 現在のGPS情報の表示
/// - GPS記録オプションの設定
/// - リアルタイム位置情報監視
library;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../providers/notification_providers.dart';
import '../services/gps_manager_service.dart';
import '../widgets/gps_info_widget.dart';
import '../widgets/settings_widgets.dart';

/// GPS設定画面
class GpsSettingsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;

  const GpsSettingsScreen({
    super.key,
    this.isEmbedded = false,
  });

  @override
  ConsumerState<GpsSettingsScreen> createState() => _GpsSettingsScreenState();
}

class _GpsSettingsScreenState extends ConsumerState<GpsSettingsScreen> {
  final GpsManagerService _gpsManager = GpsManagerService();
  bool _isScanning = false;
  String? _errorMessage;
  Map<String, dynamic>? _currentGpsInfo;

  @override
  void initState() {
    super.initState();
    _gpsManager.addListener(_onGpsManagerUpdate);
    _initializeGpsSettings();
  }

  @override
  void dispose() {
    _gpsManager.removeListener(_onGpsManagerUpdate);
    super.dispose();
  }

  /// GPS設定画面を初期化
  Future<void> _initializeGpsSettings() async {
    try {
      // GPS管理サービスを初期化（まだ初期化されていない場合）
      if (!_gpsManager.isInitialized) {
        await _gpsManager.initialize();
      }

      // 外部GNSS機器をスキャン
      await _scanGnssDevices();

      // 現在のGPS情報を取得
      _updateCurrentGpsInfo();

      setState(() {
        _errorMessage = null;
      });
    } catch (e) {
      setState(() {
        _errorMessage = t.gps.initError(error: e.toString());
      });
    }
  }

  /// GPS管理サービス更新コールバック
  void _onGpsManagerUpdate() {
    if (mounted) {
      _updateCurrentGpsInfo();
    }
  }

  /// 現在のGPS情報を更新
  void _updateCurrentGpsInfo() {
    setState(() {
      _currentGpsInfo = _gpsManager.getCurrentGpsInfo();
    });
  }

  /// 外部GNSS機器をスキャン
  Future<void> _scanGnssDevices() async {
    setState(() {
      _isScanning = true;
      _errorMessage = null;
    });

    try {
      // Android 12以降のBluetooth権限確認・要求
      if (!await _checkBluetoothPermissions()) {
        setState(() {
          _errorMessage = t.gps.bluetoothPermRequired;
        });
        return;
      }

      await _gpsManager.scanExternalGnssDevices();
      AppLogger.debug(
        '[GpsSettingsScreen] GNSS機器スキャン完了: ${_gpsManager.availableGnssDevices.length}件',
      );
    } catch (e) {
      setState(() {
        _errorMessage = t.gps.gnssScanError(error: e.toString());
      });
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  /// Bluetooth権限の確認・要求
  Future<bool> _checkBluetoothPermissions() async {
    try {
      // Android 12以降の場合は新しい権限を確認
      if (await Permission.bluetoothScan.isGranted &&
          await Permission.bluetoothConnect.isGranted) {
        return true;
      }

      // 権限要求
      final Map<Permission, PermissionStatus> statuses =
          await [
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
            Permission.location, // 位置情報も必要な場合
          ].request();

      AppLogger.debug('[GpsSettingsScreen] Bluetooth権限要求結果: $statuses');

      // 必要な権限が全て許可されているかチェック
      final bool hasBluetoothScan =
          statuses[Permission.bluetoothScan]?.isGranted == true;
      final bool hasBluetoothConnect =
          statuses[Permission.bluetoothConnect]?.isGranted == true;

      if (!hasBluetoothScan || !hasBluetoothConnect) {
        // 権限が拒否された場合はダイアログを表示
        if (mounted) {
          _showPermissionDeniedDialog();
        }
        return false;
      }

      return true;
    } catch (e) {
      AppLogger.debug('[GpsSettingsScreen] Bluetooth権限確認エラー: $e');
      return false;
    }
  }

  /// 権限拒否ダイアログを表示
  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(t.permissions.bluetoothPermissionTitle),
          content: Text(
            t.permissions.bluetoothPermissionDesc,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                openAppSettings();
              },
              child: Text(t.common.openSettings),
            ),
          ],
        );
      },
    );
  }

  /// Bluetooth権限情報ダイアログを表示
  Future<void> _showBluetoothPermissionInfo() async {
    final bluetoothScanGranted = await Permission.bluetoothScan.isGranted;
    final bluetoothConnectGranted = await Permission.bluetoothConnect.isGranted;
    final locationGranted = await Permission.location.isGranted;

    if (!mounted) return;
    unawaited(showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(t.permissions.bluetoothPermissionStatus),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.permissions.bluetoothPermissionStatusDesc,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              _buildPermissionRow(t.permissions.bluetoothScan, bluetoothScanGranted),
              _buildPermissionRow(t.permissions.bluetoothConnect, bluetoothConnectGranted),
              _buildPermissionRow(t.permissions.location, locationGranted),
              const SizedBox(height: 16),
              Text(
                t.permissions.bluetoothPermissionDeniedHelp,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.common.close),
            ),
            if (!bluetoothScanGranted ||
                !bluetoothConnectGranted ||
                !locationGranted)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  openAppSettings();
                },
                child: Text(t.common.openSettings),
              ),
          ],
        );
      },
    ));
  }

  /// 権限状態表示行
  Widget _buildPermissionRow(String permissionName, bool isGranted) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            isGranted ? Icons.check_circle : Icons.cancel,
            color: isGranted ? Colors.green : Colors.red,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            permissionName,
            style: TextStyle(color: isGranted ? Colors.green : Colors.red),
          ),
          const Spacer(),
          Text(
            isGranted ? t.permissions.granted : t.permissions.denied,
            style: TextStyle(
              fontSize: 12,
              color: isGranted ? Colors.green : Colors.red,
            ),
          ),
        ],
      ),
    );
  }

  /// GPSソース切り替えダイアログを表示
  Future<void> _showGpsSourceDialog() async {
    final sources = _gpsManager.getAvailableGpsSources();

    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(t.gps.sourceDialog.title),
          content: SizedBox(
            height: 300,
            width: double.maxFinite,
            child: Column(
              children: [
                Text(
                  t.gps.sourceDialog.description,
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.builder(
                    itemCount: sources.length,
                    itemBuilder: (context, index) {
                      final source = sources[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            source['type'] == GpsSourceType.internal
                                ? Icons.gps_fixed
                                : Icons.bluetooth,
                            color:
                                source['isSelected']
                                    ? Colors.green
                                    : Colors.grey,
                          ),
                          title: Text(
                            source['name'],
                            style: TextStyle(
                              fontWeight:
                                  source['isSelected']
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(source['description']),
                          trailing:
                              source['isSelected']
                                  ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  )
                                  : null,
                          onTap: () async {
                            Navigator.of(context).pop();
                            await _switchGpsSource(source);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.common.cancel),
            ),
            if (_gpsManager.availableGnssDevices.isEmpty)
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _scanGnssDevices();
                },
                child: Text(t.gps.sourceDialog.rescan),
              ),
          ],
        );
      },
    );
  }

  /// GPSソースを切り替え
  Future<void> _switchGpsSource(Map<String, dynamic> source) async {
    try {
      // GPS記録中の場合は警告
      if (_gpsManager.isRecording) {
        final confirm = await _showRecordingWarningDialog();
        if (!confirm) return;
      }

      if (source['type'] == GpsSourceType.internal) {
        await _gpsManager.switchReferenceGps(GpsSourceType.internal);
      } else {
        await _gpsManager.switchReferenceGps(
          GpsSourceType.external,
          source['device'],
        );
      }

      ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.switchedTo(name: source['name']),
            level: NotificationLevel.success,
          );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.switchError(error: e.toString()),
            level: NotificationLevel.error,
          );
    }
  }

  /// GPS記録中の警告ダイアログ
  Future<bool> _showRecordingWarningDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text(t.gps.recording.title),
              content: Text(
                t.gps.recording.cannotSwitchDesc,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(t.common.cancel),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  /// GPS位置取得テスト
  Future<void> _testGpsPosition() async {
    try {
      final gpsInfo = await _gpsManager.startGpsSurveyWithWait(
        timeout: const Duration(seconds: 15),
      );

      if (gpsInfo != null && mounted) {
        unawaited(showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text(t.gps.positionTestResult),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${t.gps.position.latitude}: ${(gpsInfo['latitude'] as num?)?.toStringAsFixed(6) ?? t.common.unknown}',
                  ),
                  Text(
                    '${t.gps.position.longitude}: ${(gpsInfo['longitude'] as num?)?.toStringAsFixed(6) ?? t.common.unknown}',
                  ),
                  Text(
                    t.gps.accuracyLabel(value: (gpsInfo['accuracy'] as num?)?.toStringAsFixed(1) ?? t.common.unknown),
                  ),
                  Text(t.gps.sourceLabel(name: gpsInfo['sourceName'] ?? t.common.unknown)),
                  Text('${t.gps.timestamp.lastUpdate}: ${gpsInfo['timestamp'] ?? t.common.unknown}'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.common.ok),
                ),
              ],
            );
          },
        ));
      } else if (gpsInfo == null) {
        ref.read(notificationCenterProvider.notifier).add(
              title: t.gps.positionTestTimeout,
              level: NotificationLevel.warning,
            );
      }
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.testResult.error(error: e.toString()),
            level: NotificationLevel.error,
          );
    } finally {
      // テスト終了時にGPS測量を停止
      await _gpsManager.stopGpsSurvey();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: t.gps.title,
      isEmbedded: widget.isEmbedded,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _isScanning ? null : _scanGnssDevices,
          tooltip: t.gps.rescanGnss,
        ),
        IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: _showBluetoothPermissionInfo,
          tooltip: t.gps.bluetoothPermInfo,
        ),
      ],
      body: SettingsBody(
        sections: [
          // エラーメッセージ表示
          if (_errorMessage != null) SettingsErrorCard(message: _errorMessage!),

          // 現在のGPSソース表示
          _buildCurrentGpsSourceCard(),

          // GPS操作ボタン
          _buildGpsControlButtons(),

          // GPS情報表示
          if (_currentGpsInfo != null) _buildGpsInfoCard(_currentGpsInfo!),

          // 利用可能なGPSソース一覧
          _buildAvailableSourcesCard(),
        ],
      ),
    );
  }

  /// 現在のGPSソース表示カード
  Widget _buildCurrentGpsSourceCard() {
    final currentSource = _gpsManager.currentSource;
    final selectedDevice = _gpsManager.selectedGnssDevice;

    final deviceInfo = selectedDevice != null
        ? t.gps.deviceInfoLabel(name: selectedDevice.name ?? t.gps.unknownDevice, address: selectedDevice.address)
        : null;

    return SettingsSection(
      title: t.gps.currentSource,
      icon: currentSource == GpsSourceType.internal
          ? Icons.gps_fixed
          : Icons.bluetooth,
      iconColor: Colors.blue,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                currentSource.displayName,
                style: const TextStyle(fontSize: 16),
              ),
              if (deviceInfo != null) ...[
                const SizedBox(height: 4),
                Text(
                  deviceInfo,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// GPS操作ボタン群
  Widget _buildGpsControlButtons() {
    return SettingsSection(
      title: t.gps.controls,
      icon: Icons.settings_remote,
      iconColor: Colors.blue,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _showGpsSourceDialog,
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(t.gps.switchSource),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _testGpsPosition,
                  icon: const Icon(Icons.location_searching),
                  label: Text(t.gps.positionTest),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// GPS情報表示カード
  Widget _buildGpsInfoCard(Map<String, dynamic> gpsInfo) {
    return SettingsSection(
      title: t.gps.info,
      icon: Icons.satellite_alt,
      iconColor: Colors.green,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: GpsInfoWidget(gpsInfo: gpsInfo),
        ),
      ],
    );
  }

  /// 利用可能なGPSソース一覧カード
  Widget _buildAvailableSourcesCard() {
    final sources = _gpsManager.getAvailableGpsSources();

    return SettingsSection(
      title: t.gps.availableSources,
      icon: Icons.list,
      iconColor: Colors.blue,
      trailing: _isScanning
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      children: [
        if (sources.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              t.gps.noSourcesFound,
              style: const TextStyle(color: Colors.grey),
            ),
          )
        else
          ...sources.map(
            (source) => SettingsSelectionTile(
              leadingIcon: source['type'] == GpsSourceType.internal
                  ? Icons.gps_fixed
                  : Icons.bluetooth,
              leadingIconColor: Colors.green,
              title: source['name'],
              subtitle: source['description'],
              isSelected: source['isSelected'],
              onTap: () => _switchGpsSource(source),
            ),
          ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            t.gps.externalDevices(count: _gpsManager.availableGnssDevices.length.toString()),
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

