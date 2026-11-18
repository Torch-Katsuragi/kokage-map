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
/// TruPulse測量ステータスパネル
///
/// 機器接続状態・自動再接続状態・計測値・Station情報・後視確定/未確定バッジ・後視やり直し操作・測量精度を表示するパネル。
/// [TruPulseTool.buildStatusPanel] から返される。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../i18n/strings.g.dart';
import '../../models/nodes/feature_node.dart';
import '../../services/survey/survey_chain_resolver.dart';
import '../../services/survey/traverse_recorder.dart';
import 'trupulse_detail_screen.dart';
import 'trupulse_providers.dart';
import 'trupulse_tool.dart';

/// 閉合比の警告閾値（1/N の N がこの値以下で警告）
const double _closureWarningThreshold = 300;

bool _isBacksightCorrected(PointFeatureNode? stn) =>
    stn != null && TraverseRecorder.isBacksighted(stn);

bool _isProvisionalLeg(PointFeatureNode? stn) =>
    stn != null &&
    SurveyStation.parse(stn.properties['survey_stn']) != null &&
    !TraverseRecorder.isBacksighted(stn);

/// 「名前 (緯度, 経度)」。未設定なら設定を促す文言
String _stationText(PointFeatureNode? stn) {
  if (stn == null) return t.trupulse.panel.tapToSetStation;
  final name = stn.name.isNotEmpty ? stn.name : t.trupulse.panel.point;
  return '$name (${stn.point.latitude.toStringAsFixed(5)}, '
      '${stn.point.longitude.toStringAsFixed(5)})';
}

class TruPulseStatusPanel extends ConsumerWidget {
  final TruPulseTool tool;

  const TruPulseStatusPanel({super.key, required this.tool});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = tool.service;
    final tolerance = ref.watch(backsightToleranceSettingProvider);

    return ListenableBuilder(
      listenable: Listenable.merge([tool, service]),
      builder: (context, _) {
        final stn = tool.station;
        final undoTarget = tool.undoableBacksightPoint;
        final lastM = service.lastMeasurement;
        final chain = tool.currentChain;
        final deltaTarget = _isBacksightCorrected(stn) ? stn : undoTarget;
        final delta = TraverseRecorder.backsightDeltaOf(deltaTarget);
        final reconnecting = !service.isConnected && service.isReconnecting;
        final standby = service.hasStandbyDevice;

        return Positioned(
      right: 8,
      bottom: 8,
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TruPulseDetailScreen(service: service),
          ),
        ),
        child: Card(
          elevation: 4,
          child: Container(
            width: 268,
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Icon(
                      reconnecting ? Icons.bluetooth_searching : Icons.explore,
                      size: 16,
                      color: service.isConnected
                          ? Colors.green
                          : (reconnecting ? Colors.deepOrange : Colors.grey),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        service.deviceTypeName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (reconnecting) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.red.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 12,
                          color: Colors.red.shade800,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            t.trupulse.panel.reconnectingBadge,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.red.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (standby) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.shade50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.blueGrey.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.power_settings_new,
                          size: 12,
                          color: Colors.blueGrey.shade700,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            t.trupulse.panel.standbyBadge,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.blueGrey.shade900,
                            ),
                          ),
                        ),
                        InkWell(
                          key: const Key('trupulse_reconnect_standby_button'),
                          onTap: () => unawaited(service.reconnectStandby()),
                          borderRadius: BorderRadius.circular(3),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            child: Text(
                              t.trupulse.panel.reconnect,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                decoration: TextDecoration.underline,
                                color: Colors.blue.shade800,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 8),

                // Station info
                _InfoRow(label: 'STN', value: _stationText(stn)),
                if (_isProvisionalLeg(stn))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _ProvisionalBadge(),
                  ),
                if (_isBacksightCorrected(stn) || undoTarget != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _BacksightBadge(
                      delta: delta,
                      isWarning: tolerance.isExceededBy(delta),
                      onUndoBacksight: undoTarget == null
                          ? null
                          : () => unawaited(tool.undoBacksightOf(undoTarget)),
                    ),
                  ),

                // Latest measurement
                if (lastM != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _MeasChip('HD', '${lastM.hd.toStringAsFixed(1)}m'),
                      _MeasChip('AZ', '${lastM.az.toStringAsFixed(1)}\u00b0'),
                      _MeasChip('INC', '${lastM.inc.toStringAsFixed(1)}\u00b0'),
                    ],
                  ),
                ],

                // 測量精度情報
                if (chain != null && chain.points.isNotEmpty) ...[
                  const Divider(height: 8),
                  _TraversePrecisionBar(chain: chain),
                ],
              ],
            ),
          ),
        ),
      ),
    );
      },
    );
  }
}

