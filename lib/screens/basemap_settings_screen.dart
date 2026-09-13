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
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../core/terrain/dem_tiles.dart' show DemTileSource;
import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/basemap_layer.dart';
import '../models/basemap_provider.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import '../services/basemap_service.dart';
import '../widgets/basemap_preview.dart';
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
    // 見えているレイヤ全部を落とす。OSM は一括ダウンロード禁止（タイル利用ポリシー: prefetchはブロック対象）なので除く
    final providers = _baseMapService.downloadableProviders;
    final hasOsm = _baseMapService.activeLayers.any((e) => e.$1.type == BaseMapType.openStreetMap);
    if (providers.isEmpty) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.download.osmNotAllowed,
            level: NotificationLevel.warning,
          );
      return;
    }
    if (hasOsm) {
      ref.read(notificationCenterProvider.notifier).add(
            title: t.basemap.download.osmSkipped,
            level: NotificationLevel.info,
          );
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

    // 段の範囲はプロバイダの和（等高線の z19 は地理院の切り出しになるので 18 で止める）
    final zMinAll = providers.map((p) => p.minZoom).reduce(math.min);
    final zMaxAll = math.min(18, providers.map((p) => p.maxZoom).reduce(math.max));

    // デフォルト設定
    // 初期ズーム範囲: 現在のズームレベル前後
    double currentZoom = 15.0;
    try {
      final mapController = ref.read(mapControllerHolderProvider);
      if (mapController != null) {
        currentZoom = mapController.camera.zoom;
      }
    } catch (_) {}

    double minZoom = (currentZoom - 2).clamp(zMinAll.toDouble(), zMaxAll.toDouble());
    final double maxZoom = (currentZoom + 2).clamp(zMinAll.toDouble(), zMaxAll.toDouble());
    if (minZoom > maxZoom) minZoom = maxZoom;

    final RangeValues zoomRange = RangeValues(minZoom, maxZoom);
    const double radius = 1000; // 1km

    // ダイアログ表示
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DownloadSettingsDialog(
        center: center,
        providers: providers,
        zoomMin: zMinAll,
        zoomMax: zMaxAll,
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
          _buildLayersSection(),
          _buildSourcesSection(),
          _buildDownloadSection(),
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

  /// 現在の設定セクション（見えているレイヤの要約。上から）
  Widget _buildCurrentSettingsSection() {
    final active = _baseMapService.activeLayers.reversed.toList();
    final base = _baseMapService.currentProvider;
    final summary = active.isEmpty
        ? base.description
        : [
            for (final (p, l) in active)
              '${p.name} ${l.opacity}%${l.blend == BaseMapBlend.normal ? '' : ' ${_blendLabel(l.blend)}'}',
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

  String _blendLabel(BaseMapBlend b) => switch (b) {
        BaseMapBlend.normal => t.basemap.layers.blendModes.normal,
        BaseMapBlend.multiply => t.basemap.layers.blendModes.multiply,
        BaseMapBlend.screen => t.basemap.layers.blendModes.screen,
        BaseMapBlend.overlay => t.basemap.layers.blendModes.overlay,
        BaseMapBlend.darken => t.basemap.layers.blendModes.darken,
        BaseMapBlend.lighten => t.basemap.layers.blendModes.lighten,
        BaseMapBlend.softLight => t.basemap.layers.blendModes.softLight,
        BaseMapBlend.hardLight => t.basemap.layers.blendModes.hardLight,
        BaseMapBlend.difference => t.basemap.layers.blendModes.difference,
      };

  /// レイヤセクション（松本 2026-09-13「イメージはお絵描きソフトのレイヤ。順番・可視・透明度・合成モード」）。
  /// サービスは下から上に持つが、ここでは上（手前）から並べる
  Widget _buildLayersSection() {
    final svc = _baseMapService;
    final layers = svc.layers.reversed.toList();

    return SettingsSection(
      title: t.basemap.layers.title,
      trailing: Text(
        t.basemap.layers.summary(count: layers.length.toString()),
        style: const TextStyle(fontSize: 14, color: Colors.grey),
      ),
      children: [
        // プレビュー（地図の中心のタイル 1 枚をいまの設定で合成）と説明
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BaseMapPreview(service: svc, center: _previewCenter, zoom: _previewZoom),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.basemap.layers.preview(zoom: _previewZoom.toString()),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    Text(t.basemap.layers.hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: layers.length,
          onReorderItem: (oldIndex, newIndex) async {
            // 上から数えた番号 → サービス（下から）の番号
            final n = svc.layers.length;
            await svc.moveLayer(n - 1 - oldIndex, n - 1 - newIndex);
            if (mounted) setState(() {});
          },
          itemBuilder: (context, i) {
            final layer = layers[i];
            final provider = layer.provider!;
            return _LayerRow(
              key: ValueKey(layer.providerId),
              index: i,
              layer: layer,
              provider: provider,
              isBottom: i == layers.length - 1,
              blendLabel: _blendLabel,
              onChanged: (l) async {
                await svc.updateLayer(l.providerId, (_) => l);
                if (mounted) setState(() {});
              },
              onRemove: layers.length > 1
                  ? () async {
                      await svc.removeLayer(layer.providerId);
                      if (mounted) setState(() {});
                    }
                  : null,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _showAddLayerSheet,
              icon: const Icon(Icons.add),
              label: Text(t.basemap.layers.add),
            ),
          ),
        ),
      ],
    );
  }

  /// プレビューのタイル: 地図の中心（無ければ東京）、ズームは地図のもの（12〜17 に収める）
  LatLng get _previewCenter {
    try {
      final c = ref.read(mapControllerHolderProvider)?.camera.center;
      if (c != null) return c;
    } catch (_) {}
    return const LatLng(35.681236, 139.767125);
  }

  int get _previewZoom {
    try {
      final z = ref.read(mapControllerHolderProvider)?.camera.zoom;
      if (z != null) return z.round().clamp(12, 17);
    } catch (_) {}
    return 15;
  }

  /// 追加する地図を選ぶ（一覧にまだ無いものだけ）
  Future<void> _showAddLayerSheet() async {
    final svc = _baseMapService;
    final have = {for (final l in svc.layers) l.providerId};
    final picked = await showModalBottomSheet<BaseMapProvider>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(t.basemap.layers.addTitle, style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final p in BaseMapProvider.availableProviders)
              ListTile(
                leading: Icon(p.icon, color: have.contains(p.id) ? Colors.grey : Colors.blue),
                title: Text(p.name),
                subtitle: Text([
                  p.description,
                  if ((_cacheStats[p.cacheId] ?? 0) > 0) t.basemap.cacheCount(count: _cacheStats[p.cacheId].toString()),
                ].join('\n')),
                trailing: have.contains(p.id) ? Text(t.basemap.layers.alreadyAdded, style: const TextStyle(color: Colors.grey)) : null,
                enabled: !have.contains(p.id),
                onTap: () => Navigator.of(context).pop(p),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    // 等高線のように「重ねる前提」の地図は乗算で足す（白地に線だけなので、通常でもほぼ同じ）
    await svc.addLayer(picked.id, blend: picked.type == BaseMapType.generated ? BaseMapBlend.multiply : BaseMapBlend.normal);
    if (mounted) setState(() {});
  }

  /// 出典（地図面に出すのをやめてここにまとめた。松本 2026-09-13。OSM だけは地図面にも出す）
  Widget _buildSourcesSection() {
    final basemaps = {for (final (p, _) in _baseMapService.activeLayers) if (p.attribution.isNotEmpty) p.attribution};
    final dems = {for (final s in DemTileSource.defaultCascade) s.attribution};
    return SettingsSection(
      title: t.basemap.sources.title,
      icon: Icons.public,
      iconColor: Colors.green,
      collapsible: true,
      initiallyExpanded: false,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(t.basemap.sources.hint, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        ListTile(
          leading: const Icon(Icons.map, color: Colors.green),
          title: Text(t.basemap.sources.basemap),
          subtitle: Text(basemaps.isEmpty ? '—' : basemaps.join('\n')),
        ),
        ListTile(
          leading: const Icon(Icons.terrain, color: Colors.green),
          title: Text(t.basemap.sources.elevation),
          subtitle: Text(dems.join('\n')),
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

/// ダウンロード設定ダイアログ
class _DownloadSettingsDialog extends StatefulWidget {
  final LatLng center;
  final List<BaseMapProvider> providers;
  final int zoomMin;
  final int zoomMax;
  final double initialRadius;
  final RangeValues initialZoomRange;
  final BaseMapService baseMapService;
  final Function(double, int, int) onStartDownload;

  const _DownloadSettingsDialog({
    required this.center,
    required this.providers,
    required this.zoomMin,
    required this.zoomMax,
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
      _estimatedTiles = (result['totalTiles'] ?? 0) * widget.providers.length;
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
            Text(t.basemapExtra.mapName(name: widget.providers.map((p) => p.name).join(' + '))),
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
              min: widget.zoomMin.toDouble(),
              max: widget.zoomMax.toDouble(),
              divisions: widget.zoomMax - widget.zoomMin,
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

/// レイヤ 1 行: 持ち手・目・名前・合成モード・外す、下に不透明度
class _LayerRow extends StatelessWidget {
  const _LayerRow({
    super.key,
    required this.index,
    required this.layer,
    required this.provider,
    required this.isBottom,
    required this.blendLabel,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final BaseMapLayer layer;
  final BaseMapProvider provider;

  /// 一番下の層（合成モードは効かない）
  final bool isBottom;
  final String Function(BaseMapBlend) blendLabel;
  final ValueChanged<BaseMapLayer> onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final on = layer.visible;
    final dim = on ? null : Colors.grey;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
      child: Column(
        children: [
          // 持ち手・目・名前・外す
          Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle, color: Colors.grey),
                ),
              ),
              IconButton(
                icon: Icon(on ? Icons.visibility : Icons.visibility_off, color: on ? Colors.blue : Colors.grey),
                tooltip: on ? t.basemap.layers.hide : t.basemap.layers.show,
                onPressed: () => onChanged(layer.copyWith(visible: !on)),
              ),
              Icon(provider.icon, color: dim ?? Colors.blue, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(provider.name, style: TextStyle(fontSize: 14, color: dim), overflow: TextOverflow.ellipsis)),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.grey,
                tooltip: t.basemap.layers.remove,
                onPressed: onRemove,
              ),
            ],
          ),
          // 合成モード・不透明度
          Row(
            children: [
              const SizedBox(width: 48),
              DropdownButton<BaseMapBlend>(
                value: layer.blend,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: TextStyle(fontSize: 12, color: isBottom ? Colors.grey : Theme.of(context).textTheme.bodyMedium?.color),
                items: [
                  for (final b in BaseMapBlend.values) DropdownMenuItem(value: b, child: Text(blendLabel(b))),
                ],
                onChanged: isBottom ? null : (b) => b == null ? null : onChanged(layer.copyWith(blend: b)),
              ),
              Expanded(
                child: Slider(
                  value: layer.opacity.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${layer.opacity}%',
                  onChanged: (v) => onChanged(layer.copyWith(opacity: v.round())),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${layer.opacity}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: dim ?? Colors.blue),
                ),
              ),
            ],
          ),
          const Divider(height: 4),
        ],
      ),
    );
  }
}
