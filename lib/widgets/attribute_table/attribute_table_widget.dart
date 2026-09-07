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
// Root Maps: 属性テーブルウィジェット（リファクタリング版）
// TrinaGridを使用した属性テーブル表示・編集

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../providers/notification_providers.dart';
import '../../providers/selection_providers.dart';
import '../../utils/app_logger.dart';
import 'attribute_form_view.dart';
import 'attribute_table_controller.dart';
import 'attribute_table_dialogs.dart';
import 'attribute_table_toolbar.dart';

/// 動的属性テーブルウィジェット（リファクタリング版）
class AttributeTableWidget extends ConsumerStatefulWidget {
  final LayerNode layer;
  final Function(FeatureNode feature)? onFeatureSelected;
  final Function()? onAddFeature;

  const AttributeTableWidget({
    super.key,
    required this.layer,
    this.onFeatureSelected,
    this.onAddFeature,
  });

  @override
  ConsumerState<AttributeTableWidget> createState() =>
      _AttributeTableWidgetState();
}

enum _ViewMode { table, form }

class _AttributeTableWidgetState extends ConsumerState<AttributeTableWidget> {
  late AttributeTableController _controller;
  Key _plutoGridKey = UniqueKey();
  Map<String, dynamic>? _columnStats;
  String? _statsColumnName;
  _ViewMode _viewMode = _ViewMode.table;

  /// 表示中のフィーチャを読んだときの [LayerNode.featuresRevision]
  int _loadedRevision = -1;

  @override
  void initState() {
    super.initState();
    _controller = AttributeTableController(widget.layer, ref);
    _controller.addListener(_onControllerChanged);
    _loadedRevision = widget.layer.featuresRevision;
    _controller.initialize();
  }

