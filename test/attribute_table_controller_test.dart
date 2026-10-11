// 属性表: 「表をコピー」は今のフィルタ・並べ替えの全件、ページの大きさの選択が効く、
// 読み直してもフィルタの表示（ツールバー）が「適用中」のまま
//
// 実物の GeoPackage を使う（view_hide_reload_test.dart と同じ作り）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/widgets/attribute_table/attribute_table_controller.dart';
import 'package:root_maps/widgets/attribute_table/attribute_table_toolbar.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trina_grid/trina_grid.dart';

const _count = 250;

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  late PointLayerNode layer;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> open() async {
    tmp = await Directory.systemTemp.createTemp('attr_table_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    await gpkg.addLayer('pts', GeometryType.point);
    await gpkg.addAttributeColumns('pts', {'name': 'TEXT', 'h': 'REAL'});
    final db = await gpkg.getDatabase();
    final batch = db.batch();
    // h は 0..249 を逆順に入れる（読んだ順と h の昇順が逆になる）
    for (var i = 0; i < _count; i++) {
      batch.insert('pts', {
        'geom': _gpkgPoint(139.76 + i * 0.0001, 35.68),
        'name': 'p$i',
        'h': (_count - 1 - i).toDouble(),
      });
    }
    await batch.commit(noResult: true);
    layer = PointLayerNode(gpkg, 'pts', parent: GeoPackageNode(gpkg));
    await layer.updateChildren();
  }

  Future<void> close() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }

  /// コントローラを作る（WidgetRef が要るので画面に置く）。[child] はそのコントローラで組む画面
  Future<AttributeTableController> pumpController(
    WidgetTester tester, {
    Widget Function(AttributeTableController c)? child,
  }) async {
    AttributeTableController? ctrl;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            ctrl ??= AttributeTableController(layer, ref);
            return child?.call(ctrl!) ?? const SizedBox();
          }),
        ),
      ),
    ));
    return ctrl!;
  }

  List<String> dataLines(String tsv) =>
      tsv.trim().split('\n').skip(1).toList();

  testWidgets('表をコピー: 1 ページ目だけでなく全件。フィルタで絞れば絞った件数', (tester) async {
    await tester.runAsync(open);
    addTearDown(() => tester.runAsync(close));
    final ctrl = await pumpController(tester);
    await tester.runAsync(ctrl.initialize);

    final all = (await tester.runAsync(() => ctrl.buildTableTsv(chunkSize: 30)))!;
    expect(dataLines(all), hasLength(_count));
    expect(all.split('\n').first.split('\t'), containsAll(['#', 'name', 'h']));

    await tester.runAsync(() => ctrl.applyFilter('"h" < 10'));
    final filtered = (await tester.runAsync(ctrl.buildTableTsv))!;
    expect(dataLines(filtered), hasLength(10));
  });

  testWidgets('表をコピー: 見出しで並べ替えた順（ページをまたいで全件）。隠した列は書かない', (tester) async {
    await tester.runAsync(open);
    addTearDown(() => tester.runAsync(close));
    final ctrl = await pumpController(tester);
    await tester.runAsync(ctrl.initialize);

    final hCol = ctrl.columns.firstWhere((c) => c.field == 'h')..sort = TrinaColumnSort.ascending;
    final page = await ctrl.fetchPage(TrinaLazyPaginationRequest(page: 1, pageSize: 50, sortColumn: hCol));
    // 1 ページ目に全件のうち h の小さい 50 件が来る
    expect(page.rows.map((r) => r.cells['h']!.value), [for (var i = 0; i < 50; i++) i.toDouble()]);

    ctrl.toggleColumnVisibility('name');
    final tsv = (await tester.runAsync(ctrl.buildTableTsv))!;
    final header = tsv.split('\n').first.split('\t');
    expect(header, isNot(contains('name')));
    final hIdx = header.indexOf('h');
    final hs = [for (final l in dataLines(tsv)) double.parse(l.split('\t')[hIdx])];
    expect(hs, [for (var i = 0; i < _count; i++) i.toDouble()]);
  });

  testWidgets('メタデータの列（kmaps_metadata）は表に出さない', (tester) async {
    await tester.runAsync(() async {
      await open();
      await gpkg.addAttributeColumns('pts', {'kmaps_metadata': 'TEXT'});
    });
    addTearDown(() => tester.runAsync(close));
    final ctrl = await pumpController(tester);
    await tester.runAsync(ctrl.initialize);
    expect(ctrl.columnNames, ['name', 'h']);
  });

  testWidgets('ページの大きさ: 選んだ行数で切り、総ページ数もそれで数える', (tester) async {
    await tester.runAsync(open);
    addTearDown(() => tester.runAsync(close));
    final ctrl = await pumpController(tester);
    await tester.runAsync(ctrl.initialize);

    final p50 = await ctrl.fetchPage(TrinaLazyPaginationRequest(page: 5, pageSize: 50));
    expect(p50.rows, hasLength(50));
    expect(p50.totalPage, 5);
    expect(p50.totalRecords, _count);
    expect(p50.rows.first.cells['_row_num']!.value, 201);
    expect(ctrl.pageSize, 50);

    final p200 = await ctrl.fetchPage(TrinaLazyPaginationRequest(page: 2, pageSize: 200));
    expect(p200.rows, hasLength(50));
    expect(p200.totalPage, 2);
  });

  testWidgets('読み直してもフィルタは効いたまま、ツールバーも「適用中」で式も入ったまま', (tester) async {
    await tester.runAsync(open);
    addTearDown(() => tester.runAsync(close));
    final ready = ValueNotifier(false);
    final ctrl = await pumpController(
      tester,
      child: (c) => ValueListenableBuilder(
        valueListenable: ready,
        // 読み込み中はツールバーを出さない（属性表と同じ。読み直すとツールバーは作り直しになる）
        builder: (_, r, _) => r ? AttributeTableToolbar(controller: c) : const SizedBox(),
      ),
    );
    await tester.runAsync(ctrl.initialize);
    await tester.runAsync(() => ctrl.applyFilter('"h" < 10'));
    ready.value = true;
    await tester.pump();

    // 読み直す（属性表の「再読込」と同じ）
    ready.value = false;
    await tester.pump();
    await tester.runAsync(ctrl.initialize);
    ready.value = true;
    await tester.pump();

    expect(ctrl.isFiltered, isTrue);
    expect(ctrl.filteredCount, 10);
    final filterIcon = tester.widget<Icon>(find.byIcon(Icons.filter_alt).first);
    expect(filterIcon.color, Colors.orange);
    expect(find.text('"h" < 10'), findsOneWidget);
  });

  testWidgets('読み直しで作り直したコントローラにもフィルタとページの大きさを引き継ぐ', (tester) async {
    await tester.runAsync(open);
    addTearDown(() => tester.runAsync(close));
    final ctrl = await pumpController(tester);
    await tester.runAsync(ctrl.initialize);
    await tester.runAsync(() => ctrl.applyFilter('"h" >= 200'));
    ctrl.setPageSize(200);

    late AttributeTableController next;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(builder: (context, ref, _) {
        next = AttributeTableController(layer, ref)..inheritFrom(ctrl);
        return const SizedBox();
      }),
    ));
    await tester.runAsync(next.initialize);
    expect(next.isFiltered, isTrue);
    expect(next.filterExpression, '"h" >= 200');
    expect(next.filteredCount, 50);
    expect(next.pageSize, 200);
  });
}

Uint8List _gpkgPoint(double lon, double lat) {
  final b = BytesBuilder();
  b.add([0x47, 0x50, 0x00, 0x01]); // magic 'GP', version 0, flags: LE, no envelope
  b.add((ByteData(4)..setInt32(0, 4326, Endian.little)).buffer.asUint8List());
  b.add([1]); // WKB byte order LE
  b.add((ByteData(4)..setUint32(0, 1, Endian.little)).buffer.asUint8List()); // Point
  b.add((ByteData(8)..setFloat64(0, lon, Endian.little)).buffer.asUint8List());
  b.add((ByteData(8)..setFloat64(0, lat, Endian.little)).buffer.asUint8List());
  return b.toBytes();
}
