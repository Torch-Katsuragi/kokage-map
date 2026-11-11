// ラベル（QGIS の式の部分集合）の読み替え・往復・評価
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/utils/label_expression.dart';
import 'package:root_maps/utils/label_template.dart';

void main() {
  final props = <String, Object?>{
    'block': '12-b',
    'category': 'type_b',
    'area_ha': 3.9,
    'year': 1971.0,
    'empty': '',
    '区画': '7',
  };

  group('旧形式の読み替え', () {
    test('列名だけ → "列"', () {
      expect(normalizeLabelExpression('block'), '"block"');
      expect(normalizeLabelExpression('区画'), '"区画"');
      expect(normalizeLabelExpression('area ha'), '"area ha"');
      expect(renderLabelTemplate('block', props), '12-b');
      expect(renderLabelTemplate('name', props), isNull);
    });

    test('{列} テンプレート → concat', () {
      expect(normalizeLabelExpression('{block} / {category}'), 'concat("block", \' / \', "category")');
      expect(renderLabelTemplate('{block} / {category}', props), '12-b / type_b');
      expect(renderLabelTemplate('{area_ha}ha ({year})', props), '3.9ha (1971)');
    });

    test('式はそのまま', () {
      expect(normalizeLabelExpression('"a" || \'-\' || "b"'), '"a" || \'-\' || "b"');
      expect(normalizeLabelExpression(''), isNull);
      expect(normalizeLabelExpression(null), isNull);
    });
  });

  group('評価', () {
    test('値が全部空なら null（固定文字だけを出さない）', () {
      expect(renderLabelTemplate('{missing} 区画', props), isNull);
      expect(renderLabelTemplate('{empty}', props), isNull);
      expect(renderLabelTemplate("'固定'", props), isNull);
    });

    test('concat は NULL を空として繋ぐ。|| は NULL で全体が NULL（QGIS と同じ）', () {
      expect(renderLabelTemplate('concat("block", \' \', "missing")', props), '12-b');
      expect(renderLabelTemplate('"block" || \' \' || "missing"', props), isNull);
      expect(renderLabelTemplate('"block" || \'/\' || "category"', props), '12-b/type_b');
    });

    test('関数', () {
      expect(renderLabelTemplate('upper("category")', props), 'TYPE_B');
      expect(renderLabelTemplate('coalesce("missing", "category")', props), 'type_b');
      expect(renderLabelTemplate('round("area_ha")', props), '4');
      expect(renderLabelTemplate('concat(format_number("year" , 0), \'年\')', props), '1,971年');
      expect(renderLabelTemplate('concat("区画", \'区画\')', props), '7区画');
    });

    test('読めない式は null で落ちない', () {
      expect(renderLabelTemplate('unknown_fn("a")', props), isNull);
      expect(renderLabelTemplate('"a" ||', props), isNull);
      expect(tryParseLabelExpression('"a" +  "b"'), isNull);
    });
  });

  group('部品との往復', () {
    test('parse と build', () {
      final tokens = parseLabelTemplate('No.{block} ({category})');
      expect(tokens.length, 5);
      expect(tokens.first, isA<TextToken>());
      expect((tokens[1] as FieldToken).column, 'block');
      expect(buildLabelTemplate(tokens), 'concat(\'No.\', "block", \' (\', "category", \')\')');
      expect(buildLabelTemplate(parseLabelTemplate('name')), '"name"');
      expect(parseLabelTemplate(buildLabelTemplate(tokens)).length, 5);
    });

    test('|| の並びも部品になる。関数は RawToken', () {
      expect(parseLabelTemplate('"a" || \'-\' || "b"').length, 3);
      final tokens = parseLabelTemplate('concat("a", upper("b"))');
      expect(tokens[1], isA<RawToken>());
      expect(buildLabelTemplate(tokens), 'concat("a", upper("b"))');
      expect(parseLabelTemplate('round("x", 1)').single, isA<RawToken>());
    });

    test('引用符の中の引用符', () {
      expect(buildLabelTemplate([const TextToken("it's")]), "'it''s'");
      expect(renderLabelTemplate("concat(\"category\", 'it''s')", props), "type_bit's");
      expect(labelExpressionFields(parseLabelExpression('concat("a", "b", upper("a"))')), ['a', 'b']);
    });
  });
}
