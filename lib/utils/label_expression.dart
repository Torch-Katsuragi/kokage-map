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
// こかげマップ: ラベルの式（QGIS の式の部分集合）
//
// ラベルは QGIS と同じ式で持つ。`.qgs` にそのまま `isExpression="1"` で書け、
// QGIS 側で書いた式もそのまま読み戻せる。
//
// 飲めるもの:
//   "列名"            列の値（`"` 無しの裸の名前も列として読む）
//   '文字'            固定文字（`''` で `'` を表す）
//   123 / 1.5         数
//   NULL
//   a || b            連結。⚠ QGIS と同じく、どれかが NULL なら全体が NULL
//   concat(a, b, …)   連結。NULL は空文字として繋ぐ（部品ダイアログはこちらを作る）
//   coalesce(a, b, …) 最初の NULL でないもの
//   upper(x) lower(x) trim(x) to_string(x) length(x)
//   round(x [, 桁]) format_number(x [, 桁])
//   ( … )
//
// それ以外の関数・演算子は読めない（`tryParseLabelExpression` が null）。
// 読めない式は `.kmeta.json` にそのまま残し、地図にはラベルを出さない。

/// 式の木
sealed class LabelExpr {
  const LabelExpr();
}

/// 列の参照
class FieldRef extends LabelExpr {
  const FieldRef(this.name);
  final String name;
}

class StringLit extends LabelExpr {
  const StringLit(this.value);
  final String value;
}

class NumberLit extends LabelExpr {
  const NumberLit(this.value);
  final double value;
}

class NullLit extends LabelExpr {
  const NullLit();
}

/// `a || b || c`
class ConcatOp extends LabelExpr {
  const ConcatOp(this.parts);
  final List<LabelExpr> parts;
}

class FuncCall extends LabelExpr {
  const FuncCall(this.name, this.args);
  final String name;
  final List<LabelExpr> args;
}

/// 飲める関数と引数の数（最小, 最大）
const Map<String, (int, int)> labelFunctions = {
  'concat': (1, 1 << 30),
  'coalesce': (1, 1 << 30),
  'upper': (1, 1),
  'lower': (1, 1),
  'trim': (1, 1),
  'to_string': (1, 1),
  'length': (1, 1),
  'round': (1, 2),
  'format_number': (1, 2),
};

class LabelExprParseException implements Exception {
  const LabelExprParseException(this.message, this.offset);
  final String message;
  final int offset;

  @override
  String toString() => 'LabelExprParseException($offset): $message';
}

/// 式を読む。読めなければ [LabelExprParseException]
LabelExpr parseLabelExpression(String src) => _Parser(src).parseAll();

/// 式を読む。読めなければ null
LabelExpr? tryParseLabelExpression(String src) {
  try {
    return parseLabelExpression(src);
  } on LabelExprParseException {
    return null;
  }
}

/// 評価の結果。[usedField] は「列の値（空でない）が結果に入ったか」。
/// 固定文字だけのラベルを全フィーチャに出さないための印
typedef LabelEvalResult = ({Object? value, bool usedField});

/// 式に属性を流し込む
LabelEvalResult evalLabelExpression(LabelExpr e, Map<String, Object?>? props) {
  switch (e) {
    case FieldRef(:final name):
      final v = props?[name];
      final s = v == null ? null : _stringify(v);
      return (value: s == null || s.isEmpty ? null : s, usedField: s != null && s.isNotEmpty);
    case StringLit(:final value):
      return (value: value, usedField: false);
    case NumberLit(:final value):
      return (value: value, usedField: false);
    case NullLit():
      return (value: null, usedField: false);
    case ConcatOp(:final parts):
      final buf = StringBuffer();
      var used = false;
      for (final p in parts) {
        final r = evalLabelExpression(p, props);
        if (r.value == null) return (value: null, usedField: false); // QGIS: NULL が混じると NULL
        used = used || r.usedField;
        buf.write(_stringify(r.value!));
      }
      return (value: buf.toString(), usedField: used);
    case FuncCall(:final name, :final args):
      return _call(name, [for (final a in args) evalLabelExpression(a, props)]);
  }
}

