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
// こかげマップ: `.qgs` を読み戻した結果を通知センターに出す
//
// 開いたとき・クローンしたあと・同期で落としたあとで同じ文面を出す。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../providers/notification_providers.dart';
import 'qgs_read_back.dart';

/// [r] を通知センターに出す（取り込んだ View・足した背景地図・取り込めなかったもの）
void notifyQgsReadBack(WidgetRef ref, QgsReadBackResult r) {
  final notifier = ref.read(notificationCenterProvider.notifier);
  notifier.add(
    title: t.qgis.readBack(file: r.fileName, count: r.importedViewCount),
    level: NotificationLevel.info,
  );
  if (r.baseMapsAdded.isNotEmpty) {
    notifier.add(
      title: t.qgis.baseMapsAdded(names: r.baseMapsAdded.join(' / ')),
      level: NotificationLevel.info,
    );
  }
  if (r.discarded.isNotEmpty) {
    notifier.add(
      title: t.qgis.discarded(count: r.discarded.length, names: r.discarded.join(' / ')),
      level: NotificationLevel.warning,
    );
  }
}
