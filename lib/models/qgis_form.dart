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
// こかげマップ: QGIS の属性フォームの設定（編集ウィジェット・別名・既定値・制約・読み取り専用・配置）
//
// `.qgs` の `<maplayer>` の `<fieldConfiguration>` などを読んだもの（`QgsFormReader`）。フォルダ設定
// （[KMeta.forms]、鍵はレイヤキー）に持ち、属性フォーム・編集パネル・属性テーブルの入力に使う。
// `.qgs` の側は QGIS の持ち物なので書き換えない（読んだ写し）。
// 設計は [[docs/technical/qgis-interop#属性フォーム（編集ウィジェット・既定値・制約）]]。

import 'dart:math' as math;

/// 制約の強さ（QGIS の `notnull_strength` などの 0/1/2）
enum QgisConstraintStrength {
  none,

  /// 守らないと保存しない
  hard,

  /// 警告するが保存する
  soft;

  static QgisConstraintStrength fromQgis(String? v) => switch (v) {
        '1' => hard,
        '2' => soft,
        _ => none,
      };
}

/// 編集ウィジェットの種類（QGIS の `<editWidget type=…>`）
enum QgisWidgetKind {
  valueMap('ValueMap'),
  checkBox('CheckBox'),
  dateTime('DateTime'),
  range('Range'),
  textEdit('TextEdit'),
  uniqueValues('UniqueValues'),
  hidden('Hidden'),
  valueRelation('ValueRelation'),

  /// 知らない種類（文字の欄で出す）
  other('');

  const QgisWidgetKind(this.qgisType);
  final String qgisType;

  static QgisWidgetKind fromQgis(String? type) =>
      values.where((k) => k != other && k.qgisType == type).firstOrNull ?? other;
}

/// 値と表示名の組（ValueMap・ValueRelation の選択肢）
class QgisValueOption {
  const QgisValueOption(this.value, this.label);
  final String value;
  final String label;
}

/// 1 列の設定
class QgisFieldForm {
  const QgisFieldForm({
    required this.name,
    this.alias,
    this.widgetType = '',
    this.config = const {},
    this.defaultExpression,
    this.applyDefaultOnUpdate = false,
    this.notNull = QgisConstraintStrength.none,
    this.unique = QgisConstraintStrength.none,
    this.expression,
    this.expressionDescription,
    this.expressionStrength = QgisConstraintStrength.none,
    this.readOnly = false,
  });

  final String name;

  /// 別名（空なら null）
  final String? alias;

  /// `<editWidget type=…>` そのまま（知らない種類も持ち帰る）
  final String widgetType;

  /// `<config><Option type="Map">` を Dart の値にしたもの（Map・List・文字・数・真偽）
  final Map<String, Object?> config;

  /// 既定値の式（空なら null）
  final String? defaultExpression;

  /// 更新のときも既定値を当て直す（QGIS の applyOnUpdate）
  final bool applyDefaultOnUpdate;

  final QgisConstraintStrength notNull;
  final QgisConstraintStrength unique;

  /// 式の制約（空なら null）と説明
  final String? expression;
  final String? expressionDescription;
  final QgisConstraintStrength expressionStrength;

  /// QGIS で「編集可能」を外した列
  final bool readOnly;

  QgisWidgetKind get kind => QgisWidgetKind.fromQgis(widgetType);

  /// 欄の名前（別名があれば別名）
  String get label => alias ?? name;

  bool get hidden => kind == QgisWidgetKind.hidden;

  bool get hasConstraint =>
      notNull != QgisConstraintStrength.none ||
      unique != QgisConstraintStrength.none ||
      (expression != null && expressionStrength != QgisConstraintStrength.none);

  /// 何も設定していない列（持たない）
  bool get isEmpty =>
      alias == null &&
      widgetType.isEmpty &&
      defaultExpression == null &&
      !hasConstraint &&
      !readOnly;

  // ── ウィジェットの設定 ──

  Object? _opt(String key) => config[key];

  String? _str(String key) {
    final v = _opt(key);
    if (v == null) return null;
    final s = '$v';
    return s.isEmpty ? null : s;
  }

  bool _bool(String key, {bool fallback = false}) {
    final v = _opt(key);
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == 'true' || v == '1';
    return fallback;
  }