LabelEvalResult _call(String name, List<LabelEvalResult> args) {
  final used = args.any((a) => a.usedField);
  switch (name) {
    case 'concat':
      return (value: args.map((a) => a.value == null ? '' : _stringify(a.value!)).join(), usedField: used);
    case 'coalesce':
      for (final a in args) {
        if (a.value != null) return a;
      }
      return (value: null, usedField: false);
    case 'upper':
      return _str(args, used, (s) => s.toUpperCase());
    case 'lower':
      return _str(args, used, (s) => s.toLowerCase());
    case 'trim':
      return _str(args, used, (s) => s.trim());
    case 'to_string':
      return _str(args, used, (s) => s);
    case 'length':
      final v = args.first.value;
      return (value: v == null ? null : _stringify(v).length.toDouble(), usedField: used);
    case 'round':
      final v = _num(args.first.value);
      if (v == null) return (value: null, usedField: false);
      final places = args.length > 1 ? (_num(args[1].value) ?? 0).round() : 0;
      final f = _pow10(places);
      return (value: (v * f).round() / f, usedField: used);
    case 'format_number':
      final v = _num(args.first.value);
      if (v == null) return (value: null, usedField: false);
      final places = args.length > 1 ? (_num(args[1].value) ?? 0).round() : 0;
      return (value: _formatNumber(v, places), usedField: used);
  }
  return (value: null, usedField: false);
}

LabelEvalResult _str(List<LabelEvalResult> args, bool used, String Function(String) f) {
  final v = args.first.value;
  return (value: v == null ? null : f(_stringify(v)), usedField: used);
}

double? _num(Object? v) => switch (v) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s.trim()),
      _ => null,
    };

double _pow10(int n) {
  var f = 1.0;
  for (var i = 0; i < n; i++) {
    f *= 10;
  }
  return f;
}

/// QGIS の format_number: 3 桁ごとの区切りと小数桁
String _formatNumber(double v, int places) {
  final fixed = v.toStringAsFixed(places);
  final dot = fixed.indexOf('.');
  final intPart = dot < 0 ? fixed : fixed.substring(0, dot);
  final frac = dot < 0 ? '' : fixed.substring(dot);
  final neg = intPart.startsWith('-');
  final digits = neg ? intPart.substring(1) : intPart;
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '${neg ? '-' : ''}$buf$frac';
}

/// 値の文字列化。整数値の double は小数点なし（`1971.0` → `1971`）
String stringifyLabelValue(Object v) => _stringify(v);

