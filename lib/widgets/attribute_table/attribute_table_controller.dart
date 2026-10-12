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

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';

import '../../i18n/strings.g.dart';
import '../../models/app_notification.dart';
import '../../models/nodes/external_layer_node.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/qgis_form.dart';
import '../../providers/notification_providers.dart';
import '../../providers/selection_providers.dart';
import '../../providers/ui_state_providers.dart';
import '../../services/coordinate/index.dart';
import '../../services/qgis_form_logic.dart';
import '../../services/qgis_form_options.dart';
import '../../services/table/csv_table.dart' show TableFieldType, csvBytesForExcel, csvField;
import '../../tutorial/practice_project.dart';
import '../../tutorial/tutorial.dart';
import '../../utils/app_logger.dart';
import '../../utils/attribute_columns.dart';
import '../../utils/qgis_expression_filter.dart';
import '../external_layer_actions.dart';

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
  List<String> _columnNames = [];
  List<String> _userColumnNames = [];
  List<String> _writableColumnNames = [];
  Set<String> _joinedColumns = const {};
  Map<String, String> _columnTypeMap = {};
  List<FeatureNode> _features = [];
  bool _isLoading = true;

  /// QGIS の属性フォームの設定（別名・編集ウィジェット・既定値・制約）。無ければ null
  QgisForm? _qgisForm;
  Map<String, List<QgisValueOption>> _formOptions = const {};
  AttributeTableSettings _settings = const AttributeTableSettings();

  // フィルタ状態
  String _filterExpression = '';
  String _filterSql = '';
  Set<int> _filteredRowIds = {};
  bool _isFiltered = false;
  String? _filterError;
  List<FeatureNode> _displayFeatures = [];

  /// 表に出す地物の一覧（フィルタの適用・解除）が替わるたびに進む。表はこれを見て作り直す
  /// （TrinaGrid は行を作るときにしか読まないので、作り直さないと件数だけ変わって行が残っていた）
  int displayRevision = 0;
  List<TrinaRow> _displayRows = [];

  // 並べ替え（列の見出しを押したもの）。ページをまたいで全件を並べる。null なら読んだ順
  String? _sortField;
  bool _sortDescending = false;
  List<FeatureNode>? _orderedCache;

  // ページング
  /// 1 ページの行数の選択肢
  static const List<int> pageSizes = [50, 100, 200, 500];
  int _pageSize = 100;

  /// 1 ページの行数。表を作り直しても（フィルタを変えても）選んだ大きさのまま
  int get pageSize => _pageSize;

  /// 表のページの大きさの選択から呼ぶ（このあと表が 1 ページ目を取り直す）
  void setPageSize(int size) {
    if (size > 0) _pageSize = size;
  }

  /// 「表をコピー」でこれより多い行は確かめてからコピーする
  static const int largeCopyRows = 50000;

  // エラー状態
  String? _lastError;

  // カラム非表示状態
  final Set<String> _hiddenColumns = {};

  // ゲッター
  List<TrinaColumn> get columns => _columns;
  List<TrinaRow> get rows => _displayRows;
  List<String> get columnNames => _columnNames;

  /// 内部用（`_` で始まる）を除いた列。統計・検索置換・ラベル・計算の候補
  List<String> get userColumnNames => _userColumnNames;

  /// 書き換えられる列（一括編集の候補）
  List<String> get writableColumnNames => _writableColumnNames;
  List<FeatureNode> get features => _displayFeatures;
  bool get isLoading => _isLoading;
  QgisForm? get qgisForm => _qgisForm;
  TrinaGridStateManager? get stateManager => _stateManager;

  /// UniqueValues・ValueRelation の列の選択肢
  Map<String, List<QgisValueOption>> get formOptions => _formOptions;

  /// 書き換えてよい列か（番号・形・内部用の列と、QGIS で編集可能を外した列・結合した表の列は書かない）
  bool canEdit(String column) =>
      !readOnly &&
      !isReadOnlyColumn(column, primaryKey: _primaryKey) &&
      !isJoinedColumn(column) &&
      (_qgisForm?.editable(column) ?? true);

  /// 結合した表の列か（読み取り専用。見出しに印）
  bool isJoinedColumn(String column) => _joinedColumns.contains(column);

  /// 列そのものを改名・削除してよいか（結合した表の列は gpkg に無いので `ALTER TABLE` が失敗する）
  bool canAlterColumn(String column) => !isReadOnlyColumn(column, primaryKey: _primaryKey) && !isJoinedColumn(column);

  /// レイヤの主キー（fid など。主キーの無い表は rowid で、列には出ない）。表に読み取り専用で出す（QGIS と同じ）
  String? _primaryKey;
  AttributeTableSettings get settings => _settings;
  bool get isPointLayer => layer is PointLayerNode;
  bool get isFiltered => _isFiltered;
  String get filterSql => _filterSql;

  /// 適用中のフィルタの式（入力欄に入れたまま）。ツールバーを作り直したときに欄へ戻す
  String get filterExpression => _filterExpression;
  int get totalCount => _features.length;
  int get filteredCount => _displayFeatures.length;
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

      // カラム名を取得（アプリが中身を持つメタデータの列は出さない）。
      // 主キーの列（fid）も QGIS と同じく読み取り専用で出す。id・fid という名前のふつうの列は書ける
      _primaryKey = await layer.geoPackageFile.getPrimaryKeyColumn(layer.layerName);
      _columnNames = [
        for (final c in await layer.getAttributeColumnNames(getAll: true))
          if (!isSystemColumn(c)) c,
      ];
      _userColumnNames =
          _columnNames.where((c) => !isInternalColumn(c)).toList();
      _writableColumnNames =
          _columnNames.where((c) => !isReadOnlyColumn(c, primaryKey: _primaryKey)).toList();
      // 結合した表の列（森林簿の樹種など）は後ろに読み取り専用で並べる。gpkg には無いので
      // SQL を使う操作（フィルタ・統計・置換・一括設定）の候補には入れない
      _joinedColumns = {for (final c in layer.joinedFieldNames) if (!_columnNames.contains(c)) c};
      _columnNames = [..._columnNames, ..._joinedColumns];
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

      // QGIS の属性フォームの設定と、その選択肢
      _qgisForm = await layer.getQgisForm();
      final form = _qgisForm;
      _formOptions = form == null ? const {} : await QgisFormOptions.load(layer, form);

      // フィーチャを取得
      _features = layer.features;
      AppLogger.debug('[AttributeTableController] フィーチャ: ${_features.length}個');

      // カラムを構築
      _columns = _createColumns();

      // フィルタが有効ならフィルタ済みビュー、そうでなければ全件（複製しない）。
      // 合う行は数え直す（置換・一括設定のあとは合う行が変わる）
      if (_isFiltered && _filterSql.isNotEmpty) {
        _filteredRowIds = (await layer.geoPackageFile
                .getFilteredFeatureIds(layer.layerName, _filterSql))
            .toSet();
        _applyFilterToDisplay();
      } else {
        _displayFeatures = _features;
        _orderedCache = null;
        _displayRows = _createRowsForRange(0, _pageSize);
      }

      AppLogger.debug('[AttributeTableController] 初期化完了');
    } catch (e) {
      final msg = t.attributeTable.initError(error: e.toString());
      AppLogger.debug('[AttributeTableController] $msg');
      _lastError = msg;
      _columnNames = [];
      _userColumnNames = [];
      _writableColumnNames = [];
      _features = [];
      _columns = [];
      _displayFeatures = [];
      _displayRows = [];
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 同じレイヤを読み直して作り直したコントローラに、前のフィルタとページの大きさを引き継ぐ。
  /// [initialize] の前に呼ぶ
  void inheritFrom(AttributeTableController previous) {
    if (!identical(previous.layer, layer)) return;
    _pageSize = previous._pageSize;
    if (previous._isFiltered) {
      _filterExpression = previous._filterExpression;
      _filterSql = previous._filterSql;
      _isFiltered = true;
    }
  }

  /// TrinaGridのStateManagerを設定
  void setStateManager(TrinaGridStateManager manager) {
    // 表を作り直したときは前の表の監視を外す
    _stateManager?.removeListener(_onStateChanged);
    _stateManager = manager;

    // 編集モードの監視
    manager.addListener(_onStateChanged);
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
    AppLogger.debug('[AttributeTableController] 削除開始: $featureCount個');

    // 表の行は消さずに読み直しに任せる（読み直すと表ごと作り直す）。
    // 以前は全件の中の番目で表の行を消しており、2 ページ目以降やフィルタ中は別の行を消していた
    await _ref
        .read(selectedFeaturesProvider.notifier)
        .disposeSelectedFeatures();

    // 再読み込み
    await initialize();

    AppLogger.debug('[AttributeTableController] 削除完了: $featureCount個');
  }

  /// 読み取り専用レイヤ（shp・GeoJSON など）か。見る・選ぶ・書き出すだけで、属性は書き換えない
  bool get readOnly => isInReadOnlyLayer(layer);

  /// 属性値を保存。失敗時はエラーメッセージを返す。
  Future<String?> saveAttributeChange(
    FeatureNode feature,
    String field,
    dynamic value,
  ) async {
    if (isReadOnlyColumn(field, primaryKey: _primaryKey) || isJoinedColumn(field)) return null;
    if (refuseReadOnlyEditBy(_ref.read, layer)) return null;
    final form = _qgisForm;
    if (form != null && !form.editable(field)) return null;

    // QGIS の制約（必須・一意・式）。必須の強さなら書かない、警告なら書いて知らせる
    String? warning;
    Map<String, Object?> props = {...?feature.turfFeature.properties, field: value};
    if (form != null) {
      final violations = validateQgisForm(
        form,
        props,
        only: [field],
        otherValues: (c) => [for (final f in _features) if (!identical(f, feature)) readAttribute(f, c)],
      );
      final hard = violations.where((v) => v.hard);
      if (hard.isNotEmpty) return t.qgisForm.saveBlocked(reasons: describeViolations(hard));
      if (violations.isNotEmpty) warning = t.qgisForm.softWarning(reasons: describeViolations(violations));
    }

    try {
      await feature.setAttributeValue(field, value);
      // 更新のときも当て直す既定値（QGIS の applyOnUpdate。最終更新日時など）
      if (form != null) {
        final updates = evaluateQgisDefaults(
          form,
          props,
          _columnTypeMap,
          columns: _writableColumnNames.where((c) => c != field && form.editable(c)),
          onUpdate: true,
        );
        for (final MapEntry(:key, :value) in updates.entries) {
          await feature.setAttributeValue(key, value);
        }
        props = {...props, ...updates};
      }
      if (warning != null) {
        _ref.read(notificationCenterProvider.notifier).add(title: warning, level: NotificationLevel.warning);
      }
      if (field == _sortField) _orderedCache = null;
      AppLogger.debug('[AttributeTableController] 属性保存: $field = $value');
      _ref.read(tutorialProvider.notifier).report(AttributeSaved(layer));
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

    _filterExpression = expression.trim();
    _filterSql = sql;
    _filteredRowIds = ids.toSet();
    _isFiltered = true;
    _filterError = null;

    _applyFilterToDisplay();
    notifyListeners();
    return null;
  }

  /// フィルタ結果を表示用リストに適用
  void _applyFilterToDisplay() {
    displayRevision++;
    _displayFeatures = [
      for (final f in _features)
        if (_filteredRowIds.contains(f.rowId)) f,
    ];
    _orderedCache = null;
    _displayRows = _createRowsForRange(0, _pageSize);

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
    _displayFeatures = _features;
    _orderedCache = null;
    _displayRows = _createRowsForRange(0, _pageSize);
    displayRevision++;
    notifyListeners();
  }

  /// 表の行の地物。行を並べ替えても行と地物の組は崩れない（位置から数えると別の地物を指していた）
  static FeatureNode? featureOfRow(TrinaRow? row) {
    final data = row?.data;
    return data is FeatureNode ? data : null;
  }

  /// フィーチャを選択
  void selectFeature(FeatureNode feature) {
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

    // 表に出ている行（今のページ）だけを探す
    final rows = _stateManager!.refRows;
    final localIndex = rows.indexWhere((r) => identical(r.data, feature));
    if (localIndex < 0) return;

    // 表のマスを押した選択が地図を回って戻ってきたときは動かさない。
    // 動かすと押したマスから行の先頭へ飛び、そのマスを編集できなかった（2026-10-01 チュートリアルで発覚）
    if (_stateManager!.currentRowIdx == localIndex) return;
    _stateManager!.setCurrentCell(rows[localIndex].cells.values.first, localIndex);
  }

  // ========== Phase 3: 複数行操作 ==========

  /// チェックされた行のフィーチャを取得
  List<FeatureNode> _checkedFeatures() {
    if (_stateManager == null) return [];
    return [
      for (final row in _stateManager!.checkedRows)
        ?featureOfRow(row),
    ];
  }

  /// チェックされた行数を取得
  int get checkedRowCount => _stateManager?.checkedRows.length ?? 0;

  /// チェックされた行に対して一括値設定
  Future<int> batchSetValue(String columnName, dynamic value) async {
    if (refuseReadOnlyEditBy(_ref.read, layer)) return 0;
    final features = _checkedFeatures();
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


  /// CSV 書き出しのバイト列（UTF-8 の BOM 付き → [csvBytesForExcel]）
  Future<Uint8List> exportCsvBytes() async {
    final buffer = StringBuffer();

    // ヘッダー行
    final escapedHeaders = _columnNames.map(csvField);
    buffer.writeln(escapedHeaders.join(','));

    // データ行
    for (final feature in _displayFeatures) {
      buffer.writeln(
        _columnNames
            .map((col) =>
                csvField(_cellValue(feature, col)?.toString() ?? ''))
            .join(','),
      );
    }

    return csvBytesForExcel(buffer.toString());
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
    return layer.geoPackageFile.searchText(
      layer.layerName,
      text,
      [for (final c in _columnNames) if (!isJoinedColumn(c)) c],
    );
  }

  /// テキスト置換（指定カラム内）。置き換えた行の数と、数値の列で数値にならず置き換えなかった行の数
  Future<({int replaced, int skipped})> replaceText(String column, String search, String replace) async {
    if (refuseReadOnlyEditBy(_ref.read, layer)) return (replaced: 0, skipped: 0);
    final result = await layer.geoPackageFile.replaceText(
      layer.layerName,
      column,
      search,
      replace,
    );
    if (result.replaced > 0) {
      await initialize();
    }
    return result;
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

    // Pointレイヤーの座標カラム（読み取り専用）
    if (isPointLayer) {
      if (_settings.showWgs84) {
        tableColumns.add(_coordinateColumn('_lat', 100));
        tableColumns.add(_coordinateColumn('_lon', 100));
      }
      if (_settings.additionalEpsg != null) {
        tableColumns.add(_coordinateColumn('_x', 110));
        tableColumns.add(_coordinateColumn('_y', 110));
      }
    }

    // 属性カラム（ソート・ドラッグ有効、NULLハイライト付き）
    for (final columnName in _columnNames) {
      final qf = _qgisForm?[columnName];
      if (isJoinedColumn(columnName)) {
        tableColumns.add(_joinedColumn(columnName));
        continue;
      }
      tableColumns.add(
        TrinaColumn(
          title: qf?.alias ?? columnName,
          field: columnName,
          type: _qgisColumnType(qf, columnSqlType(columnName)) ?? _determineColumnType(columnName),
          enableEditingMode: canEdit(columnName),
          enableSorting: true, // Phase 3: カラムヘッダーでソート
          enableColumnDrag: true, // Phase 3: ドラッグで並替え
          enableContextMenu: true, // Phase 3: 右クリックメニュー
          width: columnWidthFor(columnName, title: qf?.alias ?? columnName),
          renderer: _nullHighlightRenderer(columnName), // Phase 3: NULL値ハイライト
        ),
      );
    }

    return tableColumns;
  }

  /// 結合した表の列: 読み取り専用。見出しに鎖の印、マスは薄い色で gpkg の列と見分ける
  TrinaColumn _joinedColumn(String columnName) => TrinaColumn(
        title: columnName,
        field: columnName,
        titleSpan: TextSpan(children: [
          const WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(padding: EdgeInsets.only(right: 2), child: Icon(Icons.link, size: 14, color: Colors.brown)),
          ),
          TextSpan(text: columnName),
        ]),
        type: _joinedColumnType(columnName),
        readOnly: true,
        enableEditingMode: false,
        enableSorting: true,
        enableColumnDrag: true,
        enableContextMenu: true,
        backgroundColor: const Color(0xFFF7F1EA),
        width: columnWidthFor(columnName, joined: true),
        renderer: _nullHighlightRenderer(columnName),
      );

  TrinaColumnType _joinedColumnType(String columnName) {
    for (final j in layer.joins) {
      final i = j.fieldNames.indexOf(columnName);
      if (i < 0) continue;
      return switch (j.fieldTypes[i]) {
        TableFieldType.integer => _numberColumnType(),
        TableFieldType.real => _numberColumnType(real: true),
        TableFieldType.text => TrinaColumnType.text(),
      };
    }
    return TrinaColumnType.text();
  }

  /// 数の列。書式は最初に当てない（当てると NULL のマスが 0 になる）。見せ方は [_nullHighlightRenderer]、
  /// 並べ替えは [orderedFeatures]、入力した値を数にするのは表（castValueByColumnType）がする
  static TrinaColumnType _numberColumnType({bool real = false}) => real
      ? TrinaColumnType.number(format: '#,##0.######', applyFormatOnInit: false)
      : TrinaColumnType.number(applyFormatOnInit: false);

  static TrinaColumn _coordinateColumn(String field, double width) => TrinaColumn(
        title: field,
        field: field,
        type: TrinaColumnType.text(),
        enableEditingMode: false,
        width: width,
      );

  /// Phase 3: NULL/空値ハイライト用セルレンダラー
  TrinaColumnRenderer _nullHighlightRenderer(String columnName) {
    final qf = _qgisForm?[columnName];
    final boolean = isBooleanSqlType(columnSqlType(columnName));
    // チュートリアル: 練習の測点の表では、色の付いた行の name のマスを案内先にする
    final guideName = columnName == 'name' && isPracticeLayer(layer, PracticeProject.pointsLayer);
    return (TrinaColumnRendererContext ctx) {
      var value = ctx.cell.value;
      // 数の列: 値のあるマスだけ書式で丸めて見せる（以前の見え方。空は空のまま → (NULL)）
      final type = ctx.column.type;
      if (type is TrinaColumnTypeWithNumberFormat && value != null && value != '') {
        final nf = type as TrinaColumnTypeWithNumberFormat;
        if (nf.isNumeric(value)) value = nf.toNumber(nf.applyFormat(value));
      }
      // ValueMap・日付などは QGIS の見せ方で（書いてある値はそのまま）。
      // 真偽の列は ○/×（1/0・以前の版が書いた 'true'/'false' も読む）
      final bool? flag = boolean ? parseBooleanValue(value) : null;
      final text = flag != null ? (flag ? '○' : '×') : qf?.displayText(value) ?? value?.toString() ?? '';
      final isNull = text.isEmpty;
      final key = guideName &&
              _ref.read(tutorialProvider) != null &&
              ctx.rowIdx == (ctx.stateManager.currentRowIdx ?? 0)
          ? TutorialTargets.nameCell
          : null;
      return Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.centerLeft,
        child: Text(
          isNull ? '(NULL)' : text,
          style: isNull ? _nullCellStyle : _cellStyle,
          overflow: TextOverflow.ellipsis,
        ),
      );
    };
  }

  // マスの文字（マスごとに作らない）
  static const _cellStyle = TextStyle(
    fontSize: 13,
    height: 1.2,
    color: Colors.black87,
    fontStyle: FontStyle.normal,
  );
  static final _nullCellStyle = TextStyle(
    fontSize: 13,
    height: 1.2,
    color: Colors.grey.shade400,
    fontStyle: FontStyle.italic,
  );

  /// 列の SQLite の型（大文字）。分からなければ空文字
  String columnSqlType(String columnName) => _columnTypeMap[columnName] ?? '';

  /// QGIS の編集ウィジェットで選ぶ列（ValueMap・ValueRelation・チェックボックス）は選択の列にする。
  /// マスには値を書き、見せるのは表示名（[_nullHighlightRenderer]）
  TrinaColumnType? _qgisColumnType(QgisFieldForm? qf, String sqlType) {
    if (qf == null) return null;
    final List<QgisValueOption>? options = switch (qf.kind) {
      QgisWidgetKind.valueMap => qf.valueMapOptions.where((o) => o.value.isNotEmpty).toList(),
      QgisWidgetKind.valueRelation => _formOptions[qf.name],
      // 真偽の列は設定によらず 1/0（[_determineColumnType]）
      QgisWidgetKind.checkBox when !isBooleanSqlType(sqlType) => [
          for (final v in [qgisCheckValues(qf, sqlType).$1, qgisCheckValues(qf, sqlType).$2])
            QgisValueOption('$v', '$v'),
        ],
      _ => null,
    };
    if (options == null || options.isEmpty) return null;
    final labels = {for (final o in options) o.value: o.label};
    return TrinaColumnType.select<String>(
      [for (final o in options) o.value],
      itemToString: (v) => labels[v] ?? v,
    );
  }

  /// SQLiteのカラム型からTrinaColumnTypeにマッピング
  TrinaColumnType _determineColumnType(String columnName) {
    final sqlType = columnSqlType(columnName);
    // 真偽の列: 付いている・外れているから選ぶ。書くのは 1/0（GeoPackage の決まり。QGIS・GDAL が読める形）
    if (isBooleanSqlType(sqlType)) {
      return TrinaColumnType.select<String>(const ['1', '0'], itemToString: (v) => v == '1' ? '○' : '×');
    }
    if (isIntegerSqlType(sqlType)) return _numberColumnType();
    if (isNumericSqlType(sqlType)) return _numberColumnType(real: true);
    // 日付の列も書式は最初に当てない（当てると 2026/10/01 や自由な文字は (NULL)、
    // QGIS が DATETIME に書いた時刻は日付だけになる）。マスは書いてある値をそのまま見せ、
    // 選んだ日付は [storedValueFor] で列の形に直して書く
    if (_isDateTimeSqlType(sqlType)) return TrinaColumnType.dateTime(applyFormatOnInit: false);
    if (_isDateSqlType(sqlType)) return TrinaColumnType.date(applyFormatOnInit: false);
    return TrinaColumnType.text();
  }

  static bool _isDateTimeSqlType(String sqlType) => sqlType.contains('DATETIME') || sqlType.contains('TIMESTAMP');
  static bool _isDateSqlType(String sqlType) => sqlType.contains('DATE') || sqlType.contains('TIMESTAMP');

  /// 表で入れた値を列に書く形にする。日付・日時の列は、表の日付選び（`yyyy-MM-dd` / `yyyy-MM-dd HH:mm`）の値を
  /// DATE は `yyyy-MM-dd`、DATETIME は UTC の ISO 8601（Z つき）にする（QGIS・GeoPackage の決まり）。
  /// 真偽の列（BOOLEAN）は 1/0（[toBooleanStorage]）。日付と読めない値・ほかの列はそのまま
  Object? storedValueFor(String field, Object? value) {
    final sqlType = columnSqlType(field);
    if (isBooleanSqlType(sqlType)) return toBooleanStorage(value);
    if (value is! String || !_isDateSqlType(sqlType)) return value;
    final d = parseLooseDate(value);
    if (d == null) return value;
    return storeDateValue(d, sqlType, _qgisForm?[field]);
  }

  /// 日付・日時の文字を読む（ISO 8601 のほか、`2026/10/01`・`2026.10.01 9:00` のような区切りも）。読めなければ null
  static DateTime? parseLooseDate(String text) {
    final s = text.trim();
    if (s.isEmpty) return null;
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso;
    final m = _looseDate.firstMatch(s);
    if (m == null) return null;
    int? g(int i) => m.group(i) == null ? null : int.parse(m.group(i)!);
    final (month, day) = (g(2)!, g(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(g(1)!, month, day, g(4) ?? 0, g(5) ?? 0, g(6) ?? 0);
  }

  static final _looseDate =
      RegExp(r'^(\d{4})[/.\-](\d{1,2})[/.\-](\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$');

  /// 列の最初の幅。見出し（[title]。結合の列は鎖の印も）が読める幅まで広げる（上限 [maxColumnWidth]）。
  ///
  /// 以前は列名によらず決め打ちで、接頭辞の付く結合の列（`簿_樹種`）は鎖の印と「…」しか見えなかった
  @visibleForTesting
  static double columnWidthFor(String columnName, {String? title, bool joined = false}) {
    final painter = TextPainter(
      text: TextSpan(text: title ?? columnName, style: columnTitleStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    // 左右の余白（10 + 10）と、右端に重なる列のメニューの印のぶん
    final fit = painter.width + 36 + (joined ? 16 : 0);
    painter.dispose();
    return fit.ceilToDouble().clamp(_baseColumnWidth(columnName), maxColumnWidth);
  }

  /// [columnWidthFor] が広げる上限
  static const double maxColumnWidth = 200;

  /// 列の見出しの文字（表の設定 `columnTextStyle` と同じ）
  static const columnTitleStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.bold, height: 1.2);

  static double _baseColumnWidth(String columnName) {
    final lowerName = columnName.toLowerCase();
    if (lowerName == 'id' || lowerName == 'fid') return 40;
    if (lowerName == 'name') return 80;
    if (lowerName == 'description') return 100;
    if (lowerName == 'geom' || lowerName == 'geometry') return 70;
    return 60;
  }

  // ========== ページング ==========

  /// ページ取得（TrinaLazyPagination用）
  /// 並べ替えは表の 1 ページの中でなく、ここで全件を並べてから切り出す（fetchWithSorting）。
  /// ページの大きさは表の選択（[TrinaLazyPaginationRequest.pageSize]）に従う
  Future<TrinaLazyPaginationResponse> fetchPage(
    TrinaLazyPaginationRequest request,
  ) async {
    final sortColumn = request.sortColumn;
    setSort(
      sortColumn == null || sortColumn.sort.isNone ? null : sortColumn.field,
      descending: sortColumn?.sort.isDescending ?? false,
    );
    if (request.pageSize > 0) _pageSize = request.pageSize;
    final pageSize = _pageSize;
    final totalFeatures = _displayFeatures.length;
    final totalPages =
        (totalFeatures / pageSize).ceil().clamp(1, double.infinity).toInt();
    final start = (request.page - 1) * pageSize;

    final rows = _createRowsForRange(start, pageSize);

    return TrinaLazyPaginationResponse(
      totalPage: totalPages,
      rows: rows,
      totalRecords: totalFeatures,
    );
  }

  /// [feature] が載るページ（1 始まり）。表に出ていなければ 1
  int pageOf(FeatureNode feature) {
    final i = orderedFeatures.indexWhere((f) => identical(f, feature));
    return i < 0 ? 1 : i ~/ _pageSize + 1;
  }

  /// 並べ替える列を決める（null で読んだ順に戻す）
  void setSort(String? field, {bool descending = false}) {
    if (field == _sortField && descending == _sortDescending) return;
    _sortField = field;
    _sortDescending = descending;
    _orderedCache = null;
  }

  /// 表に出す順の地物（フィルタで絞り、並べ替えた全件）
  List<FeatureNode> get orderedFeatures {
    final field = _sortField;
    if (field == null) return _displayFeatures;
    return _orderedCache ??= () {
      final isDate = _isDateSqlType(columnSqlType(field));
      final keyed = [
        for (var i = 0; i < _displayFeatures.length; i++)
          (i, _displayFeatures[i], _cellValue(_displayFeatures[i], field)),
      ];
      keyed.sort((a, b) {
        final c = _compareCellValues(a.$3, b.$3, isDate: isDate);
        if (c != 0) return _sortDescending ? -c : c;
        return a.$1.compareTo(b.$1); // 同じ値は読んだ順のまま
      });
      return [for (final k in keyed) k.$2];
    }();
  }

  /// 並べ替えの比較。数どうしは数で、日付の列で両方日付と読めれば日付で、ほかは文字で比べる。空は小さい側
  static int _compareCellValues(Object? a, Object? b, {bool isDate = false}) {
    final aEmpty = a == null || a == '';
    final bEmpty = b == null || b == '';
    if (aEmpty || bEmpty) return aEmpty == bEmpty ? 0 : (aEmpty ? -1 : 1);
    if (isDate) {
      final ad = parseLooseDate('$a');
      final bd = parseLooseDate('$b');
      if (ad != null && bd != null) return ad.compareTo(bd);
    }
    final an = a is num ? a : num.tryParse('$a');
    final bn = b is num ? b : num.tryParse('$b');
    if (an != null && bn != null) return an.compareTo(bn);
    return '$a'.compareTo('$b');
  }

  // ========== 行データ構築 ==========

  /// 1 マスの値（表・コピー・並べ替えで共通）。[index] は表の順の位置（0 始まり）
  Object? _cellValue(FeatureNode feature, String field, [int index = 0]) {
    switch (field) {
      case '_row_num':
        return index + 1;
      case '_lat' || '_lon' || '_x' || '_y':
        if (feature is! PointFeatureNode) return '';
        final point = feature.point;
        if (field == '_lat') return point.latitude.toStringAsFixed(6);
        if (field == '_lon') return point.longitude.toStringAsFixed(6);
        final epsg = _settings.additionalEpsg;
        if (epsg == null) return '';
        final xy = CoordinateService.instance.transformToXYFormatted(point, epsg);
        return (field == '_x' ? xy['x'] : xy['y']) ?? '';
      default:
        if (isJoinedColumn(field)) return _joinedValue(feature, field) ?? '';
        return readAttribute(feature, field) ?? '';
    }
  }

  /// 地物の列の値（結合した表の列なら表を引いた値）。フォーム表示が読む
  Object? valueOf(FeatureNode feature, String column) =>
      isJoinedColumn(column) ? _joinedValue(feature, column) : readAttribute(feature, column);

  /// 結合した表の列の値（地物の結合の列で表を引く）
  Object? _joinedValue(FeatureNode feature, String field) {
    if (feature.isDisposed) return null;
    for (final j in layer.joins) {
      final i = j.fieldNames.indexOf(field);
      if (i < 0) continue;
      return j.valuesFor(readAttribute(feature, j.join.targetField))?[i];
    }
    return null;
  }

  /// 指定範囲のフィーチャからTrinaRowを構築
  List<TrinaRow> _createRowsForRange(int start, int count) {
    final ordered = orderedFeatures;
    if (ordered.isEmpty) return [];

    final end = (start + count).clamp(0, ordered.length);
    if (start >= end) return [];

    return [
      for (int i = start; i < end; i++)
        TrinaRow(
          cells: {
            for (final column in _columns)
              column.field: TrinaCell(value: _cellValue(ordered[i], column.field, i)),
          },
          data: ordered[i],
        ),
    ];
  }

  /// 「表をコピー」の中身（TSV）。今のフィルタ・並べ替えの全件を、隠した列を除いて書く。
  /// [chunkSize] 行ごとに一度手を離す（何万行でも画面を止めない）
  Future<String> buildTableTsv({int chunkSize = 2000}) async {
    final columns = [
      for (final c in _columns)
        if (!_hiddenColumns.contains(c.field)) c,
    ];
    final buffer = StringBuffer()
      ..writeln(columns.map((c) => _escapeTsvValue(c.title)).join('\t'));
    final ordered = orderedFeatures;
    for (var i = 0; i < ordered.length; i++) {
      if (i > 0 && i % chunkSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      buffer.writeln(
        columns
            .map((c) => _escapeTsvValue(_cellValue(ordered[i], c.field, i)?.toString() ?? ''))
            .join('\t'),
      );
    }
    return buffer.toString();
  }

  static String _escapeTsvValue(String value) {
    if (value.contains('\n') || value.contains('\t') || value.contains('"')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
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
