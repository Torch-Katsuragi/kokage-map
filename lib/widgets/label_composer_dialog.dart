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
// こかげマップ: 地図に出すラベルを、列の組み合わせと固定文字で組み立てるダイアログ
//
// 列をチップで選ぶと部品（カード）になって並び、ドラッグで順番を入れ替えたり、
// 自分で打った文字を間に挟んだりできる。結果は QGIS の式（`label_expression.dart`）。
// 列のチップは「値が入っている率」の高い順に並べる（何をラベルにすれば
// 見えるかのヒント）。式を直接書きたいときは下の欄で（読めない式は赤で知らせる）。
//
// スタイル画面（レイヤ／View）と属性テーブルの両方から開く。

import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../utils/label_expression.dart';
import '../utils/label_template.dart';

typedef LabelComposerResult = ({String template, bool enabled});

/// 列ごとの「値が入っている率」（0〜1）。[rows] は属性の辞書の列
Map<String, double> columnFillRates(
  Iterable<Map<String, Object?>?> rows,
  Iterable<String> columns,
) {
  final counts = <String, int>{for (final c in columns) c: 0};
  var total = 0;
  for (final row in rows) {
    total++;
    if (row == null) continue;
    for (final c in counts.keys) {
      final v = row[c];
      if (v != null && v.toString().trim().isNotEmpty) counts[c] = counts[c]! + 1;
    }
  }
  if (total == 0) return {for (final c in columns) c: 0};
  return {for (final e in counts.entries) e.key: e.value / total};
}

Future<LabelComposerResult?> showLabelComposerDialog(
  BuildContext context, {
  required List<String> columns,
  required String? initialTemplate,
  required bool initialEnabled,
  Map<String, Object?>? sampleProps,
  Map<String, double>? fillRates,
}) =>
    showDialog<LabelComposerResult>(
      context: context,
      builder: (_) => _LabelComposerDialog(
        columns: columns,
        initialTokens: parseLabelTemplate(initialTemplate),
        initialEnabled: initialEnabled,
        sampleProps: sampleProps,
        fillRates: fillRates ?? const {},
      ),
    );

class _LabelComposerDialog extends StatefulWidget {
  const _LabelComposerDialog({
    required this.columns,
    required this.initialTokens,
    required this.initialEnabled,
    required this.sampleProps,
    required this.fillRates,
  });

  final List<String> columns;
  final List<LabelToken> initialTokens;
  final bool initialEnabled;
  final Map<String, Object?>? sampleProps;
  final Map<String, double> fillRates;

  @override
  State<_LabelComposerDialog> createState() => _LabelComposerDialogState();
}

class _LabelComposerDialogState extends State<_LabelComposerDialog> {
  late List<LabelToken> _tokens = [...widget.initialTokens];
  late bool _enabled = widget.initialEnabled;
  final _textCtrl = TextEditingController();
  late final _exprCtrl = TextEditingController(text: buildLabelTemplate(_tokens));

  String? _exprError;

  @override
  void dispose() {
    _textCtrl.dispose();
    _exprCtrl.dispose();
    super.dispose();
  }

  /// 値が入っている率の高い順（同率は元の順）
  List<String> get _sortedColumns {
    final cols = [...widget.columns];
    if (widget.fillRates.isEmpty) return cols;
    final index = {for (var i = 0; i < cols.length; i++) cols[i]: i};
    cols.sort((a, b) {
      final d = (widget.fillRates[b] ?? 0).compareTo(widget.fillRates[a] ?? 0);
      return d != 0 ? d : index[a]!.compareTo(index[b]!);
    });
    return cols;
  }

  bool _hasColumn(String c) => _tokens.any((t) => t is FieldToken && t.column == c);

  void _setTokens(List<LabelToken> tokens) {
    setState(() {
      _tokens = tokens;
      _exprCtrl.text = buildLabelTemplate(_tokens);
      _exprError = null;
    });
  }

  void _toggleColumn(String c, bool on) {
    final next = [..._tokens];
    if (on) {
      // 直前が部品なら区切りの空白を挟む
      if (next.isNotEmpty && next.last is FieldToken) next.add(const TextToken(' '));
      next.add(FieldToken(c));
    } else {
      next.removeWhere((t) => t is FieldToken && t.column == c);
    }
    _setTokens(next);
  }

