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
// こかげマップ: `.qgs` の `<maplayer>` から属性フォームの設定を読む
//
// 読むもの: `<fieldConfiguration>`（編集ウィジェットとその設定）・`<aliases>`・`<defaults>`・
// `<constraints>` / `<constraintExpressions>`・`<editable>`・`<attributeEditorForm>`（`<editorlayout>` が
// `tablayout` のときのドラッグ&ドロップの配置）・`<previewExpression>`（表示名の式）。書き戻しはしない（QGIS の持ち物）。

import 'package:xml/xml.dart';

import '../../models/qgis_form.dart';

class QgsFormReader {
  const QgsFormReader._();

  /// [maplayer] の属性フォームの設定。何も設定していなければ null
  static QgisForm? read(XmlElement maplayer) {
    final widgets = <String, (String, Map<String, Object?>)>{};
    for (final field in _children(maplayer, 'fieldConfiguration', 'field')) {
      final name = field.getAttribute('name');
      final widget = field.getElement('editWidget');
      if (name == null || widget == null) continue;
      final type = widget.getAttribute('type') ?? '';
      final option = widget.getElement('config')?.getElement('Option');
      final config = option == null ? null : readOption(option);
      widgets[name] = (type, config is Map<String, Object?> ? config : const {});
    }

    final aliases = <String, String>{
      for (final a in _children(maplayer, 'aliases', 'alias'))
        if ((a.getAttribute('field') ?? '').isNotEmpty && (a.getAttribute('name') ?? '').isNotEmpty)
          a.getAttribute('field')!: a.getAttribute('name')!,
    };

    final defaults = <String, (String, bool)>{
      for (final d in _children(maplayer, 'defaults', 'default'))
        if ((d.getAttribute('field') ?? '').isNotEmpty && (d.getAttribute('expression') ?? '').trim().isNotEmpty)
          d.getAttribute('field')!: (d.getAttribute('expression')!.trim(), d.getAttribute('applyOnUpdate') == '1'),
    };

    // constraints はビット（1 NULL でない・2 一意・4 式）と、それぞれの強さ（1 必須・2 警告）
    final constraints = <String, (QgisConstraintStrength, QgisConstraintStrength, QgisConstraintStrength)>{};
    for (final c in _children(maplayer, 'constraints', 'constraint')) {
      final field = c.getAttribute('field');
      if (field == null) continue;
      final bits = int.tryParse(c.getAttribute('constraints') ?? '') ?? 0;
      QgisConstraintStrength s(int bit, String attr) => bits & bit == 0
          ? QgisConstraintStrength.none
          : QgisConstraintStrength.fromQgis(c.getAttribute(attr));
      constraints[field] = (s(1, 'notnull_strength'), s(2, 'unique_strength'), s(4, 'exp_strength'));
    }
    final expressions = <String, (String, String?)>{
      for (final c in _children(maplayer, 'constraintExpressions', 'constraint'))
        if ((c.getAttribute('field') ?? '').isNotEmpty && (c.getAttribute('exp') ?? '').trim().isNotEmpty)
          c.getAttribute('field')!: (
            c.getAttribute('exp')!.trim(),
            (c.getAttribute('desc') ?? '').isEmpty ? null : c.getAttribute('desc'),
          ),
    };

    final readOnly = <String>{
      for (final f in _children(maplayer, 'editable', 'field'))
        if (f.getAttribute('editable') == '0' && f.getAttribute('name') != null) f.getAttribute('name')!,
    };

    // 列の並びは fieldConfiguration（＝レイヤの列の順）。無い列も別名などから拾う
    final names = <String>{
      ...widgets.keys,
      ...aliases.keys,
      ...defaults.keys,
      ...constraints.keys,
      ...expressions.keys,
      ...readOnly,
    };
    final fields = <String, QgisFieldForm>{};
    // fid はデータソースの制約（NULL でない・一意）が付いてくるだけで、書き換えない
    names.removeWhere((n) => n.toLowerCase() == 'fid');
    for (final name in names) {
      final (type, config) = widgets[name] ?? ('', const <String, Object?>{});
      final (notNull, unique, expStrength) =
          constraints[name] ?? (QgisConstraintStrength.none, QgisConstraintStrength.none, QgisConstraintStrength.none);
      final exp = expressions[name];
      final def = defaults[name];
      final field = QgisFieldForm(
        name: name,
        alias: aliases[name],
        // 空の type は「既定（文字の欄）」と同じ
        widgetType: type == 'TextEdit' && !_bool(config['IsMultiline']) ? '' : type,
        config: type.isEmpty ? const {} : config,
        defaultExpression: def?.$1,
        applyDefaultOnUpdate: def?.$2 ?? false,
        notNull: notNull,
        unique: unique,
        expression: exp?.$1,
        expressionDescription: exp?.$2,
        // 式が無いのに強さだけあることがある（式を消したあと）。式のある時だけ数える
        expressionStrength: exp == null ? QgisConstraintStrength.none : expStrength,
        readOnly: readOnly.contains(name),
      );
      if (!field.isEmpty) fields[name] = field;
    }

    final layout = _readLayout(maplayer);
    // 表示名の式。空なら持たない（こかげマップが書いた `.qgs` は空で書く）
    final display = maplayer.getElement('previewExpression')?.innerText.trim();
    final form = QgisForm(fields: fields, layout: layout, displayExpression: display == null || display.isEmpty ? null : display);
    return form.isEmpty ? null : form;
  }

