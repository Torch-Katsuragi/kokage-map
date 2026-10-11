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
// こかげマップ: QGIS の描き分け（分類・段階・ルール）のレンダラ
//
// `.qgs` の `<renderer-v2>` を読んだもの（`QgsRendererReader`）。フォルダ設定のスタイル
// （[KMetaLayerStyle.qgisRendererDef]）に入れて持ち、地物ごとにどのシンボルで描くかを決める。
// `.qgs` のレンダラそのものは書き換えない（不変条件4）ので、ここは読んだ写し。
// 設計は [[docs/technical/qgis-interop#描き分け（分類・段階・ルール）の再現]]。

import '../utils/app_logger.dart';
import '../utils/qgis_expression.dart';
import 'kmeta.dart';

enum QgisRendererKind {
  categorized('categorizedSymbol'),
  graduated('graduatedSymbol'),
  rule('RuleRenderer');

  const QgisRendererKind(this.qgisType);

  /// `<renderer-v2 type=…>`
  final String qgisType;

  static QgisRendererKind? fromQgisType(String? type) =>
      values.where((k) => k.qgisType == type).firstOrNull;
}

/// 凡例の 1 行＝シンボル 1 つ（分類の 1 項目・段階の 1 範囲・シンボルを持つルール 1 つ）
class QgisRendererClass {
  const QgisRendererClass({
    required this.label,
    this.style,
    this.render = true,
    this.values = const [],
    this.lower,
    this.upper,
  });

  final String label;

  /// シンボルの見た目（色・太さ）。読めないシンボルなら null（代表の色で描く）
  final KMetaLayerStyle? style;

  /// 分類・段階でチェックを外した（描かない）項目なら false
  final bool render;

  /// 分類の値（複数値の項目もある）。空なら「その他の値すべて」
  final List<String?> values;

  /// 段階の範囲
  final double? lower;
  final double? upper;

  /// 分類の「その他の値すべて」
  bool get isDefaultCategory => values.isEmpty || values.every((v) => v == null || v.isEmpty);

