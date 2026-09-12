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
// Root Maps: GPS測量ボタンウィジェット
// GPS測量と軌跡抽出のためのボタン群
import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';

/// GPS測量ボタンウィジェット
/// GPS測量ボタン（長押し対応）とGPS軌跡抽出ボタンを含む
class GpsSurveyButtons extends StatelessWidget {
  /// 長押し中フラグ
  final bool isLongPressing;
  
  /// 長押しGPSカウント
  final int longPressGpsCount;
  
  /// GPS測量タップコールバック
  final VoidCallback onRecordGpsPosition;
  
  /// GPS長押し測量開始コールバック
  final VoidCallback onStartLongPressGpsSurvey;
  
  /// GPS長押し測量停止コールバック
  final VoidCallback onStopLongPressGpsSurvey;
  
  /// GPS軌跡抽出ダイアログ表示コールバック
  final VoidCallback onOpenTrackExtraction;

  const GpsSurveyButtons({
    super.key,
    required this.isLongPressing,
    required this.longPressGpsCount,
    required this.onRecordGpsPosition,
    required this.onStartLongPressGpsSurvey,
    required this.onStopLongPressGpsSurvey,
    required this.onOpenTrackExtraction,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // GPS測量ボタン（長押し対応）
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 長押し中のデータ個数表示
              if (isLongPressing)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4.0,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    t.gps.longPressCount(count: longPressGpsCount),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              // GPS測量ボタン
              GestureDetector(
                onTap: onRecordGpsPosition,
                onLongPress: onStartLongPressGpsSurvey,
                onLongPressEnd: (_) => onStopLongPressGpsSurvey(),
                child: Container(
                  width: 56.0,
                  height: 56.0,
                  decoration: const BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 8.0,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 長押し進行状況を示すプログレスインジケーター
                      if (isLongPressing)
                        SizedBox(
                          width: 56.0,
                          height: 56.0,
                          child: CircularProgressIndicator(
                            strokeWidth: 3.0,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                            backgroundColor: Colors.white.withValues(alpha: 0.3),
                          ),
                        ),
                      // メインアイコン
                      const Icon(
                        Icons.add_location,
                        size: 28,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // GPS軌跡抽出ボタン
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FloatingActionButton(
            heroTag: 'gps_track_extract',
            onPressed: onOpenTrackExtraction,
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
            tooltip: t.gps.trackExtractTooltip,
            child: const Icon(
              Icons.timeline,
              size: 28,
            ),
          ),
        ),
      ],
    );
  }
}
