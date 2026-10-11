// 使い方ガイド（assets/user_guide/{ja,en}.md）の検査。
// - `:icon-xxx:` が icon_markdown.dart に登録済みであること（未登録は画面で赤い文字のまま出るだけで気づきにくい）
// - 日本語版と英語版の見出しの数が揃っていること（片方だけ節を足した・消したのに気づく）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/widgets/icon_markdown.dart';

const _langs = ['ja', 'en'];

String _guide(String lang) => File('assets/user_guide/$lang.md').readAsStringSync();

void main() {
  for (final lang in _langs) {
    testWidgets('$lang.md のアイコンはすべて登録済み', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(
              data: _guide(lang),
              inlineSyntaxes: [IconInlineSyntax()],
              builders: {'flutterIcon': IconMarkdownBuilder()},
            ),
          ),
        ),
      ));
      expect(find.byType(Icon), findsWidgets);
      expect(find.textContaining(':icon-'), findsNothing, reason: '$lang.md に未登録のアイコン名がある');
    });
  }

  test('日本語版と英語版の見出しの数が同じ', () {
    List<int> levels(String lang) => _guide(lang)
        .split('\n')
        .where((l) => RegExp(r'^#{1,4} ').hasMatch(l))
        .map((l) => l.indexOf(' '))
        .toList();
    expect(levels('en'), levels('ja'));
  });
}
