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
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import 'notification_popup.dart';

/// AppBar用通知ベルアイコン（バッジ + 自動ポップアップ付き）
class NotificationBell extends ConsumerStatefulWidget {
  const NotificationBell({super.key});

  @override
  ConsumerState<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends ConsumerState<NotificationBell> {
  final _bellKey = GlobalKey();
  OverlayEntry? _popupEntry;
  OverlayEntry? _toastEntry;
  Timer? _toastTimer;
  int _prevCount = 0;

  @override
  void dispose() {
    _removePopup();
    _removeToast();
    super.dispose();
  }

  // ===== ドロップダウンポップアップ =====

  void _togglePopup() {
    if (_popupEntry != null) {
      _removePopup();
    } else {
      _showPopup();
    }
  }

  /// ベルアイコンの下端Y座標をOverlay座標系で取得
  double? _anchorBottomY() {
    final box = _bellKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return null;
    final globalBottom = box.localToGlobal(Offset(0, box.size.height));
    return overlayBox.globalToLocal(globalBottom).dy;
  }

  void _showPopup() {
    _removeToast();
    final overlay = Overlay.of(context);
    final bottomY = _anchorBottomY();
    if (bottomY == null) return;

    _popupEntry = OverlayEntry(
      builder:
          (_) => _PopupOverlay(
            anchorBottomY: bottomY,
            onDismiss: _removePopup,
            ref: ref,
          ),
    );
    overlay.insert(_popupEntry!);
  }

  void _removePopup() {
    _popupEntry?.remove();
    _popupEntry = null;
  }

  // ===== 自動トースト =====

  void _showAutoToast(AppNotification notification) {
    _removeToast();
    final overlay = Overlay.of(context);
    final bottomY = _anchorBottomY();
    if (bottomY == null) return;

    _toastEntry = OverlayEntry(
      builder:
          (_) => _NotificationToast(
            notification: notification,
            anchorBottomY: bottomY,
            onTap: () {
              _removeToast();
              _showPopup();
            },
            onDismiss: _removeToast,
          ),
    );
    overlay.insert(_toastEntry!);

    _toastTimer = Timer(const Duration(seconds: 3), _removeToast);
  }

  void _removeToast() {
    _toastTimer?.cancel();
    _toastTimer = null;
    _toastEntry?.remove();
    _toastEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount = ref.watch(unreadNotificationCountProvider);
    final notifications = ref.watch(notificationCenterProvider);

    // 通知追加を検知して自動トースト
    if (notifications.isNotEmpty && notifications.length > _prevCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_popupEntry == null && mounted) {
          _showAutoToast(notifications.first);
        }
      });
    }
    _prevCount = notifications.length;

    return IconButton(
      key: _bellKey,
      icon: Badge(
        isLabelVisible: unreadCount > 0,
        label: Text(
          unreadCount > 99 ? '99+' : '$unreadCount',
          style: const TextStyle(fontSize: 10),
        ),
        child: const Icon(Icons.notifications_outlined),
      ),
      tooltip: t.notification.title,
      onPressed: _togglePopup,
    );
  }
}

/// ポップアップ全体（背景タップで閉じる + 通知リスト）
class _PopupOverlay extends StatelessWidget {
  final double anchorBottomY;
  final VoidCallback onDismiss;
  final WidgetRef ref;

  const _PopupOverlay({
    required this.anchorBottomY,
    required this.onDismiss,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GestureDetector(
          onTap: onDismiss,
          behavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
        Positioned(
          top: anchorBottomY + 4,
          right: 8,
          child: NotificationPopup(onDismiss: onDismiss, ref: ref),
        ),
      ],
    );
  }
}

/// 自動ポップアップ（1件分のトースト）
class _NotificationToast extends StatefulWidget {
  final AppNotification notification;
  final double anchorBottomY;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  const _NotificationToast({
    required this.notification,
    required this.anchorBottomY,
    required this.onTap,
    required this.onDismiss,
  });

  @override
  State<_NotificationToast> createState() => _NotificationToastState();
}

class _NotificationToastState extends State<_NotificationToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween(
      begin: const Offset(0, -0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    return Stack(
      children: [
        GestureDetector(
          onTap: widget.onDismiss,
          behavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
        Positioned(
          top: widget.anchorBottomY + 4,
          right: 8,
          child: SlideTransition(
            position: _slide,
            child: FadeTransition(
              opacity: _opacity,
              child: GestureDetector(
                onTap: widget.onTap,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 300,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border(
                        left: BorderSide(color: n.level.color, width: 4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(n.level.icon, color: n.level.color, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            n.title,
                            style: const TextStyle(fontSize: 13),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
