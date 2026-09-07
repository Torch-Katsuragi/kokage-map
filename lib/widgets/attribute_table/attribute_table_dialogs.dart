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
// Root Maps: 属性テーブル用ダイアログ
// カラム追加、フィルタ複製、フィールド計算機、カラム操作など

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/geometry_type.dart';
import '../../models/nodes/layer_node.dart';
import '../../providers/notification_providers.dart';
import '../../utils/app_logger.dart';
import '../../utils/qgis_expression_filter.dart';

void _notify(WidgetRef? ref, String title, NotificationLevel level) {
  ref
      ?.read(notificationCenterProvider.notifier)
      .add(title: title, level: level);
}

/// カラム追加ダイアログを表示
Future<void> showAddColumnDialog(
  BuildContext context,
  LayerNode layer,
  VoidCallback onColumnAdded, {
  WidgetRef? ref,
}) async {
  final columnNameController = TextEditingController();
  String selectedType = 'TEXT';

  final result = await showDialog<Map<String, String>>(
    context: context,
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.add_box, color: Colors.blue),
                const SizedBox(width: 8),
                Text(t.attributeTable.addColumn),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: columnNameController,
                  decoration: InputDecoration(
                    labelText: t.attributeTable.columnName,
                    hintText: t.attributeTable.columnNameHint,
                    border: const OutlineInputBorder(),
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedType,
                  decoration: InputDecoration(
                    labelText: t.attributeTable.dataType,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(value: 'TEXT', child: Text(t.attributeTable.textType)),
                    DropdownMenuItem(
                      value: 'INTEGER',
                      child: Text(t.attributeTable.integerType),
                    ),
                    DropdownMenuItem(value: 'REAL', child: Text(t.attributeTable.realType)),
                    DropdownMenuItem(value: 'BLOB', child: Text(t.attributeTable.blobType)),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => selectedType = value);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(t.common.cancel),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  final columnName = columnNameController.text.trim();
                  if (columnName.isEmpty) {
                    _notify(ref, t.attributeTable.enterColumnName, NotificationLevel.warning);
                    return;
                  }
                  Navigator.of(
                    dialogContext,
                  ).pop({'name': columnName, 'type': selectedType});
                },
                icon: const Icon(Icons.check),
                label: Text(t.attributeTable.add),
              ),
            ],
          );
        },
      );
    },
  );

  if (result != null && context.mounted) {
    final columnName = result['name']!;
    final columnType = result['type']!;

    try {
      await layer.geoPackageFile.addAttributeColumn(
        layer.layerName,
        columnName,
        columnType,
      );
      layer.clearColumnNamesCache();
      onColumnAdded();
      _notify(ref, t.attributeTable.columnAdded(name: columnName), NotificationLevel.success);
    } catch (e) {
      AppLogger.debug('[AttributeTableDialogs] カラム追加エラー: $e');
      _notify(ref, t.attributeTable.columnAddError(error: '$e'), NotificationLevel.error);
    }
  }
}

/// フィルタ結果のフィーチャ複製ダイアログ
Future<void> showDuplicateFilteredDialog(
  BuildContext context,
  LayerNode layer,
  String filterSql,
  VoidCallback onDuplicated, {
  WidgetRef? ref,
}) async {
  final layerNameController = TextEditingController(
    text: '${layer.layerName}_filtered',
  );

  final matchCount = await layer.geoPackageFile.countFilteredFeatures(
    layer.layerName,
    filterSql,
  );

  if (!context.mounted) return;

  final result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) {
      return AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.copy_all, color: Colors.green),
            const SizedBox(width: 8),
            Text(t.attributeTable.duplicateFiltered),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.attributeTable.featuresCopyCount(count: '$matchCount'),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              t.attributeTable.filter(sql: filterSql),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: layerNameController,
              decoration: InputDecoration(
                labelText: t.attributeTable.newLayerName,
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t.common.cancel),
          ),
          ElevatedButton.icon(
            onPressed: () {
              final name = layerNameController.text.trim();
              if (name.isEmpty) {
                _notify(ref, t.attributeTable.enterLayerName, NotificationLevel.warning);
                return;
              }
              Navigator.of(dialogContext).pop(name);
            },
            icon: const Icon(Icons.copy_all),
            label: Text(t.attributeTable.duplicate),
          ),
        ],
      );
    },
  );

  if (result != null && context.mounted) {
    try {
      final gpkgFile = layer.geoPackageFile;
      final geomType = await gpkgFile.getGeometryType(layer.layerName);

      await gpkgFile.addLayer(result, geomType ?? GeometryType.point);

      final sourceColumns = await gpkgFile.getAttributeColumnInfo(
        layer.layerName,
        includeBuiltIn: false,
      );
      for (final col in sourceColumns) {
        final name = col['name'] as String;
        final type = col['type'] as String;
        if (name.toLowerCase() != 'geom' &&
            name.toLowerCase() != 'fid' &&
            name.toLowerCase() != 'id') {
          await gpkgFile.addAttributeColumn(result, name, type);
        }
      }

      final copiedCount = await gpkgFile.duplicateFilteredFeatures(
        layer.layerName,
        result,
        filterSql,
      );

      onDuplicated();
      _notify(
        ref,
        t.attributeTable.copiedToLayer(count: '$copiedCount', name: result),
        NotificationLevel.success,
      );
    } catch (e) {
      AppLogger.debug('[AttributeTableDialogs] フィルタ複製エラー: $e');
      _notify(ref, t.attributeTable.duplicateError(error: '$e'), NotificationLevel.error);
    }
  }
}

