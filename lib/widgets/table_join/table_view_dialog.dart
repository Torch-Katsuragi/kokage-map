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
// 表（森林簿 CSV）を見るだけの画面。形が無いので地図とはつながらない

import 'package:flutter/material.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../i18n/strings.g.dart';
import '../../models/nodes/table_node.dart';
import '../../services/table/csv_table.dart';

/// [node] の中身を表で見せる（読み取り専用。列の見出しで並べ替え）
Future<void> showTableViewDialog(BuildContext context, TableNode node) async {
  final table = await node.load();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 900,
        height: 640,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.table_chart_outlined, color: Colors.brown),
              title: Text(node.name),
              subtitle: table == null
                  ? null
                  : Text(t.tableJoin.rows(count: table.rows.length, encoding: table.encoding)),
              trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
            ),
            const Divider(height: 1),
            Expanded(
              child: table == null
                  ? Center(child: Text(t.tableJoin.readError))
                  : _TableGrid(table: table),
            ),
          ],
        ),
      ),
    ),
  );
}

class _TableGrid extends StatelessWidget {
  const _TableGrid({required this.table});
  final CsvTable table;

  @override
  Widget build(BuildContext context) {
    final columns = [
      for (final (i, f) in table.fields.indexed)
        TrinaColumn(
          title: f.name,
          field: 'c$i',
          type: switch (f.type) {
            TableFieldType.integer => TrinaColumnType.number(),
            TableFieldType.real => TrinaColumnType.number(format: '#,##0.######'),
            TableFieldType.text => TrinaColumnType.text(),
          },
          readOnly: true,
          enableEditingMode: false,
          width: 110,
        ),
    ];
    final rows = [
      for (final r in table.rows)
        TrinaRow(cells: {for (final (i, v) in r.indexed) 'c$i': TrinaCell(value: v ?? '')}),
    ];
    return TrinaGrid(
      columns: columns,
      rows: rows,
      mode: TrinaGridMode.readOnly,
      configuration: const TrinaGridConfiguration(),
    );
  }
}
