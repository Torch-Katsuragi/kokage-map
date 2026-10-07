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
// Root Maps: 属性テーブルツールバー
// 座標系選択、各種操作ボタンを提供

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/feature_node.dart';
import '../../providers/notification_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../screens/layer_style_settings_screen.dart' show layerStyleSettings, labelEnabledDef, labelPropertyDef;
import '../../services/coordinate/index.dart';
import '../../services/kmeta_service.dart';
import '../../utils/app_logger.dart';
import '../label_composer_dialog.dart';
import 'attribute_table_controller.dart';

/// 属性テーブルツールバー
class AttributeTableToolbar extends ConsumerStatefulWidget {
  final AttributeTableController controller;
  final VoidCallback? onRefresh;
  final VoidCallback? onCopyTable;
  final VoidCallback? onAddFeature;
  final VoidCallback? onDeleteSelected;
  final VoidCallback? onSave;
  final VoidCallback? onAddColumn;
  final VoidCallback? onFieldCalculator;
  final void Function(String columnName, String action)? onColumnAction;
  final VoidCallback? onToggleView;
  final bool isFormView;
  final Future<void> Function(String expression)? onDuplicateFiltered;
  final VoidCallback? onBatchEdit;
  final VoidCallback? onCsvExport;

  const AttributeTableToolbar({
    super.key,
    required this.controller,
    this.onRefresh,
    this.onCopyTable,
    this.onAddFeature,
    this.onDeleteSelected,
    this.onSave,
    this.onAddColumn,
    this.onFieldCalculator,
    this.onColumnAction,
    this.onToggleView,
    this.isFormView = false,
    this.onDuplicateFiltered,
    this.onBatchEdit,
    this.onCsvExport,
  });

  @override
  ConsumerState<AttributeTableToolbar> createState() =>
      _AttributeTableToolbarState();
}

class _AttributeTableToolbarState extends ConsumerState<AttributeTableToolbar> {
  final _filterController = TextEditingController();
  bool _isFilterApplied = false;
  bool _showFilter = false;

  // 検索・置換
  bool _showSearchReplace = false;
  final _searchController = TextEditingController();
  final _replaceController = TextEditingController();
  String? _selectedReplaceColumn;
  int _searchResultCount = 0;

  @override
  void dispose() {
    _filterController.dispose();
    _searchController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  Future<void> _applyFilter() async {
    final expression = _filterController.text.trim();
    if (expression.isEmpty) {
      await _clearFilter();
      return;
    }
    final error = await widget.controller.applyFilter(expression);
    setState(() => _isFilterApplied = error == null);
    if (error != null) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(title: t.attributeTable.filterError(error: error), level: NotificationLevel.error);
    }
  }