  double? _num(String key) {
    final v = _opt(key);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// ValueMap の選択肢（並びは QGIS のまま）。表示名 → 値の Map の並び、または古い形の Map
  List<QgisValueOption> get valueMapOptions {
    final map = _opt('map');
    final out = <QgisValueOption>[];
    void add(Object? m) {
      if (m is! Map) return;
      for (final e in m.entries) {
        out.add(QgisValueOption('${e.value ?? ''}', '${e.key}'));
      }
    }

    if (map is List) {
      map.forEach(add);
    } else {
      add(map);
    }
    // QGIS の「NULL」の項目（値が `{2839923C-8B7D-419E-B84B-CA2FE9B80EC7}`）は空にする
    return [
      for (final o in out)
        o.value == kQgisValueMapNull ? QgisValueOption('', o.label) : o,
    ];
  }

  String? get checkedState => _str('CheckedState');
  String? get uncheckedState => _str('UncheckedState');

  /// 保存する形（Qt の書式。DateTime の `field_format`）
  String? get fieldFormat => _str('field_format');

  /// 見せる形（Qt の書式。`display_format`）
  String? get displayFormat => _str('display_format');

  bool get allowNull => _bool('allow_null', fallback: _bool('AllowNull', fallback: true));

  double? get rangeMin => _num('Min');
  double? get rangeMax => _num('Max');
  double? get rangeStep => _num('Step');
  int? get rangePrecision => _num('Precision')?.round();
  bool get rangeSlider => _str('Style') == 'Slider' || _str('Style') == 'Dial';

  bool get multiline => _bool('IsMultiline');

  /// UniqueValues で一覧に無い値も打てるか
  bool get uniqueEditable => _bool('Editable');

  // ValueRelation
  String? get relationKey => _str('Key');
  String? get relationValue => _str('Value');
  String? get relationFilter => _str('FilterExpression');
  bool get relationOrderByValue => _bool('OrderByValue');
  bool get relationAllowMulti => _bool('AllowMulti');

  /// 参照先のレイヤ（取り込みで解決した、この列のフォルダからの gpkg の相対パスとレイヤ名）
  ({String gpkg, String layer})? get relationTarget {
    final t = _opt(kRelationTargetKey);
    if (t is! Map) return null;
    final g = t['gpkg'];
    final l = t['layer'];
    if (g is! String || l is! String) return null;
    return (gpkg: g, layer: l);
  }

  /// 保存した値を見せる形にする（ValueMap は表示名、チェックボックスはそのまま、日付は見せる書式）
  String displayText(Object? value) {
    if (value == null) return '';
    final text = '$value';
    switch (kind) {
      case QgisWidgetKind.valueMap:
        return valueMapOptions.where((o) => o.value == text).firstOrNull?.label ?? text;
      case QgisWidgetKind.dateTime:
        final d = parseStoredDate(value);
        final fmt = displayFormat ?? fieldFormat;
        return d == null || fmt == null ? text : formatQtDate(d, fmt);
      default:
        return text;
    }
  }

  /// 保存されている日付の値を読む（field_format・ISO の順に試す）
  DateTime? parseStoredDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final s = '$value'.trim();
    if (s.isEmpty) return null;
    final fmt = fieldFormat;
    if (fmt != null) {
      final d = parseQtDate(s, fmt);
      if (d != null) return d;
    }
    return DateTime.tryParse(s);
  }

  factory QgisFieldForm.fromJson(Map<String, dynamic> json) => QgisFieldForm(
        name: json['name'] as String,
        alias: json['alias'] as String?,
        widgetType: json['widget'] as String? ?? '',
        config: (json['config'] as Map?)?.cast<String, Object?>() ?? const {},
        defaultExpression: json['default'] as String?,
        applyDefaultOnUpdate: json['defaultOnUpdate'] == true,
        notNull: _strength(json['notNull']),
        unique: _strength(json['unique']),
        expression: json['expression'] as String?,
        expressionDescription: json['expressionDesc'] as String?,
        expressionStrength: _strength(json['expressionStrength']),
        readOnly: json['readOnly'] == true,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (alias != null) 'alias': alias,
        if (widgetType.isNotEmpty) 'widget': widgetType,
        if (config.isNotEmpty) 'config': config,
        if (defaultExpression != null) 'default': defaultExpression,
        if (applyDefaultOnUpdate) 'defaultOnUpdate': true,
        if (notNull != QgisConstraintStrength.none) 'notNull': notNull.name,
        if (unique != QgisConstraintStrength.none) 'unique': unique.name,
        if (expression != null) 'expression': expression,
        if (expressionDescription != null) 'expressionDesc': expressionDescription,
        if (expressionStrength != QgisConstraintStrength.none) 'expressionStrength': expressionStrength.name,
        if (readOnly) 'readOnly': true,
      };