  factory QgisRendererClass.fromJson(Map<String, dynamic> json) => QgisRendererClass(
        label: json['label'] as String? ?? '',
        style: json['style'] is Map<String, dynamic>
            ? KMetaLayerStyle.fromJson(json['style'] as Map<String, dynamic>)
            : null,
        render: json['render'] as bool? ?? true,
        values: [for (final v in (json['values'] as List<dynamic>? ?? const [])) v as String?],
        lower: (json['lower'] as num?)?.toDouble(),
        upper: (json['upper'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        if (style != null) 'style': style!.toJson(),
        if (!render) 'render': false,
        if (values.isNotEmpty) 'values': values,
        if (lower != null) 'lower': lower,
        if (upper != null) 'upper': upper,
      };
}

/// ルールベースのルール 1 つ
class QgisRule {
  const QgisRule({
    this.filter,
    this.isElse = false,
    this.active = true,
    this.classIndex,
    this.children = const [],
  });

  /// フィルタの式。null なら全部に当たる
  final String? filter;
  final bool isElse;

  /// チェックを外したルールは子も含めて無いもの扱い
  final bool active;

  /// シンボルを持つルールなら [QgisRenderer.classes] の添字
  final int? classIndex;
  final List<QgisRule> children;

  factory QgisRule.fromJson(Map<String, dynamic> json) => QgisRule(
        filter: json['filter'] as String?,
        isElse: json['else'] as bool? ?? false,
        active: json['active'] as bool? ?? true,
        classIndex: json['class'] as int?,
        children: [
          for (final c in (json['children'] as List<dynamic>? ?? const []))
            QgisRule.fromJson(c as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        if (filter != null) 'filter': filter,
        if (isElse) 'else': true,
        if (!active) 'active': false,
        if (classIndex != null) 'class': classIndex,
        if (children.isNotEmpty) 'children': [for (final c in children) c.toJson()],
      };
}

/// 描き分けのレンダラ（分類・段階・ルール）
class QgisRenderer {
  QgisRenderer({
    required this.kind,
    this.attr,
    required this.classes,
    this.rules = const [],
  });

  final QgisRendererKind kind;

  /// 分類・段階の値（列名か式）
  final String? attr;

  /// 凡例の並び（＝シンボル）
  final List<QgisRendererClass> classes;

  /// ルールベースの最上位のルール（根のルールの子）
  final List<QgisRule> rules;

  factory QgisRenderer.fromJson(Map<String, dynamic> json) => QgisRenderer(
        kind: QgisRendererKind.values.byName(json['kind'] as String),
        attr: json['attr'] as String?,
        classes: [
          for (final c in (json['classes'] as List<dynamic>? ?? const []))
            QgisRendererClass.fromJson(c as Map<String, dynamic>),
        ],
        rules: [
          for (final r in (json['rules'] as List<dynamic>? ?? const [])) QgisRule.fromJson(r as Map<String, dynamic>),
        ],
      );

  /// 読めない JSON なら null（古い版・壊れた設定は単に代表の色で描く）
  static QgisRenderer? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return QgisRenderer.fromJson(json);
    } on Object catch (e) {
      AppLogger.debug('[QgisRenderer] 読めない: $e');
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (attr != null) 'attr': attr,
        'classes': [for (final c in classes) c.toJson()],
        if (rules.isNotEmpty) 'rules': [for (final r in rules) r.toJson()],
      };

  /// 地物ごとの評価器。式が読めなければ null（そのレンダラは代表の色で描く）
  late final QgisRendererEvaluator? evaluator = QgisRendererEvaluator._compile(this);
}

/// 地物の属性 → どのシンボル（[QgisRenderer.classes] の添字）で描くか
abstract class QgisRendererEvaluator {
  const QgisRendererEvaluator();

  /// 描かないなら null。ルールで複数当たったときは、QGIS でいちばん上に描かれるもの（最後に当たったもの）
  int? classFor(Map<String, Object?>? props);

  /// 式が読めなかったものは一度だけログに出す
  static final Set<String> _logged = {};

  static QgisRendererEvaluator? _compile(QgisRenderer r) {
    try {
      return switch (r.kind) {
        QgisRendererKind.categorized => _CategorizedEval(r, _value(r.attr)),
        QgisRendererKind.graduated => _GraduatedEval(r, _value(r.attr)),
        QgisRendererKind.rule => _RuleEval([for (final rule in r.rules) _compileRule(rule)]),
      };
    } on QgisExpressionParseException catch (e) {
      final key = '${r.kind.name} ${r.attr} $e';
      if (_logged.add(key)) {
        AppLogger.debug('[QgisRenderer] 式を読めないので代表の色で描く（${r.kind.qgisType}）: $e');
      }
      return null;
    }
  }

  /// 列名か式。QGIS は列名をそのまま（`樹種`）、式なら `"林齢"` のように書く
  static QgisExpr _value(String? attr) {
    if (attr == null || attr.trim().isEmpty) throw const QgisExpressionParseException('値が無い', 0);
    // 裸の名前（列名）。空白や記号を含む列名も QGIS は引用符なしで書くので、式として読めなければ列名とみなす
    final asExpr = tryParseQgisExpression(attr);
    if (asExpr != null) return asExpr;
    return parseQgisExpression('"${attr.replaceAll('"', '""')}"');
  }

  static _CompiledRule _compileRule(QgisRule rule) {
    final f = rule.filter?.trim();
    return _CompiledRule(
      filter: (f == null || f.isEmpty || rule.isElse) ? null : parseQgisExpression(f),
      isElse: rule.isElse,
      active: rule.active,
      classIndex: rule.classIndex,
      children: [for (final c in rule.children) _compileRule(c)],
    );
  }
}

/// 分類の値の突き合わせ用キー（数として読めれば数の表記にそろえる。`5` と `5.0` と `'5'` を同じに）
String _categoryKey(Object v) {
  final n = qgisToNumber(v);
  return n != null ? qgisToText(n) : qgisToText(v);
}

class _CategorizedEval extends QgisRendererEvaluator {
  _CategorizedEval(QgisRenderer r, this.value) {
    for (var i = 0; i < r.classes.length; i++) {
      final c = r.classes[i];
      if (c.isDefaultCategory) {
        defaultIndex ??= i;
        continue;
      }
      for (final v in c.values) {
        if (v != null) byKey.putIfAbsent(_categoryKey(v), () => i);
      }
    }
    render = [for (final c in r.classes) c.render];
  }

  final QgisExpr value;
  final Map<String, int> byKey = {};
  int? defaultIndex;
  late final List<bool> render;

  @override
  int? classFor(Map<String, Object?>? props) {
    final v = value.eval(props);
    final i = (v == null ? null : byKey[_categoryKey(v)]) ?? defaultIndex;
    if (i == null || !render[i]) return null;
    return i;
  }
}

class _GraduatedEval extends QgisRendererEvaluator {
  _GraduatedEval(this.r, this.value);
  final QgisRenderer r;
  final QgisExpr value;

  @override
  int? classFor(Map<String, Object?>? props) {
    final v = qgisToNumber(value.eval(props));
    if (v == null) return null;
    for (var i = 0; i < r.classes.length; i++) {
      final c = r.classes[i];
      final lo = c.lower, hi = c.upper;
      if (lo == null || hi == null) continue;
      // QGIS の rangeForValue: 並び順で最初に lower <= v <= upper のもの
      if (lo <= v && v <= hi) return c.render ? i : null;
    }
    return null;
  }
}

class _CompiledRule {
  const _CompiledRule({
    required this.filter,
    required this.isElse,
    required this.active,
    required this.classIndex,
    required this.children,
  });

  final QgisExpr? filter;
  final bool isElse;
  final bool active;
  final int? classIndex;
  final List<_CompiledRule> children;
}

class _RuleEval extends QgisRendererEvaluator {
  _RuleEval(this.rules);
  final List<_CompiledRule> rules;

  @override
  int? classFor(Map<String, Object?>? props) {
    final drawn = <int>[];
    _children(rules, props, drawn);
    return drawn.isEmpty ? null : drawn.last;
  }

  /// QGIS の Rule::renderFeature と同じ順で辿る。ELSE は兄弟のどれも描かなかったときだけ
  bool _children(List<_CompiledRule> rules, Map<String, Object?>? props, List<int> drawn) {
    var rendered = false;
    for (final r in rules) {
      if (!r.active || r.isElse) continue;
      rendered |= _rule(r, props, drawn);
    }
    if (!rendered) {
      for (final r in rules) {
        if (!r.active || !r.isElse) continue;
        rendered |= _rule(r, props, drawn);
      }
    }
    return rendered;
  }

  bool _rule(_CompiledRule r, Map<String, Object?>? props, List<int> drawn) {
    if (r.filter != null && !r.filter!.test(props)) return false;
    var rendered = false;
    if (r.classIndex != null) {
      drawn.add(r.classIndex!);
      rendered = true;
    }
    if (_children(r.children, props, drawn)) rendered = true;
    return rendered;
  }
}
