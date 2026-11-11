// QGIS の属性フォームの設定（編集ウィジェット・別名・既定値・制約・配置）を読んで、入力に使う。
// fixture は QGIS 4.2.2 に書かせたもの（tool/qgis/write_form_fixture.py）
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/i18n/strings.g.dart';
import 'package:root_maps/models/qgis_form.dart';
import 'package:root_maps/services/qgis/qgs_form_reader.dart';
import 'package:root_maps/services/qgis_form_logic.dart';
import 'package:root_maps/utils/qgis_expression.dart';
import 'package:root_maps/widgets/qgis_form/qgis_field_input.dart';
import 'package:xml/xml.dart';

void main() {
  LocaleSettings.setLocaleSync(AppLocale.ja);
  final doc = XmlDocument.parse(File('test/fixtures/qgis_4_2_forms.qgs').readAsStringSync());
  XmlElement maplayer(String name) => doc.rootElement
      .getElement('projectlayers')!
      .findElements('maplayer')
      .firstWhere((m) => m.getElement('layername')?.innerText == name);
  final form = QgsFormReader.read(maplayer('chosa'))!;

  group('読む', () {
    test('編集ウィジェットの種類と設定', () {
      expect(form['kind']!.kind, QgisWidgetKind.valueMap);
      expect([for (final o in form['kind']!.valueMapOptions) (o.value, o.label)],
          [('SG', '種別A'), ('HN', '種別B'), ('KO', '種別C')]);
      expect(form['done']!.kind, QgisWidgetKind.checkBox);
      expect((form['done']!.checkedState, form['done']!.uncheckedState), ('Y', 'N'));
      final date = form['chosabi']!;
      expect(date.kind, QgisWidgetKind.dateTime);
      expect((date.fieldFormat, date.displayFormat), ('yyyy-MM-dd', 'yyyy/MM/dd'));
      final width = form['width']!;
      expect((width.kind, width.rangeMin, width.rangeMax, width.rangeStep, width.rangeSlider),
          (QgisWidgetKind.range, 0.0, 200.0, 0.5, false));
      expect(form['age']!.rangeSlider, isTrue);
      expect(form['memo']!.multiline, isTrue);
      expect(form['chosasha']!.kind, QgisWidgetKind.uniqueValues);
      expect(form['chosasha']!.uniqueEditable, isTrue);
      expect(form['uid']!.hidden, isTrue);
      final rel = form['parcels']!;
      expect(rel.kind, QgisWidgetKind.valueRelation);
      expect((rel.relationKey, rel.relationValue, rel.relationFilter, rel.relationOrderByValue),
          ('code', 'name', '"block" = 1', true));
      expect(form['iro']!.kind, QgisWidgetKind.other, reason: '知らない部品は文字の欄');
      expect(form['iro']!.widgetType, 'Color', reason: '種類は持ち帰る');
    });

    test('別名・既定値・制約・読み取り専用', () {
      expect(form['width']!.label, '幅員(m)');
      expect(form['chosasha']!.label, 'chosasha', reason: '別名が無ければ列名');
      expect((form['uid']!.defaultExpression, form['uid']!.applyDefaultOnUpdate), ('uuid()', false));
      expect((form['koshin']!.defaultExpression, form['koshin']!.applyDefaultOnUpdate), (r'$now', true));
      expect(form['kubun']!.defaultExpression, "'A'");
      expect(form['kind']!.notNull, QgisConstraintStrength.hard);
      expect(form['chosasha']!.notNull, QgisConstraintStrength.soft);
      expect(form['uid']!.unique, QgisConstraintStrength.hard);
      expect(form['width']!.expression, '"width" > 0 AND "width" < 150');
      expect(form['width']!.expressionDescription, '幅員は 0〜150 m');
      expect(form['width']!.expressionStrength, QgisConstraintStrength.soft);
      expect(form['biko']!.readOnly, isTrue);
      expect(form.editable('biko'), isFalse);
      expect(form.fields.containsKey('fid'), isFalse, reason: 'fid のデータソースの制約は持たない');
    });

    test('ドラッグ&ドロップの配置（タブとグループ）', () {
      final layout = form.layout!;
      expect([for (final e in layout) (e as QgisFormContainer).name], ['基本', 'その他']);
      final kihon = layout.first as QgisFormContainer;
      expect(kihon.isTab, isTrue);
      final shosai = kihon.children.last as QgisFormContainer;
      expect((shosai.name, shosai.isTab), ('詳細', false));
      expect(form.shows('memo'), isTrue);
      expect(form.shows('kiroku'), isFalse, reason: '配置に無い列は出さない');
      expect(form.shows('uid'), isFalse, reason: 'Hidden');
    });

    test('設定の無いレイヤは null', () {
      expect(QgsFormReader.read(maplayer('parcels')), isNull);
    });

    test('JSON で往復する', () {
      final back = QgisForm.fromJson(jsonDecode(jsonEncode(form.toJson())) as Map<String, dynamic>);
      expect(jsonEncode(back.toJson()), jsonEncode(form.toJson()));
      expect(back['kind']!.valueMapOptions.first.label, '種別A');
      expect((back.layout!.first as QgisFormContainer).children, hasLength(5));
    });
  });

  group('並び', () {
    const cols = ['kind', 'done', 'chosabi', 'width', 'age', 'memo', 'chosasha', 'uid', 'parcels', 'biko', 'kubun'];
    String show(QgisFormRow r) => switch (r) {
          QgisFormHeader(:final title, :final depth) => '${'  ' * depth}[$title]',
          QgisFormFieldRow(:final column, :final depth) => '${'  ' * depth}$column',
        };

    test('配置の順に、タブ・グループを見出しにする', () {
      expect(qgisFormRows(form, cols).map(show), [
        '[基本]', '  kind', '  width', '  age', '  done', '  [詳細]', '    chosabi', '    chosasha',
        '[その他]', '  memo', '  parcels', '  biko', '  kubun',
      ]);
    });

    test('配置が無ければ列の順。Hidden は出さない', () {
      final auto = QgisForm(fields: form.fields);
      expect(qgisFormRows(auto, cols).map(show), [for (final c in cols) if (c != 'uid') c]);
    });
  });

  group('式', () {
    test(r'now() と $now は今の時刻、uuid() は波かっこつき', () {
      final before = DateTime.now();
      expect(parseQgisExpression('now()').eval(null), isA<DateTime>());
      final n = parseQgisExpression(r'$now').eval(null)! as DateTime;
      expect(n.isBefore(before), isFalse);
      final u = parseQgisExpression('uuid()').eval(null)! as String;
      expect(u, matches(RegExp(r'^\{[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\}$')));
      expect(parseQgisExpression("uuid('WithoutBraces')").eval(null), isNot(startsWith('{')));
      expect(tryParseQgisExpression(r'$area'), isNull, reason: '形を使うものは読めない');
    });
  });

  group('既定値', () {
    const types = {'uid': 'TEXT', 'kiroku': 'DATETIME', 'koshin': 'TEXT', 'kubun': 'TEXT', 'fukusu': 'TEXT'};
    const columns = ['uid', 'kiroku', 'koshin', 'kubun', 'fukusu', 'kind'];

    test(r'新しい地物: 文字・uuid()・now()・$now。読めない式は飛ばす', () {
      final d = evaluateQgisDefaults(form, {}, types, columns: columns);
      expect(d['kubun'], 'A');
      expect(d['uid'], matches(RegExp(r'^\{.{36}\}$')));
      expect(d['kiroku'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')),
          reason: '日時の列は GeoPackage の決まり（UTC の ISO 8601）');
      expect(d['koshin'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$')), reason: '文字の列は Qt の ISO');
      expect(d.containsKey('fukusu'), isFalse, reason: '@user_full_name は読めない');
    });

    test('更新のとき: applyOnUpdate のものだけ', () {
      final d = evaluateQgisDefaults(form, {}, types, columns: columns, onUpdate: true);
      expect(d.keys, ['koshin']);
    });

    test('レイヤに無い列には当てない', () {
      expect(evaluateQgisDefaults(form, {}, types, columns: const ['kind']), isEmpty);
    });
  });

  group('制約', () {
    final ok = <String, Object?>{'kind': 'SG', 'width': 30, 'chosasha': '佐藤', 'uid': '{x}'};

    test('守っていれば何も出ない', () {
      expect(validateQgisForm(form, ok, otherValues: (_) => ['{y}']), isEmpty);
    });

    test('必須（強い）・必須（警告）・一意・式', () {
      final vs = validateQgisForm(
        form,
        {...ok, 'kind': null, 'chosasha': '', 'width': 180},
        otherValues: (c) => c == 'uid' ? ['{x}'] : [],
      );
      final byField = {for (final v in vs) v.field: v};
      expect(byField['kind']!.hard, isTrue);
      expect(byField['kind']!.message, '「種別」は必須です');
      expect(byField['chosasha']!.hard, isFalse, reason: '空の文字も入っていない扱い');
      expect(byField['width']!.hard, isFalse);
      expect(byField['width']!.message, '「幅員(m)」: 幅員は 0〜150 m', reason: '説明があれば説明');
      expect(byField['uid']!.hard, isTrue);
    });

    test('only の列だけ', () {
      final vs = validateQgisForm(form, {...ok, 'kind': null, 'width': 180}, only: ['width']);
      expect([for (final v in vs) v.field], ['width']);
    });
  });

  group('日付の書式', () {
    test('Qt の書式で書いて読む', () {
      final d = DateTime(2026, 5, 1, 13, 4, 5);
      expect(formatQtDate(d, 'yyyy/MM/dd'), '2026/05/01');
      expect(formatQtDate(d, "d.M.yy 'at' h:mm AP"), '1.5.26 at 1:04 PM');
      expect(parseQtDate('2026-05-01', 'yyyy-MM-dd'), DateTime(2026, 5, 1));
      expect(parseQtDate('2026-05-01 13:04:05', 'yyyy-MM-dd HH:mm:ss'), d);
      expect(parseQtDate('2026/05/01', 'yyyy-MM-dd'), isNull);
      expect(form['chosabi']!.displayText('2026-05-01'), '2026/05/01');
    });

    test('列の型で書き方を変える', () {
      final d = DateTime(2026, 5, 1, 9);
      expect(storeDateValue(d, 'DATE', form['chosabi']), '2026-05-01');
      expect(storeDateValue(d, 'TEXT', form['chosabi']), '2026-05-01', reason: 'field_format');
      final u = d.toUtc();
      expect(storeDateValue(d, 'DATETIME', null), '${formatQtDate(u, 'yyyy-MM-dd')}T${formatQtDate(u, 'HH:mm:ss')}.000Z');
    });
  });

  group('欄', () {
    Future<List<(Object?, bool)>> pump(WidgetTester tester, String column, Object? value,
        {String sqlType = 'TEXT', List<QgisValueOption>? options, String? error}) async {
      final changes = <(Object?, bool)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: QgisFieldInput(
              column: column,
              field: form[column],
              sqlType: sqlType,
              value: value,
              options: options,
              errorText: error,
              onChanged: (v, {required commit}) => changes.add((v, commit)),
            ),
          ),
        ),
      ));
      return changes;
    }

    testWidgets('ValueMap: 表示名を見せて、選ぶと値を書く', (tester) async {
      final changes = await pump(tester, 'kind', 'SG');
      expect(find.text('種別A'), findsOneWidget);
      expect(find.text('SG'), findsNothing);
      expect(find.text('種別 *'), findsOneWidget, reason: '別名と必須の印');
      await tester.tap(find.text('種別A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('種別B').last);
      await tester.pumpAndSettle();
      expect(changes.last, ('HN', true));
    });

    testWidgets('ValueMap: 選択肢に無い値も消さずに出す', (tester) async {
      await pump(tester, 'kind', 'ZZ');
      expect(find.text('ZZ'), findsOneWidget);
    });

    testWidgets('チェックボックス: 決めた値を書く', (tester) async {
      final changes = await pump(tester, 'done', 'N');
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      await tester.tap(find.byType(Checkbox));
      expect(changes.last, ('Y', true));
    });

    testWidgets('日付: 見せる書式で出し、カレンダーで選ぶと field_format で書く', (tester) async {
      final changes = await pump(tester, 'chosabi', '2026-05-01', sqlType: 'DATE');
      expect(find.text('2026/05/01'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.calendar_month));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(changes.last, ('2026-05-15', true));
      await tester.tap(find.byIcon(Icons.clear));
      expect(changes.last, (null, true));
    });

    testWidgets('範囲（数の欄）: 確定で min〜max に収める', (tester) async {
      final changes = await pump(tester, 'width', 30, sqlType: 'REAL');
      await tester.enterText(find.byType(TextField), '２５０');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(changes.last, ('200', true), reason: '全角を半角にして、最大 200 に収める');
    });

    testWidgets('範囲（つまみ）: 刻みに合わせる', (tester) async {
      final changes = await pump(tester, 'age', 40, sqlType: 'INTEGER');
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('40'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(30, 0));
      await tester.pumpAndSettle();
      final (v, commit) = changes.last;
      expect(commit, isTrue);
      expect((v! as int) % 5, 0, reason: '刻み 5');
    });

    testWidgets('値の関係: 選択肢の表示名を見せて、キーを書く', (tester) async {
      final changes = await pump(tester, 'parcels', '1-b', options: const [
        QgisValueOption('1-a', '1区 い号'),
        QgisValueOption('1-b', '1区 ろ号'),
      ]);
      expect(find.text('1区 ろ号'), findsOneWidget);
      await tester.tap(find.text('1区 ろ号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1区 い号').last);
      await tester.pumpAndSettle();
      expect(changes.last, ('1-a', true));
    });

    testWidgets('制約のエラーを欄の下に出す', (tester) async {
      await pump(tester, 'memo', null, error: '「メモ」は必須です');
      expect(find.text('「メモ」は必須です'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 4, reason: '複数行');
    });
  });
}
