// 地図が背の低い帯になっても（属性表とキーボードで押し縮められる）道具列がはみ出さない
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/widgets/map_toolbar.dart';

void main() {
  testWidgets('高さ 120 の地図でもはみ出さない', (tester) async {
    await LocaleSettings.setLocale(AppLocale.ja);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              height: 120,
              child: Stack(children: [MapToolbar(onToolChanged: () {})]),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
