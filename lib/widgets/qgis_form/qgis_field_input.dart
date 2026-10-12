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
// こかげマップ: 属性の 1 欄。QGIS の編集ウィジェット（[QgisFieldForm]）に合わせて出し分ける
//
// 属性フォーム（属性テーブルのフォーム表示）と編集パネルで共通。設定が無い列は今までどおりの文字の欄。
// ValueMap は表示名を見せて値を書く。チェックボックスは決めた値を書く。日付はカレンダーで選び field_format で書く。

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/qgis_form.dart';
import '../../services/qgis_form_logic.dart';
import '../../utils/attribute_columns.dart';

/// 値が変わった。[commit] は「確定した」（選んだ・欄を離れた・Enter）。文字を打つ途中は false
typedef QgisFieldChanged = void Function(Object? value, {required bool commit});

class QgisFieldInput extends StatefulWidget {
  const QgisFieldInput({
    super.key,
    required this.column,
    required this.value,
    required this.onChanged,
    this.field,
    this.sqlType = '',
    this.enabled = true,
    this.options,
    this.errorText,
    this.dense = true,
    this.multilineFallback = false,
  });

  final String column;
  final QgisFieldForm? field;

  /// 列の SQLite の型名（数の欄・日付の書き方に使う）
  final String sqlType;
  final Object? value;
  final bool enabled;

  /// UniqueValues・ValueRelation の選択肢（[QgisFormOptions]）
  final List<QgisValueOption>? options;
  final String? errorText;
  final bool dense;

  /// 設定の無い文字の欄を複数行にする（編集パネルのメモの列）
  final bool multilineFallback;
  final QgisFieldChanged onChanged;

  @override
  State<QgisFieldInput> createState() => _QgisFieldInputState();
}

class _QgisFieldInputState extends State<QgisFieldInput> {
  late final TextEditingController _text = TextEditingController(text: _initialText());
  final FocusNode _focus = FocusNode();

  QgisFieldForm? get _f => widget.field;
  QgisWidgetKind get _kind => _f?.kind ?? QgisWidgetKind.other;

