// 「地図を PDF に」: 作っている途中の「戻る」は取りやめ。通知センターに知らせ、残りのタイルは読まず、
// 出来上がりを捨てる（保存先を聞かない）
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/widgets/map_pdf_dialog.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.ja));

  Future<ProviderContainer> pumpDialog(WidgetTester tester, MapPdfBuilder build) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMapPdfDialog(context, defaultTitle: 't', build: build),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('作っている途中の戻るは取りやめ: 閉じて通知、残りのタイルは読まない', (tester) async {
    final gate = Completer<void>();
    var tilesAfterCancel = 0;
    Object? buildError;
    final container = await pumpDialog(tester, (o, onProgress) async {
      onProgress(0.1);
      await gate.future;
      // 取りやめたあとのタイルの知らせは投げて止める
      try {
        onProgress(0.2);
        tilesAfterCancel++;
      } catch (e) {
        buildError = e;
        rethrow;
      }
      return Uint8List(0);
    });

    await tester.tap(find.text(t.mapPdf.create));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // Android の戻る
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final notes = container.read(notificationCenterProvider);
    expect(notes.map((n) => n.title), [t.mapPdf.cancelled]);

    gate.complete();
    await tester.pumpAndSettle();
    expect(tilesAfterCancel, 0);
    expect(buildError, isNotNull);
    // 失敗の通知は出さない
    expect(container.read(notificationCenterProvider), hasLength(1));
  });

  testWidgets('作っていないときの戻るはそのまま閉じる（通知なし）', (tester) async {
    final container = await pumpDialog(tester, (o, onProgress) async => Uint8List(0));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(container.read(notificationCenterProvider), isEmpty);
  });
}
