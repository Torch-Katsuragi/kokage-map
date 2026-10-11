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
// 表（座標の列が無い CSV。森林簿など）の行。押すと中身を見る。地図には描かないので目は無い

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/nodes/table_node.dart';
import '../../table_join/table_view_dialog.dart';
import '../common_dialogs.dart';
import '../drawer_row.dart';

class TableTile extends ConsumerWidget {
  const TableTile({super.key, required this.node, this.onSwipeMove});

  final TableNode node;
  final VoidCallback? onSwipeMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DrawerRow(
      leading: const Icon(Icons.table_chart_outlined, size: 20, color: Colors.brown),
      title: node.name,
      titleStyle: const TextStyle(fontSize: 16),
      onTap: () => showTableViewDialog(context, node),
      menu: () => [
        RowMenuItem('view', t.tableJoin.view, icon: Icons.table_rows_outlined),
        RowMenuItem('delete', t.common.delete, icon: Icons.delete_outline, danger: true, dividerBefore: true),
      ],
      onMenu: (value) async {
        switch (value) {
          case 'view':
            await showTableViewDialog(context, node);
          case 'delete':
            await confirmAndExecute(
              context,
              ref: ref,
              title: t.tableJoin.deleteTitle,
              content: Text(t.tableJoin.deleteConfirm(name: node.name)),
              confirmLabel: t.common.delete,
              confirmColor: Colors.red,
              successMessage: t.tableJoin.deleted(name: node.name),
              execute: () async {
                await node.dispose();
                ref.refreshMap();
              },
            );
        }
      },
      onSwipeMove: onSwipeMove,
    );
  }
}
