// ラベルテンプレート（`{列名}` の置き換え）の検査
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/utils/label_template.dart';

void main() {
  final props = <String, Object?>{
    'compartment': '12-b',
    'species': 'hinoki',
    'area_ha': 3.9,
    'planted_year': 1971.0,
    'empty': '',
  };

  test('旧形式（列名だけ）はその列の値', () {
    expect(renderLabelTemplate('compartment', props), '12-b');
    expect(renderLabelTemplate('name', props), isNull);
  });

  test('複数の列と固定文字を組み合わせる', () {
    expect(
      renderLabelTemplate('{compartment} / {species}', props),
      '12-b / hinoki',
    );
    expect(renderLabelTemplate('{area_ha}ha ({planted_year})', props), '3.9ha (1971)');
  });

  test('値が全部空なら null（固定文字だけを出さない）', () {
    expect(renderLabelTemplate('{missing} 区画', props), isNull);
    expect(renderLabelTemplate('{empty}', props), isNull);
    expect(renderLabelTemplate('', props), isNull);
    expect(renderLabelTemplate(null, props), isNull);
  });

  test('一部だけ空なら残りで組む', () {
    expect(renderLabelTemplate('{compartment} {missing}', props), '12-b');
  });

  test('parse と build は往復する', () {
    const tpl = 'No.{compartment} ({species})';
    final tokens = parseLabelTemplate(tpl);
    expect(tokens.length, 5);
    expect(tokens.first, isA<TextToken>());
    expect((tokens[1] as FieldToken).column, 'compartment');
    expect(buildLabelTemplate(tokens), tpl);
    expect(buildLabelTemplate(parseLabelTemplate('name')), '{name}');
  });
}
