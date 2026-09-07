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
// 地図画面のAppBarアクションボタン群
// 水準器（コンパス）と設定は AppBar の ≡ メニュー（MapMenuButton）へ移動した。
import 'package:flutter/material.dart';
import '../i18n/strings.g.dart';
import 'notification/notification_bell.dart';

/// 地図画面AppBarの右側アクションボタン群を生成する関数
List<Widget> buildMapAppBarActions({
  required BuildContext context,
  required bool showAttributeTable,
  required bool drawerOpen,
  required VoidCallback onAttributeTableToggle,
  required VoidCallback onDrawerToggle,
  /// レイヤ一覧ボタンの左に挟むもの（≡ メニューなど）。
  /// レイヤ一覧は一番よく押すので、親指に近い右端に置く
  List<Widget> beforeLayerButton = const [],
}) {
  return [
    const NotificationBell(),
    // 属性テーブルボタン
    IconButton(
      icon: Icon(
        Icons.table_view,
        color: showAttributeTable ? Colors.blue : null,
      ),
      tooltip: showAttributeTable ? t.attributeTable.closeTable : t.attributeTable.openTable,
      onPressed: onAttributeTableToggle,
    ),
    ...beforeLayerButton,
    // レイヤードロワーボタン（右端）
    IconButton(
      icon: Icon(Icons.layers, color: drawerOpen ? Colors.blue : null),
      tooltip: drawerOpen ? 'Close Layer Drawer' : 'Open Layer Drawer',
      onPressed: onDrawerToggle,
    ),
  ];
}
