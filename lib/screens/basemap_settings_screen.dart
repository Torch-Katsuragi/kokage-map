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
import '../models/basemap_layer.dart';
import '../models/basemap_provider.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/basemap_service.dart';
import '../tutorial/tutorial.dart';
import '../widgets/settings_widgets.dart';
import 'basemap_settings/basemap_custom_layer_sheet.dart';
import 'basemap_settings/basemap_download_section.dart';
import 'basemap_settings/basemap_layers_section.dart';
import 'basemap_settings/basemap_sources_section.dart';

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

  /// web で利用者の地図が取れない（CORS）と分かったら注意を出し直す
  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _baseMapService.addListener(_onServiceChanged);
    _loadCacheInfo();
    // チュートリアル: 開いたことと、赤色立体図がもう重なっているか（入っていればその手順は済み）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tutorial = ref.read(tutorialProvider.notifier);
      tutorial.report(const BasemapScreenOpened());
      if (_baseMapService.layers.any((l) => l.providerId == reliefProviderId)) {
        tutorial.report(const BasemapLayerAdded(reliefProviderId));
      }
    });
  }

  @override
  void dispose() {
    _baseMapService.removeListener(_onServiceChanged);
    super.dispose();
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

  void _notify(String title, NotificationLevel level) =>
      ref.read(notificationCenterProvider.notifier).add(title: title, level: level);

  /// オフラインモード切り替え
  Future<void> _toggleOfflineMode(bool value) async {
    try {
      await _baseMapService.setOfflineMode(value);
      _notify(
        value ? t.basemap.notifications.offlineEnabled : t.basemap.notifications.offlineDisabled,
        value ? NotificationLevel.warning : NotificationLevel.info,
      );
    } catch (e) {
      _notify(t.basemap.notifications.offlineChangeFailed(error: e.toString()), NotificationLevel.error);
    }
  }

  /// キャッシュクリア
  Future<void> _clearCache({String? providerId}) async {
    try {
      final confirmed = await showSettingsConfirmDialog(
        context,
        title: t.basemap.cacheDialog.title,
        message: providerId != null
            ? t.basemap.cacheDialog.confirmProvider
            : t.basemap.cacheDialog.confirmAll,
        confirmLabel: t.common.clear,
        confirmStyle: TextButton.styleFrom(foregroundColor: Colors.red),
      );

      if (confirmed) {
        await _baseMapService.clearCache(providerId: providerId);
        await _loadCacheInfo();
        _notify(t.basemap.cacheDialog.cleared, NotificationLevel.success);
      }
    } catch (e) {
      _notify(t.basemap.cacheDialog.clearFailed(error: e.toString()), NotificationLevel.error);
    }
  }

  /// キャッシュ検証・修復
  Future<void> _validateAndRepairCache() async {
    try {
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

      final result = await _baseMapService.validateAndRepairCache();

      if (mounted) {
        Navigator.pop(context);
      }

      if (mounted) {
        await _showValidationResult(result);
        await _loadCacheInfo();
        _notify(
          t.basemap.cacheValidation.complete(count: result['removedTiles'].toString()),
          NotificationLevel.info,
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
      }
      _notify(t.basemap.cacheValidation.failed(error: e.toString()), NotificationLevel.error);
    }
  }

  /// キャッシュ検証の結果ダイアログ
  Future<void> _showValidationResult(Map<String, dynamic> result) {
    final tr = t.basemap.cacheValidation;
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.resultTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr.totalTiles(count: result['totalTiles'].toString())),
            Text(
              tr.validTiles(count: result['validTiles'].toString()),
              style: const TextStyle(color: Colors.green),
            ),
            Text(
              tr.invalidTiles(count: result['invalidTiles'].toString()),
              style: const TextStyle(color: Colors.orange),
            ),
            Text(
              tr.removedTiles(count: '${result['removedTiles']}'),
              style: const TextStyle(color: Colors.red),
            ),
            const SizedBox(height: 8),
            if ((result['removedTiles'] as int) > 0)
              Text(
                tr.corruptedRemoved,
                style: const TextStyle(fontWeight: FontWeight.bold),
              )
            else
              Text(
                tr.noIssues,
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
  }

  /// レイヤを変えて描き直す
  Future<void> _editLayers(Future<void> Function() edit) async {
    await edit();
    if (mounted) setState(() {});
  }

  /// 地図の中心（地図がまだ無ければ東京駅）
  LatLng get _mapCenter {
    try {
      final c = ref.read(mapControllerHolderProvider)?.camera.center;
      if (c != null) return c;
    } catch (_) {}
    return const LatLng(35.681236, 139.767125);
  }

  /// 地図のズーム（地図がまだ無ければ null）
  double? get _mapZoom {
    try {
      return ref.read(mapControllerHolderProvider)?.camera.zoom;
    } catch (_) {
      return null;
    }
  }

  /// プレビューのタイルのズーム: 地図のもの（12〜17 に収める）
  int get _previewZoom => _mapZoom?.round().clamp(12, 17) ?? 15;

  Future<void> _openAddLayerSheet() => showAddBasemapLayerSheet(
        context,
        service: _baseMapService,
        cacheStats: _cacheStats,
        center: _mapCenter,
        previewZoom: _previewZoom,
        editLayers: _editLayers,
        onCacheChanged: _loadCacheInfo,
        notify: _notify,
        onBuiltInOrExistingLayerAdded: (providerId) {
          ref.read(tutorialProvider.notifier).report(BasemapLayerAdded(providerId));
        },
      );

  Future<void> _openDownloadDialog() => showBasemapDownloadFlow(
        context,
        service: _baseMapService,
        center: _mapCenter,
        currentMapZoom: _mapZoom,
        notify: _notify,
        onDownloadFinished: _loadCacheInfo,
      );

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
          BasemapLayersSection(
            service: _baseMapService,
            mapCenter: _mapCenter,
            previewZoom: _previewZoom,
            onReorderLayer: (oldIdx, newIdx) => _editLayers(() => _baseMapService.moveLayer(oldIdx, newIdx)),
            onUpdateLayer: (prev, next) async {
              final opacityChanged = next.opacity != prev.opacity;
              await _editLayers(() => _baseMapService.updateLayer(next.providerId, (_) => next));
              if (opacityChanged) {
                ref.read(tutorialProvider.notifier).report(BasemapOpacityChanged(next.providerId));
              }
            },
            onRemoveLayer: (id) => _editLayers(() => _baseMapService.removeLayer(id)),
            onAddLayerPressed: _openAddLayerSheet,
          ),
          BasemapSourcesSection(service: _baseMapService),
          BasemapDownloadSection(onOpenSettings: _openDownloadDialog),
          _buildOfflineSettingsSection(),
          _buildCacheManagementSection(),
        ],
      ),
    );
  }

  /// 現在の設定セクション（見えているレイヤの要約。上から）
  Widget _buildCurrentSettingsSection() {
    final active = _baseMapService.activeLayers.reversed.toList();
    final base = _baseMapService.currentProvider;
    final summary = active.isEmpty
        ? base.description
        : [
            for (final (p, l) in active)
              '${p.name} ${l.opacity}%${l.blend == BaseMapBlend.normal ? '' : ' ${basemapBlendLabel(l.blend)}'}',
          ].join(' / ');

    return SettingsSection(
      title: t.basemap.currentSettings,
      children: [
        SettingsTile(
          leadingIcon: base.icon,
          leadingIconColor: Colors.blue,
          title: active.isEmpty ? base.name : [for (final (p, _) in active) p.name].join(' + '),
          subtitle: summary,
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

  /// オフライン設定セクション
  Widget _buildOfflineSettingsSection() {
    return SettingsSection(
      title: t.basemap.offlineSettings,
      children: [
        SettingsSwitchTile(
          leadingIcon: _baseMapService.isOfflineMode ? Icons.wifi_off : Icons.wifi,
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
    final hasCache = _cacheStats.isNotEmpty;
    return SettingsSection(
      title: t.basemap.cacheManagement,
      trailing: Text(
        t.basemapExtra.totalSize(size: _cacheSizeMB.toStringAsFixed(1)),
        style: const TextStyle(fontSize: 14, color: Colors.grey),
      ),
      children: [
        SettingsActionTile(
          leadingIcon: Icons.build,
          leadingIconColor: Colors.blue,
          title: t.basemap.validateRepair,
          subtitle: t.basemap.validateRepairDesc,
          buttonLabel: t.basemap.validate,
          buttonColor: Colors.blue,
          onPressed: _validateAndRepairCache,
          enabled: hasCache,
        ),
        const Divider(),
        SettingsActionTile(
          leadingIcon: Icons.delete_sweep,
          leadingIconColor: Colors.red,
          title: t.basemap.clearAll,
          subtitle: '${_cacheStats.values.fold(0, (sum, count) => sum + count)}タイル',
          buttonLabel: t.common.clear,
          buttonColor: Colors.red,
          onPressed: _clearCache,
          enabled: hasCache,
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 8),
          child: Text(
            t.basemap.perProviderCache,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        if (!hasCache)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              t.basemap.noCacheData,
              style: const TextStyle(color: Colors.grey),
            ),
          )
        else
          ..._cacheStats.entries.map((entry) {
            final provider = BaseMapProvider.getProviderByCacheId(entry.key);
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
