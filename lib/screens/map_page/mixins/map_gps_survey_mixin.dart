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
// Root Maps: GPS測量Mixin
// GPS測量（単一点記録、長押し測量）関連の機能を提供
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/app_notification.dart';
import '../../../providers/notification_providers.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/tool_providers.dart';
import '../../../tools/gps_tool.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/global_drawing_state.dart';
import '../map_page_state_base.dart';

/// GPS測量Mixin
/// 単一点GPS測量と長押し測量機能を提供
mixin MapGpsSurveyMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  
  // =============================================
  // GPS測量（単一点記録）
  // =============================================
  
  /// GPS測量（現在位置を記録）
  Future<void> recordGpsPosition() async {
    try {
      final currentTool = ref.read(currentToolProvider);
      if (currentTool is! GpsTool) {
        AppLogger.debug('[MapGpsSurveyMixin] GPS測量: 現在のツールがGpsToolではありません');
        return;
      }
      
      final selected = ref.read(selectedLayerNodeProvider);
      if (selected == null) {
        if (mounted) {
          ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.noLayerSelected,
            level: NotificationLevel.warning,
          );
        }
        return;
      }
      
      if (!selected.isVisibleRecursive()) {
        if (mounted) {
          ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.layerInvisible,
            level: NotificationLevel.warning,
          );
        }
        return;
      }
      
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.gps.acquiringGps,
          level: NotificationLevel.info,
        );
      }
      
      // GPS位置を記録
      final success = await currentTool.recordCurrentGpsPosition();
      if (success) {
        triggerSetState(() {}); // プレビュー更新
        
        if (mounted) {
          final drawState = GlobalDrawingState.instance;
          final totalPoints =
              drawState.drawingLine.length +
              drawState.drawingPolygon.length;
          ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.gpsRecorded(count: '$totalPoints'),
            level: NotificationLevel.success,
          );
        }
      } else {
        if (mounted) {
          ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.gpsUnavailable,
            level: NotificationLevel.error,
          );
        }
      }
    } catch (e) {
      AppLogger.debug('[MapGpsSurveyMixin] GPS測量エラー: $e');
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.gps.gpsSurveyError(error: '$e'),
          level: NotificationLevel.error,
        );
      }
    }
  }
  
  // =============================================
  // GPS長押し測量
  // =============================================
  
  /// GPS長押し測量開始
  Future<void> startLongPressGpsSurvey() async {
    try {
      final currentTool = ref.read(currentToolProvider);
      if (currentTool is! GpsTool) {
        AppLogger.debug('[MapGpsSurveyMixin] GPS長押し測量: 現在のツールがGpsToolではありません');
        return;
      }
      
      triggerSetState(() {
        isLongPressing = true;
        longPressGpsCount = 0;
      });
      
      AppLogger.debug('[MapGpsSurveyMixin] GPS長押し測量開始');
      currentTool.startLongPressGpsSurvey();
      
      // 長押し中の個数更新タイマーを開始（0.5秒間隔で更新）
      longPressCountUpdateTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (timer) {
          final newCount = currentTool.longPressGpsCount;
          if (longPressGpsCount != newCount) {
            triggerSetState(() {
              longPressGpsCount = newCount;
            });
          }
        },
      );
      
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.gps.longPressSurveying,
          level: NotificationLevel.info,
        );
      }
    } catch (e) {
      AppLogger.debug('[MapGpsSurveyMixin] GPS長押し測量開始エラー: $e');
      longPressCountUpdateTimer?.cancel();
      longPressCountUpdateTimer = null;
      triggerSetState(() {
        isLongPressing = false;
        longPressGpsCount = 0;
      });
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.gps.longPressSurveyStartError(error: '$e'),
          level: NotificationLevel.error,
        );
      }
    }
  }
  
  /// GPS長押し測量停止と平均化処理
  Future<void> stopLongPressGpsSurvey() async {
    try {
      final currentTool = ref.read(currentToolProvider);
      if (currentTool is! GpsTool) {
        AppLogger.debug('[MapGpsSurveyMixin] GPS長押し測量停止: 現在のツールがGpsToolではありません');
        return;
      }
      
      AppLogger.debug('[MapGpsSurveyMixin] GPS長押し測量停止 - 平均化処理開始');
      final success = await currentTool.stopLongPressGpsSurvey();
      
      if (!success) {
        throw Exception(t.gps.insufficientData);
      }
      
      triggerSetState(() {
        isLongPressing = false;
        longPressGpsCount = 0;
      });
      
      // 長押しカウンタータイマーを停止
      longPressCountUpdateTimer?.cancel();
      longPressCountUpdateTimer = null;
      
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.gps.longPressSurveyDone,
          level: NotificationLevel.success,
        );
      }
    } catch (e) {
      AppLogger.debug('[MapGpsSurveyMixin] GPS長押し測量停止エラー: $e');
      longPressCountUpdateTimer?.cancel();
      longPressCountUpdateTimer = null;
      triggerSetState(() {
        isLongPressing = false;
        longPressGpsCount = 0;
      });
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.gps.longPressSurveyStopError(error: '$e'),
          level: NotificationLevel.error,
        );
      }
    }
  }
  
  // =============================================
  // GPS測量確定処理
  // =============================================
  
  /// GPS測量確定処理
  Future<void> onConfirmGpsSurvey() async {
    try {
      final currentTool = ref.read(currentToolProvider);
      if (currentTool is! GpsTool) return;
      
      final selected = ref.read(selectedLayerNodeProvider);
      if (selected == null) return;
      
      // 属性入力ダイアログを表示
      final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) {
          String name = '';
          String description = '';
          return AlertDialog(
            title: Text(t.gps.surveyAttributeInput),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  decoration: InputDecoration(labelText: t.gps.nameLabel),
                  onChanged: (v) => name = v,
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: InputDecoration(labelText: t.gps.descriptionLabel),
                  maxLines: 3,
                  onChanged: (v) => description = v,
                ),
                const SizedBox(height: 12),
                Text(
                  t.gps.surveyDataInfo(count: '${GlobalDrawingState.instance.drawingLine.length + GlobalDrawingState.instance.drawingPolygon.length}'),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: Text(t.common.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, {
                  'name': name,
                  'description': description,
                }),
                child: Text(t.gps.create),
              ),
            ],
          );
        },
      );
      
      if (result == null) return;
      
      // GlobalDrawingStateの統一確定処理を使用
      final drawingState = GlobalDrawingState.instance;
      
      // GPS測量データを追加メタデータとして準備
      final surveyGpsData = drawingState.isLineDrawing
          ? drawingState.getLineWithMetadata()
          : drawingState.getPolygonWithMetadata();
      final additionalMetadata = {
        'type': 'measurement_log',
        'contents': List<Map<String, dynamic>>.from(
          surveyGpsData.map(Map<String, dynamic>.from),
        ),
      };
      
      final success = await drawingState.confirmCurrentFeature(
        layerNode: selected,
        name: result['name']?.isNotEmpty == true ? result['name']! : t.gps.defaultFeatureName,
        description: result['description'] ?? '',
        closeRing: closeRing,
        additionalMetadata: additionalMetadata,
        refreshCallback: refreshMapUI,
      );
      
      // GPS測量成功時はGPS停止
      if (success) {
        await gpsManager.stopGpsSurvey();
        await updateFeatures();
        
        if (mounted) {
          ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.surveyFeatureCreated,
            level: NotificationLevel.success,
          );
        }
      } else {
        if (mounted) {
          ref.read(notificationCenterProvider.notifier).add(
            title: t.gps.surveyFeatureCreateFailed,
            level: NotificationLevel.error,
          );
        }
      }
    } catch (e) {
      AppLogger.debug('[MapGpsSurveyMixin] GPS測量確定エラー: $e');
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: t.gps.surveyConfirmError(error: '$e'),
          level: NotificationLevel.error,
        );
      }
    }
  }
  
  // =============================================
  // 抽象メソッド（サブクラスで実装）
  // =============================================
  
  /// フィーチャデータを更新
  Future<void> updateFeatures();
  
  /// マップUIを更新
  void refreshMapUI();
}