  Future<void> _clearFilter() async {
    _filterController.clear();
    await widget.controller.clearFilter();
    setState(() => _isFilterApplied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 上段: レイヤー名（左） + アイコン群（右端）
          Row(
            children: [
              // 左側（レイヤー名と座標系）。縦持ちで幅が足りなければこちらを縮める（右端のアイコン群は削らない）
              Expanded(child: _buildTitle(context)),

              // ラベルの組み立て（列を選んで並べる）
              _buildIconButton(
                Icons.label_outline,
                null,
                () => _openLabelComposer(context),
                t.attributeTable.labelComposer,
              ),
              // フィルタトグル
              _buildIconButton(
                Icons.filter_alt,
                _isFilterApplied
                    ? Colors.orange
                    : (_showFilter ? Colors.blue : null),
                () => setState(() => _showFilter = !_showFilter),
                t.attributeTable.filterLabel,
              ),
              // 検索・置換トグル
              _buildIconButton(
                Icons.find_replace,
                _showSearchReplace ? Colors.orange : null,
                () => setState(() => _showSearchReplace = !_showSearchReplace),
                t.attributeTable.searchReplace,
              ),
              // テーブル/フォーム切替
              _buildIconButton(
                widget.isFormView ? Icons.table_chart : Icons.article,
                widget.isFormView ? Colors.orange : null,
                widget.onToggleView,
                widget.isFormView ? t.attributeTable.tableView : t.attributeTable.formView,
              ),
              // 操作メニュー（ドロップダウン）
              _buildActionsMenu(context),
            ],
          ),
          // フィルタバー（トグル表示）
          if (_showFilter) _buildFilterBar(context),
          // 検索・置換バー
          if (_showSearchReplace) _buildSearchReplaceBar(context),
        ],
      ),
    );
  }

  /// レイヤー名（件数）と、点レイヤなら座標の出し方
  Widget _buildTitle(BuildContext context) {
    final ctrl = widget.controller;
    return Row(
      children: [
        // レイヤー名
        Flexible(
          child: Text(
            ctrl.isFiltered
                ? '${ctrl.layer.layerName} (${ctrl.filteredCount}/${ctrl.totalCount})'
                : '${ctrl.layer.layerName} (${ctrl.totalCount})',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 1.2,
              color: ctrl.isFiltered ? Colors.orange.shade800 : null,
            ),
          ),
        ),
        if (ctrl.isPointLayer) ...[
          const SizedBox(width: 8),
          _buildWgs84Checkbox(context),
          const SizedBox(width: 8),
          Flexible(child: _buildEpsgSelector(context)),
        ],
      ],
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Icon(
              Icons.filter_alt,
              size: 16,
              color: _isFilterApplied ? Colors.orange : Colors.grey,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _filterController,
                style: const TextStyle(fontSize: 13),
                decoration: _fieldDecoration(
                  '"name" = \'Tokyo\'  |  "pop" > 1000',
                  hintSize: 11,
                  horizontalPadding: 8,
                  suffixIcon: _isFilterApplied
                      ? GestureDetector(
                          onTap: _clearFilter,
                          child: Icon(
                            Icons.clear,
                            size: 14,
                            color: Colors.orange.shade700,
                          ),
                        )
                      : null,
                ),
                onSubmitted: (_) => _applyFilter(),
              ),
            ),
            const SizedBox(width: 4),
            _smallButton(
              t.attributeTable.apply,
              _applyFilter,
              height: 24,
              horizontalPadding: 8,
              fontSize: 11,
              color: Colors.blue,
            ),
            if (_isFilterApplied && widget.onDuplicateFiltered != null) ...[
              const SizedBox(width: 2),
              _smallButton(
                t.attributeTable.duplicate,
                () => widget.onDuplicateFiltered?.call(widget.controller.filterSql),
                height: 24,
                horizontalPadding: 6,
                fontSize: 11,
                color: Colors.green.shade700,
                icon: Icons.copy_all,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSearchReplaceBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            Icon(Icons.search, size: 14, color: Colors.blue.shade700),
            const SizedBox(width: 4),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(fontSize: 11),
                decoration: _fieldDecoration(t.attributeTable.search, hintSize: 10),
                onSubmitted: (_) => _doSearch(),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 120,
              child: TextField(
                controller: _replaceController,
                style: const TextStyle(fontSize: 11),
                decoration: _fieldDecoration(t.attributeTable.replace, hintSize: 10),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 100,
              height: 24,
              child: DropdownButtonFormField<String>(
                initialValue: _selectedReplaceColumn,
                isDense: true,
                isExpanded: true,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 10, color: Colors.black87),
                hint: Text(t.attributeTable.column, style: const TextStyle(fontSize: 10)),
                items: [
                  for (final c in widget.controller.userColumnNames)
                    DropdownMenuItem(
                      value: c,
                      child: Text(c, style: const TextStyle(fontSize: 10)),
                    ),
                ],
                onChanged: (v) => setState(() => _selectedReplaceColumn = v),
              ),
            ),
            const SizedBox(width: 4),
            _smallButton(
              t.attributeTable.searchButton,
              _doSearch,
              height: 22,
              horizontalPadding: 6,
              fontSize: 10,
            ),
            _smallButton(
              t.attributeTable.replaceButton,
              _doReplace,
              height: 22,
              horizontalPadding: 6,
              fontSize: 10,
              color: Colors.orange.shade800,
            ),
            if (_searchResultCount > 0)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  t.attributeTable.resultCount(count: '$_searchResultCount'),
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// フィルタ・検索・置換の小さな入力欄の枠
  static InputDecoration _fieldDecoration(
    String hint, {
    required double hintSize,
    double horizontalPadding = 6,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      contentPadding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 4,
      ),
      border: const OutlineInputBorder(),
      isDense: true,
      hintText: hint,
      hintStyle: TextStyle(fontSize: hintSize, color: Colors.grey.shade400),
      suffixIcon: suffixIcon,
    );
  }

  /// フィルタ・検索・置換の小さな文字ボタン（[icon] があればアイコン付き）
  static Widget _smallButton(
    String label,
    VoidCallback onPressed, {
    required double height,
    required double horizontalPadding,
    required double fontSize,
    Color? color,
    IconData? icon,
  }) {
    final style = TextButton.styleFrom(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: color,
    );
    final text = Text(label, style: TextStyle(fontSize: fontSize));
    return SizedBox(
      height: height,
      child: icon == null
          ? TextButton(style: style, onPressed: onPressed, child: text)
          : TextButton.icon(
              style: style,
              icon: Icon(icon, size: 14),
              label: text,
              onPressed: onPressed,
            ),
    );
  }

  Future<void> _doSearch() async {
    final text = _searchController.text.trim();
    if (text.isEmpty) return;
    final results = await widget.controller.searchText(text);
    setState(() => _searchResultCount = results.length);
    if (results.isEmpty) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(title: t.attributeTable.noResults, level: NotificationLevel.info);
    }
  }

  Future<void> _doReplace() async {
    final search = _searchController.text.trim();
    final replace = _replaceController.text;
    final column = _selectedReplaceColumn;
    if (search.isEmpty || column == null) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(
            title: t.attributeTable.specifySearchAndColumn,
            level: NotificationLevel.warning,
          );
      return;
    }
    try {
      final count = await widget.controller.replaceText(
        column,
        search,
        replace,
      );
      setState(() => _searchResultCount = 0);
      ref
          .read(notificationCenterProvider.notifier)
          .add(title: t.attributeTable.replacedCount(count: '$count'), level: NotificationLevel.success);
      widget.onRefresh?.call();
    } catch (e) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(title: t.attributeTable.replaceError(error: '$e'), level: NotificationLevel.error);
    }
  }

  Widget _buildWgs84Checkbox(BuildContext context) {
    return SizedBox(
      height: 22,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: widget.controller.settings.showWgs84,
              onChanged: (value) {
                widget.controller.updateSettings(
                  widget.controller.settings.copyWith(showWgs84: value ?? true),
                );
              },
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const Text('WGS84', style: TextStyle(fontSize: 9)),
        ],
      ),
    );
  }

  Widget _buildEpsgSelector(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200, maxHeight: 22),
      child: _EpsgAutocomplete(
        initialValue: widget.controller.settings.additionalEpsg,
        onSelected: (epsg) {
          widget.controller.updateSettings(
            widget.controller.settings.copyWith(additionalEpsg: epsg),
          );
        },
        onCleared: () {
          widget.controller.updateSettings(
            widget.controller.settings.copyWith(clearAdditionalEpsg: true),
          );
        },
      ),
    );
  }



  /// 操作メニュー（ドロップダウン）
  Widget _buildActionsMenu(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      iconSize: 18,
      padding: EdgeInsets.zero,
      tooltip: t.attributeTable.actionsMenu,
      constraints: const BoxConstraints(),
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(28, 28)),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      onSelected: (value) {
        switch (value) {
          case 'refresh':
            widget.onRefresh?.call();
          case 'copy':
            widget.onCopyTable?.call();
          case 'save':
            widget.onSave?.call();
          case 'add_feature':
            widget.onAddFeature?.call();
          case 'delete':
            widget.onDeleteSelected?.call();
          case 'add_column':
            widget.onAddColumn?.call();
          case 'field_calc':
            widget.onFieldCalculator?.call();
          case 'column_menu':
            _showColumnMenu(context);
          case 'batch_edit':
            widget.onBatchEdit?.call();
          case 'csv_export':
            widget.onCsvExport?.call();
        }
      },
      itemBuilder: (ctx) => [
        _menuItem('refresh', Icons.refresh, t.attributeTable.refresh),
        _menuItem('save', Icons.save, t.attributeTable.save),
        const PopupMenuDivider(),
        _menuItem('copy', Icons.copy, t.attributeTable.copyTable),
        _menuItem('csv_export', Icons.download, t.attributeTable.csvExport),
        const PopupMenuDivider(),
        _menuItem('batch_edit', Icons.edit_note, t.attributeTable.batchEdit),
        _menuItem('field_calc', Icons.calculate, t.attributeTable.fieldCalculator),
        const PopupMenuDivider(),
        _menuItem('add_column', Icons.add_box, t.attributeTable.addColumnMenu),
        _menuItem('column_menu', Icons.view_column, t.attributeTable.columnVisibility),
        if (widget.onAddFeature != null) ...[
          const PopupMenuDivider(),
          _menuItem('add_feature', Icons.add, t.attributeTable.addFeature),
        ],
        const PopupMenuDivider(),
        _menuItem('delete', Icons.delete, t.attributeTable.deleteSelectedFeatures, iconColor: Colors.red),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? iconColor,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// カラム表示/非表示メニューを表示
  void _showColumnMenu(BuildContext context) {
    final ctrl = widget.controller;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 200,
        100,
        0,
        0,
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 32,
          child: Text(
            t.attributeTable.columnVisibility,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '_show_all',
          height: 32,
          child: Row(
            children: [
              const Icon(Icons.visibility, size: 16),
              const SizedBox(width: 8),
              Text(t.attributeTable.showAll, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        for (final col in ctrl.columnNames)
          _columnMenuItem(context, col, hidden: ctrl.hiddenColumns.contains(col)),
      ],
    ).then((value) {
      if (value == '_show_all') {
        ctrl.showAllColumns();
      } else if (value != null) {
        ctrl.toggleColumnVisibility(value);
      }
    });
  }

  /// 列の表示/非表示メニューの 1 行（押すと切り替え。右に改名・削除）
  PopupMenuItem<String> _columnMenuItem(
    BuildContext context,
    String col, {
    required bool hidden,
  }) {
    final onColumnAction = widget.onColumnAction;
    return PopupMenuItem<String>(
      value: col,
      height: 28,
      child: Row(
        children: [
          Icon(
            hidden ? Icons.visibility_off : Icons.visibility,
            size: 14,
            color: hidden ? Colors.grey : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              col,
              style: TextStyle(fontSize: 12, color: hidden ? Colors.grey : null),
            ),
          ),
          if (onColumnAction != null) ...[
            InkWell(
              onTap: () {
                Navigator.pop(context);
                onColumnAction(col, 'rename');
              },
              child: const Icon(Icons.edit, size: 14),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () {
                Navigator.pop(context);
                onColumnAction(col, 'delete');
              },
              child: const Icon(Icons.delete, size: 14, color: Colors.red),
            ),
          ],
        ],
      ),
    );
  }

  /// 地図に出すラベルを列の組み合わせで決める。結果はレイヤ固有スタイル
  /// （フォルダ設定（`.qgs`） の `styles.layers[<layer>].labelProperty`）に保存する
  Future<void> _openLabelComposer(BuildContext context) async {
    final layer = widget.controller.layer;
    final folderPath = layer.folderNode?.getAbsoluteFilePath();
    if (folderPath == null) return;
    final current = await layer.getKmetaStyle();
    final rows = layer.children
        .whereType<FeatureNode>()
        .map((f) => f.turfFeature.properties?.cast<String, Object?>())
        .toList();
    final columns = widget.controller.userColumnNames;
    if (!context.mounted) return;
    final result = await showLabelComposerDialog(
      context,
      columns: columns,
      initialTemplate: layerStyleSettings.resolveString(labelPropertyDef, current),
      initialEnabled: layerStyleSettings.resolveBool(labelEnabledDef, current),
      sampleProps: rows.firstOrNull,
      fillRates: rows.isEmpty ? null : columnFillRates(rows, columns),
    );
    if (result == null) return;

    final style = (current ?? const KMetaLayerStyle()).copyWith(
      labelProperty: result.template,
      labelEnabled: result.enabled,
    );
    await KMetaService.instance.setLayerStyle(folderPath, layer.layerKey, style);
    layer.folderNode?.invalidateMetaCache();
    layer.invalidateKmetaStyleCache();
    await layer.refreshStyleGroups();
    ref.read(featureRefreshTriggerProvider.notifier).trigger();
  }

  Widget _buildIconButton(
    IconData icon,
    Color? color,
    VoidCallback? onPressed,
    String tooltip,
  ) {
    return SizedBox(
      width: 20,
      height: 20,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 12,
        icon: Icon(icon, color: color),
        onPressed: onPressed,
        tooltip: tooltip,
      ),
    );
  }
}