  @override
  void didUpdateWidget(AttributeTableWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // レイヤが変わったとき、または同じレイヤのフィーチャが読み直されたとき
    // （View のフィルタを変えると件数が変わる）は作り直す。
    if (oldWidget.layer.layerName != widget.layer.layerName ||
        _loadedRevision != widget.layer.featuresRevision) {
      _controller.removeListener(_onControllerChanged);
      // dispose中のプロバイダ変更を遅延実行
      final oldController = _controller;
      Future.microtask(oldController.dispose);
      _controller = AttributeTableController(widget.layer, ref);
      _controller.addListener(_onControllerChanged);
      _loadedRevision = widget.layer.featuresRevision;
      _controller.initialize();
      _plutoGridKey = UniqueKey();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _rebuildGrid() {
    setState(() {
      _plutoGridKey = UniqueKey();
    });
    _controller.initialize();
  }

  @override
  Widget build(BuildContext context) {
    // 地図からの選択変更を監視してテーブル側に反映
    ref.listen<List<dynamic>>(selectedFeaturesProvider, (prev, next) {
      if (next.length == 1 && next.first is FeatureNode) {
        _controller.highlightFeatureOnCurrentPage(next.first as FeatureNode);
      }
    });

    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_controller.lastError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 32),
            const SizedBox(height: 8),
            Text(
              _controller.lastError!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                _controller.clearError();
                _rebuildGrid();
              },
              child: Text(t.attributeTable.retryButton),
            ),
          ],
        ),
      );
    }

    if (_controller.columns.isEmpty) {
      return Center(child: Text(t.attributeTable.noColumns));
    }

    return Column(
      children: [
        // ツールバー
        AttributeTableToolbar(
          controller: _controller,
          onRefresh: _rebuildGrid,
          onCopyTable: () => copyTableToClipboard(context, _controller, ref: ref),
          onAddFeature: widget.onAddFeature,
          onDeleteSelected: _handleDeleteSelected,
          onSave: _handleSave,
          onAddColumn:
              () => showAddColumnDialog(context, widget.layer, _rebuildGrid, ref: ref),
          onFieldCalculator:
              () => showFieldCalculatorDialog(
                context,
                widget.layer,
                _controller.columnNames,
                _rebuildGrid,
                ref: ref,
              ),
          onColumnAction: (columnName, action) {
            if (action == 'rename') {
              showRenameColumnDialog(
                context,
                widget.layer,
                columnName,
                _rebuildGrid,
                ref: ref,
              );
            } else if (action == 'delete') {
              showDeleteColumnDialog(
                context,
                widget.layer,
                columnName,
                _rebuildGrid,
                ref: ref,
              );
            }
          },
          onToggleView: () {
            setState(() {
              _viewMode =
                  _viewMode == _ViewMode.table
                      ? _ViewMode.form
                      : _ViewMode.table;
            });
          },
          isFormView: _viewMode == _ViewMode.form,
          onDuplicateFiltered:
              (filterSql) => showDuplicateFilteredDialog(
                context,
                widget.layer,
                filterSql,
                _rebuildGrid,
                ref: ref,
              ),
          onBatchEdit: _handleBatchEdit,
          onCsvExport: _handleCsvExport,
        ),

        // メインコンテンツ: テーブル or フォーム
        if (_viewMode == _ViewMode.form)
          Expanded(child: AttributeFormView(controller: _controller))
        else ...[
          Expanded(
            child: TrinaGrid(
              key: _plutoGridKey,
              columns: List.of(_controller.columns),
              rows: List.of(_controller.rows),
              mode: TrinaGridMode.normal,
              onLoaded: _onGridLoaded,
              onChanged: _onGridChanged,
              onRowChecked: _onRowChecked,
              createFooter: (stateManager) {
                return TrinaLazyPagination(
                  initialPage: 1,
                  initialFetch: false,
                  fetchWithSorting: false,
                  fetchWithFiltering: false,
                  fetch: _controller.fetchPage,
                  stateManager: stateManager,
                );
              },
              configuration: _buildGridConfiguration(),
            ),
          ),

          // 統計サマリバー
          _buildStatisticsBar(),
        ],
      ],
    );
  }

  void _onGridLoaded(TrinaGridOnLoadedEvent event) {
    _controller.setStateManager(event.stateManager);
    // 行選択モード（複数行のチェックボックス選択を許可）
    event.stateManager.setSelectingMode(TrinaGridSelectingMode.row);

    // セル選択時のフィーチャ選択処理
    event.stateManager.addListener(() {
      final currentRowIdx = event.stateManager.currentRowIdx;
      final currentCell = event.stateManager.currentCell;

      if (currentCell != null && currentRowIdx != null && currentRowIdx >= 0) {
        _controller.selectFeature(currentRowIdx);

        final absoluteIdx = _controller.currentPageOffset + currentRowIdx;
        if (absoluteIdx < _controller.features.length) {
          widget.onFeatureSelected?.call(_controller.features[absoluteIdx]);
        }
      }
    });
  }

  void _onGridChanged(TrinaGridOnChangedEvent event) async {
    final rowIndex = event.rowIdx;
    final field = event.column.field;
    final newValue = event.value;

    final absoluteIndex = _controller.currentPageOffset + rowIndex;
    if (absoluteIndex < _controller.features.length) {
      final feature = _controller.features[absoluteIndex];
      final error = await _controller.saveAttributeChange(
        feature,
        field,
        newValue,
      );
      if (error != null) {
        ref.read(notificationCenterProvider.notifier).add(
          title: error,
          level: NotificationLevel.error,
        );
      }
    }
  }

  Future<void> _handleDeleteSelected() async {
    await _controller.deleteSelectedFeatures();
    ref.read(notificationCenterProvider.notifier).add(
      title: t.attributeTable.featureDeleted,
      level: NotificationLevel.success,
    );
  }

  Future<void> _handleSave() async {
    try {
      await widget.layer.geoPackageFile.flushChanges();
      ref.read(notificationCenterProvider.notifier).add(
        title: t.attributeTable.saved,
        level: NotificationLevel.info,
      );
    } catch (e) {
      AppLogger.debug('[AttributeTableWidget] 保存エラー: $e');
      ref.read(notificationCenterProvider.notifier).add(
        title: t.attributeTable.saveError(field: '', error: e.toString()),
        level: NotificationLevel.error,
      );
    }
  }

  /// Phase 3: 行チェック変更時
  void _onRowChecked(TrinaGridOnRowCheckedEvent event) {
    setState(() {});
  }

  /// Phase 3: 一括編集ダイアログ
  Future<void> _handleBatchEdit() async {
    final checkedCount = _controller.checkedRowCount;
    if (checkedCount == 0) {
      ref.read(notificationCenterProvider.notifier).add(
        title: t.attributeTable.checkRows,
        level: NotificationLevel.warning,
      );
      return;
    }

    final editableColumns = _controller.columnNames
        .where((c) =>
            !c.startsWith('_') &&
            c.toLowerCase() != 'id' &&
            c.toLowerCase() != 'fid')
        .toList();

    String? selectedColumn;
    final valueController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(t.attributeTable.batchEditTitle(count: '$checkedCount')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: selectedColumn,
                decoration: InputDecoration(
                  labelText: t.attributeTable.targetColumn,
                  isDense: true,
                ),
                items: editableColumns
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setDialogState(() => selectedColumn = v),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: valueController,
                decoration: InputDecoration(
                  labelText: t.attributeTable.setValue,
                  isDense: true,
                  hintText: t.attributeTable.setValueHint,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.common.cancel),
            ),
            FilledButton(
              onPressed: selectedColumn != null
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: Text(t.attributeTable.apply),
            ),
          ],
        ),
      ),
    );

    if (result == true && selectedColumn != null) {
      final value = valueController.text.isEmpty ? null : valueController.text;
      final count = await _controller.batchSetValue(selectedColumn!, value);
      _rebuildGrid();
      ref.read(notificationCenterProvider.notifier).add(
        title: t.attributeTable.batchUpdated(count: '$count'),
        level: NotificationLevel.success,
      );
    }
    valueController.dispose();
  }

  /// Phase 3: CSVエクスポート
  Future<void> _handleCsvExport() async {
    try {
      final csv = await _controller.exportToCsvAsync();
      final layerName = widget.layer.layerName;
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .substring(0, 19);
      final fileName = '${layerName}_$timestamp.csv';

      final file = File(fileName);
      await file.writeAsString(csv);

      ref.read(notificationCenterProvider.notifier).add(
        title: t.attributeTable.csvExported(name: fileName),
        level: NotificationLevel.success,
      );
    } catch (e) {
      ref.read(notificationCenterProvider.notifier).add(
        title: t.attributeTable.csvExportError(error: e.toString()),
        level: NotificationLevel.error,
      );
    }
  }



  Widget _buildStatisticsBar() {
    final editableColumns =
        _controller.columnNames.where((c) => !c.startsWith('_')).toList();

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            height: 24,
            child: DropdownButtonFormField<String>(
              initialValue: _statsColumnName,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(horizontal: 4),
                border: InputBorder.none,
                isDense: true,
              ),
              style: const TextStyle(fontSize: 12, color: Colors.black87),
              hint: Text(t.attributeTable.statsColumn, style: const TextStyle(fontSize: 12)),
              items:
                  editableColumns
                      .map(
                        (c) => DropdownMenuItem(
                          value: c,
                          child: Text(c, style: const TextStyle(fontSize: 12)),
                        ),
                      )
                      .toList(),
              onChanged: (v) async {
                if (v != null) {
                  final stats = await _controller.getColumnStatistics(v);
                  setState(() {
                    _statsColumnName = v;
                    _columnStats = stats;
                  });
                }
              },
            ),
          ),
          if (_columnStats != null) ...[
            const SizedBox(width: 8),
            _buildStatChip(t.attributeTable.statCount, '${_columnStats!['count']}'),
            _buildStatChip(t.attributeTable.statUnique, '${_columnStats!['unique']}'),
            if (_columnStats!['sum'] != null)
              _buildStatChip(t.attributeTable.statSum, _formatStat(_columnStats!['sum'])),
            if (_columnStats!['avg'] != null)
              _buildStatChip(t.attributeTable.statAvg, _formatStat(_columnStats!['avg'])),
            _buildStatChip(t.attributeTable.statMin, '${_columnStats!['min'] ?? '-'}'),
            _buildStatChip(t.attributeTable.statMax, '${_columnStats!['max'] ?? '-'}'),
          ],
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(
        '$label: $value',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
      ),
    );
  }

  String _formatStat(dynamic value) {
    if (value is double) return value.toStringAsFixed(2);
    return '$value';
  }

  TrinaGridConfiguration _buildGridConfiguration() {
    return TrinaGridConfiguration(
      columnSize: const TrinaGridColumnSizeConfig(
        autoSizeMode: TrinaAutoSizeMode.none,
        resizeMode: TrinaResizeMode.normal,
      ),
      style: TrinaGridStyleConfig(
        rowHeight: 32,
        columnHeight: 36,
        cellTextStyle: const TextStyle(fontSize: 13, height: 1.2),
        columnTextStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          height: 1.2,
        ),
        borderColor: Colors.grey.shade300,
        activatedBorderColor: Colors.blue.shade300,
        evenRowColor: Colors.grey.shade50,
        oddRowColor: Colors.white,
      ),
      scrollbar: const TrinaGridScrollbarConfig(
        thickness: 8,
      ),
      shortcut: const TrinaGridShortcut(actions: {}),
      enterKeyAction: TrinaGridEnterKeyAction.none,
    );
  }
}