  static bool _bool(Object? v) => v == true || v == 'true' || v == 1;

  static Iterable<XmlElement> _children(XmlElement maplayer, String parent, String child) =>
      maplayer.findElements(parent).firstOrNull?.findElements(child) ?? const [];

  /// ドラッグ&ドロップの配置（`<editorlayout>tablayout</editorlayout>` のときだけ）
  static List<QgisFormElement>? _readLayout(XmlElement maplayer) {
    final kind = maplayer.findElements('editorlayout').firstOrNull?.innerText.trim();
    if (kind != 'tablayout') return null;
    final form = maplayer.findElements('attributeEditorForm').firstOrNull;
    if (form == null) return null;
    return _readElements(form);
  }

  static List<QgisFormElement> _readElements(XmlElement parent) {
    final out = <QgisFormElement>[];
    for (final e in parent.childElements) {
      switch (e.name.local) {
        case 'attributeEditorField':
          final name = e.getAttribute('name');
          if (name != null) out.add(QgisFormFieldRef(name));
        case 'attributeEditorContainer':
          final type = e.getAttribute('type');
          // QGIS 3.30 より前は type が無く groupBox="1" でグループ
          final isTab = type == null ? e.getAttribute('groupBox') != '1' : type == 'Tab';
          out.add(QgisFormContainer(
            name: e.getAttribute('name') ?? '',
            isTab: isTab,
            children: _readElements(e),
          ));
        // 関係・QML・HTML・テキスト・アクション・間隔などは出さない
      }
    }
    return out;
  }

  /// QGIS の `<Option>` を Dart の値にする
  static Object? readOption(XmlElement option) {
    final type = option.getAttribute('type');
    switch (type) {
      case 'Map':
        return <String, Object?>{
          for (final c in option.findElements('Option'))
            if (c.getAttribute('name') != null) c.getAttribute('name')!: readOption(c),
        };
      case 'List' || 'StringList':
        return [for (final c in option.findElements('Option')) readOption(c)];
      case 'bool':
        return option.getAttribute('value') == 'true';
      case 'int' || 'uint' || 'qlonglong' || 'qulonglong':
        return int.tryParse(option.getAttribute('value') ?? '');
      case 'double':
        return double.tryParse(option.getAttribute('value') ?? '');
      case null || 'invalid':
        return null;
      default:
        return option.getAttribute('value');
    }
  }
}