/// EPSG座標系オートコンプリート。
/// 選び直すと表を読み直してツールバーごと作り直すので、入っている文字は [initialValue] から始まる
class _EpsgAutocomplete extends StatelessWidget {
  final EpsgDefinition? initialValue;
  final ValueChanged<EpsgDefinition> onSelected;
  final VoidCallback onCleared;

  const _EpsgAutocomplete({
    this.initialValue,
    required this.onSelected,
    required this.onCleared,
  });

  static EpsgRegistry get _registry => EpsgRegistry.instance;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<EpsgDefinition>(
      initialValue: TextEditingValue(text: initialValue?.displayString ?? ''),
      optionsBuilder: (TextEditingValue value) {
        return _registry.search(value.text);
      },
      displayStringForOption: (option) => option.displayString,
      onSelected: onSelected,
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(fontSize: 8, height: 1.0),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 2,
            ),
            border: const OutlineInputBorder(),
            isDense: true,
            hintText: t.attributeTable.epsgHint,
            hintStyle: const TextStyle(fontSize: 8),
            suffixIcon:
                initialValue != null
                    ? GestureDetector(
                      onTap: () {
                        controller.clear();
                        onCleared();
                      },
                      child: const Icon(Icons.clear, size: 12),
                    )
                    : null,
          ),
          onSubmitted: (value) {
            final code = value.split(' ').first.trim();
            if (code.isNotEmpty) {
              final epsg = _registry.getByCode(code);
              if (epsg != null) {
                onSelected(epsg);
              }
            }
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4.0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 380),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(
                        option.displayString,
                        style: const TextStyle(fontSize: 9),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// テーブルをTSV形式でクリップボードにコピー
Future<void> copyTableToClipboard(
  BuildContext context,
  AttributeTableController controller, {
  WidgetRef? ref,
}) async {
  try {
    final buffer = StringBuffer();

    // ヘッダー行
    final headerNames =
        controller.columns.map((c) => _escapeTsvValue(c.title)).toList();
    buffer.writeln(headerNames.join('\t'));

    // データ行
    for (final row in controller.rows) {
      final rowValues = <String>[];
      for (final column in controller.columns) {
        final cell = row.cells[column.field];
        final value = cell?.value?.toString() ?? '';
        rowValues.add(_escapeTsvValue(value));
      }
      buffer.writeln(rowValues.join('\t'));
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));

    if (ref != null) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(
            title: t.attributeTable.copiedToClipboard(count: '${controller.rows.length}'),
            level: NotificationLevel.success,
          );
    }
  } catch (e) {
    AppLogger.debug('[AttributeTableToolbar] クリップボードコピーエラー: $e');
    if (ref != null) {
      ref
          .read(notificationCenterProvider.notifier)
          .add(title: t.attributeTable.copyError(error: '$e'), level: NotificationLevel.error);
    }
  }
}

String _escapeTsvValue(String value) {
  if (value.contains('\n') || value.contains('\t') || value.contains('"')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}
