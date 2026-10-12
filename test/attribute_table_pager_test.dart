// 属性テーブルのページ送り: 縦向きのスマホの幅（約 412 dp）ではみ出さない
// （以前は TrinaLazyPagination の既定の見た目で、右端が 76 px はみ出していた）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/widgets/attribute_table/attribute_table_pager.dart';

void main() {
  Future<void> pump(WidgetTester tester, double width, {int page = 12, int totalPage = 124}) async {
    await tester.binding.setSurfaceSize(Size(width, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: AttributeTablePager(
              page: page,
              totalPage: totalPage,
              totalRecords: 12345,
              pageSize: 100,
              pageSizes: const [50, 100, 200, 500],
              onPage: (_) {},
              onPageSize: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('412 dp ではみ出さず、先頭へ・末尾へも出る', (tester) async {
    await pump(tester, 412);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.first_page), findsOneWidget);
    expect(find.byIcon(Icons.last_page), findsOneWidget);
    expect(find.text('12 / 124 [12345]'), findsOneWidget);
  });

  testWidgets('狭い幅では先頭へ・末尾へと件数を畳む（はみ出さない）', (tester) async {
    for (final w in [330.0, 270.0]) {
      await pump(tester, w);
      expect(tester.takeException(), isNull, reason: '幅 $w');
      expect(find.byIcon(Icons.first_page), findsNothing);
      expect(find.byIcon(Icons.navigate_next), findsOneWidget);
    }
  });

  testWidgets('先頭のページでは戻れず、次へは押せる', (tester) async {
    final pages = <int>[];
    await tester.binding.setSurfaceSize(const Size(412, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttributeTablePager(
            page: 1,
            totalPage: 3,
            totalRecords: 250,
            pageSize: 100,
            pageSizes: const [50, 100],
            onPage: pages.add,
            onPageSize: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.navigate_before));
    await tester.tap(find.byIcon(Icons.navigate_next));
    await tester.tap(find.byIcon(Icons.last_page));
    expect(pages, [2, 3]);
  });
}