class _ProvisionalBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.amber.shade400),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_top, size: 10, color: Colors.amber.shade900),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              t.trupulse.panel.provisionalBadge,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Colors.amber.shade900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TraversePrecisionBar extends StatelessWidget {
  final TraverseChain chain;

  const _TraversePrecisionBar({required this.chain});

  @override
  Widget build(BuildContext context) {
    final totalDist = chain.totalDistance;
    final closureErr = chain.closureError;
    final ratioN = chain.closureRatioN;
    final pointCount = chain.length;
    final unconfirmed = chain.unconfirmedCount;

    final isWarning = !ratioN.isInfinite && ratioN < _closureWarningThreshold;
    final ratioText =
        ratioN.isInfinite ? '\u221e' : '1/${ratioN.toStringAsFixed(0)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isWarning ? Icons.warning_amber : Icons.straighten,
              size: 12,
              color: isWarning ? Colors.orange : Colors.grey,
            ),
            const SizedBox(width: 4),
            Text(
              t.trupulse.traverse(count: '$pointCount'),
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            if (unconfirmed > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  t.trupulse.panel.unconfirmedCount(count: '$unconfirmed'),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade900,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            _MeasChip(
              t.trupulse.pathLength,
              '${totalDist.toStringAsFixed(1)}m',
            ),
            _MeasChip(
              t.trupulse.closureError,
              '${closureErr.toStringAsFixed(2)}m',
            ),
            _MeasChip(t.trupulse.closureRatio, ratioText, highlight: isWarning),
          ],
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

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
            style: const TextStyle(fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MeasChip extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  const _MeasChip(this.label, this.value, {this.highlight = false});

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
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: highlight ? Colors.orange.shade800 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BacksightBadge extends StatelessWidget {
  final BacksightDelta? delta;
  final bool isWarning;
  final VoidCallback? onUndoBacksight;

  const _BacksightBadge({
    this.delta,
    this.isWarning = false,
    this.onUndoBacksight,
  });

  @override
  Widget build(BuildContext context) {
    final d = delta;
    final bgColor = isWarning ? Colors.orange.shade50 : Colors.green.shade50;
    final borderColor =
        isWarning ? Colors.orange.shade300 : Colors.green.shade300;
    final iconColor =
        isWarning ? Colors.orange.shade800 : Colors.green.shade700;
    final titleColor =
        isWarning ? Colors.orange.shade900 : Colors.green.shade800;
    final diffColor =
        isWarning ? Colors.orange.shade900 : Colors.green.shade900;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                isWarning ? Icons.warning_amber : Icons.check_circle,
                size: 10,
                color: iconColor,
              ),
              const SizedBox(width: 3),
              Expanded(
                child: Text(
                  t.trupulse.backsightCorrected,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
              ),
              if (onUndoBacksight != null)
                InkWell(
                  key: const Key('trupulse_undo_backsight_button'),
                  onTap: onUndoBacksight,
                  borderRadius: BorderRadius.circular(3),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.undo, size: 10, color: titleColor),
                        const SizedBox(width: 2),
                        Text(
                          t.trupulse.panel.undoBacksight,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline,
                            color: titleColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (d != null) ...[
            const SizedBox(height: 1),
            Text(
              t.trupulse.backsightDiff(
                azDelta: d.azDeg.toStringAsFixed(1),
                hdDelta: d.hdM.toStringAsFixed(2),
              ),
              style: TextStyle(fontSize: 9, color: diffColor),
            ),
          ],
        ],
      ),
    );
  }
}