  void _addText() {
    final text = _textCtrl.text;
    if (text.isEmpty) return;
    _setTokens([..._tokens, TextToken(text)]);
    _textCtrl.clear();
  }

  Future<void> _editText(int index) async {
    final ctrl = TextEditingController(text: (_tokens[index] as TextToken).text);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.labelComposer.fixedText),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.common.cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(t.common.ok)),
        ],
      ),
    );
    if (v == null || !mounted) return;
    final next = [..._tokens];
    next[index] = TextToken(v);
    _setTokens(next);
  }

  /// 式の欄が変わった: 読めれば部品に分解し直す、読めなければ赤く
  void _onExprChanged(String text) {
    setState(() {
      if (text.trim().isEmpty) {
        _tokens = [];
        _exprError = null;
        return;
      }
      try {
        parseLabelExpression(text);
        _tokens = parseLabelTemplate(text);
        _exprError = null;
      } on LabelExprParseException catch (e) {
        _exprError = e.message;
      }
    });
  }

  String get _expression => _exprError == null ? buildLabelTemplate(_tokens) : _exprCtrl.text;

  @override
  Widget build(BuildContext context) {
    final tr = t.labelComposer;
    final expression = _expression;
    final preview = _exprError != null
        ? ''
        : widget.sampleProps == null
            ? expression
            : (renderLabelTemplate(expression, widget.sampleProps) ?? '');

    return AlertDialog(
      title: Text(tr.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.show),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              Text(
                widget.fillRates.isEmpty ? tr.columns : tr.columnsSorted,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: -6,
                children: [
                  for (final c in _sortedColumns)
                    FilterChip(
                      label: Text(
                        widget.fillRates.containsKey(c)
                            ? tr.columnWithRate(name: c, percent: (widget.fillRates[c]! * 100).round())
                            : c,
                      ),
                      selected: _hasColumn(c),
                      onSelected: (on) => _toggleColumn(c, on),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(tr.order, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              if (_tokens.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(tr.empty, style: const TextStyle(color: Colors.grey)),
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: _tokens.length,
                  onReorderItem: (from, to) {
                    final next = [..._tokens];
                    next.insert(to, next.removeAt(from));
                    _setTokens(next);
                  },
                  itemBuilder: (context, i) {
                    final tok = _tokens[i];
                    final (title, subtitle, color) = switch (tok) {
                      FieldToken(:final column) => (column, tr.fieldToken, Colors.blue.shade50),
                      TextToken(:final text) => ("'$text'", tr.textToken, Colors.grey.shade100),
                      RawToken(:final expression) => (expression, tr.rawToken, Colors.amber.shade50),
                    };
                    return Card(
                      key: ValueKey('tok-$i-${tok.hashCode}'),
                      color: color,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      child: ListTile(
                        dense: true,
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle),
                        ),
                        title: Text(
                          title,
                          style: TextStyle(fontWeight: tok is FieldToken ? FontWeight.w600 : FontWeight.normal),
                        ),
                        subtitle: Text(subtitle),
                        onTap: tok is TextToken ? () => _editText(i) : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            final next = [..._tokens];
                            next.removeAt(i);
                            _setTokens(next);
                          },
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: tr.fixedText,
                        hintText: tr.fixedTextHint,
                      ),
                      onSubmitted: (_) => _addText(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: tr.addText,
                    onPressed: _addText,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(tr.expression, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              TextField(
                controller: _exprCtrl,
                maxLines: 2,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr.expressionHint,
                  errorText: _exprError == null ? null : tr.invalid(error: _exprError!),
                  helperText: _exprError == null ? tr.expressionHelp : null,
                ),
                onChanged: _onExprChanged,
              ),
              const SizedBox(height: 12),
              Text(tr.preview, style: Theme.of(context).textTheme.labelLarge),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(preview.isEmpty ? '—' : preview),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(
          onPressed: _exprError != null
              ? null
              : () => Navigator.pop(context, (template: expression, enabled: _enabled)),
          child: Text(t.common.ok),
        ),
      ],
    );
  }
}