  String _initialText() => widget.value?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && widget.enabled) _commitText();
    });
  }

  @override
  void didUpdateWidget(QgisFieldInput old) {
    super.didUpdateWidget(old);
    // 外から値が替わった（別の地物へ移った・既定値が入った）。打っている最中は触らない
    final next = _initialText();
    if (!_focus.hasFocus && _text.text != next) _text.text = next;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commitText() {
    var v = normalizeAttributeInput(widget.sqlType, _text.text) as String?;
    if (_kind == QgisWidgetKind.range && v != null && v.isNotEmpty) {
      v = _clampRange(v);
      if (_text.text != v) _text.text = v;
    }
    widget.onChanged(v == null || v.isEmpty ? null : v, commit: true);
  }

  /// 範囲の欄は min〜max に収める（QGIS のスピンボックスと同じ）
  String _clampRange(String text) {
    final n = double.tryParse(text);
    final f = _f;
    if (n == null || f == null) return text;
    var x = n;
    if (f.rangeMin != null && x < f.rangeMin!) x = f.rangeMin!;
    if (f.rangeMax != null && x > f.rangeMax!) x = f.rangeMax!;
    if (x == n) return text;
    return isIntegerSqlType(widget.sqlType) ? x.round().toString() : _trimNum(x);
  }

  static String _trimNum(double x) => x == x.roundToDouble() ? x.toInt().toString() : x.toString();

  String get _label {
    final base = _f?.label ?? widget.column;
    return _f?.notNull == QgisConstraintStrength.hard ? '$base *' : base;
  }

  InputDecoration _decoration({Widget? suffix}) => InputDecoration(
        labelText: _label,
        isDense: widget.dense,
        border: const OutlineInputBorder(),
        errorText: widget.errorText,
        errorMaxLines: 3,
        suffixIcon: suffix ?? (widget.enabled ? null : const Icon(Icons.lock, size: 14, color: Colors.grey)),
      );

  @override
  Widget build(BuildContext context) {
    switch (_kind) {
      case QgisWidgetKind.valueMap:
        return _dropdown(_f!.valueMapOptions);
      case QgisWidgetKind.valueRelation:
        final opts = widget.options;
        if (opts != null) return _dropdown(opts, allowNull: _f!.allowNull);
      case QgisWidgetKind.uniqueValues:
        final opts = widget.options ?? const [];
        if (!_f!.uniqueEditable) return _dropdown(opts, allowNull: true);
        return _autocomplete(opts);
      case QgisWidgetKind.checkBox:
        return _checkBox();
      case QgisWidgetKind.dateTime:
        return _date();
      case QgisWidgetKind.range:
        if (_f!.rangeSlider) return _slider();
      case QgisWidgetKind.other || QgisWidgetKind.textEdit:
        // 設定の無い真偽の列も、文字の欄でなくチェックボックスにする（1/0 を書く）
        if (isBooleanSqlType(widget.sqlType)) return _checkBox();
      default:
    }
    return _textField();
  }

  Widget _textField() {
    final numeric = isNumericSqlType(widget.sqlType);
    final multi = _kind == QgisWidgetKind.textEdit ? _f!.multiline : widget.multilineFallback;
    return TextField(
      controller: _text,
      focusNode: _focus,
      readOnly: !widget.enabled,
      keyboardType: numeric
          ? TextInputType.numberWithOptions(signed: true, decimal: !isIntegerSqlType(widget.sqlType))
          : (multi ? TextInputType.multiline : null),
      minLines: 1,
      maxLines: multi ? 4 : 1,
      style: TextStyle(fontSize: widget.dense ? 12 : null, color: widget.enabled ? null : Colors.grey.shade600),
      decoration: _decoration(),
      onChanged: (v) {
        final n = normalizeAttributeInput(widget.sqlType, v);
        widget.onChanged(n is String && n.isEmpty ? null : n, commit: false);
      },
      onSubmitted: widget.enabled && !multi ? (_) => _commitText() : null,
    );
  }

  /// 選択肢から選ぶ。今の値が選択肢に無ければ、その値も並べる（消さない）
  Widget _dropdown(List<QgisValueOption> options, {bool allowNull = true}) {
    final current = widget.value == null || '${widget.value}'.isEmpty ? null : '${widget.value}';
    final items = <DropdownMenuItem<String?>>[
      if (allowNull && !options.any((o) => o.value.isEmpty))
        DropdownMenuItem(value: null, child: Text(t.qgisForm.noValue, style: const TextStyle(color: Colors.grey))),
      for (final o in options)
        DropdownMenuItem(value: o.value.isEmpty ? null : o.value, child: Text(o.label, overflow: TextOverflow.ellipsis)),
      if (current != null && !options.any((o) => o.value == current))
        DropdownMenuItem(value: current, child: Text(current, overflow: TextOverflow.ellipsis)),
    ];
    final selectable = items.any((i) => i.value == current) ? current : null;
    return DropdownButtonFormField<String?>(
      key: ValueKey('${widget.column}:$selectable'),
      initialValue: selectable,
      isExpanded: true,
      isDense: widget.dense,
      items: items,
      style: TextStyle(fontSize: widget.dense ? 12 : 14, color: Theme.of(context).colorScheme.onSurface),
      decoration: _decoration(),
      onChanged: widget.enabled ? (v) => widget.onChanged(v, commit: true) : null,
    );
  }

  Widget _autocomplete(List<QgisValueOption> options) {
    return RawAutocomplete<String>(
      textEditingController: _text,
      focusNode: _focus,
      optionsBuilder: (v) {
        final q = v.text.toLowerCase();
        return [for (final o in options) if (q.isEmpty || o.value.toLowerCase().contains(q)) o.value];
      },
      onSelected: (v) => widget.onChanged(v, commit: true),
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        controller: controller,
        focusNode: focus,
        readOnly: !widget.enabled,
        style: TextStyle(fontSize: widget.dense ? 12 : null),
        decoration: _decoration(suffix: const Icon(Icons.arrow_drop_down)),
        onChanged: (v) => widget.onChanged(v.isEmpty ? null : v, commit: false),
        onSubmitted: (_) => _commitText(),
      ),
      optionsViewBuilder: (context, onSelected, opts) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final o in opts) ListTile(dense: true, title: Text(o), onTap: () => onSelected(o)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// チェックボックス（QGIS の CheckBox・設定の無い真偽の列）。書く値は [qgisCheckValues]。
  /// 横に値の文字は出さない（QGIS と同じ）。NULL は、三つめの状態（AllowNullState）があれば「－」、無ければ（なし）と添える
  Widget _checkBox() {
    final (on, off) = qgisCheckValues(_f, widget.sqlType);
    final checked = qgisCheckState(_f, widget.sqlType, widget.value);
    final tristate = _f?.allowNullState ?? false;
    return InputDecorator(
      decoration: _decoration(),
      child: Row(
        children: [
          Checkbox(
            tristate: tristate,
            value: tristate ? checked : (checked ?? false),
            onChanged: widget.enabled
                ? (c) => widget.onChanged(c == null ? null : (c ? on : off), commit: true)
                : null,
          ),
          if (checked == null && !tristate)
            Expanded(
              child: Text(
                t.qgisForm.noValue,
                style: TextStyle(fontSize: widget.dense ? 12 : null, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }

  bool get _hasTime {
    final fmt = _f?.fieldFormat ?? _f?.displayFormat ?? '';
    final t = widget.sqlType.toUpperCase();
    return fmt.contains(RegExp('[Hhm]')) || t.contains('DATETIME') || t.contains('TIMESTAMP');
  }

  Widget _date() {
    final f = _f!;
    final text = f.displayText(widget.value);
    return InkWell(
      onTap: widget.enabled ? _pickDate : null,
      child: InputDecorator(
        decoration: _decoration(
          suffix: !widget.enabled
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.value != null && f.allowNull)
                      IconButton(
                        tooltip: t.qgisForm.clear,
                        iconSize: 16,
                        icon: const Icon(Icons.clear),
                        onPressed: () => widget.onChanged(null, commit: true),
                      ),
                    IconButton(
                      tooltip: t.qgisForm.pickDate,
                      iconSize: 18,
                      icon: const Icon(Icons.calendar_month),
                      onPressed: _pickDate,
                    ),
                  ],
                ),
        ),
        child: Text(text, style: TextStyle(fontSize: widget.dense ? 12 : null)),
      ),
    );
  }

  Future<void> _pickDate() async {
    final f = _f!;
    final now = DateTime.now();
    final current = f.parseStoredDate(widget.value) ?? now;
    final day = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1800),
      lastDate: DateTime(now.year + 100),
    );
    if (day == null || !mounted) return;
    var picked = DateTime(day.year, day.month, day.day, current.hour, current.minute, current.second);
    if (_hasTime) {
      final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
      if (!mounted) return;
      if (time != null) picked = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    }
    widget.onChanged(storeDateValue(picked, widget.sqlType, f), commit: true);
  }

  Widget _slider() {
    final f = _f!;
    final min = f.rangeMin ?? 0;
    final max = (f.rangeMax ?? 100) <= min ? min + 1 : (f.rangeMax ?? 100);
    final step = (f.rangeStep ?? 0) > 0 ? f.rangeStep! : null;
    final raw = qgisToNumberText(widget.value);
    final v = (raw ?? min).clamp(min, max).toDouble();
    final divisions = step == null ? null : ((max - min) / step).round().clamp(1, 1000);
    final integer = isIntegerSqlType(widget.sqlType) || (step != null && step == step.roundToDouble());
    String show(double x) => integer ? x.round().toString() : _trimNum(x);
    return InputDecorator(
      decoration: _decoration(),
      child: Row(
        children: [
          Expanded(
            child: Slider(
              value: v,
              min: min,
              max: max,
              divisions: divisions,
              label: show(v),
              onChanged: widget.enabled
                  ? (x) {
                      final s = step == null ? x : snapToStep(x, min, step);
                      widget.onChanged(integer ? s.round() : s, commit: false);
                    }
                  : null,
              onChangeEnd: widget.enabled
                  ? (x) {
                      final s = step == null ? x : snapToStep(x, min, step);
                      widget.onChanged(integer ? s.round() : s, commit: true);
                    }
                  : null,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              raw == null ? t.qgisForm.noValue : show(v),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: widget.dense ? 12 : null),
            ),
          ),
        ],
      ),
    );
  }
}

/// 数として読めれば数
double? qgisToNumberText(Object? v) => switch (v) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s.trim()),
      _ => null,
    };

