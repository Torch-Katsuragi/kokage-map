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
/// オフライン一括ダウンロードセクションおよび設定・進捗ダイアログ
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/basemap_provider.dart';
import '../../services/basemap_service.dart';
import '../../widgets/settings_widgets.dart';

/// 一括ダウンロードセクション
class BasemapDownloadSection extends StatelessWidget {
  const BasemapDownloadSection({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return SettingsHighlightSection(
      title: t.basemap.download.title,
      icon: Icons.download_for_offline,
      iconColor: Colors.blue,
      backgroundColor: Colors.blue[50]!,
      description: t.basemap.download.description,
      actionButton: ElevatedButton.icon(
        onPressed: onOpenSettings,
        icon: const Icon(Icons.download),
        label: Text(t.basemap.download.openSettings),
        style: settingsButtonStyle(
          Colors.blue,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}

/// 一括ダウンロードの設定ダイアログ → 進捗ダイアログを開く
Future<void> showBasemapDownloadFlow(
  BuildContext context, {
  required BaseMapService service,
  required LatLng center,
  required double? currentMapZoom,
  required void Function(String title, NotificationLevel level) notify,
  required VoidCallback onDownloadFinished,
}) async {
  // 見えているレイヤ全部を落とす。OSM は一括ダウンロード禁止（タイル利用ポリシー: prefetchはブロック対象）なので除く
  final providers = service.downloadableProviders;
  final hasOsm = service.activeLayers.any((e) => e.$1.type == BaseMapType.openStreetMap);
  if (providers.isEmpty) {
    notify(t.basemap.download.osmNotAllowed, NotificationLevel.warning);
    return;
  }
  if (hasOsm) {
    notify(t.basemap.download.osmSkipped, NotificationLevel.info);
  }

  // 段の範囲はプロバイダの和（等高線の z19 は地理院の切り出しになるので 18 で止める）
  final zMinAll = providers.map((p) => p.minZoom).reduce(math.min);
  final zMaxAll = math.min(18, providers.map((p) => p.maxZoom).reduce(math.max));

  // 初期ズーム範囲: 現在のズームレベル前後
  final currentZoom = currentMapZoom ?? 15.0;
  double minZoom = (currentZoom - 2).clamp(zMinAll.toDouble(), zMaxAll.toDouble());
  final double maxZoom = (currentZoom + 2).clamp(zMinAll.toDouble(), zMaxAll.toDouble());
  if (minZoom > maxZoom) minZoom = maxZoom;

  final RangeValues zoomRange = RangeValues(minZoom, maxZoom);
  const double radius = 1000; // 1km

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => BasemapDownloadSettingsDialog(
      center: center,
      providers: providers,
      zoomMin: zMinAll,
      zoomMax: zMaxAll,
      initialRadius: radius,
      initialZoomRange: zoomRange,
      baseMapService: service,
      onStartDownload: (r, zMin, zMax) {
        Navigator.pop(dialogContext);
        if (!context.mounted) return;
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => BasemapDownloadProgressDialog(
              center: center,
              radius: r,
              minZoom: zMin,
              maxZoom: zMax,
              baseMapService: service,
            ),
          ).then((_) => onDownloadFinished()),
        );
      },
    ),
  );
}

/// ダウンロード設定ダイアログ
class BasemapDownloadSettingsDialog extends StatefulWidget {
  final LatLng center;
  final List<BaseMapProvider> providers;
  final int zoomMin;
  final int zoomMax;
  final double initialRadius;
  final RangeValues initialZoomRange;
  final BaseMapService baseMapService;
  final void Function(double radius, int minZoom, int maxZoom) onStartDownload;

  const BasemapDownloadSettingsDialog({
    super.key,
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
  State<BasemapDownloadSettingsDialog> createState() => _BasemapDownloadSettingsDialogState();
}

class _BasemapDownloadSettingsDialogState extends State<BasemapDownloadSettingsDialog> {
  late double _radius = widget.initialRadius;
  late RangeValues _zoomRange = widget.initialZoomRange;
  late int _estimatedTiles = _estimateTiles();

  /// いまの範囲・段で落とすタイル数（全レイヤ分）
  int _estimateTiles() {
    final result = widget.baseMapService.estimateDownloadSize(
      center: widget.center,
      radiusMeters: _radius,
      minZoom: _zoomRange.start.round(),
      maxZoom: _zoomRange.end.round(),
    );
    return (result['totalTiles'] ?? 0) * widget.providers.length;
  }

  void _update({double? radius, RangeValues? zoomRange}) {
    setState(() {
      _radius = radius ?? _radius;
      _zoomRange = zoomRange ?? _zoomRange;
      _estimatedTiles = _estimateTiles();
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
            Text(
              t.basemapExtra.center(
                lat: widget.center.latitude.toStringAsFixed(4),
                lng: widget.center.longitude.toStringAsFixed(4),
              ),
            ),
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
                    onChanged: (value) => _update(radius: value),
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
              onChanged: (values) => _update(zoomRange: values),
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
                    _zoomRange.end.round(),
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
class BasemapDownloadProgressDialog extends StatefulWidget {
  final LatLng center;
  final double radius;
  final int minZoom;
  final int maxZoom;
  final BaseMapService baseMapService;

  const BasemapDownloadProgressDialog({
    super.key,
    required this.center,
    required this.radius,
    required this.minZoom,
    required this.maxZoom,
    required this.baseMapService,
  });

  @override
  State<BasemapDownloadProgressDialog> createState() => _BasemapDownloadProgressDialogState();
}

class _BasemapDownloadProgressDialogState extends State<BasemapDownloadProgressDialog> {
  Map<String, dynamic> _status = {};
  bool _isFinished = false;

  static const _finishedStatuses = {'completed', 'cancelled', 'error'};

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  void _startDownload() {
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
          if (_finishedStatuses.contains(status['status'])) _isFinished = true;
        });
      }
    }, onError: (Object e) {
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
            Text(
              t.basemap.download.progress(
                percent: (percent * 100).toStringAsFixed(1),
                processed: processed.toString(),
                total: total.toString(),
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (statusStr == 'completed')
            _resultText(t.basemap.download.complete, Colors.green)
          else if (statusStr == 'cancelled')
            _resultText(t.basemap.download.cancelled, Colors.orange)
          else if (statusStr == 'error')
            Text(
              t.common.errorOccurred(error: _status['message'].toString()),
              style: const TextStyle(color: Colors.red),
            ),
          const Divider(),
          SettingsInfoRow(
            label: t.basemap.download.successDownloaded,
            value: downloaded.toString(),
            valueColor: Colors.blue,
          ),
          SettingsInfoRow(
            label: t.basemap.download.skipped,
            value: skipped.toString(),
            valueColor: Colors.grey,
          ),
          SettingsInfoRow(
            label: t.basemap.download.errors,
            value: errors.toString(),
            valueColor: Colors.red,
          ),
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

  /// 終わったときの一言（完了・中止）
  Widget _resultText(String text, Color color) => Center(
        child: Text(
          text,
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      );
}
