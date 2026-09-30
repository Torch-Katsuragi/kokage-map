// 更新履歴の図解（tool/changelog/build.py が Typst から書き出す、切れごとの SVG と一覧 json）。
// 一覧の名前がその言語の md の版の見出しと合っていること（間違えると黙って md で出るだけなので、ここで気づく）と、
// 画面で図の版は切れを継ぎ目なく並べ、図の無い版は md のまま出すこと
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/screens/changelog_screen.dart';
import 'package:root_maps/services/changelog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('見出しから版を取る', () {
    expect(ChangelogService.figureSlug('次のリリース'), 'next');
    expect(ChangelogService.figureSlug('Next release'), 'next');
    expect(ChangelogService.figureSlug('v0.7.4 (2026-10-01)'), 'v0.7.4');
    expect(ChangelogService.figureSlug('更新履歴'), isNull);
  });

  test('図解の一覧はどれも、同じ言語の md に対応する版の見出しがあり、切れのファイルがそろっている', () {
    final indexes = Directory('assets/changelog/svg').listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    expect(indexes, isNotEmpty);
    for (final index in indexes) {
      final parts = p.basenameWithoutExtension(index.path).split('.');
      final lang = parts.last;
      final slug = parts.sublist(0, parts.length - 1).join('.');
      final headings = File('assets/changelog/$lang.md')
          .readAsLinesSync()
          .where((l) => l.startsWith('## '))
          .map((l) => ChangelogService.figureSlug(l.substring(3)));
      expect(headings, contains(slug), reason: '${p.basename(index.path)} に対応する見出しが $lang.md に無い');
      final json = jsonDecode(index.readAsStringSync()) as Map<String, dynamic>;
      final chunks = (json['chunks'] as List).cast<Map<String, dynamic>>();
      expect(chunks, isNotEmpty);
      for (final c in chunks) {
        final svg = File('assets/changelog/svg/${c['file']}');
        expect(svg.existsSync(), isTrue, reason: '${c['file']} が無い（build.py で書き直す）');
        // 地を塗らない（アプリの画面の地がそのまま見えて、継ぎ目が出ない）
        expect(svg.readAsStringSync(), isNot(contains('fill="#ffffff" fill-rule="nonzero" d="M 0 0v')));
      }
    }
  });

  testWidgets('図の版は切れを並べ（文章は読み上げ用）、図の無い版は md のまま', (tester) async {
    await LocaleSettings.setLocale(AppLocale.ja);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2424);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(const MaterialApp(home: ChangelogScreen()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsWidgets);
    // 図の版の本文は画面に文字として出さないが、読み上げでは読める
    const line = 'サブフォルダの中の GeoPackage を改名すると';
    expect(find.textContaining(line, findRichText: true), findsNothing);
    expect(find.bySemanticsLabel(RegExp(line)), findsOneWidget);
    // 図の無い版（v0.7.3 等）は md の見出しがそのまま出る
    await tester.scrollUntilVisible(
      find.textContaining(RegExp(r'^v0\.7\.3'), findRichText: true),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
