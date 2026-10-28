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

/// 通知の重要度レベル
enum NotificationLevel {
  info(Icons.info_outline, Colors.blue),
  success(Icons.check_circle_outline, Colors.green),
  warning(Icons.warning_amber_rounded, Colors.orange),
  error(Icons.error_outline, Colors.red);

  final IconData icon;
  final Color color;
  const NotificationLevel(this.icon, this.color);
}

/// アプリ内通知データ
class AppNotification {
  final String id;
  final String title;
  final String? detail;
  final NotificationLevel level;
  final DateTime timestamp;
  bool isRead;

  /// 通知から押せる操作（例: 衝突をクラウドの値に戻す）。一度だけ押せる
  final String? actionLabel;
  final Future<void> Function()? onAction;
  bool actionDone = false;

  /// バックグラウンド転送と紐づけるキー（[DriveTransferRegistry.normalizeKey] の値）。
  /// 転送中は [DriveTransferRegistry.progressOf] を購読してライブ進捗バーを描画し、
  /// 完了時に同じ枠を完了通知へ差し替える。
  final String? transferKey;

  AppNotification({
    required this.id,
    required this.title,
    this.detail,
    this.level = NotificationLevel.info,
    DateTime? timestamp,
    this.isRead = false,
    this.actionLabel,
    this.onAction,
    this.transferKey,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isExpandable => detail != null && detail!.isNotEmpty;
}
