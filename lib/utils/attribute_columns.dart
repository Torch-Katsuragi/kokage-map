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
// 属性の列の決まり（属性表・属性フォーム・地物の編集で共通）

import '../models/geopackage/feature_repository.dart' show metadataColumn;
import '../models/nodes/feature_node.dart';

/// 内部用の列（`_` で始まる）。統計・検索置換・ラベルの列の候補から外す
bool isInternalColumn(String name) => name.startsWith('_');

/// アプリが中身を持つ列（地物のメタデータの JSON）。属性表・編集パネルには出さない。
/// 大文字小文字は区別しない
bool isSystemColumn(String name) {
  final n = name.toLowerCase();
  return n == metadataColumn || n == 'rmaps_metadata'; // 旧名
}

/// 書き換えない列（主キー [primaryKey]・内部用）。大文字小文字は区別しない。
///
/// 主キーは表ごと（fid・旧形式の id・OBJECTID など。主キーの無い表は rowid で、列には出ない）。
/// QGIS と同じく、`id`・`fid` という名前でも主キーでなければふつうの列として書ける
/// （以前は名前で弾いていて、主キーが fid の表の id の列を直せなかった）。
///
/// 形の列（geom・geometry・Shape など表ごとの名前）は列の一覧（`GeoPackageSchema.getColumnNames`）から外してある。
/// ここで geom・geometry を名前で弾くと、形の列が別の名前の表の geom・geometry というふつうの列が書けなくなる
bool isReadOnlyColumn(String name, {String? primaryKey}) {
  final n = name.toLowerCase();
  return (primaryKey != null && n == primaryKey.toLowerCase()) || n.startsWith('_');
}

/// 整数の列か（SQLite の型名から）
bool isIntegerSqlType(String sqlType) => sqlType.toUpperCase().contains('INT');

/// 数値の列か（SQLite の型名から）
bool isNumericSqlType(String sqlType) {
  final t = sqlType.toUpperCase();
  return t.contains('INT') ||
      t.contains('REAL') ||
      t.contains('DOUB') ||
      t.contains('FLOA') ||
      t.contains('NUMERIC');
}

/// 真偽の列か（SQLite の型名 BOOLEAN。GDAL・QGIS は真偽として読む）。
/// GeoPackage の決まりで中身は INTEGER の 0/1
bool isBooleanSqlType(String sqlType) => sqlType.toUpperCase().contains('BOOL');

/// 値を真偽として読む。1/0・true/false・t/f・yes/no・y/n（大文字小文字を問わない）と bool。
/// 空・NULL・読めない値は null
bool? parseBooleanValue(Object? value) {
  switch (value) {
    case final bool b:
      return b;
    case final num n:
      return n != 0;
    case final String s:
      final v = s.trim().toLowerCase();
      if (v == '1' || v == 'true' || v == 't' || v == 'yes' || v == 'y') return true;
      if (v == '0' || v == 'false' || v == 'f' || v == 'no' || v == 'n') return false;
      final n = num.tryParse(v);
      return n == null ? null : n != 0;
  }
  return null;
}

/// 真偽の列に書く形（1/0）。空は NULL、真偽と読めない値はそのまま（黙って捨てない）
Object? toBooleanStorage(Object? value) {
  if (value is String && value.trim().isEmpty) return null;
  final b = parseBooleanValue(value);
  return b == null ? value : (b ? 1 : 0);
}

/// 全角の数字・小数点・符号を半角にする（日本語入力のまま打つと「３３」になる）
String toHalfWidthNumber(String text) {
  final b = StringBuffer();
  for (final r in text.runes) {
    if (r >= 0xFF10 && r <= 0xFF19) {
      b.writeCharCode(r - 0xFF10 + 0x30);
    } else if (r == 0xFF0E) {
      b.write('.');
    } else if (r == 0xFF0D || r == 0x2212 || r == 0x30FC) {
      b.write('-');
    } else if (r == 0xFF0B) {
      b.write('+');
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString().trim();
}

/// 入力欄で打った値を列に書く形にする（属性フォーム・編集パネルで共通）。
/// 数値の列（[sqlType]）なら全角の数字・小数点・符号を半角に。真偽の列は 1/0（[toBooleanStorage]）。
/// ほかの列・文字でない値はそのまま
Object? normalizeAttributeInput(String sqlType, Object? value) {
  if (isBooleanSqlType(sqlType)) return toBooleanStorage(value);
  return value is String && isNumericSqlType(sqlType) ? toHalfWidthNumber(value) : value;
}

/// 地物の属性の値（同期で読む）。消した地物・読めない地物は null。
/// [FeatureNode.getAttributeValue] と同じ値を返す（あちらは 1 マスごとに await が挟まる）
Object? readAttribute(FeatureNode feature, String column) {
  if (feature.isDisposed) return null;
  try {
    return feature.turfFeature.properties?[column];
  } catch (_) {
    return null;
  }
}