/// フィールド計算機ダイアログ
Future<void> showFieldCalculatorDialog(
  BuildContext context,
  LayerNode layer,
  List<String> columnNames,
  VoidCallback onUpdated, {
  WidgetRef? ref,
}) async {
  final expressionController = TextEditingController();
  String? selectedColumn;
  bool createNew = false;
  final newColumnController = TextEditingController();
  String newColumnType = 'TEXT';

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.calculate, color: Colors.deepPurple),
                const SizedBox(width: 8),
                Text(t.attributeTable.fieldCalculator),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: createNew,
                        onChanged:
                            (v) => setState(() => createNew = v ?? false),
                      ),
                      Text(t.attributeTable.createNewColumn, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                  if (createNew) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: newColumnController,
                            decoration: InputDecoration(
                              labelText: t.attributeTable.newColumnName,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 120,
                          child: DropdownButtonFormField<String>(
                            initialValue: newColumnType,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'TEXT',
                                child: Text('TEXT'),
                              ),
                              DropdownMenuItem(
                                value: 'INTEGER',
                                child: Text('INTEGER'),
                              ),
                              DropdownMenuItem(
                                value: 'REAL',
                                child: Text('REAL'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => newColumnType = v);
                            },
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: selectedColumn,
                      decoration: InputDecoration(
                        labelText: t.attributeTable.targetColumn,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      items:
                          columnNames
                              .where((c) => !c.startsWith('_'))
                              .map(
                                (c) =>
                                    DropdownMenuItem(value: c, child: Text(c)),
                              )
                              .toList(),
                      onChanged: (v) => setState(() => selectedColumn = v),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: expressionController,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: t.attributeTable.sqlExpression,
                      hintText: t.attributeTable.sqlExpressionHint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t.attributeTable.sqlHelp,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(t.common.cancel),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  final expr = expressionController.text.trim();
                  if (expr.isEmpty) return;

                  final target =
                      createNew
                          ? newColumnController.text.trim()
                          : selectedColumn;
                  if (target == null || target.isEmpty) return;

                  Navigator.of(dialogContext).pop({
                    'target': target,
                    'expression': expr,
                    'createNew': createNew,
                    'newType': newColumnType,
                  });
                },
                icon: const Icon(Icons.play_arrow),
                label: Text(t.attributeTable.execute),
              ),
            ],
          );
        },
      );
    },
  );

  if (result != null && context.mounted) {
    try {
      final target = result['target'] as String;
      final expression = result['expression'] as String;
      final isNew = result['createNew'] as bool;

      final validation = QgisExpressionFilter.toSqlWhere(expression);
      if (validation is FilterResultError) {
        _notify(ref, t.attributeTable.expressionError(message: validation.message), NotificationLevel.error);
        return;
      }

      if (isNew) {
        final newType = result['newType'] as String;
        await layer.geoPackageFile.addAttributeColumn(
          layer.layerName,
          target,
          newType,
        );
        layer.clearColumnNamesCache();
      }

      final updatedCount = await layer.geoPackageFile
          .updateColumnWithExpression(layer.layerName, target, expression);

      onUpdated();
      _notify(ref, t.attributeTable.updatedRows(count: '$updatedCount', column: target), NotificationLevel.success);
    } catch (e) {
      AppLogger.debug('[FieldCalculator] エラー: $e');
      _notify(ref, t.attributeTable.fieldCalcError(error: '$e'), NotificationLevel.error);
    }
  }
}

/// カラムリネームダイアログ
Future<void> showRenameColumnDialog(
  BuildContext context,
  LayerNode layer,
  String currentName,
  VoidCallback onRenamed, {
  WidgetRef? ref,
}) async {
  final controller = TextEditingController(text: currentName);

  final newName = await showDialog<String>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          title: Text(t.attributeTable.renameColumn),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: t.attributeTable.newColumnNameLabel,
              border: const OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.common.cancel),
            ),
            ElevatedButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty && name != currentName) {
                  Navigator.of(ctx).pop(name);
                }
              },
              child: Text(t.common.change),
            ),
          ],
        ),
  );

  if (newName != null && context.mounted) {
    try {
      await layer.geoPackageFile.renameColumn(
        layer.layerName,
        currentName,
        newName,
      );
      layer.clearColumnNamesCache();
      onRenamed();
      _notify(
        ref,
        t.attributeTable.columnRenamed(from: currentName, to: newName),
        NotificationLevel.success,
      );
    } catch (e) {
      AppLogger.debug('[RenameColumn] エラー: $e');
      _notify(ref, t.attributeTable.renameColumnError(error: '$e'), NotificationLevel.error);
    }
  }
}

/// カラム削除確認ダイアログ
Future<void> showDeleteColumnDialog(
  BuildContext context,
  LayerNode layer,
  String columnName,
  VoidCallback onDeleted, {
  WidgetRef? ref,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (ctx) => AlertDialog(
          title: Text(t.attributeTable.deleteColumn),
          content: Text(t.attributeTable.deleteColumnConfirm(name: columnName)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t.common.cancel),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.common.delete, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
  );

  if (confirmed == true && context.mounted) {
    try {
      await layer.geoPackageFile.dropColumn(layer.layerName, columnName);
      layer.clearColumnNamesCache();
      onDeleted();
      _notify(ref, t.attributeTable.columnDeleted(name: columnName), NotificationLevel.success);
    } catch (e) {
      AppLogger.debug('[DeleteColumn] エラー: $e');
      _notify(ref, t.attributeTable.deleteColumnError(error: '$e'), NotificationLevel.error);
    }
  }
}
