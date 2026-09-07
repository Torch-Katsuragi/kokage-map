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
// こかげマップ: 現在位置マーカーをタップしたときに出す GPS 情報カード
//
// 以前は AppBar の下に常時バーを出していたが、地図の高さを削るわりに
// 見るのは稀なので、フィーチャの情報カードと同じ枠で必要なときだけ出す。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import '../../../widgets/info_panel_card.dart';

class GpsInfoPanel extends StatelessWidget {
  const GpsInfoPanel({
    super.key,
    required this.gpsInfo,
    required this.headingNotifier,
    required this.onClose,
  });

  /// `GpsManagerService.getCurrentGpsInfo()` の Map（null / isActive=false は取得中）
  final Map<String, dynamic>? gpsInfo;
  final ValueListenable<double?> headingNotifier;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final info = gpsInfo;
    final active = info != null && info['isActive'] == true;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: Text(value)),
            ],
          ),
        );

    final lat = info?['latitude'] as double?;
    final lon = info?['longitude'] as double?;
    final accuracy = info?['accuracy'] as double?;
    final satellites = info?['satelliteCount'] as int?;
    final hdop = info?['hdop'] as double?;
    final sourceName = info?['sourceName'] as String? ?? t.gps.unknownDevice;

    return InfoPanelCard(
      title: t.gpsPanel.title,
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: onClose,
      ),
      children: [
        if (!active) row(t.gpsPanel.status, t.gps.acquiring),
        if (lat != null && lon != null)
          row(
            t.gpsPanel.position,
            '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}',
          ),
        if (accuracy != null) row(t.gpsPanel.accuracy, '±${accuracy.toStringAsFixed(1)} m'),
        if (satellites != null) row(t.gpsPanel.satellites, '$satellites'),
        if (hdop != null) row('HDOP', hdop.toStringAsFixed(2)),
        row(t.gpsPanel.source, sourceName),
        ValueListenableBuilder<double?>(
          valueListenable: headingNotifier,
          builder: (_, heading, _) => heading == null
              ? const SizedBox.shrink()
              : row(t.gpsPanel.heading, '${heading.toStringAsFixed(0)}°'),
        ),
      ],
    );
  }
}
