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
/// 機器接続状態・計測値・Station情報・測量精度を表示するパネル。
/// [TruPulseTool.buildStatusPanel] から返される。
library;

import 'package:flutter/material.dart';
import '../../i18n/strings.g.dart';
import '../../models/nodes/feature_node.dart';
import '../../services/survey/survey_chain_resolver.dart';
import 'trupulse_detail_screen.dart';
import 'trupulse_tool.dart';

/// 閉合比の警告閾値（1/N の N がこの値以下で警告）
const double _closureWarningThreshold = 300;

bool _isBacksightCorrected(PointFeatureNode? stn) {
  if (stn == null) return false;
  final v = stn.turfFeature.properties?['survey_backsight'];
  return v == true || v == 'true';
}

class TruPulseStatusPanel extends StatelessWidget {
  final TruPulseTool tool;

  const TruPulseStatusPanel({super.key, required this.tool});

  @override
  Widget build(BuildContext context) {
    final service = tool.service;
    final stn = tool.station;
    final lastM = service.lastMeasurement;
    final chain = tool.currentChain;

    return Positioned(
      right: 8,
      bottom: 8,
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TruPulseDetailScreen(service: tool.service),
          ),
        ),
        child: Card(
          elevation: 4,
          child: Container(
            width: 260,
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Icon(
                      Icons.explore,
                      size: 16,
                      color: service.isConnected ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      service.deviceTypeName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 8),

                // Station info
                _InfoRow(
                  label: 'STN',
                  value: stn != null
                      ? '${stn.name.isNotEmpty ? stn.name : "Point"} '
                          '(${stn.point.latitude.toStringAsFixed(5)}, '
                          '${stn.point.longitude.toStringAsFixed(5)})'
                      : 'Tap a point to set station',
                ),
                if (_isBacksightCorrected(stn))
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: _BacksightBadge(),
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

    final isWarning = !ratioN.isInfinite && ratioN < _closureWarningThreshold;
    final ratioText = ratioN.isInfinite
        ? '\u221e'
        : '1/${ratioN.toStringAsFixed(0)}';

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
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            _MeasChip(t.trupulse.pathLength, '${totalDist.toStringAsFixed(1)}m'),
            _MeasChip(t.trupulse.closureError, '${closureErr.toStringAsFixed(2)}m'),
            _MeasChip(
              t.trupulse.closureRatio,
              ratioText,
              highlight: isWarning,
            ),
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
            Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
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
  const _BacksightBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.green.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 10, color: Colors.green.shade700),
          const SizedBox(width: 3),
          Text(
            t.trupulse.backsightCorrected,
            style: TextStyle(fontSize: 9, color: Colors.green.shade800),
          ),
        ],
      ),
    );
  }
}
