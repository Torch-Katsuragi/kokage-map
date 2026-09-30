// 更新履歴の図解（assets/changelog/svg/<版>.<言語>.svg、tool/changelog/build.py が Typst から書き出す）が、
// その言語の md の版の見出しと対応していること。名前を間違えると黙って md で出るだけなので、ここで気づく
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
  testWidgets('図解のある版は図を出し、文章は「文章で読む」を開くと出る。図の無い版は md のまま', (tester) async {
    await LocaleSettings.setLocale(AppLocale.ja);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1080, 2424);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: ChangelogScreen()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsOneWidget);
    final toggle = find.text('文章で読む');
    expect(toggle, findsOneWidget);
    // 畳んである間は、次のリリースの本文は出ない
    const line = 'サブフォルダの中の GeoPackage を改名すると';
    expect(find.textContaining(line, findRichText: true), findsNothing);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.textContaining(line, findRichText: true), findsOneWidget);
    // 図の無い版（v0.7.3 等）は md の見出しがそのまま出る
    await tester.scrollUntilVisible(
      find.textContaining(RegExp(r'^v0\.7\.3'), findRichText: true),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });

  test('見出しから版を取る', () {
    expect(ChangelogService.figureSlug('次のリリース'), 'next');
    expect(ChangelogService.figureSlug('Next release'), 'next');
    expect(ChangelogService.figureSlug('v0.7.4 (2026-10-01)'), 'v0.7.4');
    expect(ChangelogService.figureSlug('更新履歴'), isNull);
  });

  test('図解はどれも、同じ言語の md に対応する版の見出しがある', () {
    final svgs = Directory('assets/changelog/svg').listSync().whereType<File>().where((f) => f.path.endsWith('.svg'));
    expect(svgs, isNotEmpty);
    for (final svg in svgs) {
      final parts = p.basenameWithoutExtension(svg.path).split('.');
      final lang = parts.last;
      final slug = parts.sublist(0, parts.length - 1).join('.');
      final headings = File('assets/changelog/$lang.md')
          .readAsLinesSync()
          .where((l) => l.startsWith('## '))
          .map((l) => ChangelogService.figureSlug(l.substring(3)));
      expect(headings, contains(slug), reason: '${p.basename(svg.path)} に対応する見出しが $lang.md に無い');
      // Typst の出力（文字は形で焼き込み。端末にフォントが無くても同じに見える）
      expect(svg.readAsStringSync(), contains('class="typst-doc"'));
    }
  });
}
