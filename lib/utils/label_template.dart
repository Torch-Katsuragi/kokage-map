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
// こかげマップ: ラベルのテンプレート
//
// `{列名}` を属性値に置き換える。`{` を含まない文字列は列名そのもの
// （旧形式。`labelProperty: "name"` など）として扱う。
// 例: `{compartment} / {species}` → `12-b / hinoki`
library;

/// テンプレートを部品に分けたもの。UI（ラベル合成ダイアログ）と描画で共有する
sealed class LabelToken {
  const LabelToken();
}

class FieldToken extends LabelToken {
  const FieldToken(this.column);
  final String column;
}

class TextToken extends LabelToken {
  const TextToken(this.text);
  final String text;
}

final _placeholder = RegExp(r'\{([^{}]+)\}');

/// テンプレート文字列 → 部品列。旧形式（列名だけ）は 1 つの [FieldToken] になる
List<LabelToken> parseLabelTemplate(String? template) {
  if (template == null || template.isEmpty) return const [];
  if (!template.contains('{')) return [FieldToken(template)];
  final tokens = <LabelToken>[];
  var last = 0;
  for (final m in _placeholder.allMatches(template)) {
    if (m.start > last) tokens.add(TextToken(template.substring(last, m.start)));
    tokens.add(FieldToken(m.group(1)!));
    last = m.end;
  }
  if (last < template.length) tokens.add(TextToken(template.substring(last)));
  return tokens;
}

/// 部品列 → テンプレート文字列（保存形式）
String buildLabelTemplate(List<LabelToken> tokens) => tokens
    .map((t) => switch (t) {
          FieldToken(:final column) => '{$column}',
          TextToken(:final text) => text,
        })
    .join();

/// テンプレートに属性値を流し込む。
///
/// 置き換え先が全部空（列が無い・値が null）なら null を返す。固定文字だけの
/// ラベルを全フィーチャに出してしまわないため。
String? renderLabelTemplate(String? template, Map<String, Object?>? props) {
  final tokens = parseLabelTemplate(template);
  if (tokens.isEmpty) return null;
  final buf = StringBuffer();
  var anyValue = false;
  for (final t in tokens) {
    switch (t) {
      case FieldToken(:final column):
        final v = props?[column];
        if (v == null) continue;
        final s = v is double && v == v.roundToDouble()
            ? v.toInt().toString()
            : v.toString();
        if (s.isEmpty) continue;
        anyValue = true;
        buf.write(s);
      case TextToken(:final text):
        buf.write(text);
    }
  }
  if (!anyValue) return null;
  final out = buf.toString().trim();
  return out.isEmpty ? null : out;
}
