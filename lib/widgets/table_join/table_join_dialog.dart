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
// レイヤの長押し →「表を結合」。QGIS のレイヤのプロパティ →「結合」と同じ項目（表・結ぶ列・足す列・接頭辞）。
// 設計は docs/technical/qgis-interop.md#表の結合（森林簿 CSV と計画図）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/layer_join.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/table_node.dart';
import '../../services/kmeta_service.dart';
import '../../services/table/csv_table.dart';
import '../../services/table/table_join.dart';
import '../../utils/attribute_columns.dart';
import '../layer_drawer/common_dialogs.dart';

/// [layer] の結合を見る・足す・外す
Future<void> showTableJoinDialog(BuildContext context, LayerNode layer) =>
    showDialog<void>(context: context, builder: (_) => _TableJoinDialog(layer: layer));

/// [layer] から結べる表（レイヤのある dir とその下、祖先の dir の直下。読み込み済みのツリーから）
List<TableNode> joinableTables(LayerNode layer) {
  final folder = layer.folderNode;
  if (folder == null) return const [];
  final found = <TableNode>[];
  void walk(LayerTreeNode n) {
    for (final c in n.children) {
      if (c is TableNode) found.add(c);
      if (c is FolderNode) walk(c);
    }
  }

  walk(folder);
  for (LayerTreeNode? a = folder.parent; a != null; a = a.parent) {
    found.addAll(a.children.whereType<TableNode>());
  }
  return found;
}

class _TableJoinDialog extends ConsumerStatefulWidget {
  const _TableJoinDialog({required this.layer});
  final LayerNode layer;

  @override
  ConsumerState<_TableJoinDialog> createState() => _TableJoinDialogState();
}

class _TableJoinDialogState extends ConsumerState<_TableJoinDialog> {
  LayerNode get layer => widget.layer;

  List<LayerJoin> _joins = const [];
  List<String> _layerFields = const [];
  late final List<TableNode> _tables = joinableTables(layer);

  // 足す結合の入力
  TableNode? _table;
  CsvTable? _tableData;
  String? _targetField;
  String? _joinField;
  Set<String> _fields = {};
  final _prefix = TextEditingController();
  bool _normalize = false;
  bool _busy = false;

