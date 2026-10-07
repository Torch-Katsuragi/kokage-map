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

import '../models/nodes/feature_node.dart';

/// 内部用の列（`_` で始まる）。統計・検索置換・ラベルの列の候補から外す
bool isInternalColumn(String name) => name.startsWith('_');

/// 書き換えない列（番号・形・内部用）。大文字小文字は区別しない
bool isReadOnlyColumn(String name) {
  final n = name.toLowerCase();
  return n == 'id' ||
      n == 'fid' ||
      n == 'geom' ||
      n == 'geometry' ||
      n.startsWith('_');
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
