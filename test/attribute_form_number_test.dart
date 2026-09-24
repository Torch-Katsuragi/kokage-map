// 属性フォームの数値の列: 全角で打っても半角の数値として保存する
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/widgets/attribute_table/attribute_form_view.dart';

void main() {
  test('全角の数字・小数点・符号を半角にする', () {
    expect(toHalfWidthNumber('３３'), '33');
    expect(toHalfWidthNumber('－１２．５'), '-12.5');
    expect(toHalfWidthNumber(' 42 '), '42');
    expect(toHalfWidthNumber('abc'), 'abc');
  });

  test('数値の列を型名で見分ける', () {
    for (final t in ['INTEGER', 'INT', 'MEDIUMINT', 'REAL', 'DOUBLE', 'FLOAT', 'NUMERIC']) {
      expect(isNumericSqlType(t), isTrue, reason: t);
    }
    for (final t in ['TEXT', 'BLOB', 'DATE', '']) {
      expect(isNumericSqlType(t), isFalse, reason: t);
    }
  });
}
