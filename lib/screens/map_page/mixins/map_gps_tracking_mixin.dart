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
// Root Maps: GPS軌跡抽出Mixin
// GPS軌跡は常時記録されており、このmixinは軌跡抽出ダイアログを開く機能のみ提供
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/app_notification.dart';
import '../../../providers/notification_providers.dart';
import '../../../widgets/track_extraction_dialog.dart';
import '../map_page_state_base.dart';

/// GPS軌跡抽出Mixin
/// GPS軌跡は GpsHistoryRecorder により常時記録されている。
/// このmixinは軌跡抽出ダイアログを開くインターフェースを提供する。
mixin MapGpsTrackingMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {

  /// 軌跡抽出ダイアログを開く
  Future<void> openTrackExtractionDialog() async {
    if (!gpsHistoryRecorder.isInitialized) {
      if (mounted) {
        ref.read(notificationCenterProvider.notifier).add(
          title: 'GPS履歴が初期化されていません',
          level: NotificationLevel.warning,
        );
      }
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => TrackExtractionDialog(
        recorder: gpsHistoryRecorder,
      ),
    );

    // ダイアログで保存された場合、フィーチャを更新
    if (result == true) {
      await updateFeatures();
      triggerSetState(() {});
    }
  }

  // =============================================
  // 抽象メソッド（サブクラスで実装）
  // =============================================

  /// フィーチャデータを更新
  Future<void> updateFeatures();
}
