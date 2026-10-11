// 表（森林簿 CSV）を見る画面の格子: 空の数値のマスを 0 と見せない
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/services/table/csv_table.dart';
import 'package:root_maps/widgets/table_join/table_view_dialog.dart';

void main() {
  testWidgets('空の数値のマスは空のまま（0 にしない）。値のあるマスは数で見せる', (tester) async {
    final table = CsvTable.parse(Uint8List.fromList(utf8.encode('林小班,林齢,材積\n12-1,,\n12-2,35,120.5\n')));
    expect(table.fields.map((f) => f.type), [TableFieldType.text, TableFieldType.integer, TableFieldType.real]);
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CsvTableGrid(table: table))));
    await tester.pumpAndSettle();

    expect(find.text('35'), findsOneWidget);
    expect(find.text('120.5'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });
}
