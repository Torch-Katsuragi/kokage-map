// QGIS の描き分け（分類・段階・ルール）を読んで、地物ごとに QGIS と同じシンボルを選ぶか
//
// fixture は QGIS 4.2.2 に書かせたもの（tool/qgis/write_renderer_fixture.py）。
// `_expected.json` は QGIS 自身が地物ごとに選んだシンボル（色・当たったルールの key）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/qgis_renderer.dart';
import 'package:root_maps/services/qgis/qgs_importer.dart';
import 'package:root_maps/services/qgis/qgs_renderer_reader.dart';
import 'package:root_maps/utils/qgis_expression.dart';
import 'package:xml/xml.dart';

void main() {
  final doc = XmlDocument.parse(File('test/fixtures/qgis_4_2_renderers.qgs').readAsStringSync());
  final expected = jsonDecode(File('test/fixtures/qgis_4_2_renderers_expected.json').readAsStringSync())
      as Map<String, dynamic>;
  XmlElement maplayer(String name) => doc.rootElement
      .getElement('projectlayers')!
      .findElements('maplayer')
      .firstWhere((m) => m.getElement('layername')?.innerText == name);
  QgisRenderer renderer(String name) => QgsRendererReader.read(maplayer(name))!;
  String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  Color? colorOf(KMetaLayerStyle? s) => s?.polygonFillColor ?? s?.lineColor ?? s?.pointColor;

  group('読む', () {
    test('分類: 項目・その他の値・描かない項目', () {
      final r = renderer('樹種で分類');
      expect(r.kind, QgisRendererKind.categorized);
      expect(r.attr, '樹種');
      expect([for (final c in r.classes) c.label], ['スギ', 'ヒノキ', 'マツ', 'その他']);
      expect(r.classes[2].render, isFalse);
      expect(r.classes[3].isDefaultCategory, isTrue);
      expect(hex(r.classes[0].style!.polygonFillColor!), '#33a02c');
      // 輪郭 0.8mm → px
      expect(r.classes[1].style!.polygonBorderWidth, closeTo(0.8 * 96 / 25.4, 1e-6));
      // 色のアルファ 128 は塗りの不透明度
      expect(r.classes[3].style!.polygonFillOpacity, closeTo(128 / 255, 1e-6));
    });

    test('段階: 範囲と、塗り無し・輪郭無し', () {
      final r = renderer('林齢で段階');
      expect(r.kind, QgisRendererKind.graduated);
      expect(r.attr, '"林齢"');
      expect([for (final c in r.classes) (c.lower, c.upper)], [(0.0, 20.0), (20.0, 40.0), (40.0, 60.0), (60.0, 80.0)]);
      expect(r.classes[2].style!.polygonFillOpacity, 0, reason: 'style=no は塗らない');
      expect(r.classes[3].style!.polygonBorderOpacity, 0, reason: 'outline_style=no は輪郭を描かない');
    });

    test('ルール: 入れ子と ELSE', () {
      final r = renderer('ルールで');
      expect(r.kind, QgisRendererKind.rule);
      expect(r.rules, hasLength(5));
      expect(r.rules[1].children.single.filter, '"林齢" < 20');
      expect(r.rules.last.isElse, isTrue);
      expect([for (final c in r.classes) c.label], ['高齢スギ', 'ヒノキ・マツ', '若い', '不明', '葉', 'その他']);
    });

    test('点: シンボルの大きさ', () {
      final r = renderer('杭');
      expect(r.classes[1].style!.pointSize, closeTo(4 * 96 / 25.4 / 2, 1e-6));
    });

    test('JSON を往復しても同じ', () {
      for (final name in ['樹種で分類', '林齢で段階', 'ルールで', '林道', '杭']) {
        final r = renderer(name);
        final back = QgisRenderer.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
        expect(jsonEncode(back.toJson()), jsonEncode(r.toJson()), reason: name);
      }
    });

    test('インポータは印と中身を両方スタイルに入れ、フォルダ設定の JSON を往復する', () {
      final style = const QgsImporter().readStyle(maplayer('樹種で分類'))!;
      expect(style.qgisRenderer, 'categorizedSymbol');
      expect(style.qgisRendererDef!.classes, hasLength(4));
      final back = KMetaLayerStyle.fromJson(jsonDecode(jsonEncode(style.toJson())) as Map<String, dynamic>);
      expect(back.qgisRendererDef!.classes[1].label, 'ヒノキ');
      // 単一シンボルに戻されたら外す
      expect(back.withoutQgisRenderer().qgisRendererDef, isNull);
      expect(back.withoutQgisRenderer().qgisRenderer, isNull);
    });

    test('印を持つ子のスタイルは、親の中身を混ぜない', () {
      final parent = KMetaLayerStyle(qgisRenderer: 'RuleRenderer', qgisRendererDef: renderer('ルールで'));
      const child = KMetaLayerStyle(qgisRenderer: 'invertedPolygonRenderer');
      expect(child.mergeWith(parent).qgisRendererDef, isNull);
      expect(const KMetaLayerStyle(labelEnabled: true).mergeWith(parent).qgisRendererDef, isNotNull);
    });
  });

  group('QGIS と同じシンボルを選ぶ', () {
    for (final name in ['樹種で分類', '林齢で段階', '林道', '杭']) {
      test(name, () {
        final r = renderer(name);
        final eval = r.evaluator!;
        for (final row in expected[name] as List<dynamic>) {
          final attrs = (row as Map<String, dynamic>)['attrs'] as Map<String, dynamic>;
          final i = eval.classFor(attrs);
          final got = i == null ? null : hex(colorOf(r.classes[i].style)!);
          expect(got, row['color'], reason: '$attrs');
        }
      });
    }

    test('ルールで（いちばん上に描かれるルール）', () {
      final r = renderer('ルールで');
      // XML のルールを深さ優先の順に並べ、QGIS が当てた key のうち最後のものがいちばん上
      final ruleEls = maplayer('ルールで').findAllElements('rule').toList();
      for (final row in expected['ルールで'] as List<dynamic>) {
        final attrs = (row as Map<String, dynamic>)['attrs'] as Map<String, dynamic>;
        final keys = (row['keys'] as List<dynamic>).cast<String>().toSet();
        final top = ruleEls.lastWhere((e) => keys.contains(e.getAttribute('key'))).getAttribute('label');
        final i = r.evaluator!.classFor(attrs);
        expect(r.classes[i!].label, top, reason: '$attrs');
      }
    });
  });

  group('式', () {
    bool t(String expr, Map<String, Object?> props) => parseQgisExpression(expr).test(props);

    test('比較・論理・NULL', () {
      expect(t('"a" = 1 AND "b" <> \'x\'', {'a': 1, 'b': 'y'}), isTrue);
      expect(t('"a" >= 10', {'a': '9'}), isFalse, reason: '数として比べる');
      expect(t('"a" > 1', {'a': null}), isFalse, reason: 'NULL との比較は偽');
      expect(t('NOT ("a" > 1)', {'a': null}), isFalse, reason: 'NOT NULL も NULL（偽）');
      expect(t('"a" > 1 OR TRUE', {'a': null}), isTrue);
      expect(t('"a" IS NULL', {}), isTrue);
      expect(t('"a" IS NOT NULL', {'a': 0}), isTrue);
      expect(t('"a" != 2', {'a': 3}), isTrue);
    });

    test('IN・LIKE・BETWEEN・CASE・関数', () {
      expect(t('"s" IN (\'ヒノキ\', \'マツ\')', {'s': 'マツ'}), isTrue);
      expect(t('"s" NOT IN (\'ヒノキ\')', {'s': 'マツ'}), isTrue);
      expect(t('"s" LIKE \'%葉%\'', {'s': '広葉樹'}), isTrue);
      expect(t('"s" LIKE \'a_c\'', {'s': 'abc'}), isTrue);
      expect(t('"s" ILIKE \'SUGI%\'', {'s': 'sugi1'}), isTrue);
      expect(t('"s" NOT LIKE \'%葉%\'', {'s': 'スギ'}), isTrue);
      expect(t('"n" BETWEEN 10 AND 20', {'n': 15}), isTrue);
      expect(t('CASE WHEN "n" > 5 THEN TRUE ELSE FALSE END', {'n': 6}), isTrue);
      expect(t('lower("s") = \'abc\' AND length("s") = 3', {'s': 'ABC'}), isTrue);
      expect(t('coalesce("x", 0) + 2 * 3 = 6', {}), isTrue);
      expect(t('"a" || \'-\' || "b" = \'1-2\'', {'a': 1, 'b': 2}), isTrue);
      expect(t('to_int("s") % 2 = 1', {'s': '7'}), isTrue);
      expect(t('if("n" > 1, \'big\', \'small\') = \'big\'', {'n': 2}), isTrue);
    });

    test('読めない式は例外（呼び出し側は代表の色に戻す）', () {
      expect(() => parseQgisExpression(r'$area > 10'), throwsA(isA<QgisExpressionParseException>()));
      expect(() => parseQgisExpression('make_point(1, 2)'), throwsA(isA<QgisExpressionParseException>()));
      final r = QgisRenderer(
        kind: QgisRendererKind.rule,
        classes: const [QgisRendererClass(label: 'x')],
        rules: const [QgisRule(filter: r'$area > 10', classIndex: 0)],
      );
      expect(r.evaluator, isNull);
    });

    test('分類の値は列名でも式でもよい。数の表記ゆれは同じ値', () {
      final r = QgisRenderer(
        kind: QgisRendererKind.categorized,
        attr: '林班',
        classes: const [
          QgisRendererClass(label: '5', values: ['5']),
          QgisRendererClass(label: 'その他'),
        ],
      );
      expect(r.evaluator!.classFor({'林班': 5}), 0);
      expect(r.evaluator!.classFor({'林班': 5.0}), 0);
      expect(r.evaluator!.classFor({'林班': '6'}), 1);
      final spaced = QgisRenderer(
        kind: QgisRendererKind.categorized,
        attr: 'tree type',
        classes: const [QgisRendererClass(label: 'a', values: ['a'])],
      );
      expect(spaced.evaluator!.classFor({'tree type': 'a'}), 0, reason: '空白入りの列名は列として読む');
    });
  });

  test('1 万件の振り分けが十分速い', () {
    final cat = renderer('樹種で分類');
    final rule = renderer('ルールで');
    const species = ['スギ', 'ヒノキ', 'マツ', '広葉樹', null];
    final rows = [
      for (var i = 0; i < 10000; i++) {'樹種': species[i % 5], '林齢': i % 90, '面積': (i % 50) / 10},
    ];
    final sw = Stopwatch()..start();
    for (final p in rows) {
      cat.evaluator!.classFor(p);
    }
    final catMs = sw.elapsedMilliseconds;
    sw.reset();
    for (final p in rows) {
      rule.evaluator!.classFor(p);
    }
    final ruleMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('1 万件: 分類 ${catMs}ms / ルール ${ruleMs}ms');
    expect(catMs + ruleMs, lessThan(1000));
  });
}
