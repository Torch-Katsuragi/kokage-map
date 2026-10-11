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
// こかげマップ: QGIS の式（フィルタ・値）の部分集合を、地物の属性で評価する
//
// QGIS のルールベースのレンダラのフィルタと、分類・段階のレンダラの「値」（列名か式）に使う。
// ラベルの式（label_expression.dart）は文字列を作るための別の木で、こちらは真偽と比較が要る。
//
// 飲めるもの:
//   "列名" / 裸の名前      列の値
//   '文字' 123 1.5 NULL TRUE FALSE
//   AND OR NOT
//   = <> != < <= > >=  LIKE ILIKE  NOT LIKE  IS [NOT] NULL  IS / IS NOT  [NOT] IN (…)  BETWEEN a AND b
//   + - * / %  ||  単項 -
//   CASE WHEN … THEN … [ELSE …] END
//   関数: lower upper trim length coalesce concat to_string to_int to_real round abs if
//         left right substr starts_with
//
// NULL は QGIS と同じく三値（比較の片方が NULL なら NULL、フィルタでは偽）。
// それ以外は読めない（[QgisExpressionParseException]）。呼び出し側は代表の色に戻す。

/// 式の木（評価用にコンパイル済み）
abstract class QgisExpr {
  const QgisExpr();

  Object? eval(Map<String, Object?>? props);

  /// フィルタとして評価（NULL は偽）
  bool test(Map<String, Object?>? props) => qgisTruthy(eval(props)) == true;
}

class QgisExpressionParseException implements Exception {
  const QgisExpressionParseException(this.message, this.offset);
  final String message;
  final int offset;

  @override
  String toString() => 'QgisExpressionParseException($offset): $message';
}

/// 式を読む。読めなければ [QgisExpressionParseException]
QgisExpr parseQgisExpression(String src) => _Parser(src).parseAll();

/// 式を読む。読めなければ null
QgisExpr? tryParseQgisExpression(String src) {
  try {
    return parseQgisExpression(src);
  } on QgisExpressionParseException {
    return null;
  }
}

/// QGIS の真偽（NULL は null）
bool? qgisTruthy(Object? v) => switch (v) {
      null => null,
      final bool b => b,
      final num n => n != 0,
      final String s => s.isNotEmpty && s.toLowerCase() != 'false' && s != '0',
      _ => true,
    };

/// 数として読めれば数
double? qgisToNumber(Object? v) => switch (v) {
      final num n => n.toDouble(),
      final bool b => b ? 1 : 0,
      final String s => double.tryParse(s.trim()),
      _ => null,
    };

