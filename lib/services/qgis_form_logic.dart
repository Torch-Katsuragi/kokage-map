// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// こかげマップ: QGIS の属性フォームの既定値と制約（[QgisForm]）を、地物の属性に当てる
//
// 既定値の式は `qgis_expression.dart` で評価する（now() / $now / uuid() / 文字・数・列の参照など）。
// 読めない式（`@user_full_name` などの変数・知らない関数）はその列を飛ばしてログに 1 回出す。

import '../i18n/strings.g.dart';
import '../models/qgis_form.dart';
import '../utils/app_logger.dart';
import '../utils/attribute_columns.dart';
import '../utils/qgis_expression.dart';

/// 制約に引っかかった 1 件
class QgisFormViolation {
  const QgisFormViolation({required this.field, required this.message, required this.hard});
  final String field;
  final String message;

  /// 守らないと保存しない（false なら警告だけ）
  final bool hard;
}

/// 既定値の式で、読めずに飛ばしたもの（ログを 1 回にする）
final Set<String> _skippedDefaults = {};

/// 日付・時刻を列に書く形にする。
///
/// 日付の列（DATE）は `yyyy-MM-dd`、日時の列（DATETIME）は GeoPackage の決まり（UTC の ISO 8601）。
/// 文字の列は DateTime ウィジェットの `field_format`、無ければ Qt の ISO 形式（QGIS が文字の列に書く形）
String storeDateValue(DateTime d, String sqlType, QgisFieldForm? field) {
  final t = sqlType.toUpperCase();
  if (t.contains('DATETIME') || t.contains('TIMESTAMP')) {
    return formatQtDate(d.toUtc(), "yyyy-MM-dd'T'HH:mm:ss.zzz'Z'");
  }
  if (t.contains('DATE')) return formatQtDate(d, 'yyyy-MM-dd');
  final fmt = field?.fieldFormat;
  return formatQtDate(d, fmt ?? "yyyy-MM-dd'T'HH:mm:ss");
}

/// 式の結果を列に書く形にする（日時は文字に、整数の列は整数に）
Object? _toStored(Object? v, String sqlType, QgisFieldForm field) {
  if (v is DateTime) return storeDateValue(v, sqlType, field);
  if (v is double && isIntegerSqlType(sqlType) && v == v.roundToDouble()) return v.toInt();
  if (v is bool) return v ? 1 : 0;
  return v;
}

/// 既定値。[onUpdate] なら「更新のときも当て直す」ものだけ。
///
/// [props] は今の属性（式が列を参照するときに使う）。[sqlTypes] は列 → SQLite の型名。
/// [columns] にある列だけに当てる（レイヤに無い列は書かない）
Map<String, Object?> evaluateQgisDefaults(
  QgisForm form,
  Map<String, Object?> props,
  Map<String, String> sqlTypes, {
  required Iterable<String> columns,
  bool onUpdate = false,
}) {
  final out = <String, Object?>{};
  final cols = columns.toSet();
  for (final field in form.fields.values) {
    final src = field.defaultExpression;
    if (src == null || !cols.contains(field.name)) continue;
    if (onUpdate && !field.applyDefaultOnUpdate) continue;
    final expr = tryParseQgisExpression(src);
    if (expr == null) {
      if (_skippedDefaults.add(src)) {
        AppLogger.debug('[QgisForm] 既定値の式を読めないので飛ばす: ${field.name} = $src');
      }
      continue;
    }
    try {
      out[field.name] = _toStored(expr.eval({...props, ...out}), sqlTypes[field.name] ?? '', field);
    } on Object catch (e) {
      AppLogger.debug('[QgisForm] 既定値の式を評価できない: ${field.name} = $src ($e)');
    }
  }
  return out;
}

bool _isMissing(Object? v) => v == null || (v is String && v.trim().isEmpty);

/// 制約を確かめる。[only] を渡せばその列だけ。
///
/// [otherValues] は一意の制約に使う、ほかの地物のその列の値（自分は除く）
List<QgisFormViolation> validateQgisForm(
  QgisForm form,
  Map<String, Object?> props, {
  Iterable<String>? only,
  Iterable<Object?> Function(String column)? otherValues,
}) {
  final targets = only?.toSet();
  final out = <QgisFormViolation>[];
  for (final field in form.fields.values) {
    if (!field.hasConstraint) continue;
    if (targets != null && !targets.contains(field.name)) continue;
    if (!props.containsKey(field.name)) continue; // レイヤに無い列
    final value = props[field.name];
    final label = field.label;

    if (field.notNull != QgisConstraintStrength.none && _isMissing(value)) {
      out.add(QgisFormViolation(
        field: field.name,
        message: t.qgisForm.notNull(field: label),
        hard: field.notNull == QgisConstraintStrength.hard,
      ));
    }

    if (field.unique != QgisConstraintStrength.none && !_isMissing(value) && otherValues != null) {
      final text = '$value';
      if (otherValues(field.name).any((o) => o != null && '$o' == text)) {
        out.add(QgisFormViolation(
          field: field.name,
          message: t.qgisForm.unique(field: label, value: field.displayText(value)),
          hard: field.unique == QgisConstraintStrength.hard,
        ));
      }
    }

    final src = field.expression;
    if (src != null && field.expressionStrength != QgisConstraintStrength.none) {
      final expr = tryParseQgisExpression(src);
      if (expr == null) {
        if (_skippedDefaults.add('constraint:$src')) {
          AppLogger.debug('[QgisForm] 制約の式を読めないので確かめない: ${field.name} = $src');
        }
      } else if (!expr.test(props)) {
        final desc = field.expressionDescription;
        out.add(QgisFormViolation(
          field: field.name,
          message: desc == null
              ? t.qgisForm.expressionNoDesc(field: label, exp: src)
              : t.qgisForm.expression(field: label, desc: desc),
          hard: field.expressionStrength == QgisConstraintStrength.hard,
        ));
      }
    }
  }
  return out;
}

/// 引っかかったものを 1 行の理由にまとめる
String describeViolations(Iterable<QgisFormViolation> vs) => vs.map((v) => v.message).join(' / ');