/// フォームの並びの 1 行（見出しか欄）
sealed class QgisFormRow {
  const QgisFormRow(this.depth);

  /// 入れ子の深さ（0 が一番外）
  final int depth;
}

class QgisFormHeader extends QgisFormRow {
  const QgisFormHeader(this.title, {required this.isTab, required int depth}) : super(depth);
  final String title;
  final bool isTab;
}

class QgisFormFieldRow extends QgisFormRow {
  const QgisFormFieldRow(this.column, {required int depth}) : super(depth);
  final String column;
}

/// フォームに出す並び。ドラッグ&ドロップの配置があればその順（タブ・グループは見出しにする）、
/// 無ければ [columns] の順。Hidden の列と、[columns] に無い列（fid など）は出さない
List<QgisFormRow> qgisFormRows(QgisForm? form, List<String> columns) {
  final cols = columns.toSet();
  bool showable(String c) => cols.contains(c) && !(form?[c]?.hidden ?? false);
  final layout = form?.layout;
  if (layout == null) {
    return [for (final c in columns) if (showable(c)) QgisFormFieldRow(c, depth: 0)];
  }
  final out = <QgisFormRow>[];
  void walk(QgisFormElement e, int depth) {
    switch (e) {
      case QgisFormFieldRef(:final name):
        if (showable(name)) out.add(QgisFormFieldRow(name, depth: depth));
      case QgisFormContainer(:final name, :final isTab, :final children):
        final start = out.length;
        out.add(QgisFormHeader(name, isTab: isTab, depth: depth));
        for (final c in children) {
          walk(c, depth + 1);
        }
        // 中に出す欄が無ければ見出しも出さない
        if (!out.skip(start + 1).any((r) => r is QgisFormFieldRow)) out.removeRange(start, out.length);
    }
  }

  for (final e in layout) {
    walk(e, 0);
  }
  return out;
}

/// 見出しの 1 行
class QgisFormHeaderView extends StatelessWidget {
  const QgisFormHeaderView(this.header, {super.key});
  final QgisFormHeader header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: header.depth * 8.0, top: 6, bottom: 8),
      child: Row(
        children: [
          Icon(header.isTab ? Icons.tab : Icons.folder_open, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              header.title,
              style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}
