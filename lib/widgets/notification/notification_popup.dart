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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';

/// 通知ドロップダウン一覧
class NotificationPopup extends StatelessWidget {
  final VoidCallback onDismiss;
  final WidgetRef ref;

  const NotificationPopup({
    super.key,
    required this.onDismiss,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    final notifications = ref.watch(notificationCenterProvider);
    final theme = Theme.of(context);

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 360,
        constraints: const BoxConstraints(maxHeight: 480),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, notifications),
            const Divider(height: 1),
            if (notifications.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  t.notification.empty,
                  style: const TextStyle(color: Colors.grey),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: notifications.length,
                  separatorBuilder:
                      (_, _) =>
                          const Divider(height: 1, indent: 12, endIndent: 12),
                  itemBuilder:
                      (context, index) => _NotificationPanel(
                        notification: notifications[index],
                        onMarkAsRead:
                            () => ref
                                .read(notificationCenterProvider.notifier)
                                .markAsRead(notifications[index].id),
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    List<AppNotification> notifications,
  ) {
    final unread = notifications.where((n) => !n.isRead).length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Text(
            t.notification.title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (unread > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$unread',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ],
          const Spacer(),
          if (unread > 0)
            TextButton(
              onPressed:
                  () =>
                      ref
                          .read(notificationCenterProvider.notifier)
                          .markAllAsRead(),
              child: Text(
                t.notification.markAllRead,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (notifications.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: t.notification.clearAll,
              onPressed: () {
                ref.read(notificationCenterProvider.notifier).clear();
                onDismiss();
              },
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

/// 個別通知パネル（展開可能）
class _NotificationPanel extends StatefulWidget {
  final AppNotification notification;
  final VoidCallback onMarkAsRead;

  const _NotificationPanel({
    required this.notification,
    required this.onMarkAsRead,
  });

  @override
  State<_NotificationPanel> createState() => _NotificationPanelState();
}

class _NotificationPanelState extends State<_NotificationPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    return InkWell(
      onTap:
          n.isExpandable
              ? () {
                setState(() => _expanded = !_expanded);
                if (!n.isRead) widget.onMarkAsRead();
              }
              : () {
                if (!n.isRead) widget.onMarkAsRead();
              },
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: n.isRead ? Colors.transparent : n.level.color,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(n.level.icon, color: n.level.color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    n.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          n.isRead ? FontWeight.normal : FontWeight.w600,
                    ),
                    maxLines: _expanded ? null : 1,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                  ),
                ),
                if (n.isExpandable)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Colors.grey,
                  ),
              ],
            ),
            // タイムスタンプ
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(
                _formatTime(n.timestamp),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            // 展開時の詳細
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.only(left: 26, top: 6),
                child: Text(
                  n.detail ?? '',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              crossFadeState:
                  _expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return t.notification.justNow;
    if (diff.inMinutes < 60) return t.notification.minutesAgo(n: diff.inMinutes);
    if (diff.inHours < 24) return t.notification.hoursAgo(n: diff.inHours);
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