  String? get _folderPath => layer.folderNode?.getAbsoluteFilePath();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prefix.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await layer.loadJoins();
    final columns = await layer.getAttributeColumnNames(getAll: true, skipPrimaryKey: true);
    if (!mounted) return;
    setState(() {
      _joins = List.of(layer.joinDefs);
      _layerFields = [for (final c in columns) if (!isSystemColumn(c) && !isInternalColumn(c)) c];
    });
    if (_tables.isNotEmpty) await _pickTable(_tables.first);
  }

  Future<void> _pickTable(TableNode node) async {
    final data = await node.load();
    if (!mounted) return;
    setState(() {
      _table = node;
      _tableData = data;
      final names = data?.fieldNames ?? const <String>[];
      // 同じ名前の列があれば、それどうしを結ぶ（林班・小班など）
      final common = _layerFields.where(names.contains).firstOrNull;
      _targetField = common ?? _targetField ?? _layerFields.firstOrNull;
      _joinField = common ?? names.firstOrNull;
      _fields = {for (final n in names) if (n != _joinField) n};
      _prefix.text = '${node.tableName}_';
    });
  }

  String _relativeTable(TableNode node) =>
      p.relative(node.sourcePath, from: _folderPath ?? p.dirname(node.sourcePath)).replaceAll(r'\', '/');

  LayerJoin? get _draft {
    final table = _table;
    final data = _tableData;
    if (table == null || data == null || _targetField == null || _joinField == null) return null;
    final names = data.fieldNames.where((n) => n != _joinField).toList();
    final all = names.every(_fields.contains);
    final prefix = _prefix.text;
    return LayerJoin(
      table: _relativeTable(table),
      joinField: _joinField!,
      targetField: _targetField!,
      fields: all ? null : [for (final n in names) if (_fields.contains(n)) n],
      prefix: prefix == '${table.tableName}_' ? null : prefix,
      normalize: _normalize,
    );
  }

  /// 当たる地物の数（読み込んである地物で数える）
  ({int matched, int total})? get _preview {
    final draft = _draft;
    final data = _tableData;
    if (draft == null || data == null) return null;
    final r = ResolvedJoin.build(draft, data);
    if (r == null) return null;
    final features = layer.features;
    var matched = 0;
    for (final f in features) {
      if (f.isDisposed) continue;
      if (r.valuesFor(readAttribute(f, draft.targetField)) != null) matched++;
    }
    return (matched: matched, total: features.length);
  }

  Future<void> _save(List<LayerJoin> joins, String message) async {
    final folder = layer.folderNode;
    final folderPath = _folderPath;
    if (folder == null || folderPath == null) return;
    setState(() => _busy = true);
    try {
      await KMetaService.instance.setLayerJoins(folderPath, layer.layerKey, joins);
      folder.invalidateMetaCache();
      await layer.loadJoins();
      await layer.refreshStyleGroups();
      ref.refreshMap();
      ref.notify(message, level: NotificationLevel.success);
      if (mounted) setState(() => _joins = List.of(layer.joinDefs));
    } catch (e) {
      ref.notify(t.layerDrawer.errorPrefix(error: '$e'), level: NotificationLevel.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = t.tableJoin;
    final draft = _draft;
    final preview = _preview;
    final resolved = {for (final r in layer.joins) r.join};
    // 保存の途中は閉じさせない（閉じると後の ref.refreshMap / ref.notify が破棄済みの ref を使って落ちる）
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
      title: Text(tr.title(layer: layer.layerName)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr.existing, style: Theme.of(context).textTheme.titleSmall),
              if (_joins.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(tr.none, style: const TextStyle(color: Colors.black54)),
                ),
              for (final j in _joins)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link, color: Colors.brown),
                  title: Text('${j.table}  ${j.targetField} = ${j.joinField}'),
                  subtitle: Text(
                    resolved.contains(j)
                        ? '${j.effectivePrefix}…${j.fields == null ? '' : '（${j.fields!.join('・')}）'}'
                        : tr.missing,
                    style: TextStyle(color: resolved.contains(j) ? null : Colors.red),
                  ),
                  trailing: TextButton(
                    onPressed: _busy
                        ? null
                        : () => _save([for (final o in _joins) if (!identical(o, j)) o], tr.removed(table: j.table)),
                    child: Text(tr.remove),
                  ),
                ),
              const Divider(),
              Text(tr.add, style: Theme.of(context).textTheme.titleSmall),
              if (_tables.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(tr.noTables, style: const TextStyle(color: Colors.black54)),
                )
              else ...[
                DropdownButtonFormField<TableNode>(
                  initialValue: _table,
                  decoration: InputDecoration(labelText: tr.table),
                  items: [
                    for (final n in _tables) DropdownMenuItem(value: n, child: Text(_relativeTable(n))),
                  ],
                  onChanged: (n) => n == null ? null : _pickTable(n),
                ),
                if (_table != null && _tableData == null)
                  Text(tr.readError, style: const TextStyle(color: Colors.red)),
                if (_tableData != null) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey('target-$_targetField'),
                    initialValue: _targetField,
                    decoration: InputDecoration(labelText: tr.targetField),
                    items: [for (final f in _layerFields) DropdownMenuItem(value: f, child: Text(f))],
                    onChanged: (v) => setState(() => _targetField = v),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('join-${_table?.sourcePath}-$_joinField'),
                    initialValue: _joinField,
                    decoration: InputDecoration(labelText: tr.joinField),
                    items: [
                      for (final f in _tableData!.fieldNames) DropdownMenuItem(value: f, child: Text(f)),
                    ],
                    onChanged: (v) => setState(() {
                      if (_joinField != null) _fields.add(_joinField!);
                      _joinField = v;
                      _fields.remove(v);
                    }),
                  ),
                  const SizedBox(height: 8),
                  Text(tr.fields, style: Theme.of(context).textTheme.bodySmall),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final f in _tableData!.fieldNames)
                        if (f != _joinField)
                          FilterChip(
                            label: Text(f),
                            selected: _fields.contains(f),
                            onSelected: (on) => setState(() => on ? _fields.add(f) : _fields.remove(f)),
                          ),
                    ],
                  ),
                  TextField(
                    controller: _prefix,
                    decoration: InputDecoration(labelText: tr.prefix),
                    onChanged: (_) => setState(() {}),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr.normalize),
                    subtitle: Text(tr.normalizeDesc, style: const TextStyle(fontSize: 12)),
                    value: _normalize,
                    onChanged: (v) => setState(() => _normalize = v),
                  ),
                  if (preview != null)
                    Text(
                      tr.matched(matched: preview.matched, total: preview.total),
                      style: TextStyle(color: preview.matched == 0 ? Colors.red : Colors.black87),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        // PopScope は Navigator.pop を止めないので、保存の途中はボタンも押せなくする
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(t.common.close)),
        FilledButton(
          onPressed: _busy || draft == null || _fields.isEmpty
              ? null
              : () => _save(
                    [for (final o in _joins) if (!o.sameLink(draft)) o, draft],
                    tr.saved(table: draft.table),
                  ),
          child: Text(tr.save),
        ),
      ],
      ),
    );
  }
}
