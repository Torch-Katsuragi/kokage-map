// 属性テーブルのページ送り: 縦向きのスマホの幅（約 412 dp）ではみ出さない
// （以前は TrinaLazyPagination の既定の見た目で、右端が 76 px はみ出していた）
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/widgets/attribute_table/attribute_table_pager.dart';

void main() {
  Future<void> pump(WidgetTester tester, double width, {int page = 12, int totalPage = 124, int totalRecords = 12345}) async {
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
              totalRecords: totalRecords,
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
    // 総件数は左に出ているので、ページの横には繰り返さない
    expect(find.text('12 / 124'), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
  });

  // ページの表示が「…」に切れない（2026-10-12 に Pixel 9 で 1 件の表が「1 / …」と出た。
  // 両脇の Spacer と幅を三等分していたので、空きが少ないと文字が切れていた）
  testWidgets('ページ / 総ページは切れずに全部出る', (tester) async {
    bool fits(String s) {
      final p = tester.renderObject<RenderParagraph>(find.text(s));
      return p.size.width >= p.getMaxIntrinsicWidth(double.infinity) - 0.5;
    }

    for (final (w, one, many) in [
      (412.0, '1 / 1', '12 / 124'),
      (330.0, '1 / 1', '12 / 124'),
      // 左の件数を畳む幅では、総件数をページの横に添える
      (270.0, '1 / 1 [1]', '12 / 124 [12345]'),
    ]) {
      await pump(tester, w, page: 1, totalPage: 1, totalRecords: 1);
      expect(tester.takeException(), isNull, reason: '幅 $w');
      expect(find.text(one), findsOneWidget, reason: '幅 $w');
      // テストの字は 1 字が字の大きさと同じ幅で実機より広い。切れないかは 1 件の表（実機で切れた形）で見る
      if (w > 300) expect(fits(one), isTrue, reason: '幅 $w');
      await pump(tester, w);
      expect(find.text(many), findsOneWidget, reason: '幅 $w');
    }
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
