// ラベル（QGIS の式の部分集合）の読み替え・往復・評価
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/utils/label_expression.dart';
import 'package:root_maps/utils/label_template.dart';

void main() {
  final props = <String, Object?>{
    'compartment': '12-b',
    'species': 'hinoki',
    'area_ha': 3.9,
    'planted_year': 1971.0,
    'empty': '',
    '林班': '7',
  };

  group('旧形式の読み替え', () {
    test('列名だけ → "列"', () {
      expect(normalizeLabelExpression('compartment'), '"compartment"');
      expect(normalizeLabelExpression('林班'), '"林班"');
      expect(normalizeLabelExpression('area ha'), '"area ha"');
      expect(renderLabelTemplate('compartment', props), '12-b');
      expect(renderLabelTemplate('name', props), isNull);
    });

    test('{列} テンプレート → concat', () {
      expect(normalizeLabelExpression('{compartment} / {species}'), 'concat("compartment", \' / \', "species")');
      expect(renderLabelTemplate('{compartment} / {species}', props), '12-b / hinoki');
      expect(renderLabelTemplate('{area_ha}ha ({planted_year})', props), '3.9ha (1971)');
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
      expect(renderLabelTemplate('concat("compartment", \' \', "missing")', props), '12-b');
      expect(renderLabelTemplate('"compartment" || \' \' || "missing"', props), isNull);
      expect(renderLabelTemplate('"compartment" || \'/\' || "species"', props), '12-b/hinoki');
    });

    test('関数', () {
      expect(renderLabelTemplate('upper("species")', props), 'HINOKI');
      expect(renderLabelTemplate('coalesce("missing", "species")', props), 'hinoki');
      expect(renderLabelTemplate('round("area_ha")', props), '4');
      expect(renderLabelTemplate('concat(format_number("planted_year" , 0), \'年\')', props), '1,971年');
      expect(renderLabelTemplate('concat("林班", \'林班\')', props), '7林班');
    });

    test('読めない式は null で落ちない', () {
      expect(renderLabelTemplate('unknown_fn("a")', props), isNull);
      expect(renderLabelTemplate('"a" ||', props), isNull);
      expect(tryParseLabelExpression('"a" +  "b"'), isNull);
    });
  });

  group('部品との往復', () {
    test('parse と build', () {
      final tokens = parseLabelTemplate('No.{compartment} ({species})');
      expect(tokens.length, 5);
      expect(tokens.first, isA<TextToken>());
      expect((tokens[1] as FieldToken).column, 'compartment');
      expect(buildLabelTemplate(tokens), 'concat(\'No.\', "compartment", \' (\', "species", \')\')');
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
      expect(renderLabelTemplate("concat(\"species\", 'it''s')", props), "hinokiit's");
      expect(labelExpressionFields(parseLabelExpression('concat("a", "b", upper("a"))')), ['a', 'b']);
    });
  });
}
