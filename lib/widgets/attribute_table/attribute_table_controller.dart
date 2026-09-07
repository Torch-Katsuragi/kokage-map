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
// Root Maps: 属性テーブルコントローラ
// TrinaGridの状態管理、フィーチャ操作、属性編集を担当

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../i18n/strings.g.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../providers/selection_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/coordinate/index.dart';
import '../../utils/app_logger.dart';
import '../../utils/qgis_expression_filter.dart';

/// 属性テーブルの表示設定
class AttributeTableSettings {
  final bool showWgs84;
  final EpsgDefinition? additionalEpsg;

  const AttributeTableSettings({this.showWgs84 = true, this.additionalEpsg});

  AttributeTableSettings copyWith({
    bool? showWgs84,
    EpsgDefinition? additionalEpsg,
    bool clearAdditionalEpsg = false,
  }) {
    return AttributeTableSettings(
      showWgs84: showWgs84 ?? this.showWgs84,
      additionalEpsg:
          clearAdditionalEpsg ? null : (additionalEpsg ?? this.additionalEpsg),
    );
  }
}

/// 属性テーブルコントローラ
/// 状態管理とTrinaGridとの連携を担当
class AttributeTableController extends ChangeNotifier {
  final LayerNode layer;
  final WidgetRef _ref;
  // dispose() 後も安全に使えるよう、コンストラクタ時点でキャッシュ
  late final IsAttributeTableEditing _editingNotifier;

  // 状態
  TrinaGridStateManager? _stateManager;
  List<TrinaColumn> _columns = [];
  List<TrinaRow> _rows = [];
  List<String> _columnNames = [];
  Map<String, String> _columnTypeMap = {};
  List<FeatureNode> _features = [];
  bool _isLoading = true;
  AttributeTableSettings _settings = const AttributeTableSettings();

  // フィルタ状態
  String _filterExpression = '';
  String _filterSql = '';
  Set<int> _filteredRowIds = {};
  bool _isFiltered = false;
  String? _filterError;
  List<FeatureNode> _displayFeatures = [];
  List<TrinaRow> _displayRows = [];

  // ページング状態
  int _currentPageOffset = 0;
  static const int defaultPageSize = 100;

  // エラー状態
  String? _lastError;

  // カラム非表示状態
  final Set<String> _hiddenColumns = {};

  // ゲッター
  TrinaGridStateManager? get stateManager => _stateManager;
  List<TrinaColumn> get columns => _columns;
  List<TrinaRow> get rows => _displayRows;
  List<String> get columnNames => _columnNames;
  List<FeatureNode> get features => _displayFeatures;
  List<FeatureNode> get allFeatures => _features;
  bool get isLoading => _isLoading;
  AttributeTableSettings get settings => _settings;
  bool get isPointLayer => layer is PointLayerNode;
  bool get isFiltered => _isFiltered;
  String get filterExpression => _filterExpression;
  String get filterSql => _filterSql;
  String? get filterError => _filterError;
  int get totalCount => _features.length;
  int get filteredCount => _displayFeatures.length;
  int get currentPageOffset => _currentPageOffset;
  String? get lastError => _lastError;

  /// エラーをクリア
  void clearError() {
    _lastError = null;
  }

  Set<String> get hiddenColumns => _hiddenColumns;

  /// カラムの表示/非表示を切り替え
  void toggleColumnVisibility(String columnName) {
    if (_hiddenColumns.contains(columnName)) {
      _hiddenColumns.remove(columnName);
    } else {
      _hiddenColumns.add(columnName);
    }
    if (_stateManager != null) {
      for (final col in _stateManager!.refColumns) {
        if (col.field == columnName) {
          _stateManager!.hideColumn(col, _hiddenColumns.contains(columnName));
          break;
        }
      }
    }
    notifyListeners();
  }

  /// 全カラムを表示
  void showAllColumns() {
    if (_stateManager != null) {
      for (final col in _stateManager!.refColumns) {
        if (_hiddenColumns.contains(col.field)) {
          _stateManager!.hideColumn(col, false);
        }
      }
    }
    _hiddenColumns.clear();
    notifyListeners();
  }

  AttributeTableController(this.layer, this._ref)
      : _editingNotifier =
            _ref.read(isAttributeTableEditingProvider.notifier);

  /// 初期化
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      AppLogger.debug('[AttributeTableController] 初期化開始: ${layer.layerName}');

      // カラム名を取得
      _columnNames = await layer.getAttributeColumnNames(
        getAll: true,
        skipPrimaryKey: true,
      );
      AppLogger.debug(
        '[AttributeTableController] カラム名: ${_columnNames.length}個',
      );