/// 文字列化（整数値の double は小数点なし）
String qgisToText(Object v) {
  if (v is double && v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  if (v is bool) return v ? 'true' : 'false';
  return v.toString();
}

/// QGIS の比較: 両方が数として読めれば数で、そうでなければ文字列で。NULL が混じれば null
int? qgisCompare(Object? a, Object? b) {
  if (a == null || b == null) return null;
  final na = qgisToNumber(a);
  final nb = qgisToNumber(b);
  if (na != null && nb != null) return na.compareTo(nb);
  return qgisToText(a).compareTo(qgisToText(b));
}

// ── 木 ──────────────────────────────────────────

class _Lit extends QgisExpr {
  const _Lit(this.value);
  final Object? value;
  @override
  Object? eval(Map<String, Object?>? props) => value;
}

class _Field extends QgisExpr {
  const _Field(this.name);
  final String name;
  @override
  Object? eval(Map<String, Object?>? props) => props?[name];
}

class _Not extends QgisExpr {
  const _Not(this.e);
  final QgisExpr e;
  @override
  Object? eval(Map<String, Object?>? props) {
    final v = qgisTruthy(e.eval(props));
    return v == null ? null : !v;
  }
}

class _Neg extends QgisExpr {
  const _Neg(this.e);
  final QgisExpr e;
  @override
  Object? eval(Map<String, Object?>? props) {
    final v = qgisToNumber(e.eval(props));
    return v == null ? null : -v;
  }
}

class _And extends QgisExpr {
  const _And(this.a, this.b);
  final QgisExpr a, b;
  @override
  Object? eval(Map<String, Object?>? props) {
    final x = qgisTruthy(a.eval(props));
    if (x == false) return false;
    final y = qgisTruthy(b.eval(props));
    if (y == false) return false;
    if (x == null || y == null) return null;
    return true;
  }
}

class _Or extends QgisExpr {
  const _Or(this.a, this.b);
  final QgisExpr a, b;
  @override
  Object? eval(Map<String, Object?>? props) {
    final x = qgisTruthy(a.eval(props));
    if (x == true) return true;
    final y = qgisTruthy(b.eval(props));
    if (y == true) return true;
    if (x == null || y == null) return null;
    return false;
  }
}

class _Cmp extends QgisExpr {
  const _Cmp(this.op, this.a, this.b);
  final String op;
  final QgisExpr a, b;
  @override
  Object? eval(Map<String, Object?>? props) {
    final c = qgisCompare(a.eval(props), b.eval(props));
    if (c == null) return null;
    return switch (op) {
      '=' => c == 0,
      '<>' => c != 0,
      '<' => c < 0,
      '<=' => c <= 0,
      '>' => c > 0,
      _ => c >= 0, // '>='
    };
  }
}

/// `IS` / `IS NOT`（NULL どうしも比べられる。結果は NULL にならない）
class _Is extends QgisExpr {
  const _Is(this.a, this.b, {required this.negate});
  final QgisExpr a, b;
  final bool negate;
  @override
  Object? eval(Map<String, Object?>? props) {
    final x = a.eval(props);
    final y = b.eval(props);
    final same = (x == null || y == null) ? (x == null && y == null) : qgisCompare(x, y) == 0;
    return negate ? !same : same;
  }
}

class _In extends QgisExpr {
  const _In(this.a, this.list, {required this.negate});
  final QgisExpr a;
  final List<QgisExpr> list;
  final bool negate;
  @override
  Object? eval(Map<String, Object?>? props) {
    final x = a.eval(props);
    if (x == null) return null;
    var sawNull = false;
    for (final e in list) {
      final c = qgisCompare(x, e.eval(props));
      if (c == null) {
        sawNull = true;
      } else if (c == 0) {
        return !negate;
      }
    }
    if (sawNull) return null;
    return negate;
  }
}

class _Like extends QgisExpr {
  _Like(this.a, this.pattern, {required this.caseInsensitive, required this.negate});
  final QgisExpr a, pattern;
  final bool caseInsensitive;
  final bool negate;
  final Map<String, RegExp> _cache = {};

  @override
  Object? eval(Map<String, Object?>? props) {
    final x = a.eval(props);
    final p = pattern.eval(props);
    if (x == null || p == null) return null;
    final re = _cache.putIfAbsent(qgisToText(p), () => _likeToRegExp(qgisToText(p), caseInsensitive));
    final m = re.hasMatch(qgisToText(x));
    return negate ? !m : m;
  }

  static RegExp _likeToRegExp(String like, bool ci) {
    final buf = StringBuffer('^');
    for (var i = 0; i < like.length; i++) {
      final c = like[i];
      if (c == r'\' && i + 1 < like.length) {
        buf.write(RegExp.escape(like[++i]));
      } else if (c == '%') {
        buf.write('.*');
      } else if (c == '_') {
        buf.write('.');
      } else {
        buf.write(RegExp.escape(c));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString(), caseSensitive: !ci, dotAll: true);
  }
}

class _Arith extends QgisExpr {
  const _Arith(this.op, this.a, this.b);
  final String op;
  final QgisExpr a, b;
  @override
  Object? eval(Map<String, Object?>? props) {
    final x = a.eval(props);
    final y = b.eval(props);
    if (x == null || y == null) return null;
    if (op == '||') return qgisToText(x) + qgisToText(y);
    final nx = qgisToNumber(x);
    final ny = qgisToNumber(y);
    if (op == '+' && (nx == null || ny == null) && x is String && y is String) return x + y;
    if (nx == null || ny == null) return null;
    return switch (op) {
      '+' => nx + ny,
      '-' => nx - ny,
      '*' => nx * ny,
      '/' => ny == 0 ? null : nx / ny,
      _ => ny == 0 ? null : nx % ny, // '%'
    };
  }
}

class _Case extends QgisExpr {
  const _Case(this.whens, this.otherwise);
  final List<(QgisExpr, QgisExpr)> whens;
  final QgisExpr? otherwise;
  @override
  Object? eval(Map<String, Object?>? props) {
    for (final (cond, value) in whens) {
      if (cond.test(props)) return value.eval(props);
    }
    return otherwise?.eval(props);
  }
}

class _Func extends QgisExpr {
  const _Func(this.name, this.args);
  final String name;
  final List<QgisExpr> args;

  @override
  Object? eval(Map<String, Object?>? props) {
    // if / coalesce は引数を必要なぶんだけ評価する
    if (name == 'if') {
      return args[0].test(props) ? args[1].eval(props) : (args.length > 2 ? args[2].eval(props) : null);
    }
    if (name == 'coalesce') {
      for (final a in args) {
        final v = a.eval(props);
        if (v != null) return v;
      }
      return null;
    }
    final v = [for (final a in args) a.eval(props)];
    if (name == 'concat') return v.map((x) => x == null ? '' : qgisToText(x)).join();
    final first = v.first;
    if (first == null) return null;
    String s() => qgisToText(first);
    int n(int i) => (qgisToNumber(v[i]) ?? 0).round();
    switch (name) {
      case 'lower':
        return s().toLowerCase();
      case 'upper':
        return s().toUpperCase();
      case 'trim':
        return s().trim();
      case 'length':
        return s().length;
      case 'to_string':
        return s();
      case 'to_int':
        return qgisToNumber(first)?.truncate();
      case 'to_real':
        return qgisToNumber(first);
      case 'abs':
        return qgisToNumber(first)?.abs();
      case 'round':
        final x = qgisToNumber(first);
        if (x == null) return null;
        final places = v.length > 1 ? n(1) : 0;
        var f = 1.0;
        for (var i = 0; i < places; i++) {
          f *= 10;
        }
        return (x * f).round() / f;
      case 'left':
        final str = s();
        return str.substring(0, n(1).clamp(0, str.length));
      case 'right':
        final str = s();
        return str.substring(str.length - n(1).clamp(0, str.length));
      case 'substr':
        // QGIS は 1 始まり。負の開始は末尾から
        final str = s();
        var start = n(1);
        start = start < 0 ? str.length + start : start - 1;
        start = start.clamp(0, str.length);
        final len = v.length > 2 ? n(2) : str.length - start;
        return str.substring(start, (start + len).clamp(start, str.length));
      case 'starts_with':
        final p = v[1];
        return p == null ? null : s().startsWith(qgisToText(p));
    }
    return null;
  }
}

/// 飲める関数と引数の数（最小, 最大）
const Map<String, (int, int)> _functions = {
  'lower': (1, 1),
  'upper': (1, 1),
  'trim': (1, 1),
  'length': (1, 1),
  'to_string': (1, 1),
  'to_int': (1, 1),
  'to_real': (1, 1),
  'abs': (1, 1),
  'round': (1, 2),
  'coalesce': (1, 1 << 30),
  'concat': (1, 1 << 30),
  'if': (2, 3),
  'left': (2, 2),
  'right': (2, 2),
  'substr': (2, 3),
  'starts_with': (2, 2),
};

// ── 字句 ──────────────────────────────────────────

enum _T { str, field, ident, number, op, lparen, rparen, comma, end }

class _Tok {
  const _Tok(this.type, this.text, this.offset);
  final _T type;
  final String text;
  final int offset;

  bool isKw(String kw) => type == _T.ident && text.toUpperCase() == kw;
  bool isOp(String o) => type == _T.op && text == o;
}

class _Parser {
  _Parser(this.src) {
    _tokenize();
  }

  final String src;
  final List<_Tok> _toks = [];
  int _i = 0;

  _Tok get _cur => _toks[_i];
  _Tok _take() => _toks[_i++];
  _Tok get _peek => _toks[_i + 1 < _toks.length ? _i + 1 : _i];

  static final _identStart = RegExp('[A-Za-z_À-￿]');
  static final _identBody = RegExp('[A-Za-z0-9_À-￿]');
  static final _numberRe = RegExp(r'\d+(\.\d+)?([eE][-+]?\d+)?|\.\d+');
  static const _ops = ['<>', '!=', '<=', '>=', '||', '=', '<', '>', '+', '-', '*', '/', '%'];

  void _tokenize() {
    var pos = 0;
    while (true) {
      while (pos < src.length && src[pos].trim().isEmpty) {
        pos++;
      }
      if (pos >= src.length) break;
      final start = pos;
      final c = src[pos];
      if (c == "'" || c == '"') {
        final buf = StringBuffer();
        pos++;
        while (true) {
          if (pos >= src.length) throw QgisExpressionParseException('引用符が閉じていない', start);
          if (src[pos] == c) {
            if (pos + 1 < src.length && src[pos + 1] == c) {
              buf.write(c);
              pos += 2;
              continue;
            }
            pos++;
            break;
          }
          // QGIS は文字列の中の \' も受ける
          if (c == "'" && src[pos] == r'\' && pos + 1 < src.length) {
            buf.write(src[pos + 1]);
            pos += 2;
            continue;
          }
          buf.write(src[pos]);
          pos++;
        }
        _toks.add(_Tok(c == "'" ? _T.str : _T.field, buf.toString(), start));
        continue;
      }
      if (c == '(' || c == ')' || c == ',') {
        _toks.add(_Tok(c == '(' ? _T.lparen : (c == ')' ? _T.rparen : _T.comma), c, start));
        pos++;
        continue;
      }
      final num = _numberRe.matchAsPrefix(src, pos);
      if (num != null) {
        pos = num.end;
        _toks.add(_Tok(_T.number, num.group(0)!, start));
        continue;
      }
      final op = _ops.where((o) => src.startsWith(o, pos)).firstOrNull;
      if (op != null) {
        pos += op.length;
        _toks.add(_Tok(_T.op, op == '!=' ? '<>' : op, start));
        continue;
      }
      if (_identStart.hasMatch(c)) {
        while (pos < src.length && _identBody.hasMatch(src[pos])) {
          pos++;
        }
        _toks.add(_Tok(_T.ident, src.substring(start, pos), start));
        continue;
      }
      throw QgisExpressionParseException('読めない文字: $c', start);
    }
    _toks.add(_Tok(_T.end, '', src.length));
  }

  QgisExpr parseAll() {
    if (src.trim().isEmpty) throw const QgisExpressionParseException('空', 0);
    final e = _or();
    if (_cur.type != _T.end) throw QgisExpressionParseException('余分な文字: ${_cur.text}', _cur.offset);
    return e;
  }

  QgisExpr _or() {
    var e = _and();
    while (_cur.isKw('OR')) {
      _take();
      e = _Or(e, _and());
    }
    return e;
  }

  QgisExpr _and() {
    var e = _not();
    while (_cur.isKw('AND')) {
      _take();
      e = _And(e, _not());
    }
    return e;
  }

  QgisExpr _not() {
    if (_cur.isKw('NOT')) {
      _take();
      return _Not(_not());
    }
    return _comparison();
  }

  QgisExpr _comparison() {
    final left = _additive();
    final t = _cur;
    if (t.type == _T.op && const ['=', '<>', '<', '<=', '>', '>='].contains(t.text)) {
      _take();
      return _Cmp(t.text, left, _additive());
    }
    if (t.isKw('IS')) {
      _take();
      final negate = _cur.isKw('NOT');
      if (negate) _take();
      return _Is(left, _additive(), negate: negate);
    }
    var negate = false;
    if (t.isKw('NOT') && (_peek.isKw('IN') || _peek.isKw('LIKE') || _peek.isKw('ILIKE') || _peek.isKw('BETWEEN'))) {
      _take();
      negate = true;
    }
    if (_cur.isKw('IN')) {
      _take();
      _expect(_T.lparen, '(');
      final list = <QgisExpr>[];
      if (_cur.type != _T.rparen) {
        list.add(_or());
        while (_cur.type == _T.comma) {
          _take();
          list.add(_or());
        }
      }
      _expect(_T.rparen, ')');
      return _In(left, list, negate: negate);
    }
    if (_cur.isKw('LIKE') || _cur.isKw('ILIKE')) {
      final ci = _take().text.toUpperCase() == 'ILIKE';
      return _Like(left, _additive(), caseInsensitive: ci, negate: negate);
    }
    if (_cur.isKw('BETWEEN')) {
      _take();
      final lo = _additive();
      if (!_cur.isKw('AND')) throw QgisExpressionParseException('BETWEEN に AND が要る', _cur.offset);
      _take();
      final hi = _additive();
      final e = _And(_Cmp('>=', left, lo), _Cmp('<=', left, hi));
      return negate ? _Not(e) : e;
    }
    if (negate) throw QgisExpressionParseException('NOT の後が読めない', t.offset);
    return left;
  }

  QgisExpr _additive() {
    var e = _multiplicative();
    while (_cur.type == _T.op && (_cur.text == '+' || _cur.text == '-' || _cur.text == '||')) {
      final op = _take().text;
      e = _Arith(op, e, _multiplicative());
    }
    return e;
  }

  QgisExpr _multiplicative() {
    var e = _unary();
    while (_cur.type == _T.op && (_cur.text == '*' || _cur.text == '/' || _cur.text == '%')) {
      final op = _take().text;
      e = _Arith(op, e, _unary());
    }
    return e;
  }

  QgisExpr _unary() {
    if (_cur.isOp('-')) {
      _take();
      return _Neg(_unary());
    }
    if (_cur.isOp('+')) {
      _take();
      return _unary();
    }
    return _primary();
  }

  QgisExpr _primary() {
    final t = _take();
    switch (t.type) {
      case _T.str:
        return _Lit(t.text);
      case _T.field:
        return _Field(t.text);
      case _T.number:
        return _Lit(t.text.contains(RegExp('[.eE]')) ? double.parse(t.text) : int.parse(t.text));
      case _T.lparen:
        final e = _or();
        _expect(_T.rparen, ')');
        return e;
      case _T.ident:
        final up = t.text.toUpperCase();
        if (up == 'NULL') return const _Lit(null);
        if (up == 'TRUE') return const _Lit(true);
        if (up == 'FALSE') return const _Lit(false);
        if (up == 'CASE') return _case();
        if (_cur.type == _T.lparen) return _func(t);
        if (const {'AND', 'OR', 'NOT', 'IN', 'LIKE', 'ILIKE', 'IS', 'WHEN', 'THEN', 'ELSE', 'END'}.contains(up)) {
          throw QgisExpressionParseException('ここに値が要る', t.offset);
        }
        return _Field(t.text); // 裸の名前は列
      case _T.op:
      case _T.rparen:
      case _T.comma:
      case _T.end:
        throw QgisExpressionParseException('ここに値が要る', t.offset);
    }
  }

  QgisExpr _case() {
    final whens = <(QgisExpr, QgisExpr)>[];
    while (_cur.isKw('WHEN')) {
      _take();
      final cond = _or();
      if (!_cur.isKw('THEN')) throw QgisExpressionParseException('THEN が要る', _cur.offset);
      _take();
      whens.add((cond, _or()));
    }
    if (whens.isEmpty) throw QgisExpressionParseException('WHEN が要る', _cur.offset);
    QgisExpr? otherwise;
    if (_cur.isKw('ELSE')) {
      _take();
      otherwise = _or();
    }
    if (!_cur.isKw('END')) throw QgisExpressionParseException('END が要る', _cur.offset);
    _take();
    return _Case(whens, otherwise);
  }

  QgisExpr _func(_Tok t) {
    final name = t.text.toLowerCase();
    final arity = _functions[name];
    if (arity == null) throw QgisExpressionParseException('知らない関数: ${t.text}', t.offset);
    _expect(_T.lparen, '(');
    final args = <QgisExpr>[];
    if (_cur.type != _T.rparen) {
      args.add(_or());
      while (_cur.type == _T.comma) {
        _take();
        args.add(_or());
      }
    }
    _expect(_T.rparen, ')');
    if (args.length < arity.$1 || args.length > arity.$2) {
      throw QgisExpressionParseException('${t.text} の引数の数', t.offset);
    }
    return _Func(name, args);
  }

  void _expect(_T type, String what) {
    if (_cur.type != type) throw QgisExpressionParseException('$what が要る', _cur.offset);
    _take();
  }
}
