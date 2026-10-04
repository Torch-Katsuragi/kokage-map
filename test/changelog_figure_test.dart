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
        // 地を塗らない（アプリの画面の地がそのまま見えて、継ぎ目が出ない）。Typst はページの地を
        // svg 直下の最初の図形として書く
        expect(svg.readAsStringSync(), isNot(matches(RegExp(r'^<svg[^>]*>\s*<path class="typst-shape" fill='))));
      }
    }
  });

  testWidgets('全部の版を図の切れで並べる（文章は読み上げ用）', (tester) async {
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
    // いちばん新しい版（開いている）の 1 行。版を足したら差し替える
    const line = '使い方ガイドとチュートリアルの「自分のデータで」';
    expect(find.textContaining(line, findRichText: true), findsNothing);
    expect(find.bySemanticsLabel(RegExp(line)), findsOneWidget);
    // 版ごとに畳む。開いているのはいちばん新しい版だけ
    final oldest = find.text('v0.3.0 — 2026/03/09');
    await tester.scrollUntilVisible(oldest, 600, scrollable: find.byType(Scrollable).first);
    final before = find.byType(SvgPicture).evaluate().length;
    // 古い版の見出しを押すと開き、図の切れが続く（見出しが画面の端に半分だけ出ていると押し外す）
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(oldest);
    await tester.pumpAndSettle();
    // 図の一覧（json）と切れの読み込みを待つ（版が増えるほど読む量が増える）
    for (var i = 0; i < 5 && find.byType(SvgPicture).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await tester.pumpAndSettle();
    }
    // 開いた版の図は見出しの下に続く（画面の外なら組まれないので、少し送ってから数える）
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture).evaluate().length, greaterThan(before));
    expect(find.text('地図の描画を爆速に'), findsOneWidget, reason: '見出しに版の一言');
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
