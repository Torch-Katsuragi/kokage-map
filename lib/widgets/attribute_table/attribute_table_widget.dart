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

/// 統計バーで選んだ列とその統計
typedef _ColumnStats = ({String column, Map<String, dynamic> stats});

class _AttributeTableWidgetState extends ConsumerState<AttributeTableWidget> {
  late AttributeTableController _controller;
  Key _plutoGridKey = UniqueKey();
  _ViewMode _viewMode = _ViewMode.table;

  /// 統計バーの中身。統計バーだけを描き直す（表ごと組み立て直さない）
  final _columnStats = ValueNotifier<_ColumnStats?>(null);

  /// 表示中のフィーチャを読んだときの [LayerNode.featuresRevision]
  int _loadedRevision = -1;

  /// 表に渡す列・行の写し（[_gridInput]）
  List<TrinaColumn>? _gridColumnsSource;
  List<TrinaRow>? _gridRowsSource;
  List<TrinaColumn> _gridColumns = const [];
  List<TrinaRow> _gridRows = const [];

  /// 表の見た目（毎回作らない）
  static final _gridConfiguration = TrinaGridConfiguration(
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
    scrollbar: const TrinaGridScrollbarConfig(thickness: 8),
    shortcut: const TrinaGridShortcut(actions: {}),
    enterKeyAction: TrinaGridEnterKeyAction.none,
  );

