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
// こかげマップ: ラベルの「部品」表現と、旧形式からの読み替え
//
// ラベルの正体は QGIS の式（`label_expression.dart`）。ここはその上に載る薄い層で、
//   - 部品（列／固定文字／そのままの式）の列 ⇄ 式 の往復（組み立てダイアログ用）
//   - 旧形式（`{列}` テンプレート、列名だけ）を式に読み替える
//   - 属性を流し込んで地図に出す文字を作る
// を受け持つ。
//
// 2026-09-12 までは独自の `{列}` テンプレートだった。`.qgs` に `isExpression="0"` のまま
// 書いていたので複数列のラベルが QGIS で壊れていた。以後は式で持つ。

import 'label_expression.dart';

/// ラベルの部品
sealed class LabelToken {
  const LabelToken();
}

/// 列の値
class FieldToken extends LabelToken {
  const FieldToken(this.column);
  final String column;
}

/// 固定文字
class TextToken extends LabelToken {
  const TextToken(this.text);
  final String text;
}

/// 部品に分解できない式（関数など）。そのまま持ち回る
class RawToken extends LabelToken {
  const RawToken(this.expression);
  final String expression;
}

final _placeholder = RegExp(r'\{([^{}]+)\}');

/// 保存されている文字列を式に読み替える。
///
/// - `{列} / {列2}`（旧テンプレート）→ `concat("列", ' / ', "列2")`
/// - `列名`（さらに古い形式。引用符も演算子も無い）→ `"列名"`
/// - それ以外は式としてそのまま（読めない式もそのまま返す。捨てない）
String? normalizeLabelExpression(String? stored) {
  if (stored == null || stored.trim().isEmpty) return null;
  final s = stored.trim();
  if (s.contains('{')) {
    final tokens = <LabelToken>[];
    var last = 0;
    for (final m in _placeholder.allMatches(s)) {
      if (m.start > last) tokens.add(TextToken(s.substring(last, m.start)));
      tokens.add(FieldToken(m.group(1)!));
      last = m.end;
    }
    if (last < s.length) tokens.add(TextToken(s.substring(last)));
    return buildLabelTemplate(tokens);
  }
  // 引用符も演算子も無い裸の名前は列名（`name` → `"name"`。空白や記号入りでも同じ）
  if (!s.contains('"') && !s.contains("'") && !s.contains('(') && !s.contains('||')) {
    return quoteField(s);
  }
  return s;
}

/// 式 → 部品列。`concat(...)` / `||` の平らな並びは部品に、それ以外は [RawToken] 1 つ
List<LabelToken> parseLabelTemplate(String? stored) {
  final expr = normalizeLabelExpression(stored);
  if (expr == null) return const [];
  final e = tryParseLabelExpression(expr);
  if (e == null) return [RawToken(expr)];
  List<LabelExpr>? parts;
  switch (e) {
    case FuncCall(name: 'concat', :final args):
      parts = args;
    case ConcatOp(parts: final p):
      parts = p;
    case FieldRef() || StringLit():
      parts = [e];
    default:
      parts = null;
  }
  if (parts == null) return [RawToken(expr)];
  final tokens = <LabelToken>[];
  for (final p in parts) {
    switch (p) {
      case FieldRef(:final name):
        tokens.add(FieldToken(name));
      case StringLit(:final value):
        tokens.add(TextToken(value));
      default:
        tokens.add(RawToken(formatLabelExpression(p)));
    }
  }
  return tokens;
}

/// 部品列 → 式（保存形式）。列 1 つなら `"列"`、それ以外は NULL に強い `concat(...)`
String buildLabelTemplate(List<LabelToken> tokens) {
  if (tokens.isEmpty) return '';
  if (tokens.length == 1) {
    return switch (tokens.first) {
      FieldToken(:final column) => quoteField(column),
      TextToken(:final text) => quoteString(text),
      RawToken(:final expression) => expression,
    };
  }
  final parts = tokens.map((t) => switch (t) {
        FieldToken(:final column) => quoteField(column),
        TextToken(:final text) => quoteString(text),
        RawToken(:final expression) => expression,
      });
  return 'concat(${parts.join(', ')})';
}

/// ラベルに属性を流し込む。
///
/// 列の値が 1 つも入らなければ null（固定文字だけのラベルを全フィーチャに出さないため）。
/// 読めない式も null（地図には出さないが、設定は消さない）
String? renderLabelTemplate(String? stored, Map<String, Object?>? props) {
  final expr = normalizeLabelExpression(stored);
  if (expr == null) return null;
  final e = tryParseLabelExpression(expr);
  if (e == null) return null;
  final r = evalLabelExpression(e, props);
  if (r.value == null || !r.usedField) return null;
  final out = stringifyLabelValue(r.value!).trim();
  return out.isEmpty ? null : out;
}
