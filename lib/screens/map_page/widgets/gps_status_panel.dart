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

/// GPS / 外部GNSS 測量ステータスパネル
///
/// ツールバーで [GpsTool] を選んでいる間、コンパスツール（[TruPulseStatusPanel]）と
/// 同じ作法で画面右下（左利き配置では左下）に現在の GPS / 外部GNSS の状態を表示する。
/// 外部GNSS 接続時は自動的に外部GNSS 向けの測位状態（RTK FIX / FLOAT / DGPS / 衛星数 / HDOP / GST精度）へ切り替わる。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/gnss_quality.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../providers/gps_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../services/gps_manager_service.dart';
import '../../../services/ntrip/ntrip_client_service.dart';
import '../../../tools/gps_tool.dart';
import '../../../utils/global_drawing_state.dart';
import '../../gps_settings_screen.dart';

class GpsStatusPanel extends ConsumerWidget {
  const GpsStatusPanel({
    super.key,
    required this.tool,
    this.toolbarLeft = true,
    this.rightInset = 0,
    this.gpsManager,
    this.ntripService,
    this.infoOverride,
    this.onTapOverride,
  });

  final GpsTool tool;

  /// ツールバーと GPS 測量ボタンが左側にあるか（左利き配置のときは false → パネルを左下に逃がす）
  final bool toolbarLeft;

  /// 広い画面で右ドロワーが開いているときに空ける右余白
  final double rightInset;

  /// テスト差し替え用
  final GpsManagerService? gpsManager;
  final NtripClientService? ntripService;
  final GpsInfo? infoOverride;
  final VoidCallback? onTapOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = gpsManager ?? GpsManagerService();
    final ntrip = ntripService ?? NtripClientService.instance;
    final drawingState = GlobalDrawingState.instance;
    final selectedLayer = ref.watch(selectedLayerNodeProvider);
    final gate = ref.watch(gnssQualityGateSettingProvider);