String _stringify(Object v) {
  if (v is double && v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return v.toString();
}

/// 式を正規化した文字列に（保存形式・`.qgs` の fieldName）
String formatLabelExpression(LabelExpr e) {
  switch (e) {
    case FieldRef(:final name):
      return quoteField(name);
    case StringLit(:final value):
      return quoteString(value);
    case NumberLit(:final value):
      return _stringify(value);
    case NullLit():
      return 'NULL';
    case ConcatOp(:final parts):
      return parts.map((p) => p is ConcatOp ? '(${formatLabelExpression(p)})' : formatLabelExpression(p)).join(' || ');
    case FuncCall(:final name, :final args):
      return '$name(${args.map(formatLabelExpression).join(', ')})';
  }
}

String quoteField(String name) => '"${name.replaceAll('"', '""')}"';

String quoteString(String s) => "'${s.replaceAll("'", "''")}'";

/// 式に出てくる列名（重複なし・出現順）
List<String> labelExpressionFields(LabelExpr e) {
  final out = <String>[];
  void walk(LabelExpr x) {
    switch (x) {
      case FieldRef(:final name):
        if (!out.contains(name)) out.add(name);
      case ConcatOp(:final parts):
        parts.forEach(walk);
      case FuncCall(:final args):
        args.forEach(walk);
      case StringLit() || NumberLit() || NullLit():
        break;
    }
  }

  walk(e);
  return out;
}

// ── 字句・構文 ──────────────────────────────────────────

enum _Tok { str, field, ident, number, concat, lparen, rparen, comma, end }

class _Token {
  const _Token(this.type, this.text, this.offset);
  final _Tok type;
  final String text;
  final int offset;
}

class _Parser {
  _Parser(this.src);
  final String src;
  int _pos = 0;
  late _Token _cur = _next();

  static final _identStart = RegExp('[A-Za-z_À-￿]');
  static final _identBody = RegExp('[A-Za-z0-9_À-￿]');
  static final _numberRe = RegExp(r'^-?\d+(\.\d+)?');

  LabelExpr parseAll() {
    if (src.trim().isEmpty) throw const LabelExprParseException('空', 0);
    final e = _expr();
    if (_cur.type != _Tok.end) throw LabelExprParseException('余分な文字: ${_cur.text}', _cur.offset);
    return e;
  }

  LabelExpr _expr() {
    final parts = <LabelExpr>[_term()];
    while (_cur.type == _Tok.concat) {
      _cur = _next();
      parts.add(_term());
    }
    return parts.length == 1 ? parts.first : ConcatOp(parts);
  }

  LabelExpr _term() {
    final t = _cur;
    switch (t.type) {
      case _Tok.str:
        _cur = _next();
        return StringLit(t.text);
      case _Tok.field:
        _cur = _next();
        return FieldRef(t.text);
      case _Tok.number:
        _cur = _next();
        return NumberLit(double.parse(t.text));
      case _Tok.lparen:
        _cur = _next();
        final e = _expr();
        _expect(_Tok.rparen, ')');
        return e;
      case _Tok.ident:
        _cur = _next();
        if (t.text.toUpperCase() == 'NULL') return const NullLit();
        if (_cur.type == _Tok.lparen) {
          final name = t.text.toLowerCase();
          final arity = labelFunctions[name];
          if (arity == null) throw LabelExprParseException('知らない関数: ${t.text}', t.offset);
          _cur = _next();
          final args = <LabelExpr>[];
          if (_cur.type != _Tok.rparen) {
            args.add(_expr());
            while (_cur.type == _Tok.comma) {
              _cur = _next();
              args.add(_expr());
            }
          }
          _expect(_Tok.rparen, ')');
          if (args.length < arity.$1 || args.length > arity.$2) {
            throw LabelExprParseException('${t.text} の引数の数', t.offset);
          }
          return FuncCall(name, args);
        }
        return FieldRef(t.text); // 裸の名前は列
      case _Tok.rparen:
      case _Tok.comma:
      case _Tok.concat:
      case _Tok.end:
        throw LabelExprParseException('ここに値が要る', t.offset);
    }
  }

  void _expect(_Tok type, String what) {
    if (_cur.type != type) throw LabelExprParseException('$what が要る', _cur.offset);
    _cur = _next();
  }

  _Token _next() {
    while (_pos < src.length && src[_pos].trim().isEmpty) {
      _pos++;
    }
    if (_pos >= src.length) return _Token(_Tok.end, '', _pos);
    final start = _pos;
    final c = src[_pos];
    if (c == "'" || c == '"') {
      final buf = StringBuffer();
      _pos++;
      while (true) {
        if (_pos >= src.length) throw LabelExprParseException('引用符が閉じていない', start);
        if (src[_pos] == c) {
          if (_pos + 1 < src.length && src[_pos + 1] == c) {
            buf.write(c);
            _pos += 2;
            continue;
          }
          _pos++;
          break;
        }
        buf.write(src[_pos]);
        _pos++;
      }
      return _Token(c == "'" ? _Tok.str : _Tok.field, buf.toString(), start);
    }
    if (src.startsWith('||', _pos)) {
      _pos += 2;
      return _Token(_Tok.concat, '||', start);
    }
    if (c == '(') {
      _pos++;
      return _Token(_Tok.lparen, c, start);
    }
    if (c == ')') {
      _pos++;
      return _Token(_Tok.rparen, c, start);
    }
    if (c == ',') {
      _pos++;
      return _Token(_Tok.comma, c, start);
    }
    final num = _numberRe.firstMatch(src.substring(_pos));
    if (num != null && (c != '-' || num.end > 1)) {
      _pos += num.end;
      return _Token(_Tok.number, num.group(0)!, start);
    }
    if (_identStart.hasMatch(c)) {
      while (_pos < src.length && _identBody.hasMatch(src[_pos])) {
        _pos++;
      }
      return _Token(_Tok.ident, src.substring(start, _pos), start);
    }
    throw LabelExprParseException('読めない文字: $c', start);
  }
}
