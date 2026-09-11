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
/// 背景地図設定画面
/// 背景地図プロバイダーの選択とオフライン機能の管理
library;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/basemap_provider.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/basemap_service.dart';
import '../widgets/settings_widgets.dart';

class BaseMapSettingsScreen extends ConsumerStatefulWidget {
  final bool isEmbedded;

  const BaseMapSettingsScreen({
    super.key,
    this.isEmbedded = false,
  });

  @override
  ConsumerState<BaseMapSettingsScreen> createState() => _BaseMapSettingsScreenState();
}

class _BaseMapSettingsScreenState extends ConsumerState<BaseMapSettingsScreen> {
  final BaseMapService _baseMapService = BaseMapService();
  Map<String, int> _cacheStats = {};
  double _cacheSizeMB = 0.0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCacheInfo();
  }

  /// キャッシュ情報を読み込み
  Future<void> _loadCacheInfo() async {
    try {
      final stats = await _baseMapService.getCacheStatistics();
      final sizeMB = await _baseMapService.getCacheSizeMB();

      if (mounted) {
        setState(() {
          _cacheStats = stats;
          _cacheSizeMB = sizeMB;
          _isLoading = false;
        });
      }
    } catch (e) {
      AppLogger.debug('[ERROR] BaseMapSettingsScreen: キャッシュ情報読み込みエラー: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// プロバイダー変更
  Future<void> _changeProvider(BaseMapProvider provider) async {
    try {
      await _baseMapService.setProvider(provider);

      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.notifications.changed(name: provider.name),
            level: NotificationLevel.success,
          );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.notifications.changeFailed(error: e.toString()),
            level: NotificationLevel.error,
          );
    }
  }

  /// オフラインモード切り替え
  Future<void> _toggleOfflineMode(bool value) async {
    try {
      await _baseMapService.setOfflineMode(value);

      ref.read(notificationCenterProvider.notifier).add(
            title: value ? t.basemap.notifications.offlineEnabled : t.basemap.notifications.offlineDisabled,
            level: value ? NotificationLevel.warning : NotificationLevel.info,
          );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.notifications.offlineChangeFailed(error: e.toString()),
            level: NotificationLevel.error,
          );
    }
  }

  /// キャッシュクリア
  Future<void> _clearCache({String? providerId}) async {
    try {
      // 確認ダイアログ
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text(t.basemap.cacheDialog.title),
              content: Text(
                providerId != null
                    ? t.basemap.cacheDialog.confirmProvider
                    : t.basemap.cacheDialog.confirmAll,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(t.common.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: Text(t.common.clear),
                ),
              ],
            ),
      );

      if (confirmed == true) {
        await _baseMapService.clearCache(providerId: providerId);
        await _loadCacheInfo(); // キャッシュ情報を再読み込み

        ref.read(notificationCenterProvider.notifier).add(
              title: t.basemap.cacheDialog.cleared,
              level: NotificationLevel.success,
            );
      }
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.cacheDialog.clearFailed(error: e.toString()),
            level: NotificationLevel.error,
          );
    }
  }

  /// キャッシュ検証・修復
  Future<void> _validateAndRepairCache() async {
    try {
      // 進行状況ダイアログを表示
      if (!mounted) return;
      
      unawaited(showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Expanded(child: Text(t.basemap.cacheValidation.validating)),
            ],
          ),
        ),
      ));

      // キャッシュ検証実行
      final result = await _baseMapService.validateAndRepairCache();
      
      // ダイアログを閉じる
      if (mounted) {
        Navigator.pop(context);
      }

      // 結果を表示
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t.basemap.cacheValidation.resultTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.basemap.cacheValidation.totalTiles(count: result['totalTiles'].toString())),
                Text(
                  t.basemap.cacheValidation.validTiles(count: result['validTiles'].toString()),
                  style: const TextStyle(color: Colors.green),
                ),
                Text(
                  t.basemap.cacheValidation.invalidTiles(count: result['invalidTiles'].toString()),
                  style: const TextStyle(color: Colors.orange),
                ),
                Text(
                  t.basemap.cacheValidation.removedTiles(count: '${result['removedTiles']}'),
                  style: const TextStyle(color: Colors.red),
                ),
                const SizedBox(height: 8),
                if ((result['removedTiles'] as int) > 0)
                  Text(
                    t.basemap.cacheValidation.corruptedRemoved,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  )
                else
                  Text(
                    t.basemap.cacheValidation.noIssues,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.common.close),
              ),
            ],
          ),
        );

        // キャッシュ情報を再読み込み
        await _loadCacheInfo();

        ref.read(notificationCenterProvider.notifier).add(
              title: t.basemap.cacheValidation.complete(count: result['removedTiles'].toString()),
              level: NotificationLevel.info,
            );
      }
    } catch (e) {
      // エラー時はダイアログを閉じる
      if (mounted) {
        Navigator.pop(context);
      }
      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.cacheValidation.failed(error: e.toString()),
            level: NotificationLevel.error,
          );
    }
  }

  /// ダウンロード設定ダイアログを表示
  Future<void> _showDownloadDialog() async {
    // OSMは一括ダウンロード禁止（タイル利用ポリシー: prefetchはブロック対象）
    if (_baseMapService.currentProvider.type == BaseMapType.openStreetMap) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.download.osmNotAllowed,
            level: NotificationLevel.warning,
          );
      return;
    }

    // 現在の地図中心座標を取得
    LatLng center;
    try {
      final mapController = ref.read(mapControllerHolderProvider);
      if (mapController != null) {
        center = mapController.camera.center;
      } else {
        center = const LatLng(35.681236, 139.767125);
      }
    } catch (e) {
      center = const LatLng(35.681236, 139.767125);
    }

    final provider = _baseMapService.currentProvider;
    
    // デフォルト設定
    // 初期ズーム範囲: 現在のズームレベル前後
    double currentZoom = 15.0;
    try {
      final mapController = ref.read(mapControllerHolderProvider);
      if (mapController != null) {
        currentZoom = mapController.camera.zoom;
      }
    } catch (_) {}

    double minZoom = (currentZoom - 2).clamp(provider.minZoom.toDouble(), provider.maxZoom.toDouble());
    final double maxZoom = (currentZoom + 2).clamp(provider.minZoom.toDouble(), provider.maxZoom.toDouble());
    if (minZoom > maxZoom) minZoom = maxZoom;

    final RangeValues zoomRange = RangeValues(minZoom, maxZoom);
    const double radius = 1000; // 1km

    // ダイアログ表示
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DownloadSettingsDialog(
        center: center,
        provider: provider,
        initialRadius: radius,
        initialZoomRange: zoomRange,
        baseMapService: _baseMapService,
        onStartDownload: (r, zMin, zMax) {
            Navigator.pop(context); // 設定ダイアログを閉じる
            _startDownload(center, r, zMin, zMax); // ダウンロード開始
        },
      ),
    );
  }

  /// ダウンロード実行と進捗ダイアログ
  void _startDownload(LatLng center, double radius, int minZoom, int maxZoom) {
    showDialog(
      context: context,
      barrierDismissible: false, // 背景タップで閉じない
      builder: (context) => _DownloadProgressDialog(
        center: center,
        radius: radius,
        minZoom: minZoom,
        maxZoom: maxZoom,
        baseMapService: _baseMapService,
      ),
    ).then((_) {
        // ダイアログが閉じたらキャッシュ情報を更新
        _loadCacheInfo();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: t.basemap.title,
      isEmbedded: widget.isEmbedded,
      isLoading: _isLoading,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: t.basemap.refreshCache,
          onPressed: _loadCacheInfo,
        ),
      ],
      body: SettingsBody(
        spacing: 24,
        sections: [
          _buildCurrentSettingsSection(),
          _buildDownloadSection(),
          _buildProviderSelectionSection(),
          _buildOfflineSettingsSection(),
          _buildCacheManagementSection(),
        ],
      ),
    );
  }

  /// 一括ダウンロードセクション
  Widget _buildDownloadSection() {
    return SettingsHighlightSection(
      title: t.basemap.download.title,
      icon: Icons.download_for_offline,
      iconColor: Colors.blue,
      backgroundColor: Colors.blue[50]!,
      description: t.basemap.download.description,
      actionButton: ElevatedButton.icon(
        onPressed: _showDownloadDialog,
        icon: const Icon(Icons.download),
        label: Text(t.basemap.download.openSettings),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  /// 現在の設定セクション
  Widget _buildCurrentSettingsSection() {
    final currentProvider = _baseMapService.currentProvider;

    return SettingsSection(
      title: t.basemap.currentSettings,
      children: [
        SettingsTile(
          leadingIcon: currentProvider.icon,
          leadingIconColor: Colors.blue,
          title: currentProvider.name,
          subtitle: currentProvider.description,
          trailing: _baseMapService.isOfflineMode
              ? Chip(
                  label: Text(t.basemap.offline),
                  backgroundColor: Colors.orange,
                )
              : Chip(
                  label: Text(t.basemap.online),
                  backgroundColor: Colors.green,
                ),
        ),
      ],
    );
  }

  /// 背景地図選択セクション
  Widget _buildProviderSelectionSection() {
    final currentProvider = _baseMapService.currentProvider;
    final isAdvanced = _baseMapService.isAdvancedMode;
    final weights = _baseMapService.providerWeights;

    return SettingsSection(
      title: t.basemap.selectBasemap,
      children: [
        // 通常モード: ラジオボタン式
        if (!isAdvanced)
          ...BaseMapProvider.availableProviders.map((provider) {
            final isSelected = provider.id == currentProvider.id;
            final cachedTileCount = _cacheStats[provider.id] ?? 0;
            final subtitleText = cachedTileCount > 0
                ? '${provider.description}\n${t.basemap.cacheCount(count: cachedTileCount.toString())}'
                : provider.description;

            return SettingsSelectionTile(
              leadingIcon: provider.icon,
              leadingIconColor: Colors.blue,
              title: provider.name,
              subtitle: subtitleText,
              isSelected: isSelected,
              onTap: () => _changeProvider(provider),
            );
          }),

        // 高度モード: スライダー式
        if (isAdvanced)
          ...BaseMapProvider.availableProviders.map((provider) {
            final weight = weights[provider.id] ?? 0;
            final cachedTileCount = _cacheStats[provider.id] ?? 0;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    provider.icon,
                    color: weight > 0
                        ? Colors.blue
                        : Colors.grey.withValues(alpha: 0.4),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          provider.name,
                          style: TextStyle(
                            fontSize: 13,
                            color: weight > 0 ? null : Colors.grey,
                          ),
                        ),
                        if (cachedTileCount > 0)
                          Text(
                            t.basemap.cacheCount(count: cachedTileCount.toString()),
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: Slider(
                      value: weight.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 20,
                      label: weight.toString(),
                      onChanged: (value) {
                        _baseMapService.setProviderWeight(
                          provider.id,
                          value.round(),
                        );
                        setState(() {});
                      },
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      '$weight',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: weight > 0 ? Colors.blue : Colors.grey,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),

        const Divider(),

        // 高度な設定チェックボックス
        SettingsSwitchTile(
          leadingIcon: Icons.tune,
          activeIconColor: Colors.deepPurple,
          inactiveIconColor: Colors.grey,
          title: '高度な設定',
          subtitle: '複数の背景地図を重ねて表示',
          value: isAdvanced,
          onChanged: (value) async {
            await _baseMapService.setAdvancedMode(value);
            setState(() {});
          },
        ),
      ],
    );
  }

  /// オフライン設定セクション
  Widget _buildOfflineSettingsSection() {
    return SettingsSection(
      title: t.basemap.offlineSettings,
      children: [
        SettingsSwitchTile(
          leadingIcon:
              _baseMapService.isOfflineMode ? Icons.wifi_off : Icons.wifi,
          activeIconColor: Colors.orange,
          inactiveIconColor: Colors.green,
          title: t.basemap.offlineMode,
          subtitle: t.basemap.offlineModeDesc,
          value: _baseMapService.isOfflineMode,
          onChanged: _toggleOfflineMode,
        ),
      ],
    );
  }

  /// キャッシュ管理セクション
  Widget _buildCacheManagementSection() {
    return SettingsSection(
      title: t.basemap.cacheManagement,
      trailing: Text(
        t.basemapExtra.totalSize(size: _cacheSizeMB.toStringAsFixed(1)),
        style: const TextStyle(fontSize: 14, color: Colors.grey),
      ),
      children: [
        // キャッシュ検証・修復
        SettingsActionTile(
          leadingIcon: Icons.build,
          leadingIconColor: Colors.blue,
          title: t.basemap.validateRepair,
          subtitle: t.basemap.validateRepairDesc,
          buttonLabel: t.basemap.validate,
          buttonColor: Colors.blue,
          onPressed: _cacheStats.isNotEmpty ? _validateAndRepairCache : null,
          enabled: _cacheStats.isNotEmpty,
        ),
        const Divider(),

        // 全キャッシュクリア
        SettingsActionTile(
          leadingIcon: Icons.delete_sweep,
          leadingIconColor: Colors.red,
          title: t.basemap.clearAll,
          subtitle:
              '${_cacheStats.values.fold(0, (sum, count) => sum + count)}タイル',
          buttonLabel: t.common.clear,
          buttonColor: Colors.red,
          onPressed: _cacheStats.isNotEmpty ? _clearCache : null,
          enabled: _cacheStats.isNotEmpty,
        ),
        const Divider(),

        // プロバイダー別キャッシュ情報
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 8),
          child: Text(
            t.basemap.perProviderCache,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        if (_cacheStats.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              t.basemap.noCacheData,
              style: const TextStyle(color: Colors.grey),
            ),
          )
        else
          ..._cacheStats.entries.map((entry) {
            final provider = BaseMapProvider.getProviderById(entry.key);
            if (provider == null) return const SizedBox.shrink();

            return SettingsTile(
              leadingIcon: provider.icon,
              leadingIconColor: Colors.grey,
              title: provider.name,
              subtitle: '${entry.value}タイル',
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                tooltip: t.basemap.clearProviderCache,
                onPressed: () => _clearCache(providerId: entry.key),
              ),
            );
          }),
      ],
    );
  }
}

/// ダウンロード設定ダイアログ
class _DownloadSettingsDialog extends StatefulWidget {
  final LatLng center;
  final BaseMapProvider provider;
  final double initialRadius;
  final RangeValues initialZoomRange;
  final BaseMapService baseMapService;
  final Function(double, int, int) onStartDownload;

  const _DownloadSettingsDialog({
    required this.center,
    required this.provider,
    required this.initialRadius,
    required this.initialZoomRange,
    required this.baseMapService,
    required this.onStartDownload,
  });

  @override
  State<_DownloadSettingsDialog> createState() => _DownloadSettingsDialogState();
}

class _DownloadSettingsDialogState extends State<_DownloadSettingsDialog> {
  late double _radius;
  late RangeValues _zoomRange;
  int _estimatedTiles = 0;

  @override
  void initState() {
    super.initState();
    _radius = widget.initialRadius;
    _zoomRange = widget.initialZoomRange;
    _calculateTiles();
  }

  void _calculateTiles() {
    final result = widget.baseMapService.estimateDownloadSize(
      center: widget.center,
      radiusMeters: _radius,
      minZoom: _zoomRange.start.round(),
      maxZoom: _zoomRange.end.round(),
    );
    setState(() {
      _estimatedTiles = result['totalTiles'] ?? 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.basemap.download.settingsTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.basemapExtra.mapName(name: widget.provider.name)),
            const SizedBox(height: 4),
            Text(t.basemapExtra.center(lat: widget.center.latitude.toStringAsFixed(4), lng: widget.center.longitude.toStringAsFixed(4))),
            const Divider(),
            
            Text(t.basemap.download.range, style: const TextStyle(fontWeight: FontWeight.bold)),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _radius,
                    min: 100,
                    max: 10000,
                    divisions: 99,
                    label: '${(_radius / 1000).toStringAsFixed(1)} km',
                    onChanged: (value) {
                      setState(() {
                        _radius = value;
                      });
                      _calculateTiles();
                    },
                  ),
                ),
                Text('${(_radius / 1000).toStringAsFixed(1)} km'),
              ],
            ),
            
            Text(t.basemap.download.zoomRange, style: const TextStyle(fontWeight: FontWeight.bold)),
            RangeSlider(
              values: _zoomRange,
              min: widget.provider.minZoom.toDouble(),
              max: widget.provider.maxZoom.toDouble(),
              divisions: widget.provider.maxZoom - widget.provider.minZoom,
              labels: RangeLabels(
                _zoomRange.start.round().toString(),
                _zoomRange.end.round().toString(),
              ),
              onChanged: (values) {
                setState(() {
                  _zoomRange = values;
                });
                _calculateTiles();
              },
            ),
            Center(child: Text('${_zoomRange.start.round()} 〜 ${_zoomRange.end.round()}')),
            
            const Divider(),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.image, size: 20, color: Colors.grey),
                const SizedBox(width: 8),
                Text(
                  t.basemap.download.estimatedTiles(count: _estimatedTiles.toString()),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: _estimatedTiles > 1000 ? Colors.red : Colors.black,
                  ),
                ),
              ],
            ),
            if (_estimatedTiles > 1000)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.basemap.download.tooManyTiles,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
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
        ElevatedButton(
          onPressed: _estimatedTiles > 0 && _estimatedTiles < 5000 
            ? () => widget.onStartDownload(
                _radius, 
                _zoomRange.start.round(), 
                _zoomRange.end.round()
              ) 
            : null,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
          child: Text(t.basemap.download.startDownload, style: const TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

/// ダウンロード進捗ダイアログ
class _DownloadProgressDialog extends StatefulWidget {
  final LatLng center;
  final double radius;
  final int minZoom;
  final int maxZoom;
  final BaseMapService baseMapService;

  const _DownloadProgressDialog({
    required this.center,
    required this.radius,
    required this.minZoom,
    required this.maxZoom,
    required this.baseMapService,
  });

  @override
  State<_DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  Map<String, dynamic> _status = {};
  bool _isFinished = false;
  
  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  void _startDownload() async {
    final stream = widget.baseMapService.downloadArea(
      center: widget.center,
      radiusMeters: widget.radius,
      minZoom: widget.minZoom,
      maxZoom: widget.maxZoom,
    );

    stream.listen((status) {
      if (mounted) {
        setState(() {
          _status = status;
        });
        
        if (status['status'] == 'completed' || 
            status['status'] == 'cancelled' || 
            status['status'] == 'error') {
          setState(() {
            _isFinished = true;
          });
        }
      }
    }, onError: (e) {
      if (mounted) {
        setState(() {
          _status = {'status': 'error', 'message': e.toString()};
          _isFinished = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = _status['total'] as int? ?? 0;
    final processed = _status['processed'] as int? ?? 0;
    final downloaded = _status['downloaded'] as int? ?? 0;
    final skipped = _status['skipped'] as int? ?? 0;
    final errors = _status['errors'] as int? ?? 0;
    final percent = total > 0 ? processed / total : 0.0;
    final statusStr = _status['status'] as String? ?? 'init';

    return AlertDialog(
      title: Text(t.basemap.download.downloading),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_isFinished) ...[
            LinearProgressIndicator(value: percent, minHeight: 10),
            const SizedBox(height: 8),
            Text(t.basemap.download.progress(percent: (percent * 100).toStringAsFixed(1), processed: processed.toString(), total: total.toString())),
          ],
          const SizedBox(height: 16),
          
          if (statusStr == 'completed')
            Center(
              child: Text(
                t.basemap.download.complete, 
                style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 18),
              ),
            )
          else if (statusStr == 'cancelled')
            Center(
              child: Text(
                t.basemap.download.cancelled, 
                style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 18),
              ),
            )
          else if (statusStr == 'error')
             Text(
                t.common.errorOccurred(error: _status['message'].toString()), 
                style: const TextStyle(color: Colors.red),
              ),
              
          const Divider(),
          _buildStatRow(t.basemap.download.successDownloaded, downloaded.toString(), Colors.blue),
          _buildStatRow(t.basemap.download.skipped, skipped.toString(), Colors.grey),
          _buildStatRow(t.basemap.download.errors, errors.toString(), Colors.red),
        ],
      ),
      actions: [
        if (!_isFinished)
          TextButton(
            onPressed: () {
              widget.baseMapService.cancelDownload();
            },
            child: Text(t.common.cancel, style: const TextStyle(color: Colors.red)),
          )
        else
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.common.close),
          ),
      ],
    );
  }
  
  Widget _buildStatRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}