  @override
  void initState() {
    super.initState();
    _attachController();
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
      _attachController();
      _plutoGridKey = UniqueKey();
    }
  }

  void _attachController() {
    _controller = AttributeTableController(widget.layer, ref);
    _controller.addListener(_onControllerChanged);
    _gridDisplayRevision = _controller.displayRevision;
    _loadedRevision = widget.layer.featuresRevision;
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _columnStats.dispose();
    super.dispose();
  }

  int _gridDisplayRevision = 0;

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {
      if (_controller.displayRevision != _gridDisplayRevision) {
        _gridDisplayRevision = _controller.displayRevision;
        _plutoGridKey = UniqueKey(); // 絞った一覧の 1 ページ目から作り直す
      }
    });
  }

  void _rebuildGrid() {
    setState(() {
      _plutoGridKey = UniqueKey();
    });
    _controller.initialize();
  }

  void _notify(String title, NotificationLevel level) {
    ref.read(notificationCenterProvider.notifier).add(title: title, level: level);
  }

  @override
  Widget build(BuildContext context) {
    // 地図からの選択変更を監視してテーブル側に反映
    ref.listen<List<dynamic>>(selectedFeaturesProvider, (prev, next) {
      if (next.length == 1 && next.first is FeatureNode) {
        _controller.highlightFeatureOnCurrentPage(next.first as FeatureNode);
      }
    });

    final showGrid = !_controller.isLoading &&
        _controller.lastError == null &&
        _controller.columns.isNotEmpty &&
        _viewMode == _ViewMode.table;
    // 表が消えたら写しを捨てる（次に表を作るときは読み込んだままの行から）
    if (!showGrid) _gridRowsSource = null;

    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_controller.lastError != null) return _buildError();
    if (_controller.columns.isEmpty) {
      return Center(child: Text(t.attributeTable.noColumns));
    }

    return Column(
      children: [
        _buildToolbar(),
        // メインコンテンツ: テーブル or フォーム
        if (_viewMode == _ViewMode.form)
          Expanded(child: AttributeFormView(controller: _controller))
        else ...[
          Expanded(child: _buildGrid()),
          _buildStatisticsBar(),
        ],
      ],
    );
  }

  Widget _buildError() {
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

  Widget _buildToolbar() {
    return AttributeTableToolbar(
      controller: _controller,
      onRefresh: _rebuildGrid,
      onCopyTable: () => copyTableToClipboard(context, _controller, ref: ref),
      onAddFeature: widget.onAddFeature,
      onDeleteSelected: _handleDeleteSelected,
      onSave: _handleSave,
      onAddColumn: () =>
          showAddColumnDialog(context, widget.layer, _rebuildGrid, ref: ref),
      onFieldCalculator: () => showFieldCalculatorDialog(
        context,
        widget.layer,
        _controller.userColumnNames,
        _rebuildGrid,
        ref: ref,
      ),
      onColumnAction: _handleColumnAction,
      onToggleView: () => setState(() {
        _viewMode =
            _viewMode == _ViewMode.table ? _ViewMode.form : _ViewMode.table;
      }),
      isFormView: _viewMode == _ViewMode.form,
      onDuplicateFiltered: (filterSql) => showDuplicateFilteredDialog(
        context,
        widget.layer,
        filterSql,
        _rebuildGrid,
        ref: ref,
      ),
      onBatchEdit: _handleBatchEdit,
      onCsvExport: _handleCsvExport,
    );
  }

  void _handleColumnAction(String columnName, String action) {
    if (action == 'rename') {
      showRenameColumnDialog(context, widget.layer, columnName, _rebuildGrid, ref: ref);
    } else if (action == 'delete') {
      showDeleteColumnDialog(context, widget.layer, columnName, _rebuildGrid, ref: ref);
    }
  }

  /// TrinaGrid は作るときにしか列・行を読まず、渡した一覧を書き換える（ページ送り・並べ替え）。
  /// コントローラの一覧を守るため写して渡すが、写すのは一覧が替わったときだけにする（以前は組み立てのたびに写していた）
  (List<TrinaColumn>, List<TrinaRow>) _gridInput() {
    if (!identical(_gridColumnsSource, _controller.columns) ||
        !identical(_gridRowsSource, _controller.rows)) {
      _gridColumnsSource = _controller.columns;
      _gridRowsSource = _controller.rows;
      _gridColumns = List.of(_controller.columns);
      _gridRows = List.of(_controller.rows);
    }
    return (_gridColumns, _gridRows);
  }

  Widget _buildGrid() {
    final (columns, rows) = _gridInput();
    return TrinaGrid(
      key: _plutoGridKey,
      columns: columns,
      rows: rows,
      mode: TrinaGridMode.normal,
      onLoaded: _onGridLoaded,
      onChanged: _onGridChanged,
      createFooter: (stateManager) {
        return TrinaLazyPagination(
          initialPage: 1,
          // ⚠ 最初の取得をしないと総ページ数が 0 のままで、先頭のページから先へ進めない（2026-10-07 に Fold で確認）
          initialFetch: true,
          fetchWithSorting: false,
          fetchWithFiltering: false,
          fetch: _controller.fetchPage,
          stateManager: stateManager,
        );
      },
      configuration: _gridConfiguration,
    );
  }

  void _onGridLoaded(TrinaGridOnLoadedEvent event) {
    _controller.setStateManager(event.stateManager);
    // 行選択モード（複数行のチェックボックス選択を許可）
    event.stateManager.setSelectingMode(TrinaGridSelectingMode.row);

    // セル選択時のフィーチャ選択処理。表の通知はスクロールや入力でも来るので、今いる行が変わったときだけ選び直す
    // （以前は通知のたびに選択・地図の寄せ・setState をしていた）
    final stateManager = event.stateManager;
    FeatureNode? lastFeature;
    stateManager.addListener(() {
      final currentRowIdx = stateManager.currentRowIdx;
      if (stateManager.currentCell == null || currentRowIdx == null || currentRowIdx < 0) return;
      final feature = AttributeTableController.featureOfRow(stateManager.currentRow);
      if (feature == null) return;
      // 同じ行でも、地図で別のものを選んだあとなら選び直す
      if (identical(feature, lastFeature) && ref.read(selectedFeaturesProvider).contains(feature)) return;
      lastFeature = feature;
      _controller.selectFeature(feature);
      widget.onFeatureSelected?.call(feature);
    });

    // 開いたときに地図で選んでいるものがあれば、その行に色を付ける（選択の変化しか見ていなかったので、
    // 先に選んでから表を開くと色が付かなかった。2026-10-01 チュートリアルで発覚）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selected = ref.read(selectedFeaturesProvider);
      if (selected.length == 1 && selected.first is FeatureNode) {
        _controller.highlightFeatureOnCurrentPage(selected.first as FeatureNode);
      }
    });
  }

  void _onGridChanged(TrinaGridOnChangedEvent event) async {
    final feature = AttributeTableController.featureOfRow(event.row);
    if (feature == null) return;
    final error = await _controller.saveAttributeChange(
      feature,
      event.column.field,
      event.value,
    );
    if (error != null) _notify(error, NotificationLevel.error);
  }

  Future<void> _handleDeleteSelected() async {
    await _controller.deleteSelectedFeatures();
    _notify(t.attributeTable.featureDeleted, NotificationLevel.success);
  }

  Future<void> _handleSave() async {
    try {
      await widget.layer.geoPackageFile.flushChanges();
      _notify(t.attributeTable.saved, NotificationLevel.info);
    } catch (e) {
      AppLogger.debug('[AttributeTableWidget] 保存エラー: $e');
      _notify(
        t.attributeTable.saveError(field: '', error: e.toString()),
        NotificationLevel.error,
      );
    }
  }

  /// Phase 3: 一括編集
  Future<void> _handleBatchEdit() async {
    final checkedCount = _controller.checkedRowCount;
    if (checkedCount == 0) {
      _notify(t.attributeTable.checkRows, NotificationLevel.warning);
      return;
    }

    final result = await showBatchEditDialog(
      context,
      checkedCount: checkedCount,
      columns: _controller.writableColumnNames,
    );
    if (result == null) return;
    final count = await _controller.batchSetValue(result.column, result.value);
    _rebuildGrid();
    _notify(
      t.attributeTable.batchUpdated(count: '$count'),
      NotificationLevel.success,
    );
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

      _notify(
        t.attributeTable.csvExported(name: fileName),
        NotificationLevel.success,
      );
    } catch (e) {
      _notify(
        t.attributeTable.csvExportError(error: e.toString()),
        NotificationLevel.error,
      );
    }
  }

  Widget _buildStatisticsBar() {
    final theme = Theme.of(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.dividerColor, width: 0.5),
        ),
      ),
      child: ValueListenableBuilder<_ColumnStats?>(
        valueListenable: _columnStats,
        builder: (context, selected, _) => Row(
          children: [
            SizedBox(
              width: 120,
              height: 24,
              child: DropdownButtonFormField<String>(
                initialValue: selected?.column,
                isDense: true,
                isExpanded: true,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                  border: InputBorder.none,
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 12, color: Colors.black87),
                hint: Text(t.attributeTable.statsColumn, style: const TextStyle(fontSize: 12)),
                items: [
                  for (final c in _controller.userColumnNames)
                    DropdownMenuItem(
                      value: c,
                      child: Text(c, style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  final stats = await _controller.getColumnStatistics(v);
                  if (mounted) _columnStats.value = (column: v, stats: stats);
                },
              ),
            ),
            if (selected != null) ..._statChips(selected.stats),
          ],
        ),
      ),
    );
  }

  List<Widget> _statChips(Map<String, dynamic> stats) => [
        const SizedBox(width: 8),
        _buildStatChip(t.attributeTable.statCount, '${stats['count']}'),
        _buildStatChip(t.attributeTable.statUnique, '${stats['unique']}'),
        if (stats['sum'] != null)
          _buildStatChip(t.attributeTable.statSum, _formatStat(stats['sum'])),
        if (stats['avg'] != null)
          _buildStatChip(t.attributeTable.statAvg, _formatStat(stats['avg'])),
        _buildStatChip(t.attributeTable.statMin, '${stats['min'] ?? '-'}'),
        _buildStatChip(t.attributeTable.statMax, '${stats['max'] ?? '-'}'),
      ];

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
}
