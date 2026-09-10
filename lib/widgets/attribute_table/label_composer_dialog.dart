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
// 属性テーブルの列をチェックで選ぶと部品（カード）になって並び、
// ドラッグで順番を入れ替えたり、自分で打った文字を間に挟んだりできる。
// 結果は `{列名}` を含むテンプレート文字列（`label_template.dart`）。

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../utils/label_template.dart';

typedef LabelComposerResult = ({String template, bool enabled});

Future<LabelComposerResult?> showLabelComposerDialog(
  BuildContext context, {
  required List<String> columns,
  required String? initialTemplate,
  required bool initialEnabled,
  Map<String, Object?>? sampleProps,
}) =>
    showDialog<LabelComposerResult>(
      context: context,
      builder: (_) => _LabelComposerDialog(
        columns: columns,
        initialTokens: parseLabelTemplate(initialTemplate),
        initialEnabled: initialEnabled,
        sampleProps: sampleProps,
      ),
    );

class _LabelComposerDialog extends StatefulWidget {
  const _LabelComposerDialog({
    required this.columns,
    required this.initialTokens,
    required this.initialEnabled,
    required this.sampleProps,
  });

  final List<String> columns;
  final List<LabelToken> initialTokens;
  final bool initialEnabled;
  final Map<String, Object?>? sampleProps;

  @override
  State<_LabelComposerDialog> createState() => _LabelComposerDialogState();
}

class _LabelComposerDialogState extends State<_LabelComposerDialog> {
  late final List<LabelToken> _tokens = [...widget.initialTokens];
  late bool _enabled = widget.initialEnabled;
  final _textCtrl = TextEditingController();

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  bool _hasColumn(String c) =>
      _tokens.any((t) => t is FieldToken && t.column == c);

  void _toggleColumn(String c, bool on) {
    setState(() {
      if (on) {
        // 直前が部品なら区切りの空白を挟む
        if (_tokens.isNotEmpty && _tokens.last is FieldToken) {
          _tokens.add(const TextToken(' '));
        }
        _tokens.add(FieldToken(c));
      } else {
        _tokens.removeWhere((t) => t is FieldToken && t.column == c);
      }
    });
  }

  void _addText() {
    final text = _textCtrl.text;
    if (text.isEmpty) return;
    setState(() {
      _tokens.add(TextToken(text));
      _textCtrl.clear();
    });
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
    setState(() => _tokens[index] = TextToken(v));
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.labelComposer;
    final template = buildLabelTemplate(_tokens);
    final preview = widget.sampleProps == null
        ? template
        : (renderLabelTemplate(template, widget.sampleProps) ?? '');

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
              Text(tr.columns, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: -6,
                children: [
                  for (final c in widget.columns)
                    FilterChip(
                      label: Text(c),
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
                  onReorderItem: (from, to) => setState(() {
                    _tokens.insert(to, _tokens.removeAt(from));
                  }),
                  itemBuilder: (context, i) {
                    final tok = _tokens[i];
                    final isField = tok is FieldToken;
                    return Card(
                      key: ValueKey('tok-$i-${tok.hashCode}'),
                      color: isField ? Colors.blue.shade50 : Colors.grey.shade100,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      child: ListTile(
                        dense: true,
                        leading: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_handle),
                        ),
                        title: Text(
                          isField
                              ? tok.column
                              : "'${(tok as TextToken).text}'",
                          style: TextStyle(
                            fontWeight: isField ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(isField ? tr.fieldToken : tr.textToken),
                        onTap: isField ? null : () => _editText(i),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _tokens.removeAt(i)),
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
          onPressed: () => Navigator.pop(
            context,
            (template: template, enabled: _enabled),
          ),
          child: Text(t.common.ok),
        ),
      ],
    );
  }
}