  static QgisConstraintStrength _strength(Object? v) =>
      QgisConstraintStrength.values.where((s) => s.name == v).firstOrNull ?? QgisConstraintStrength.none;
}

/// ValueMap の「NULL」の項目の値（QGIS の決まった文字列）
const kQgisValueMapNull = '{2839923C-8B7D-419E-B84B-CA2FE9B80EC7}';

/// ValueRelation の参照先を取り込みで解決したもの（[QgisFieldForm.config] に入れる鍵）
const kRelationTargetKey = 'kokageTarget';

/// ドラッグ&ドロップの配置の要素
sealed class QgisFormElement {
  const QgisFormElement();

  static QgisFormElement? fromJson(Object? json) {
    if (json is! Map) return null;
    final field = json['field'];
    if (field is String) return QgisFormFieldRef(field);
    final children = [
      for (final c in (json['children'] as List?) ?? const []) ?QgisFormElement.fromJson(c),
    ];
    return QgisFormContainer(
      name: json['name'] as String? ?? '',
      isTab: json['tab'] == true,
      children: children,
    );
  }

  Map<String, dynamic> toJson();
}

class QgisFormFieldRef extends QgisFormElement {
  const QgisFormFieldRef(this.name);
  final String name;

  @override
  Map<String, dynamic> toJson() => {'field': name};
}

/// タブかグループ
class QgisFormContainer extends QgisFormElement {
  const QgisFormContainer({required this.name, required this.isTab, this.children = const []});
  final String name;
  final bool isTab;
  final List<QgisFormElement> children;

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        if (isTab) 'tab': true,
        'children': [for (final c in children) c.toJson()],
      };
}

/// レイヤの属性フォーム（と、QGIS の「表示名」の式）
class QgisForm {
  const QgisForm({this.fields = const {}, this.layout, this.displayExpression});

  /// 列名 → 設定（`.qgs` の並び。何も設定していない列は持たない）
  final Map<String, QgisFieldForm> fields;

  /// ドラッグ&ドロップの配置（自動生成の配置なら null）。ここに出てこない列は QGIS でもフォームに出ない
  final List<QgisFormElement>? layout;

  /// QGIS の「表示名」の式（レイヤのプロパティ → 表示。`.qgs` の `<previewExpression>`）。無ければ null。
  /// フォームの設定ではないが、同じく maplayer ごとに QGIS が持つので一緒に写す
  final String? displayExpression;

  bool get isEmpty => fields.isEmpty && layout == null && displayExpression == null;

  /// [fields] と [layout] を替えたもの（[displayExpression] は残す）
  QgisForm withFields(Map<String, QgisFieldForm> fields, {List<QgisFormElement>? layout}) =>
      QgisForm(fields: fields, layout: layout ?? this.layout, displayExpression: displayExpression);

  QgisFieldForm? operator [](String column) => fields[column];

  /// 配置に出てくる列（配置が無ければ null）
  Set<String>? get layoutFields {
    final l = layout;
    if (l == null) return null;
    final out = <String>{};
    void walk(QgisFormElement e) {
      switch (e) {
        case QgisFormFieldRef(:final name):
          out.add(name);
        case QgisFormContainer(:final children):
          children.forEach(walk);
      }
    }

    l.forEach(walk);
    return out;
  }

  /// フォームに出す列か（Hidden と、配置に無い列は出さない）
  bool shows(String column) {
    if (fields[column]?.hidden ?? false) return false;
    final inLayout = layoutFields;
    return inLayout == null || inLayout.contains(column);
  }

  /// 書き換えてよい列か（QGIS で編集可能を外した列は書かない）
  bool editable(String column) => !(fields[column]?.readOnly ?? false);

  factory QgisForm.fromJson(Map<String, dynamic> json) {
    final fields = <String, QgisFieldForm>{};
    for (final f in (json['fields'] as List?) ?? const []) {
      if (f is Map<String, dynamic>) {
        final field = QgisFieldForm.fromJson(f);
        fields[field.name] = field;
      }
    }
    final layout = json['layout'];
    final display = json['displayExpression'];
    return QgisForm(
      fields: fields,
      layout: layout is List ? [for (final e in layout) ?QgisFormElement.fromJson(e)] : null,
      displayExpression: display is String && display.trim().isNotEmpty ? display : null,
    );
  }

