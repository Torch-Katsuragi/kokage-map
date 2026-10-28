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
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/app_notification.dart';

part 'notification_providers.g.dart';

const _maxNotifications = 100;

/// 通知の id の連番
var _seq = 0;

/// アプリ内通知の中央管理
@Riverpod(keepAlive: true)
class NotificationCenter extends _$NotificationCenter {
  @override
  List<AppNotification> build() => [];

  /// 通知を追加（先頭挿入、上限超過で末尾削除）
  void add({
    required String title,
    String? detail,
    NotificationLevel level = NotificationLevel.info,
    String? actionLabel,
    Future<void> Function()? onAction,
  }) {
    final notification = AppNotification(
      // 時刻だけだと同じ瞬間に 2 件足したとき（web は 1ms 刻み）に重なるので連番を添える
      id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      title: title,
      detail: detail,
      level: level,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    state = [notification, ...state.take(_maxNotifications - 1)];
  }

  /// 進行中の転送通知を開始（既存の同一 [transferKey] 通知があれば先頭に更新して差し替え）
  void startTransfer({
    required String transferKey,
    required String title,
    String? detail,
  }) {
    final notification = AppNotification(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      title: title,
      detail: detail,
      level: NotificationLevel.info,
      transferKey: transferKey,
    );
    final rest = state.where((n) => n.transferKey != transferKey);
    state = [notification, ...rest.take(_maxNotifications - 1)];
  }

  /// 進行中の転送通知を完了（成功/失敗）通知に切り替えて先頭に配置する（自動トーストも再発火）
  void completeTransfer({
    required String transferKey,
    required String title,
    String? detail,
    NotificationLevel level = NotificationLevel.success,
    String? actionLabel,
    Future<void> Function()? onAction,
  }) {
    final completed = AppNotification(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      title: title,
      detail: detail,
      level: level,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    final rest = state.where((n) => n.transferKey != transferKey);
    state = [completed, ...rest.take(_maxNotifications - 1)];
  }

  void markAsRead(String id) {
    final idx = state.indexWhere((n) => n.id == id);
    if (idx == -1) return;
    state[idx].isRead = true;
    state = [...state];
  }

  void markAllAsRead() {
    for (final n in state) {
      n.isRead = true;
    }
    state = [...state];
  }

  void clear() => state = [];
}

/// 未読通知数
@Riverpod(keepAlive: true)
int unreadNotificationCount(Ref ref) {
  final notifications = ref.watch(notificationCenterProvider);
  return notifications.where((n) => !n.isRead).length;
}