      // スキーマからカラム型情報を取得
      final columnInfo = await layer.geoPackageFile.getAttributeColumnInfo(
        layer.layerName,
        includeBuiltIn: true,
      );
      _columnTypeMap = {
        for (final info in columnInfo)
          info['name'] as String: (info['type'] as String).toUpperCase(),
      };

      // フィーチャを取得
      _features = layer.features;
      AppLogger.debug('[AttributeTableController] フィーチャ: ${_features.length}個');

      // カラムを構築
      _columns = _createColumns();

      // フィルタが有効ならフィルタ済みビューを構築
      if (_isFiltered && _filterSql.isNotEmpty) {
        await _applyFilterToDisplay();
      } else {
        _displayFeatures = List.of(_features);
      }

      // 初回ページのデータを構築
      _currentPageOffset = 0;
      _displayRows = await _createRowsForRange(0, defaultPageSize);
      _rows = _displayRows;

      AppLogger.debug('[AttributeTableController] 初期化完了');
    } catch (e) {
      final msg = t.attributeTable.initError(error: e.toString());
      AppLogger.debug('[AttributeTableController] $msg');
      _lastError = msg;
      _columnNames = [];
      _features = [];
      _columns = [];
      _rows = [];
      _displayFeatures = [];
      _displayRows = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// TrinaGridのStateManagerを設定
  void setStateManager(TrinaGridStateManager manager) {
    _stateManager = manager;

    // 編集モードの監視
    _stateManager?.addListener(_onStateChanged);
  }

  /// 設定を更新
  Future<void> updateSettings(AttributeTableSettings newSettings) async {
    if (_settings.showWgs84 != newSettings.showWgs84 ||
        _settings.additionalEpsg != newSettings.additionalEpsg) {
      _settings = newSettings;
      await initialize();
    }
  }

  /// 選択されたフィーチャを削除
  Future<void> deleteSelectedFeatures() async {
    final currentSelection = _ref.read(selectedFeaturesProvider);
    if (currentSelection.isEmpty) {
      AppLogger.debug('[AttributeTableController] 削除対象なし');
      return;
    }

    final featureCount = currentSelection.length;
    final selectedFeaturesToDelete = List.from(
      currentSelection.whereType<FeatureNode>(),
    );

    AppLogger.debug('[AttributeTableController] 削除開始: $featureCount個');

    // TrinaGridから行を削除
    final rowIndicesToRemove = <int>[];
    for (final feature in selectedFeaturesToDelete) {
      final index = _features.indexOf(feature);
      if (index >= 0) rowIndicesToRemove.add(index);
    }

    if (_stateManager != null && rowIndicesToRemove.isNotEmpty) {
      rowIndicesToRemove.sort((a, b) => b.compareTo(a));
      final rowsToRemove = <TrinaRow>[];
      for (final index in rowIndicesToRemove) {
        if (index < _rows.length) {
          rowsToRemove.add(_rows[index]);
        }
      }
      _stateManager!.removeRows(rowsToRemove);
    }

    // ローカルリストから削除
    for (final feature in selectedFeaturesToDelete) {
      _features.remove(feature);
    }

    await _ref
        .read(selectedFeaturesProvider.notifier)
        .disposeSelectedFeatures();

    // 再読み込み
    await initialize();

    AppLogger.debug('[AttributeTableController] 削除完了: $featureCount個');
  }

  /// 属性値を保存。失敗時はエラーメッセージを返す。
  Future<String?> saveAttributeChange(
    FeatureNode feature,
    String field,
    dynamic value,
  ) async {
    if (field == 'id' ||
        field == 'fid' ||
        field == 'geom' ||
        field == 'geometry') {
      return null;
    }

    if (field.startsWith('_')) {
      return null;
    }

    try {
      await feature.setAttributeValue(field, value);
      AppLogger.debug('[AttributeTableController] 属性保存: $field = $value');
      return null;
    } catch (e) {
      final msg = t.attributeTable.saveError(field: field, error: e.toString());
      _lastError = msg;
      AppLogger.debug('[AttributeTableController] $msg');
      notifyListeners();
      return msg;
    }
  }

  // ========== フィルタ操作 ==========

  /// QGIS式でフィルタを適用
  Future<String?> applyFilter(String expression) async {
    if (expression.trim().isEmpty) {
      await clearFilter();
      return null;
    }

    final result = QgisExpressionFilter.toSqlWhere(expression);
    if (result is FilterResultError) {
      _filterError = result.message;
      notifyListeners();
      return result.message;
    }

    final sql = (result as FilterResultOk).sql;

    // カラム名バリデーション
    final allColumns = await layer.getAttributeColumnNames(
      getAll: true,
      skipPrimaryKey: false,
    );
    final fieldError = QgisExpressionFilter.validateFieldReferences(
      sql,
      allColumns.toSet(),
    );
    if (fieldError != null) {
      _filterError = fieldError;
      notifyListeners();
      return fieldError;
    }

    // SQLを実行してマッチするrowIdを取得
    final ids = await layer.geoPackageFile.getFilteredFeatureIds(
      layer.layerName,
      sql,
    );
    if (ids.isEmpty &&
        await layer.geoPackageFile.countFilteredFeatures(layer.layerName, sql) <
            0) {
      _filterError = t.attributeTable.sqlError;
      notifyListeners();
      return _filterError;
    }

    _filterExpression = expression;
    _filterSql = sql;
    _filteredRowIds = ids.toSet();
    _isFiltered = true;
    _filterError = null;

    await _applyFilterToDisplay();
    notifyListeners();
    return null;
  }

  /// フィルタ結果を表示用リストに適用
  Future<void> _applyFilterToDisplay() async {
    _displayFeatures = [];

    for (var i = 0; i < _features.length; i++) {
      if (_filteredRowIds.contains(_features[i].rowId)) {
        _displayFeatures.add(_features[i]);
      }
    }

    _currentPageOffset = 0;
    _displayRows = await _createRowsForRange(0, defaultPageSize);
    _rows = _displayRows;

    AppLogger.debug(
      '[AttributeTableController] フィルタ適用: '
      '${_displayFeatures.length}/${_features.length}件',
    );
  }

  /// フィルタを解除
  Future<void> clearFilter() async {
    _filterExpression = '';
    _filterSql = '';
    _filteredRowIds = {};
    _isFiltered = false;
    _filterError = null;
    _displayFeatures = List.of(_features);
    _currentPageOffset = 0;
    _displayRows = await _createRowsForRange(0, defaultPageSize);
    _rows = _displayRows;
    notifyListeners();
  }

  /// フィーチャを選択（ページオフセットを考慮）
  void selectFeature(int rowIndex) {
    final absoluteIndex = _currentPageOffset + rowIndex;
    if (absoluteIndex < 0 || absoluteIndex >= _displayFeatures.length) return;

    final feature = _displayFeatures[absoluteIndex];

    final currentSelection = _ref.read(selectedFeaturesProvider);
    if (currentSelection.length == 1 && currentSelection.first == feature) {
      return;
    }

    _ref.read(selectedFeaturesProvider.notifier).set([feature]);
    AppLogger.debug(
      '[AttributeTableController] フィーチャ選択: rowId=${feature.rowId}',
    );
  }

  /// 外部からの選択に応じてテーブルの行をハイライト（同一ページ内）
  void highlightFeatureOnCurrentPage(FeatureNode feature) {
    if (_stateManager == null) return;

    final absoluteIndex = _displayFeatures.indexOf(feature);
    if (absoluteIndex < 0) return;

    final pageEnd = _currentPageOffset + defaultPageSize;
    if (absoluteIndex < _currentPageOffset || absoluteIndex >= pageEnd) return;

    final localIndex = absoluteIndex - _currentPageOffset;
    if (localIndex >= 0 && localIndex < _stateManager!.refRows.length) {
      _stateManager!.setCurrentCell(
        _stateManager!.refRows[localIndex].cells.values.first,
        localIndex,
      );
    }
  }

  // ========== Phase 3: 複数行操作 ==========

  /// チェックされた行のフィーチャを取得
  List<FeatureNode> getCheckedFeatures() {
    if (_stateManager == null) return [];
    final checkedRows = _stateManager!.checkedRows;
    final result = <FeatureNode>[];
    for (final row in checkedRows) {
      final rowNum = row.cells['_row_num']?.value;
      if (rowNum is int && rowNum > 0 && rowNum <= _displayFeatures.length) {
        result.add(_displayFeatures[rowNum - 1]);
      }
    }
    return result;
  }

  /// チェックされた行数を取得
  int get checkedRowCount => _stateManager?.checkedRows.length ?? 0;

  /// チェックされた行に対して一括値設定
  Future<int> batchSetValue(String columnName, dynamic value) async {
    final features = getCheckedFeatures();
    if (features.isEmpty) return 0;

    int count = 0;
    for (final feature in features) {
      try {
        await feature.setAttributeValue(columnName, value);
        count++;
      } catch (e) {
        AppLogger.debug('[AttributeTableController] 一括設定エラー: $e');
      }
    }

    if (count > 0) {
      await initialize(); // テーブル再構築
    }

    AppLogger.debug('[AttributeTableController] 一括設定完了: $count/${ features.length}件');
    return count;
  }


  /// CSVエクスポート用のデータを非同期で生成
  Future<String> exportToCsvAsync() async {
    final buffer = StringBuffer();

    // ヘッダー行
    final escapedHeaders = _columnNames.map(_escapeCsvField);
    buffer.writeln(escapedHeaders.join(','));

    // データ行
    for (final feature in _displayFeatures) {
      final values = <String>[];
      for (final col in _columnNames) {
        try {
          final value = await feature.getAttributeValue(col);
          values.add(_escapeCsvField(value?.toString() ?? ''));
        } catch (e) {
          values.add('');
        }
      }
      buffer.writeln(values.join(','));
    }

    return buffer.toString();
  }

  /// CSV用フィールドエスケープ
  String _escapeCsvField(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  // ========== 統計 ==========

  /// 指定カラムの統計情報を計算
  Future<Map<String, dynamic>> getColumnStatistics(String columnName) async {
    return layer.geoPackageFile.getColumnStatistics(
      layer.layerName,
      columnName,
    );
  }

  // ========== 検索・置換 ==========

  /// テキスト検索（全カラム横断）。マッチしたrowIdを返す。
  Future<List<int>> searchText(String text) async {
    if (text.isEmpty) return [];
    return layer.geoPackageFile.searchText(layer.layerName, text, _columnNames);
  }

  /// テキスト置換（指定カラム内）
  Future<int> replaceText(String column, String search, String replace) async {
    final count = await layer.geoPackageFile.replaceText(
      layer.layerName,
      column,
      search,
      replace,
    );
    if (count > 0) {
      await initialize();
    }
    return count;
  }

  // ========== カラム構築 ==========

  List<TrinaColumn> _createColumns() {
    final tableColumns = <TrinaColumn>[];

    // 行番号カラム（チェックボックス付き、ソート・ドラッグ無効）
    tableColumns.add(
      TrinaColumn(
        title: '#',
        field: '_row_num',
        type: TrinaColumnType.number(),
        enableEditingMode: false,
        enableSorting: false,
        enableColumnDrag: false,
        enableRowChecked: true, // Phase 3: 複数行選択チェックボックス
        width: 100,
        frozen: TrinaColumnFrozen.start,
      ),
    );

    // Pointレイヤーの座標カラム
    if (isPointLayer) {
      if (_settings.showWgs84) {
        tableColumns.add(
          TrinaColumn(
            title: '_lat',
            field: '_lat',
            type: TrinaColumnType.text(),
            enableEditingMode: false,
            width: 100,
          ),
        );
        tableColumns.add(
          TrinaColumn(
            title: '_lon',
            field: '_lon',
            type: TrinaColumnType.text(),
            enableEditingMode: false,
            width: 100,
          ),
        );
      }

      if (_settings.additionalEpsg != null) {
        tableColumns.add(
          TrinaColumn(
            title: '_x',
            field: '_x',
            type: TrinaColumnType.text(),
            enableEditingMode: false,
            width: 110,
          ),
        );
        tableColumns.add(
          TrinaColumn(
            title: '_y',
            field: '_y',
            type: TrinaColumnType.text(),
            enableEditingMode: false,
            width: 110,
          ),
        );
      }
    }

    // 属性カラム（ソート・ドラッグ有効、NULLハイライト付き）
    for (final columnName in _columnNames) {
      tableColumns.add(
        TrinaColumn(
          title: columnName,
          field: columnName,
          type: _determineColumnType(columnName),
          enableEditingMode: _isColumnEditable(columnName),
          enableSorting: true, // Phase 3: カラムヘッダーでソート
          enableColumnDrag: true, // Phase 3: ドラッグで並替え
          enableContextMenu: true, // Phase 3: 右クリックメニュー
          width: _getColumnWidth(columnName),
          renderer: _nullHighlightRenderer(columnName), // Phase 3: NULL値ハイライト
        ),
      );
    }

    return tableColumns;
  }

  /// Phase 3: NULL/空値ハイライト用セルレンダラー
  TrinaColumnRenderer _nullHighlightRenderer(String columnName) {
    return (TrinaColumnRendererContext ctx) {
      final value = ctx.cell.value;
      final isNull = value == null || value.toString().isEmpty;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.centerLeft,
        child: Text(
          isNull ? '(NULL)' : value.toString(),
          style: TextStyle(
            fontSize: 13,
            height: 1.2,
            color: isNull ? Colors.grey.shade400 : Colors.black87,
            fontStyle: isNull ? FontStyle.italic : FontStyle.normal,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      );
    };
  }

  /// SQLiteのカラム型からTrinaColumnTypeにマッピング
  TrinaColumnType _determineColumnType(String columnName) {
    final sqlType = _columnTypeMap[columnName] ?? '';
    if (sqlType.contains('INT')) {
      return TrinaColumnType.number();
    } else if (sqlType.contains('REAL') ||
        sqlType.contains('DOUBLE') ||
        sqlType.contains('FLOAT') ||
        sqlType.contains('NUMERIC')) {
      return TrinaColumnType.number(format: '#,##0.######');
    } else if (sqlType.contains('DATE') || sqlType.contains('TIMESTAMP')) {
      return TrinaColumnType.date();
    } else if (sqlType.contains('BOOL')) {
      return TrinaColumnType.text();
    }
    return TrinaColumnType.text();
  }

  bool _isColumnEditable(String columnName) {
    final lowerName = columnName.toLowerCase();
    if (lowerName == 'id' ||
        lowerName == 'fid' ||
        lowerName == 'geom' ||
        lowerName == 'geometry' ||
        lowerName.startsWith('_')) {
      return false;
    }
    return true;
  }

  double _getColumnWidth(String columnName) {
    final lowerName = columnName.toLowerCase();
    if (lowerName == 'id' || lowerName == 'fid') return 40;
    if (lowerName == 'name') return 80;
    if (lowerName == 'description') return 100;
    if (lowerName == 'geom' || lowerName == 'geometry') return 70;
    return 60;
  }

  // ========== ページング ==========

  /// ページ取得（TrinaLazyPagination用）
  Future<TrinaLazyPaginationResponse> fetchPage(
    TrinaLazyPaginationRequest request,
  ) async {
    final page = request.page;
    const pageSize = defaultPageSize;
    final totalFeatures = _displayFeatures.length;
    final totalPages =
        (totalFeatures / pageSize).ceil().clamp(1, double.infinity).toInt();
    final start = (page - 1) * pageSize;

    _currentPageOffset = start;
    final rows = await _createRowsForRange(start, pageSize);

    return TrinaLazyPaginationResponse(totalPage: totalPages, rows: rows);
  }

  // ========== 行データ構築 ==========

  /// 指定範囲のフィーチャからTrinaRowを構築
  Future<List<TrinaRow>> _createRowsForRange(int start, int count) async {
    if (_displayFeatures.isEmpty) return [];

    final end = (start + count).clamp(0, _displayFeatures.length);
    if (start >= end) return [];

    final tableRows = <TrinaRow>[];
    final coordService = CoordinateService.instance;

    for (int i = start; i < end; i++) {
      final feature = _displayFeatures[i];
      final cells = <String, TrinaCell>{};

      cells['_row_num'] = TrinaCell(value: i + 1);

      for (final columnName in _columnNames) {
        try {
          final value = await feature.getAttributeValue(columnName);
          cells[columnName] = TrinaCell(value: value ?? '');
        } catch (e) {
          cells[columnName] = TrinaCell(value: '');
        }
      }

      if (isPointLayer && feature is PointFeatureNode) {
        final point = feature.point;

        if (_settings.showWgs84) {
          cells['_lat'] = TrinaCell(value: point.latitude.toStringAsFixed(6));
          cells['_lon'] = TrinaCell(value: point.longitude.toStringAsFixed(6));
        }

        if (_settings.additionalEpsg != null) {
          final xy = coordService.transformToXYFormatted(
            point,
            _settings.additionalEpsg!,
          );
          cells['_x'] = TrinaCell(value: xy['x'] ?? '');
          cells['_y'] = TrinaCell(value: xy['y'] ?? '');
        }
      }

      tableRows.add(TrinaRow(cells: cells));
    }

    return tableRows;
  }

  // ========== 内部コールバック ==========

  bool _lastEditing = false;

  void _onStateChanged() {
    final isEditing = _stateManager?.isEditing ?? false;
    if (_lastEditing != isEditing) {
      _lastEditing = isEditing;
      _editingNotifier.set(isEditing);
    }
  }

  @override
  void dispose() {
    _stateManager?.removeListener(_onStateChanged);
    // dispose中のプロバイダ変更はビルド中クラッシュの原因になるため遅延実行
    final notifier = _editingNotifier;
    Future.microtask(() => notifier.set(false));
    super.dispose();
  }
}
