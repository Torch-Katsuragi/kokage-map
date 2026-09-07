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
/// GPS情報表示ウィジェット
///
/// 統合GPS管理サービスから取得したGPS情報を
/// 見やすい形式で表示するためのウィジェット
///
/// Features:
/// - GPS位置情報の詳細表示
/// - GPS精度・信号強度の視覚的表示
/// - GPS状態インジケーター
/// - ソース情報の表示
library;

import 'package:flutter/material.dart';
import '../i18n/strings.g.dart';

/// GPS情報表示ウィジェット
class GpsInfoWidget extends StatelessWidget {
  /// GPS情報データ
  final Map<String, dynamic> gpsInfo;

  /// 詳細情報の表示/非表示
  final bool showDetails;

  /// コンパクト表示モード
  final bool isCompact;

  const GpsInfoWidget({
    super.key,
    required this.gpsInfo,
    this.showDetails = true,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return _buildCompactView(context);
    } else {
      return _buildDetailedView(context);
    }
  }

  /// 詳細表示ビュー
  Widget _buildDetailedView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // GPS状態表示
        _buildGpsStatusRow(),

        if (showDetails) ...[
          const SizedBox(height: 12),
          const Divider(),

          // 位置情報
          _buildPositionSection(),

          const SizedBox(height: 12),

          // 精度・信号情報
          _buildAccuracySection(),

          const SizedBox(height: 12),

          // ソース情報
          _buildSourceSection(),

          const SizedBox(height: 12),

          // 時刻情報
          _buildTimestampSection(),
        ],
      ],
    );
  }

  /// コンパクト表示ビュー
  Widget _buildCompactView(BuildContext context) {
    final isActive = gpsInfo['isActive'] == true;
    final latitude = gpsInfo['latitude'];
    final longitude = gpsInfo['longitude'];
    final accuracy = gpsInfo['accuracy'];

    return Row(
      children: [
        // GPS状態アイコン
        Icon(
          isActive ? Icons.gps_fixed : Icons.gps_off,
          color: isActive ? Colors.green : Colors.grey,
          size: 20,
        ),
        const SizedBox(width: 8),

        // 位置情報（簡略表示）
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (latitude != null && longitude != null)
                Text(
                  '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                )
              else
                Text(
                  t.common.acquiring,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              if (accuracy != null)
                Text(
                  '${t.gps.accuracy.positionAccuracy}: ±${accuracy.toStringAsFixed(1)}m',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
            ],
          ),
        ),

        // ソース表示
        Text(
          gpsInfo['sourceName'] ?? 'GPS',
          style: const TextStyle(fontSize: 10, color: Colors.blue),
        ),
      ],
    );
  }

  /// GPS状態表示行
  Widget _buildGpsStatusRow() {
    final isActive = gpsInfo['isActive'] == true;
    final isInitialized = gpsInfo['isInitialized'] == true;
    final sourceName = gpsInfo['sourceName'] ?? t.common.unknown;

    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (!isInitialized) {
      statusColor = Colors.orange;
      statusText = t.gps.status.initializing;
      statusIcon = Icons.gps_not_fixed;
    } else if (isActive) {
      statusColor = Colors.green;
      statusText = t.gps.status.receiving(source: sourceName);
      statusIcon = Icons.gps_fixed;
    } else {
      statusColor = Colors.grey;
      statusText = t.gps.status.stopped(source: sourceName);
      statusIcon = Icons.gps_off;
    }

    return Row(
      children: [
        Icon(statusIcon, color: statusColor, size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                statusText,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: statusColor,
                ),
              ),
              if (gpsInfo['usesForegroundService'] == true)
                Text(
                  t.gps.status.foregroundService,
                  style: const TextStyle(fontSize: 12, color: Colors.blue),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 位置情報セクション
  Widget _buildPositionSection() {
    final latitude = gpsInfo['latitude'];
    final longitude = gpsInfo['longitude'];
    final altitude = gpsInfo['altitude'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.gps.position.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        _buildInfoRow(
          t.gps.position.latitude,
          latitude != null ? '${latitude.toStringAsFixed(6)}\u00b0' : t.common.acquiring,
        ),
        _buildInfoRow(
          t.gps.position.longitude,
          longitude != null ? '${longitude.toStringAsFixed(6)}\u00b0' : t.common.acquiring,
        ),
        if (altitude != null)
          _buildInfoRow(t.gps.position.altitude, '${altitude.toStringAsFixed(1)}m'),
      ],
    );
  }

  /// 精度・信号情報セクション
  Widget _buildAccuracySection() {
    final accuracy = gpsInfo['accuracy'];
    final speed = gpsInfo['speed'];
    final bearing = gpsInfo['bearing'];
    final satelliteCount = gpsInfo['satelliteCount'];
    final hdop = gpsInfo['hdop'];
    final gpsQuality = gpsInfo['gpsQuality'];
    final sourceType = gpsInfo['sourceType'];
    final isExternalGnss = sourceType == 'GNSS';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.gps.accuracy.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (accuracy != null) ...[
          _buildInfoRow(t.gps.accuracy.positionAccuracy, '\u00b1${accuracy.toStringAsFixed(1)}m'),
          _buildAccuracyIndicator(accuracy),
        ] else
          _buildInfoRow(t.gps.accuracy.positionAccuracy, t.common.acquiring),

        // 外部GNSS機器の場合のみ衛星情報を表示
        if (isExternalGnss) ...[
          const SizedBox(height: 8),
          _buildGnssSatelliteSection(satelliteCount, hdop, gpsQuality),
        ],

        if (speed != null && speed > 0)
          _buildInfoRow(t.gps.accuracy.speed, '${(speed * 3.6).toStringAsFixed(1)} km/h'),

        if (bearing != null)
          _buildInfoRow(t.gps.accuracy.bearing, '${bearing.toStringAsFixed(0)}\u00b0'),
      ],
    );
  }

  /// 精度インジケーター
  Widget _buildAccuracyIndicator(double accuracy) {
    Color accuracyColor;
    String accuracyLabel;

    if (accuracy <= 3.0) {
      accuracyColor = Colors.green;
      accuracyLabel = t.gps.accuracy.high;
    } else if (accuracy <= 10.0) {
      accuracyColor = Colors.orange;
      accuracyLabel = t.gps.accuracy.medium;
    } else {
      accuracyColor = Colors.red;
      accuracyLabel = t.gps.accuracy.low;
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: accuracyColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            accuracyLabel,
            style: TextStyle(
              fontSize: 12,
              color: accuracyColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// ソース情報セクション
  Widget _buildSourceSection() {
    final sourceType = gpsInfo['sourceType'] ?? t.common.unknown;
    final sourceName = gpsInfo['sourceName'] ?? t.common.unknown;
    final selectedDevice = gpsInfo['selectedDevice'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.gps.source.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        _buildInfoRow(t.gps.source.type, sourceType),
        _buildInfoRow(t.gps.source.name, sourceName),
        if (selectedDevice != null) _buildInfoRow(t.gps.source.device, selectedDevice),
      ],
    );
  }

  /// 時刻情報セクション
  Widget _buildTimestampSection() {
    final timestamp = gpsInfo['timestamp'];
    final isSurveyMode = gpsInfo['isSurveyMode'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.gps.timestamp.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        _buildInfoRow(
          t.gps.timestamp.lastUpdate,
          timestamp != null ? _formatTimestamp(timestamp) : t.gps.timestamp.notAcquired,
        ),
        if (isSurveyMode)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                const Icon(Icons.engineering, size: 16, color: Colors.blue),
                const SizedBox(width: 4),
                Text(
                  t.gps.status.surveyMode,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.blue,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 情報行ウィジェット
  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const Text(' : ', style: TextStyle(fontSize: 12, color: Colors.grey)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  /// GNSS衛星情報セクション（外部GNSS機器専用）
  Widget _buildGnssSatelliteSection(
    int? satelliteCount,
    double? hdop,
    int? gpsQuality,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.satellite_alt, size: 16, color: Colors.blue.shade700),
              const SizedBox(width: 4),
              Text(
                t.gps.gnss.title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _buildSatelliteInfo(t.gps.gnss.satellites, satelliteCount)),
              const SizedBox(width: 16),
              Expanded(child: _buildSatelliteInfo('HDOP', hdop)),
            ],
          ),
          const SizedBox(height: 4),
          _buildGpsQualityIndicator(gpsQuality),
        ],
      ),
    );
  }

  /// 衛星情報項目表示
  Widget _buildSatelliteInfo(String label, dynamic value) {
    String displayValue;

    if (value == null) {
      displayValue = t.gps.timestamp.notAcquired;
    } else if (value is int) {
      displayValue = t.gps.gnss.satelliteUnit(count: value.toString());
    } else if (value is double) {
      displayValue = value.toStringAsFixed(2);
    } else {
      displayValue = value.toString();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        Text(
          displayValue,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  /// GPS品質インジケーター
  Widget _buildGpsQualityIndicator(int? quality) {
    if (quality == null) return const SizedBox.shrink();

    String qualityText;
    Color qualityColor;

    switch (quality) {
      case 0:
        qualityText = t.gps.gnss.qualityInvalid;
        qualityColor = Colors.red;
      case 1:
        qualityText = t.gps.gnss.qualityStandard;
        qualityColor = Colors.orange;
      case 2:
        qualityText = t.gps.gnss.qualityDgps;
        qualityColor = Colors.blue;
      case 3:
        qualityText = t.gps.gnss.qualityRtkFixed;
        qualityColor = Colors.green;
      case 4:
        qualityText = t.gps.gnss.qualityRtkFloat;
        qualityColor = Colors.lightGreen;
      case 5:
        qualityText = t.gps.gnss.qualityDeadReckoning;
        qualityColor = Colors.purple;
      default:
        qualityText = t.gps.gnss.qualityN(n: quality.toString());
        qualityColor = Colors.grey;
    }

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: qualityColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          qualityText,
          style: TextStyle(
            fontSize: 10,
            color: qualityColor,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// タイムスタンプのフォーマット
  String _formatTimestamp(String timestamp) {
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);

      if (difference.inSeconds < 60) {
        return t.common.seconds(count: difference.inSeconds.toString());
      } else if (difference.inMinutes < 60) {
        return t.common.minutes(count: difference.inMinutes.toString());
      } else {
        return '${dateTime.hour.toString().padLeft(2, '0')}:'
            '${dateTime.minute.toString().padLeft(2, '0')}:'
            '${dateTime.second.toString().padLeft(2, '0')}';
      }
    } catch (e) {
      return timestamp;
    }
  }
}
