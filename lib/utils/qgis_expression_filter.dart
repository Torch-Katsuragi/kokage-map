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
/// QGIS式をSQLite WHERE句に変換するユーティリティ
///
/// QGIS式の基本構文はSQLと互換性が高いため、
/// 安全性バリデーション + 軽微な変換のみで対応する。
///
/// サポート構文:
///   "field" = 'value'  |  "field" > 100  |  "field" LIKE 'T%'
///   "field" IN ('A','B')  |  "field" IS NULL  |  "field" IS NOT NULL
///   "field" BETWEEN 1 AND 10  |  AND / OR / NOT  |  "field" ILIKE 'T%'
library;

import '../i18n/strings.g.dart';
import 'app_logger.dart';

class QgisExpressionFilter {
  QgisExpressionFilter._();

  static const _dangerousPatterns = [
    'DROP ',
    'ALTER ',
    'DELETE ',
    'UPDATE ',
    'INSERT ',
    'CREATE ',
    'ATTACH ',
    'DETACH ',
    'PRAGMA ',
    'VACUUM',
    'REINDEX',
    '--',
    ';',
  ];

  /// QGIS式をSQLite WHERE句に変換する。
  /// 無効な式の場合は [FilterResult.error] を返す。
  static FilterResult toSqlWhere(String expression) {
    final trimmed = expression.trim();
    if (trimmed.isEmpty) {
      return FilterResult.error(t.qgisFilter.emptyExpression);
    }

    final upper = trimmed.toUpperCase();
    for (final pattern in _dangerousPatterns) {
      if (upper.contains(pattern)) {
        return FilterResult.error(t.qgisFilter.forbiddenKeyword(pattern: pattern));
      }
    }

    // ILIKE → SQLiteのLIKE（SQLiteのLIKEはASCII範囲でcase-insensitive）
    final sql = trimmed.replaceAllMapped(
      RegExp(r'\bILIKE\b', caseSensitive: false),
      (_) => 'LIKE',
    );

    // 括弧の対応チェック
    var depth = 0;
    var inSingleQuote = false;
    var inDoubleQuote = false;
    for (var i = 0; i < sql.length; i++) {
      final c = sql[i];
      if (c == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
      } else if (c == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
      } else if (!inSingleQuote && !inDoubleQuote) {
        if (c == '(') depth++;
        if (c == ')') depth--;
        if (depth < 0) {
          return FilterResult.error(t.qgisFilter.unmatchedParens);
        }
      }
    }
    if (depth != 0) {
      return FilterResult.error(t.qgisFilter.unclosedParens);
    }
    if (inSingleQuote || inDoubleQuote) {
      return FilterResult.error(t.qgisFilter.unclosedQuotes);
    }

    AppLogger.debug('[QgisExpressionFilter] 変換結果: $sql');
    return FilterResult.ok(sql);
  }

  /// テーブルのカラム名で式をバリデーション（フィールド参照の存在チェック）
  static String? validateFieldReferences(
    String expression,
    Set<String> validColumns,
  ) {
    final fieldPattern = RegExp('"([^"]+)"');
    for (final match in fieldPattern.allMatches(expression)) {
      final fieldName = match.group(1)!;
      if (!validColumns.contains(fieldName)) {
        return t.gps.columnNotExists(name: fieldName);
      }
    }
    return null;
  }
}

/// フィルタ変換結果
sealed class FilterResult {
  const FilterResult();
  const factory FilterResult.ok(String sql) = FilterResultOk;
  const factory FilterResult.error(String message) = FilterResultError;
}

class FilterResultOk extends FilterResult {
  final String sql;
  const FilterResultOk(this.sql);
}

class FilterResultError extends FilterResult {
  final String message;
  const FilterResultError(this.message);
}
