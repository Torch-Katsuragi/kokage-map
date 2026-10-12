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
// こかげマップ: 属性の値を人に見せる形（情報パネル）
//
// 真偽の列（SQLite の型が BOOLEAN、QGIS のチェックボックス、Dart の bool）は「はい／いいえ」で出す
// （2026-10-12 に「確認済: true」と生の値が出ていた）。gpkg の BOOLEAN は 1/0 で入るが、
// 文字で 'true'/'false' が入っていることもあるので両方読む。読めない値はそのまま出す。
//
// QGIS の属性フォームの設定があれば、QGIS の「地物情報の表示」と同じく列は別名、値は表示する形
// （ValueMap・ValueRelation は表示名、日付は見せる書式）で出す（2026-10-12 に「直径: 24」と列名のまま出ていた）。

import '../i18n/strings.g.dart';
import '../models/qgis_form.dart';

/// 列の見出し。QGIS で別名を付けてあれば別名、無ければ列名
String attributeLabel(String column, QgisForm? form) => form?.fields[column]?.alias ?? column;

/// 属性の値を見せる文字。真偽の列なら「はい／いいえ」、ValueMap・日付は QGIS の見せ方、
/// ValueRelation は [relationOptions]（参照先の キー → 値）で表示名に。ほかは値の文字そのまま
String attributeDisplayText(
  Object? value, {
  QgisFieldForm? form,
  String sqlType = '',
  List<QgisValueOption>? relationOptions,
}) {
  final b = attributeBool(value, form: form, sqlType: sqlType);
  if (b != null) return b ? t.featureDetail.boolTrue : t.featureDetail.boolFalse;
  if (value == null) return '';
  if (form != null && form.kind == QgisWidgetKind.valueRelation) {
    return valueRelationDisplayText(value, form, relationOptions) ?? '$value';
  }
  return form?.displayText(value) ?? '$value';
}

/// ValueRelation の値の表示名。選べる値が複数（AllowMulti の `{a,b}`）なら表示名を「, 」でつなぐ。
/// 選択肢が無い・どれにも当たらなければ null
String? valueRelationDisplayText(Object value, QgisFieldForm form, List<QgisValueOption>? options) {
  if (options == null || options.isEmpty) return null;
  final text = '$value'.trim();
  String? find(String v) => options.where((o) => o.value == v).firstOrNull?.label;
  final hit = find(text);
  if (hit != null) return hit;
  if (form.relationAllowMulti && text.startsWith('{') && text.endsWith('}')) {
    final parts = [
      for (final raw in text.substring(1, text.length - 1).split(','))
        if (raw.trim().replaceAll('"', '') case final v when v.isNotEmpty) v,
    ];
    if (parts.isEmpty) return null;
    return [for (final v in parts) find(v) ?? v].join(', ');
  }
  return null;
}

/// 真偽の列の値なら true/false、真偽の列でない・読めない値なら null
bool? attributeBool(Object? value, {QgisFieldForm? form, String sqlType = ''}) {
  if (value == null) return null;
  if (value is bool) return value;
  final text = '$value'.trim();
  if (text.isEmpty) return null;
  if (form?.kind == QgisWidgetKind.checkBox) {
    // QGIS で入れる値を決めてあればそれで見分ける
    if (form!.checkedState case final on? when on == text) return true;
    if (form.uncheckedState case final off? when off == text) return false;
    return _parseBool(text);
  }
  if (sqlType.toUpperCase().contains('BOOL')) return _parseBool(text);
  return null;
}

bool? _parseBool(String text) => switch (text.toLowerCase()) {
      '1' || 'true' || 't' || 'yes' || 'y' => true,
      '0' || 'false' || 'f' || 'no' || 'n' => false,
      _ => null,
    };
