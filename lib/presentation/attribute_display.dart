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

import '../i18n/strings.g.dart';
import '../models/qgis_form.dart';

/// 属性の値を見せる文字。真偽の列なら「はい／いいえ」、ほかは値の文字そのまま
String attributeDisplayText(Object? value, {QgisFieldForm? form, String sqlType = ''}) {
  final b = attributeBool(value, form: form, sqlType: sqlType);
  if (b != null) return b ? t.featureDetail.boolTrue : t.featureDetail.boolFalse;
  return value?.toString() ?? '';
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