  static QgisForm? tryFromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    try {
      return QgisForm.fromJson(json);
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'fields': [for (final f in fields.values) f.toJson()],
        if (layout != null) 'layout': [for (final e in layout!) e.toJson()],
        if (displayExpression != null) 'displayExpression': displayExpression,
      };
}

// ── Qt の日付書式（QDateTime::toString / fromString の部分集合） ──

final _qtToken = RegExp("'[^']*'|yyyy|yy|MM|M|dd|d|HH|H|hh|h|mm|m|ss|s|zzz|z|AP|ap|A|a");

/// [d] を Qt の書式 [format]（例 `yyyy-MM-dd HH:mm:ss`）で文字にする
String formatQtDate(DateTime d, String format) {
  String two(int v) => v.toString().padLeft(2, '0');
  final ampm = format.contains(RegExp('AP|ap|A|a'));
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return format.replaceAllMapped(_qtToken, (m) {
    final t = m.group(0)!;
    if (t.startsWith("'")) return t.length == 2 ? "'" : t.substring(1, t.length - 1);
    return switch (t) {
      'yyyy' => d.year.toString().padLeft(4, '0'),
      'yy' => two(d.year % 100),
      'MM' => two(d.month),
      'M' => '${d.month}',
      'dd' => two(d.day),
      'd' => '${d.day}',
      'HH' => two(d.hour),
      'H' => '${d.hour}',
      'hh' => two(ampm ? h12 : d.hour),
      'h' => '${ampm ? h12 : d.hour}',
      'mm' => two(d.minute),
      'm' => '${d.minute}',
      'ss' => two(d.second),
      's' => '${d.second}',
      'zzz' => d.millisecond.toString().padLeft(3, '0'),
      'z' => '${d.millisecond}',
      'AP' || 'A' => d.hour < 12 ? 'AM' : 'PM',
      _ => d.hour < 12 ? 'am' : 'pm',
    };
  });
}

/// [text] を Qt の書式 [format] で読む。合わなければ null
DateTime? parseQtDate(String text, String format) {
  final fields = <String>[];
  final pattern = StringBuffer('^');
  var last = 0;
  for (final m in _qtToken.allMatches(format)) {
    pattern.write(RegExp.escape(format.substring(last, m.start)));
    last = m.end;
    final t = m.group(0)!;
    if (t.startsWith("'")) {
      pattern.write(RegExp.escape(t.length == 2 ? "'" : t.substring(1, t.length - 1)));
      continue;
    }
    fields.add(t);
    pattern.write(switch (t) {
      'yyyy' => r'(\d{4})',
      'yy' || 'MM' || 'dd' || 'HH' || 'hh' || 'mm' || 'ss' => r'(\d{2})',
      'zzz' => r'(\d{3})',
      'AP' || 'ap' || 'A' || 'a' => '([AaPp][Mm])',
      _ => r'(\d{1,3})',
    });
  }
  pattern
    ..write(RegExp.escape(format.substring(last)))
    ..write(r'$');
  final m = RegExp(pattern.toString()).firstMatch(text.trim());
  if (m == null) return null;
  var y = 2000, mo = 1, d = 1, h = 0, mi = 0, s = 0, ms = 0;
  bool? pm;
  for (var i = 0; i < fields.length; i++) {
    final g = m.group(i + 1)!;
    final n = int.tryParse(g);
    switch (fields[i]) {
      case 'yyyy':
        y = n!;
      case 'yy':
        y = 2000 + n!;
      case 'MM' || 'M':
        mo = n!;
      case 'dd' || 'd':
        d = n!;
      case 'HH' || 'H' || 'hh' || 'h':
        h = n!;
      case 'mm' || 'm':
        mi = n!;
      case 'ss' || 's':
        s = n!;
      case 'zzz' || 'z':
        ms = n!;
      default:
        pm = g.toLowerCase() == 'pm';
    }
  }
  if (pm != null) h = (h % 12) + (pm ? 12 : 0);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59) return null;
  return DateTime(y, mo, d, h, mi, s, ms);
}

/// 範囲の値を刻みに合わせて丸める
double snapToStep(double v, double min, double step) {
  if (step <= 0) return v;
  final k = ((v - min) / step).round();
  final out = min + k * step;
  // 浮動小数の誤差を落とす
  final digits = math.max(0, -(math.log(step) / math.ln10).floor() + 1);
  return double.parse(out.toStringAsFixed(digits.clamp(0, 10)));
}