    return ListenableBuilder(
      listenable: Listenable.merge([manager, ntrip, tool, drawingState]),
      builder: (context, _) {
        final info = infoOverride ?? manager.currentInfo;
        final lineDrawing = selectedLayer is LineLayerNode && drawingState.isLineDrawing;
        final polygonDrawing = selectedLayer is PolygonLayerNode && drawingState.isPolygonDrawing;
        final hasBottomRightFab = toolbarLeft && (lineDrawing || polygonDrawing);
        final vertexCount = lineDrawing
            ? drawingState.drawingLine.length
            : polygonDrawing
                ? drawingState.drawingPolygon.length
                : 0;

        return Positioned(
          right: toolbarLeft ? 8 + rightInset : null,
          left: toolbarLeft ? null : 8,
          bottom: hasBottomRightFab ? 84 : 8,
          child: GestureDetector(
            onTap: onTapOverride ??
                () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const GpsSettingsScreen()),
                    ),
            child: Card(
              elevation: 4,
              child: Container(
                width: 268,
                padding: const EdgeInsets.all(8),
                child: _GpsStatusContent(
                  info: info,
                  manager: manager,
                  ntrip: ntrip,
                  selectedLayer: selectedLayer,
                  gate: gate,
                  isLongPressing: tool.isLongPressing,
                  longPressCount: tool.longPressGpsCount,
                  longPressRejected: tool.longPressRejectedCount,
                  vertexCount: vertexCount,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GpsStatusContent extends StatelessWidget {
  const _GpsStatusContent({
    required this.info,
    required this.manager,
    required this.ntrip,
    required this.selectedLayer,
    required this.gate,
    required this.isLongPressing,
    required this.longPressCount,
    required this.longPressRejected,
    required this.vertexCount,
  });

  final GpsInfo info;
  final GpsManagerService manager;
  final NtripClientService ntrip;
  final LayerNode? selectedLayer;
  final GnssQualityGate gate;
  final bool isLongPressing;
  final int longPressCount;
  final int longPressRejected;
  final int vertexCount;

  @override
  Widget build(BuildContext context) {
    final p = t.gps.panel;
    final visual = _resolveVisual(info);
    final gateFailures = _checkGateFailures(info, gate);

    final accBad = info.accuracy != null &&
        ((gate.maxAccuracy != null && info.accuracy! > gate.maxAccuracy!) ||
            (!info.isExternal && info.accuracy! > 10.0));
    final satBad = info.isExternal &&
        gate.minSatellites != null &&
        (info.satelliteCount == null || info.satelliteCount! < gate.minSatellites!);

    final coordText = (info.latitude != null && info.longitude != null)
        ? '${info.latitude!.toStringAsFixed(6)}, ${info.longitude!.toStringAsFixed(6)}'
        : t.common.acquiring;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header: ソース名（内蔵GPS / 外部GNSS・機器名）＋ 測位状態バッジ
        Row(
          children: [
            Icon(visual.icon, size: 16, color: visual.color),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                visual.title,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            _StatusBadge(label: visual.badge, color: visual.color),
          ],
        ),
        const Divider(height: 8),

        // 記録先レイヤ
        _InfoRow(
          label: p.targetLabel,
          value: selectedLayer?.name ?? p.noTargetLayer,
          valueColor: selectedLayer == null ? Colors.orange.shade800 : null,
        ),

        // 現在座標
        const SizedBox(height: 2),
        _InfoRow(label: p.coordLabel, value: coordText),

        // 長押し平均化中のライブ進捗
        if (isLongPressing)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: Colors.blue.shade700,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      longPressRejected > 0
                          ? p.averagingWithRejected(count: '$longPressCount', rejected: '$longPressRejected')
                          : p.averaging(count: '$longPressCount'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 4),

        // メトリクス 3 チップ（外部GNSS vs 内蔵GPS で自動切替）
        if (info.isExternal) ...[
          Row(
            children: [
              _MeasChip(
                info.accuracySource == GnssAccuracySource.gst ? p.accuracyGstChip : p.accuracyChip,
                info.accuracy != null ? '±${formatMeters(info.accuracy!)}' : '--',
                highlight: accBad,
              ),
              _MeasChip(
                p.satellitesChip,
                info.satelliteCount != null ? t.gps.gnss.satelliteUnit(count: '${info.satelliteCount}') : '--',
                highlight: satBad,
              ),
              _MeasChip(
                'HDOP',
                info.hdop != null ? info.hdop!.toStringAsFixed(2) : '--',
              ),
            ],
          ),
          if (info.altitude != null || _hasInformativeCorrection(info)) ...[
            const SizedBox(height: 3),
            _InfoRow(
              label: info.altitude != null ? p.altitudeChip : p.correctionLabel,
              value: [
                if (info.altitude != null) '${info.altitude!.toStringAsFixed(1)}m',
                if (_hasInformativeCorrection(info)) info.correctionSource!,
              ].join(' · '),
            ),
          ],
          if (ntrip.status != NtripStatus.disconnected) ...[
            const SizedBox(height: 3),
            _NtripStatusRow(ntrip: ntrip),
          ],
          if (!info.isExternalConnected &&
              !info.isExternalConnecting &&
              !info.isActive) ...[
            if (!info.isExternalReconnecting &&
                info.selectedDevice != null &&
                info.selectedDevice!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    Icons.power_settings_new,
                    size: 12,
                    color: Colors.blueGrey.shade700,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      p.standbyBadge,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey.shade800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const Key('gps_reconnect_external_button'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    foregroundColor: Colors.blue.shade800,
                    side: BorderSide(color: Colors.blue.shade400),
                    textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
                  ),
                  onPressed: manager.reconnectExternalGnssNow,
                  icon: const Icon(Icons.bluetooth_connected, size: 13),
                  label: Text(p.reconnectExternal),
                ),
              ),
            ],
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('gps_use_internal_fallback_button'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  foregroundColor: Colors.amber.shade900,
                  side: BorderSide(color: Colors.amber.shade600),
                  textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
                ),
                onPressed: manager.enableTemporaryInternalFallback,
                icon: const Icon(Icons.swap_horiz, size: 13),
                label: Text(p.useInternalFallback),
              ),
            ),
          ],
        ] else ...[
          Row(
            children: [
              _MeasChip(
                p.accuracyChip,
                info.accuracy != null ? '±${formatMeters(info.accuracy!)}' : '--',
                highlight: accBad,
              ),
              _MeasChip(
                p.altitudeChip,
                info.altitude != null ? '${info.altitude!.toStringAsFixed(1)}m' : '--',
              ),
              if (vertexCount > 0)
                _MeasChip(p.verticesChip, '$vertexCount')
              else
                _MeasChip(
                  p.bearingChip,
                  info.bearing != null ? '${info.bearing!.toStringAsFixed(0)}°' : '--',
                ),
            ],
          ),
          if (info.isFallbackInternal) ...[
            const SizedBox(height: 5),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.amber.shade400),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.fallbackHint,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.amber.shade900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Align(
                    alignment: Alignment.centerRight,
                    child: InkWell(
                      key: const Key('gps_resume_external_button'),
                      onTap: manager.resumeExternalGnssFromFallback,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        child: Text(
                          p.resumeExternalGnss,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline,
                            color: Colors.blue.shade800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],

        // GNSS 品質足切り（設定 → GPS・測位）に対するライブ判定警告
        if (gateFailures.isNotEmpty) ...[
          const Divider(height: 8),
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 13,
                color: gate.strict ? Colors.red.shade700 : Colors.orange.shade800,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  gateFailures.join(' / '),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: gate.strict ? Colors.red.shade700 : Colors.orange.shade800,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static bool _hasInformativeCorrection(GpsInfo info) {
    final c = info.correctionSource;
    if (c == null || c.isEmpty) return false;
    return c != t.gps.unknown && c != t.gps.noCorrection && c != t.gps.standalone;
  }

  static List<String> _checkGateFailures(GpsInfo info, GnssQualityGate gate) {
    if (!gate.isActive || info.latitude == null || info.longitude == null) {
      return const [];
    }
    final sample = GnssSample(
      latitude: info.latitude!,
      longitude: info.longitude!,
      accuracy: info.accuracy,
      accuracySource: info.accuracySource ??
          (info.isExternal ? GnssAccuracySource.hdop : GnssAccuracySource.device),
      satellites: info.satelliteCount,
      hdop: info.hdop,
      pdop: info.pdop,
      gpsQuality: info.gpsQuality,
      isExternal: info.isExternal,
      device: info.selectedDevice,
      time: info.timestamp,
    );
    return gate.check(sample);
  }

  static ({IconData icon, Color color, String title, String badge}) _resolveVisual(GpsInfo info) {
    final p = t.gps.panel;
    if (info.isFallbackInternal) {
      return (
        icon: Icons.gps_not_fixed,
        color: Colors.amber.shade900,
        title: GpsSourceType.internal.displayName,
        badge: p.fallbackBadge,
      );
    }
    if (info.isExternal) {
      final device = info.selectedDevice;
      final title = (device != null && device.isNotEmpty)
          ? '${info.sourceName} · $device'
          : info.sourceName;

      if (info.isExternalConnecting) {
        return (
          icon: Icons.bluetooth_searching,
          color: Colors.blue,
          title: title,
          badge: p.connectingBadge,
        );
      }
      if (!info.isExternalConnected && info.isExternalReconnecting) {
        return (
          icon: Icons.bluetooth_searching,
          color: Colors.deepOrange.shade700,
          title: title,
          badge: p.reconnectingBadge,
        );
      }
      if (!info.isExternalConnected && !info.isActive && info.gpsQuality == null) {
        return (
          icon: Icons.bluetooth_disabled,
          color: Colors.red.shade700,
          title: title,
          badge: p.disconnectedBadge,
        );
      }
      return switch (info.gpsQuality) {
        4 => (
            icon: Icons.satellite_alt,
            color: Colors.green.shade700,
            title: title,
            badge: 'RTK FIX',
          ),
        5 => (
            icon: Icons.satellite_alt,
            color: Colors.teal.shade700,
            title: title,
            badge: 'RTK FLOAT',
          ),
        2 || 3 || 9 => (
            icon: Icons.satellite_alt,
            color: Colors.blue.shade700,
            title: title,
            badge: info.fixType ?? 'DGPS',
          ),
        1 => (
            icon: Icons.satellite_alt,
            color: Colors.orange.shade800,
            title: title,
            badge: 'GPS',
          ),
        0 => (
            icon: Icons.satellite_alt,
            color: Colors.red.shade700,
            title: title,
            badge: 'No Fix',
          ),
        _ => (
            icon: Icons.satellite_alt,
            color: info.isActive ? Colors.green.shade700 : Colors.orange.shade800,
            title: title,
            badge: info.isActive ? (info.fixType ?? 'GNSS') : p.acquiringBadge,
          ),
      };
    }

    // 内蔵GPS
    if (info.isActive) {
      return (
        icon: Icons.gps_fixed,
        color: Colors.green.shade700,
        title: info.sourceName,
        badge: p.receivingBadge,
      );
    }
    if (info.isGpsActive) {
      return (
        icon: Icons.gps_not_fixed,
        color: Colors.orange.shade800,
        title: info.sourceName,
        badge: p.acquiringBadge,
      );
    }
    return (
      icon: Icons.gps_off,
      color: Colors.grey.shade600,
      title: info.sourceName,
      badge: p.stoppedBadge,
    );
  }
}

class _NtripStatusRow extends StatelessWidget {
  const _NtripStatusRow({required this.ntrip});

  final NtripClientService ntrip;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (ntrip.status) {
      NtripStatus.streaming => (
          Icons.cell_tower,
          Colors.teal.shade700,
          t.ntrip.panelStreaming(
            mount: ntrip.activeConfig.normalizedMountpoint,
            frames: '${ntrip.validRtcmFrames}',
          ),
        ),
      NtripStatus.connecting || NtripStatus.reconnecting => (
          Icons.sync,
          Colors.blue.shade700,
          t.ntrip.panelConnecting,
        ),
      NtripStatus.error => (
          Icons.error_outline,
          Colors.red.shade700,
          t.ntrip.panelError,
        ),
      NtripStatus.disconnected => (Icons.cell_tower, Colors.grey, ''),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          '$label: ',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 11,
              color: valueColor,
              fontFamily: label == 'POS' ? 'monospace' : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MeasChip extends StatelessWidget {
  const _MeasChip(this.label, this.value, {this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        decoration: BoxDecoration(
          color: highlight ? Colors.orange.shade100 : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 9, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: highlight ? Colors.orange.shade800 : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
