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
// Root Maps: レイヤノードクラス
// GeoPackage内のレイヤに対応するレイヤツリーノード
// turf_dartのFeatureCollectionオブジェクトをメインデータとして使用

import 'dart:async';

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:turf/turf.dart' as turf;

import '../../converters/turf_converter.dart';
import '../../core/node_types.dart';
import '../../services/kmeta_service.dart';
import '../geometry_type.dart';
import '../geopackage/geopackage_file.dart';
import '../kmeta.dart';
import 'feature_node.dart';
import 'folder_node.dart';
import 'geopackage_node.dart';
import 'layer_tree_node.dart';
import 'view_node.dart';

/// 重複レイヤ名のナンバリング処理ユーティリティ
class LayerNameUtils {
  /// 重複しない新しいレイヤ名を生成する
  /// 例: "道路" が既存の場合 → "道路_2"
  /// "道路_2" も既存の場合 → "道路_3" と番号を増やしていく
  static String generateUniqueLayerName(
    String baseName,
    List<String> existingNames,
  ) {
    if (!existingNames.contains(baseName)) {
      return baseName;
    }

    int number = 2;
    String candidateName;

    do {
      candidateName = '${baseName}_$number';
      number++;
    } while (existingNames.contains(candidateName));

    return candidateName;
  }
}

/// レイヤノード（LayerNode）: GeoPackage内のフィーチャテーブル＋FeatureNodeコレクション
/// turf_dartのFeatureをMap管理し、FeatureCollectionを動的生成する（Single Source of Truth）
abstract class LayerNode extends LayerTreeNode {
  /// GeoPackageファイル管理クラスへの参照
  final GeoPackageFile geoPackageFile;

  /// レイヤ名（DBテーブル名）
  final String layerName;

  /// turf_dartのFeatureをrowIdで管理するMap（真のデータソース）
  final Map<int, turf.Feature> _featureMap = {};

  /// 変更の追跡フラグ（将来的なバッチ保存最適化用に予約）
  // ignore: unused_field
  bool _isDirty = false;

  /// dispose済みフラグ（null参照対策）
  bool _isDisposed = false;

  /// updateChildren進行中のCompleter（二重実行防止＋完了待ち）
  Completer<void>? _updateChildrenCompleter;

  /// DB からフィーチャを一度でも読んだか。空のレイヤと未ロードのレイヤを区別する
  bool _featuresLoaded = false;
  bool get featuresLoaded => _featuresLoaded;

  /// dispose済みかどうかを取得
  bool get isDisposed => _isDisposed;

  /// 親のGeoPackageNodeを取得
  GeoPackageNode get geoPackageNode {
    LayerTreeNode? current = parent;
    while (current != null) {
      if (current is GeoPackageNode) {
        return current;
      }
      current = current.parent;
    }
    throw StateError('LayerNode must have a GeoPackageNode parent');
  }

  /// 親のFolderNodeを取得
  FolderNode? get folderNode {
    LayerTreeNode? current = parent;
    while (current != null) {
      if (current is FolderNode) {
        return current;
      }
      current = current.parent;
    }
    return null;
  }

  @override
  Future<void> persistVisibility() async {
    final folder = folderNode;
    if (folder == null) return;
    final folderPath = folder.getAbsoluteFilePath();
    if (folderPath == null) return;
    await KMetaService.instance.setLayerVisibility(
      folderPath,
      layerKey,
      visible,
    );
    folder.invalidateMetaCache();
  }

  /// レイヤーの一意キー（gpkgName/layerName形式）
  /// 同一フォルダ内の異なるGeoPackageの同名レイヤーを区別するため
  String get layerKey {
    if (_isDisposed) {
      throw StateError(
        'Cannot access layerKey on disposed LayerNode: $layerName',
      );
    }
    final gpkg = geoPackageNode;
    return '${gpkg.name}/$layerName';
  }

  /// フィーチャを読み直すたびに増える版番号。
  ///
  /// 「同じ [LayerNode] なのに中身が入れ替わった」を外から検知するためのもの。
  /// View のフィルタを変えると件数が変わるので、属性テーブルのように
  /// フィーチャのリストを抱えている側はこれを見て作り直す。
  int get featuresRevision => _featuresRevision;
  int _featuresRevision = 0;

  /// このレイヤの View（＝見せ方）。
  ///
  /// > [!WARNING] `children` とは別物。混ぜてはいけない
  /// > `children` は FeatureNode 専用（`children.cast<FeatureNode>()` を
  /// > 書いている箇所すらある）。View はデータではないのでこちらに持つ。
  /// > 詳しい理由は [[view_node]]。
  ///
  /// [loadViews] を呼ぶまで空。空リストは「まだ読んでいない」であって
  /// 「View が無い」ではない（View が無いレイヤにも既定Viewが1枚できる）。
  final List<ViewNode> views = [];

  /// `.kmeta.json` から View 定義を読み直す。
  ///
  /// 定義が無ければ既定View（[kDefaultViewName]）を1枚だけ作る。
  /// 既定Viewはファイルには書かない — 書くと全プロジェクトに差分が出て
  /// Drive同期が無駄に動くため。
  Future<List<ViewNode>> loadViews() async {
    final loaded = await _buildViews();
    views
      ..clear()
      ..addAll(loaded);
    return views;
  }

  Future<List<ViewNode>> _buildViews() async {
    final folder = folderNode;
    if (folder == null) return [ViewNode(name: kDefaultViewName, parent: this)];

    final KMeta meta;
    try {
      meta = await folder.getMeta();
    } catch (e) {
      AppLogger.debug('[LayerNode] View定義を読めない: $e');
      return [ViewNode(name: kDefaultViewName, parent: this)];
    }

    final key = layerKey;
    final defs = meta.getViews(key);
    if (defs.isEmpty) return [ViewNode(name: kDefaultViewName, parent: this)];

    return [
      for (final def in defs)
        ViewNode(
          name: def.name,
          parent: this,
          filter: def.filter,
          style: def.style,
          visible: meta.getViewVisibility('$key/${def.name}') ?? true,
        ),
    ];
  }

  /// rowId → スタイルグループのキー。載っていないフィーチャは既定スタイルで描く。
  ///
  /// [refreshStyleGroups] が埋める。
  final Map<int, String> styleKeyByRowId = {};

  /// スタイルグループ（キー → 実際のスタイル）。**挿入順が z順**（View順）。
  ///
  /// 空なら「このレイヤに固有のスタイルは無い」＝ View 導入前とまったく同じ描画。
  final Map<String, KMetaLayerStyle> styleGroups = {};

  /// View（とレイヤ）のスタイル指定を、フィーチャ単位の割り当てに落とす。
  ///
  /// > [!NOTE] 「最初に当たった View が勝つ」
  /// > フィーチャは1つのスタイルでしか描けないので、複数の View に当てはまる
  /// > フィーチャは**上にある View** のものとして描く。z順の考え方と揃えてある。
  ///
  /// > [!IMPORTANT] スタイル指定が1つも無ければ何もしない
  /// > `styleGroups` が空のままなら描画経路は View 導入前と完全に同じになる。
  /// > 既存プロジェクトの見え方を変えないための保険。
  Future<void> refreshStyleGroups() async {
    styleKeyByRowId.clear();
    styleGroups.clear();

    if (views.isEmpty) return;
    final layerStyle = await getKmetaStyle();

    for (final view in views) {
      if (!view.visible) continue;
      final style = view.style ?? layerStyle;
      if (style == null || style.isEmpty) continue;

      final key = view.viewKey;
      styleGroups[key] = style;

      if (!view.hasFilter) {
        // フィルタ無しの View は残り全部を受け持つ
        for (final rowId in _featureMap.keys) {
          styleKeyByRowId.putIfAbsent(rowId, () => key);
        }
        continue;
      }

      final ids = await geoPackageFile.getFeatureIds(
        layerName,
        where: view.filter,
      );
      for (final rowId in ids) {
        styleKeyByRowId.putIfAbsent(rowId, () => key);
      }
    }

    // どの View にも当たらなかったフィーチャは既定スタイル。
    // グループが1つも無ければ、そもそも属性を載せない（[styleGroups] が空）。
    if (styleGroups.isEmpty) styleKeyByRowId.clear();
  }

  /// [rowId] のフィーチャが属するスタイルグループのキー。既定なら空文字。
  String styleKeyOf(int rowId) => styleKeyByRowId[rowId] ?? '';

  /// 表示中の View のフィルタを OR で束ねた WHERE 句。絞り込み不要なら null。
  ///
  /// > [!NOTE] なぜ OR なのか
  /// > View は「同じレイヤを別の条件で何枚も見せる」ためのもので、
  /// > 見えているぶんの**和**が画面に出るべきものだから。
  /// > フィルタを持たない View が1枚でも見えていれば、全件が出る（＝WHERE無し）。
  /// >
  /// > ⚠ フィーチャは Layer に1組しか無いので、どの View 由来かはここでは分からない。
  /// > View ごとに見た目を変えるには、フィーチャに所属Viewを持たせる必要がある（段4b）。
  String? get activeViewFilter {
    if (views.isEmpty) return null; // 未ロード＝絞り込みなし
    final visibleViews = views.where((v) => v.visible).toList();
    if (visibleViews.isEmpty) return null; // 1枚も見えない → 可視判定側で弾く
    if (visibleViews.any((v) => !v.hasFilter)) return null;
    return visibleViews.map((v) => '(${v.filter!.trim()})').join(' OR ');
  }

  /// 表示すべき View が1枚でもあるか。
  ///
  /// View を全部消灯したレイヤは、レイヤ自体が可視でも何も描かない。
  bool get hasVisibleView => views.isEmpty || views.any((v) => v.visible);

  /// 現在の [views] を `.kmeta.json` に書き戻す。
  ///
  /// 既定View1枚だけの状態は「View未定義」と同じ意味なので、書かずに消す。
  Future<void> persistViews() async {
    final folder = folderNode;
    if (folder == null) return;
    final folderPath = folder.getAbsoluteFilePath();
    if (folderPath == null) return;

    final isJustDefault = views.length == 1 && views.first.isDefaultView;
    await KMetaService.instance.setViews(
      folderPath,
      layerKey,
      isJustDefault ? const [] : [for (final v in views) v.toKMetaView()],
    );
    folder.invalidateMetaCache();
  }

  /// KMetaスタイルキャッシュ
  KMetaLayerStyle? _cachedKmetaStyle;
  bool _kmetaStyleLoaded = false;

  /// このレイヤーのKMetaスタイルを取得（キャッシュ対応）
  /// layerKey（gpkgName/layerName形式）を使用して一意に識別
  Future<KMetaLayerStyle?> getKmetaStyle() async {
    if (_kmetaStyleLoaded) return _cachedKmetaStyle;
    _kmetaStyleLoaded = true;

    final folder = folderNode;
    if (folder == null) return null;

    try {
      final meta = await folder.getMeta();
      final key = layerKey;
      _cachedKmetaStyle = meta.getLayerStyle(key);
      return _cachedKmetaStyle;
    } catch (e) {
      AppLogger.debug('[LayerNode] Error getting KMeta style: $e');
      return null;
    }
  }

  /// KMetaスタイルキャッシュをクリア
  void invalidateKmetaStyleCache() {
    _cachedKmetaStyle = null;
    _kmetaStyleLoaded = false;
  }

  /// キャッシュ済みのKMetaスタイルを同期的に取得（描画用）
  /// キャッシュされていない場合はnullを返す
  KMetaLayerStyle? get cachedKmetaStyle => _cachedKmetaStyle;

  /// KMetaスタイルがキャッシュ済みかどうか
  bool get isKmetaStyleLoaded => _kmetaStyleLoaded;

  /// turf_dartのFeatureCollectionオブジェクトを取得
  /// _featureMapから動的に生成（常に最新の状態を反映）
  turf.FeatureCollection get turfFeatureCollection {
    if (_isDisposed) {
      throw StateError('LayerNode is disposed');
    }
    return TurfConverter.createFeatureCollection(_featureMap.values.toList());
  }

  /// rowIdでFeatureを取得（null安全）
  turf.Feature? getFeatureById(int rowId) {
    if (_isDisposed) return null;
    return _featureMap[rowId];
  }

  /// Featureを追加（FeatureNodeから呼ばれる、null参照対策含む）
  void addFeatureToMap(int rowId, turf.Feature feature) {
    if (_isDisposed) {
      AppLogger.debug('[WARNING] LayerNode is disposed, cannot add feature');
      return;
    }
    _featureMap[rowId] = feature;
    _markDirty();
  }

  /// Featureを削除（内部用、null参照対策含む）
  void _removeFeatureFromMap(int rowId) {
    if (_isDisposed) {
      AppLogger.debug('[WARNING] LayerNode is disposed, cannot remove feature');
      return;
    }
    _featureMap.remove(rowId);
    _markDirty();
  }

  /// Featureの属性を更新（内部用、null参照対策含む）
  bool updateFeatureAttribute(int rowId, String key, dynamic value) {
    if (_isDisposed) {
      AppLogger.debug(
        '[WARNING] LayerNode is disposed, cannot update attribute',
      );
      return false;
    }
    final feature = _featureMap[rowId];
    if (feature == null) return false;

    feature.properties ??= {};
    feature.properties![key] = value;
    _markDirty();
    return true;
  }

  /// このレイヤに含まれるFeatureNodeリスト（型安全なchildren、dispose済みを除外）
  List<FeatureNode> get features =>
      super.children
          .whereType<FeatureNode>()
          .where((f) => !f.isDisposed) // dispose済みを除外
          .toList();

  /// position型の座標データを取得（全フィーチャの重心座標リスト）
  List<List<double>> get positions {
    return features.map((feature) => feature.position).toList();
  }

  /// 全フィーチャの実座標を収集（バウンディングボックス計算等に使用）
  List<LatLng> getAllCoordinates() {
    final coords = <LatLng>[];
    for (final feature in features) {
      if (feature is PointFeatureNode) {
        coords.add(feature.point);
      } else if (feature is LineFeatureNode) {
        coords.addAll(feature.line);
      } else if (feature is PolygonFeatureNode) {
        for (final ring in feature.polygon) {
          coords.addAll(ring);
        }
      }
    }
    return coords;
  }

  /// 変更フラグをセット
  void _markDirty() {
    if (_isDisposed) return;
    _isDirty = true;
    // FeatureCollectionは動的生成なのでキャッシュクリア不要
  }

  /// 属性テーブルのカラム名キャッシュ
  List<String>? _cachedColumnNames;

  /// PRIMARY KEYスキップ時のカラム名キャッシュ
  List<String>? _cachedColumnNamesWithoutPK;

  /// 属性テーブルのカラム名を取得（キャッシュ機能付き）
  /// [skipPrimaryKey] trueの場合、PRIMARY KEYカラムを除外（属性テーブル表示用）
  Future<List<String>> getAttributeColumnNames({
    bool getAll = false,
    bool skipPrimaryKey = false,
  }) async {
    if (skipPrimaryKey) {
      _cachedColumnNamesWithoutPK ??= await geoPackageFile.getColumnNames(
        layerName,
        getAll: getAll,
        skipPrimaryKey: true,
      );
      return _cachedColumnNamesWithoutPK!;
    }
    _cachedColumnNames ??= await geoPackageFile.getColumnNames(
      layerName,
      getAll: getAll,
    );
    return _cachedColumnNames!;
  }

  /// 属性テーブルのカラム名キャッシュをクリア
  void clearColumnNamesCache() {
    _cachedColumnNames = null;
    _cachedColumnNamesWithoutPK = null;
  }

  /// データベースからFeatureNodeを非同期で読み込み（プライベートメソッド）
  /// サブクラスでoverrideして具体的な実装を提供する
  Future<List<FeatureNode>> _loadFeaturesFromDB() async {
    return <FeatureNode>[];
  }

  /// FeatureNodeを安全に追加するメソッド
  void addFeature(FeatureNode feature) {
    if (_isDisposed) {
      AppLogger.debug('[WARNING] LayerNode is disposed, cannot add feature');
      return;
    }
    super.addChild(feature);
    // _featureMapにも追加（FeatureNodeが持つturfFeatureを登録）
    addFeatureToMap(feature.rowId, feature.turfFeature);
  }

  /// FeatureNodeを安全に削除するメソッド
  void removeFeature(FeatureNode feature) {
    if (_isDisposed) {
      AppLogger.debug('[WARNING] LayerNode is disposed, cannot remove feature');
      return;
    }
    super.removeChild(feature);
    // _featureMapからも削除
    _removeFeatureFromMap(feature.rowId);
  }

  /// rowIdに該当するFeatureNodeを検索
  FeatureNode? findFeatureByRowId(int rowId) {
    for (final feature in features) {
      if (feature.rowId == rowId) {
        return feature;
      }
    }
    return null;
  }

  /// childrenから属性値辞書を取得し、属性テーブルの2次元配列を返す
  /// [columns] 取得するカラム名のリスト（nullの場合は全カラム取得）
  /// 戻り値: `List<List<dynamic>>` - [ヘッダー行, データ行1, データ行2, ...]
  Future<List<List<dynamic>>> getAttributeTableData({
    List<String>? columns,
    bool getAll = false,
  }) async {
    // カラム名を取得
    final columnNames =
        columns ?? await getAttributeColumnNames(getAll: getAll);

    // ヘッダー行
    final table = <List<dynamic>>[columnNames];

    // 各FeatureNodeから属性値を取得してデータ行を作成
    for (final feature in features) {
      final row = <dynamic>[];

      for (final columnName in columnNames) {
        // FeatureNodeのcachedAttributesから値を取得
        final value = await feature.getAttributeValue(columnName);
        row.add(value);
      }

      table.add(row);
    }

    return table;
  }

  /// 属性テーブルデータを辞書形式で取得（UI表示用）
  /// 戻り値: `Map<String, List<dynamic>>` - カラム名をキーとした列データのマップ
  Future<Map<String, List<dynamic>>> getAttributeTableMap({
    List<String>? columns,
    bool getAll = false,
  }) async {
    // カラム名を取得
    final columnNames =
        columns ?? await getAttributeColumnNames(getAll: getAll);

    // 各カラムの値リストを初期化
    final tableMap = <String, List<dynamic>>{};
    for (final columnName in columnNames) {
      tableMap[columnName] = <dynamic>[];
    }

    // 各FeatureNodeから属性値を取得
    for (final feature in features) {
      for (final columnName in columnNames) {
        final value = await feature.getAttributeValue(columnName);
        tableMap[columnName]!.add(value);
      }
    }

    return tableMap;
  }

  /// コンストラクタ
  LayerNode(
    this.geoPackageFile,
    this.layerName, {
    bool visible = true,
    LayerTreeNode? parent,
  }) : super(
         layerName,
         visible: visible,
         parent: parent,
         nodeType: NodeType.layer,
       );

  /// （サブクラスでoverride推奨）親ノード直下の自分型インスタンスリストを返す（非同期化）
  static Future<List<LayerTreeNode>> loadNodes(LayerTreeNode? parent) async {
    final nodes = <LayerTreeNode>[];
    if (parent is! GeoPackageNode) return nodes;
    final gpkgNode = parent;
    final tableNames = await gpkgNode.geoPackageFile.getLayerNames();
    for (final tableName in tableNames) {
      final type = await gpkgNode.geoPackageFile.getGeometryType(tableName);
      if (type == GeometryType.point) {
        nodes.add(
          PointLayerNode(
            gpkgNode.geoPackageFile,
            tableName,
            visible: true,
            parent: parent,
          ),
        );
      } else if (type == GeometryType.linestring) {
        nodes.add(
          LineLayerNode(
            gpkgNode.geoPackageFile,
            tableName,
            visible: true,
            parent: parent,
          ),
        );
      } else if (type == GeometryType.polygon) {
        nodes.add(
          PolygonLayerNode(
            gpkgNode.geoPackageFile,
            tableName,
            visible: true,
            parent: parent,
          ),
        );
      }
    }
    return nodes;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      AppLogger.debug('[WARNING] LayerNode already disposed');
      return;
    }

    // 先に子のFeatureNodeを全てdispose（_isDisposed = trueを設定する前に）
    // これにより、子がparent.removeFeature()を呼んだ時に正常に_featureMapから削除される
    await super.dispose();

    // 子のdispose完了後にdispose済みフラグを設定
    _isDisposed = true;

    // レイヤ（DBテーブル）削除
    await geoPackageFile.removeLayer(layerName);

    // Mapをクリア（メモリ解放）
    _featureMap.clear();
  }

  @override
  Future<void> updateChildren() async {
    if (_isDisposed) {
      AppLogger.debug(
        '[WARNING] LayerNode is disposed, cannot update children',
      );
      return;
    }

    // 実行中なら完了を待つ（二重実行防止＋呼び出し元に結果を返す）
    if (_updateChildrenCompleter != null) {
      AppLogger.debug(
        '[LayerNode] updateChildren already in progress for $layerName, waiting',
      );
      return _updateChildrenCompleter!.future;
    }

    _updateChildrenCompleter = Completer<void>();

    try {
      final featureList = await _loadFeaturesFromDB();
      _featuresLoaded = true;

      // コンストラクタで _featureMap に登録済みの新エントリを退避
      final newEntries = <int, turf.Feature>{};
      for (final node in featureList) {
        final f = _featureMap[node.rowId];
        if (f != null) newEntries[node.rowId] = f;
      }

      // 同期的にスワップ（ここでは await しない）
      children.clear();
      _featureMap
        ..clear()
        ..addAll(newEntries);

      for (final node in featureList) {
        super.addChild(node);
      }

      // 子ノードの変更があったためキャッシュをクリア
      clearColumnNamesCache();
      _markDirty();
      _featuresRevision++;
      // フィーチャが入れ替わったので、どれがどの View のものかも取り直す
      await refreshStyleGroups();
      _updateChildrenCompleter!.complete();
    } catch (e) {
      _updateChildrenCompleter!.completeError(e);
      rethrow;
    } finally {
      _updateChildrenCompleter = null;
    }
  }

  /// レイヤを別のGeoPackageに移植
  /// [targetGeoPackage] 移植先のGeoPackageNode
  /// [newLayerName] 移植先での新しいレイヤ名（省略時は現在のレイヤ名を使用）
  /// [moveLayer] trueの場合は移植元を削除（移動）、falseの場合は複製
  /// 戻り値: 移植に成功したLayerNode（移植先）
  Future<LayerNode?> migrateToGeoPackage(
    GeoPackageNode targetGeoPackage, {
    String? newLayerName,
    bool moveLayer = true,
  }) async {
    try {
      AppLogger.debug(
        '[LayerNode] レイヤ移植開始: $layerName → ${targetGeoPackage.name}',
      );

      // 移植先のレイヤ名を決定
      final targetLayerName = newLayerName ?? layerName;

      // 移植先に同名のレイヤが存在するかチェック
      final existingLayers =
          await targetGeoPackage.geoPackageFile.getLayerNames();
      if (existingLayers.contains(targetLayerName)) {
        AppLogger.debug('[LayerNode] 移植失敗: レイヤ名 "$targetLayerName" は既に存在します');
        return null;
      }

      // 移植元のジオメトリタイプを取得
      final geometryType = await geoPackageFile.getGeometryType(layerName);
      if (geometryType == null) {
        AppLogger.debug('[LayerNode] 移植失敗: ジオメトリタイプを取得できません');
        return null;
      }

      // 移植先に新しいレイヤを作成
      await targetGeoPackage.geoPackageFile.addLayer(
        targetLayerName,
        geometryType,
      );
      AppLogger.debug(
        '[LayerNode] 移植先レイヤ作成完了: $targetLayerName (${geometryType.value})',
      );

      // 移植元の属性スキーマを取得して移植先に適用
      await _migrateAttributeSchema(targetGeoPackage, targetLayerName);

      // すべてのフィーチャデータを移植
      final migratedFeatureCount = await _migrateFeatureData(
        targetGeoPackage,
        targetLayerName,
        geometryType,
      );

      AppLogger.debug('[LayerNode] フィーチャデータ移植完了: $migratedFeatureCount個のフィーチャ');

      // 移植先のレイヤツリーを更新
      AppLogger.debug('[LayerNode] 移植先レイヤツリー更新開始');
      await targetGeoPackage.updateChildren();

      // 移植されたレイヤノードを取得
      AppLogger.debug(
        '[LayerNode] 移植先の子ノード確認: ${targetGeoPackage.children.map((c) => c.name).toList()}',
      );
      final migratedLayerNode =
          targetGeoPackage.children
              .whereType<LayerNode>()
              .where((layer) => layer.layerName == targetLayerName)
              .firstOrNull;

      if (migratedLayerNode == null) {
        AppLogger.debug('[LayerNode] 移植失敗: 移植先レイヤノードが見つかりません');
        AppLogger.debug('[LayerNode] 期待されるレイヤ名: $targetLayerName');
        AppLogger.debug(
          '[LayerNode] 利用可能なレイヤ: ${targetGeoPackage.children.whereType<LayerNode>().map((l) => l.layerName).toList()}',
        );
        return null;
      }

      // 移植されたレイヤのフィーチャを読み込み
      AppLogger.debug('[LayerNode] 移植されたレイヤのフィーチャ読み込み開始');
      await migratedLayerNode.updateChildren();
      AppLogger.debug(
        '[LayerNode] 移植されたレイヤのフィーチャ数: ${migratedLayerNode.features.length}',
      );

      // 移植元を削除（移動の場合）
      if (moveLayer) {
        await _removeSelfFromParent();
        AppLogger.debug('[LayerNode] 移植元レイヤ削除完了');
      }

      AppLogger.debug('[LayerNode] レイヤ移植成功: $migratedFeatureCount個のフィーチャを移植');
      return migratedLayerNode;
    } catch (e, stack) {
      AppLogger.debug('[LayerNode] レイヤ移植エラー: $e');
      AppLogger.debug('スタックトレース: $stack');
      return null;
    }
  }

  /// 属性スキーマを移植先に適用
  Future<void> _migrateAttributeSchema(
    GeoPackageNode targetGeoPackage,
    String targetLayerName,
  ) async {
    try {
      // 移植元の属性カラム情報を取得
      final sourceColumnInfo = await geoPackageFile.getAttributeColumnInfo(
        layerName,
        includeBuiltIn: false, // 組み込みカラムは除外
      );

      if (sourceColumnInfo.isEmpty) {
        AppLogger.debug('[LayerNode] 移植する属性カラムがありません');
        return;
      }

      // 属性スキーマを作成
      final attributeSchema = <String, String>{};
      for (final columnInfo in sourceColumnInfo) {
        final columnName = columnInfo['name'] as String;
        final columnType = columnInfo['type'] as String;
        attributeSchema[columnName] = columnType;
      }

      // 移植先に属性カラムを追加
      await targetGeoPackage.geoPackageFile.addAttributeColumns(
        targetLayerName,
        attributeSchema,
      );

      // 移植先のカラムを確認し、不足カラムがあれば警告
      final targetColumns = await targetGeoPackage.geoPackageFile
          .getTableColumns(targetLayerName);
      final targetColumnSet = targetColumns.map((c) => c.toLowerCase()).toSet();
      final missingColumns =
          attributeSchema.keys
              .where((c) => !targetColumnSet.contains(c.toLowerCase()))
              .toList();

      if (missingColumns.isNotEmpty) {
        AppLogger.debug('[LayerNode] 追加されなかったカラム: $missingColumns');
      }

      AppLogger.debug(
        '[LayerNode] 属性スキーマ移植完了: ${attributeSchema.length}個中${targetColumns.length - 2}個のカラム追加',
      );
    } catch (e) {
      AppLogger.debug('[LayerNode] 属性スキーマ移植エラー: $e');
      // エラーが発生しても継続（基本的な属性は移植可能）
    }
  }

  /// フィーチャデータを移植先に書き込み
  Future<int> _migrateFeatureData(
    GeoPackageNode targetGeoPackage,
    String targetLayerName,
    GeometryType geometryType,
  ) async {
    try {
      // 移植元のすべてのフィーチャを取得
      final sourceFeatures = await geoPackageFile.getFeatures(layerName);

      if (sourceFeatures.isEmpty) {
        AppLogger.debug('[LayerNode] 移植するフィーチャがありません');
        return 0;
      }

      AppLogger.debug('[LayerNode] 移植対象フィーチャ数: ${sourceFeatures.length}個');

      // バッチ処理でフィーチャを移植
      final batchData = <Map<String, dynamic>>[];
      const batchSize = 1000; // 1000個ずつバッチ処理
      int migratedCount = 0;
      int skippedCount = 0;

      for (final sourceFeature in sourceFeatures) {
        final featureId = sourceFeature['id'] as int?;
        if (featureId == null) {
          AppLogger.debug('[LayerNode] フィーチャIDがnull: $sourceFeature');
          skippedCount++;
          continue;
        }

        // 完全なフィーチャデータを取得（geometry変換済み）
        final completeFeature = await geoPackageFile.getFeature(
          layerName,
          featureId,
        );
        if (completeFeature == null) {
          AppLogger.debug('[LayerNode] フィーチャ取得失敗 ID=$featureId');
          skippedCount++;
          continue;
        }

        AppLogger.debug(
          '[LayerNode] フィーチャ詳細 ID=$featureId: ${completeFeature.keys}',
        );

        // ジオメトリデータを取得
        final geometryData = _extractGeometryData(
          completeFeature,
          geometryType,
        );
        if (geometryData == null) {
          AppLogger.debug(
            '[LayerNode] ジオメトリ抽出失敗 ID=$featureId, type=$geometryType',
          );
          AppLogger.debug('[LayerNode] フィーチャ内容: $completeFeature');
          skippedCount++;
          continue;
        }

        AppLogger.debug('[LayerNode] 抽出されたジオメトリ: $geometryData');

        // 属性データを取得（idとgeomを除く）
        final attributes = Map<String, dynamic>.from(completeFeature);
        attributes.remove('id');
        attributes.remove('geom');
        attributes.remove('geometry'); // 変換済みgeometryも除外
        attributes.remove('points'); // 変換済みpointsも除外
        attributes.remove('lines'); // 変換済みlinesも除外
        attributes.remove('polygons'); // 変換済みpolygonsも除外

        AppLogger.debug('[LayerNode] 抽出された属性: $attributes');

        // バッチデータに追加
        final batchItem = {...geometryData, ...attributes};
        batchData.add(batchItem);
        AppLogger.debug('[LayerNode] バッチアイテム: $batchItem');

        // バッチサイズに達したら処理
        if (batchData.length >= batchSize) {
          final processedCount = await _processMigrationBatch(
            targetGeoPackage,
            targetLayerName,
            geometryType,
            batchData,
          );
          migratedCount += processedCount;
          batchData.clear();

          if (migratedCount % 5000 == 0) {
            AppLogger.debug('[LayerNode] 移植進捗: $migratedCount個完了');
          }
        }
      }

      // 残りのバッチを処理
      if (batchData.isNotEmpty) {
        final processedCount = await _processMigrationBatch(
          targetGeoPackage,
          targetLayerName,
          geometryType,
          batchData,
        );
        migratedCount += processedCount;
      }

      AppLogger.debug(
        '[LayerNode] 移植完了: $migratedCount個成功, $skippedCount個スキップ',
      );
      return migratedCount;
    } catch (e, stack) {
      AppLogger.debug('[LayerNode] フィーチャデータ移植エラー: $e');
      AppLogger.debug('[LayerNode] スタックトレース: $stack');
      return 0;
    }
  }

  /// ジオメトリデータを抽出
  Map<String, dynamic>? _extractGeometryData(
    Map<String, dynamic> feature,
    GeometryType geometryType,
  ) {
    try {
      AppLogger.debug(
        '[LayerNode] ジオメトリ抽出開始: type=$geometryType, 利用可能なキー=${feature.keys}',
      );

      // getFeatureメソッドは'geometry'キーにデータを格納する
      final geometryData = feature['geometry'];
      AppLogger.debug(
        '[LayerNode] geometryデータ: $geometryData (型: ${geometryData.runtimeType})',
      );

      switch (geometryType) {
        case GeometryType.point:
          // ポイントの場合：[LatLng] の配列で返される
          if (geometryData is List<LatLng> && geometryData.isNotEmpty) {
            AppLogger.debug('[LayerNode] ポイント抽出成功: ${geometryData.first}');
            return {'point': geometryData.first};
          }
          // 旧形式との互換性
          final points = feature['points'] as List<LatLng>?;
          if (points != null && points.isNotEmpty) {
            AppLogger.debug('[LayerNode] ポイント抽出成功（旧形式）: ${points.first}');
            return {'point': points.first};
          }

        case GeometryType.linestring:
          // ラインの場合：List<LatLng> で返される
          if (geometryData is List<LatLng> && geometryData.isNotEmpty) {
            AppLogger.debug('[LayerNode] ライン抽出成功: ${geometryData.length}個の頂点');
            return {'line': geometryData};
          }
          // 旧形式との互換性
          final lines = feature['lines'] as List<LatLng>?;
          if (lines != null && lines.isNotEmpty) {
            AppLogger.debug('[LayerNode] ライン抽出成功（旧形式）: ${lines.length}個の頂点');
            return {'line': lines};
          }

        case GeometryType.polygon:
          // ポリゴンの場合：List<List<LatLng>> で返される
          if (geometryData is List<List<LatLng>> && geometryData.isNotEmpty) {
            AppLogger.debug(
              '[LayerNode] ポリゴン抽出成功: ${geometryData.length}個のリング',
            );
            return {'rings': geometryData};
          }
          // 旧形式との互換性
          final polygons = feature['polygons'] as List<List<LatLng>>?;
          if (polygons != null && polygons.isNotEmpty) {
            AppLogger.debug(
              '[LayerNode] ポリゴン抽出成功（旧形式）: ${polygons.length}個のリング',
            );
            return {'rings': polygons};
          }
      }

      AppLogger.debug('[LayerNode] ジオメトリデータの抽出に失敗');
      return null;
    } catch (e, stack) {
      AppLogger.debug('[LayerNode] ジオメトリデータ抽出エラー: $e');
      AppLogger.debug('[LayerNode] スタックトレース: $stack');
      return null;
    }
  }

  /// バッチデータを移植先に書き込み
  Future<int> _processMigrationBatch(
    GeoPackageNode targetGeoPackage,
    String targetLayerName,
    GeometryType geometryType,
    List<Map<String, dynamic>> batchData,
  ) async {
    try {
      AppLogger.debug(
        '[LayerNode] バッチ処理開始: ${batchData.length}個のフィーチャ, タイプ=$geometryType',
      );

      List<int> insertedIds = [];

      switch (geometryType) {
        case GeometryType.point:
          AppLogger.debug('[LayerNode] ポイントバッチ処理実行');
          insertedIds = await targetGeoPackage.geoPackageFile.addPointsBatch(
            targetLayerName,
            batchData,
          );

        case GeometryType.linestring:
          AppLogger.debug('[LayerNode] ラインバッチ処理実行');
          insertedIds = await targetGeoPackage.geoPackageFile.addLinesBatch(
            targetLayerName,
            batchData,
          );

        case GeometryType.polygon:
          AppLogger.debug('[LayerNode] ポリゴンバッチ処理実行');
          insertedIds = await targetGeoPackage.geoPackageFile.addPolygonsBatch(
            targetLayerName,
            batchData,
          );
      }

      AppLogger.debug('[LayerNode] バッチ処理完了: ${insertedIds.length}個挿入');
      AppLogger.debug('[LayerNode] 挿入されたID: $insertedIds');

      return insertedIds.length;
    } catch (e, stack) {
      AppLogger.debug('[LayerNode] バッチ処理エラー: $e');
      AppLogger.debug('[LayerNode] バッチデータサンプル: ${batchData.take(3).toList()}');
      AppLogger.debug('[LayerNode] スタックトレース: $stack');
      rethrow;
    }
  }

  /// 自分自身を親から削除
  Future<void> _removeSelfFromParent() async {
    try {
      // 親のGeoPackageNodeを取得
      final parentGeoPackage = geoPackageNode;

      // レイヤを削除
      await dispose();

      // 親のレイヤツリーを更新
      await parentGeoPackage.updateChildren();
    } catch (e) {
      AppLogger.debug('[LayerNode] 自己削除エラー: $e');
      rethrow;
    }
  }
}

/// ポイントレイヤノード
class PointLayerNode extends LayerNode {
  PointLayerNode(super.file, super.name, {super.visible, super.parent});

  @override
  Future<List<FeatureNode>> _loadFeaturesFromDB() async {
    // 1クエリで全フィーチャをジオメトリパース済みで取得。
    // 表示中Viewのフィルタがあれば WHERE で絞る（[activeViewFilter]）。
    final rows = await geoPackageFile.getFeaturesWithGeometry(
      layerName,
      where: activeViewFilter,
    );
    final features = <FeatureNode>[];

    for (final row in rows) {
      if (row['geometry'] == null) continue;
      final featureNode = PointFeatureNode(row, this);
      features.add(featureNode);
    }

    return features;
  }

  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動

  /// 指定したGeoPackageNodeの下に新しいPointレイヤを作成し、PointLayerNodeインスタンスを返す
  /// 重複名がある場合は自動的にナンバリング（例: "道路_2", "道路_3"）する
  static Future<PointLayerNode?> createIn(
    LayerTreeNode parent,
    String name,
  ) async {
    if (parent is! GeoPackageNode) return null;
    final gpkgFile = parent.geoPackageFile;
    final existingLayers = await gpkgFile.getLayerNames();

    // 重複しない名前を生成
    final uniqueName = LayerNameUtils.generateUniqueLayerName(
      name,
      existingLayers,
    );

    await gpkgFile.addLayer(uniqueName, GeometryType.point);
    final node = PointLayerNode(gpkgFile, uniqueName, parent: parent);
    parent.addChild(node);
    return node;
  }
}

/// ラインレイヤノード
class LineLayerNode extends LayerNode {
  LineLayerNode(super.file, super.name, {super.visible, super.parent});

  @override
  Future<List<FeatureNode>> _loadFeaturesFromDB() async {
    final rows = await geoPackageFile.getFeaturesWithGeometry(
      layerName,
      where: activeViewFilter,
    );
    final features = <FeatureNode>[];

    for (final row in rows) {
      if (row['geometry'] == null) continue;
      final featureNode = LineFeatureNode(row, this);
      features.add(featureNode);
    }

    return features;
  }

  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動

  /// 指定したGeoPackageNodeの下に新しいLineレイヤを作成し、LineLayerNodeインスタンスを返す
  /// 重複名がある場合は自動的にナンバリング（例: "道路_2", "道路_3"）する
  static Future<LineLayerNode?> createIn(
    LayerTreeNode parent,
    String name,
  ) async {
    if (parent is! GeoPackageNode) return null;
    final gpkgFile = parent.geoPackageFile;
    final existingLayers = await gpkgFile.getLayerNames();

    // 重複しない名前を生成
    final uniqueName = LayerNameUtils.generateUniqueLayerName(
      name,
      existingLayers,
    );

    await gpkgFile.addLayer(uniqueName, GeometryType.linestring);
    final node = LineLayerNode(gpkgFile, uniqueName, parent: parent);
    parent.addChild(node);
    return node;
  }
}

/// ポリゴンレイヤノード
class PolygonLayerNode extends LayerNode {
  PolygonLayerNode(super.file, super.name, {super.visible, super.parent});

  @override
  Future<List<FeatureNode>> _loadFeaturesFromDB() async {
    final rows = await geoPackageFile.getFeaturesWithGeometry(
      layerName,
      where: activeViewFilter,
    );
    final features = <FeatureNode>[];

    for (final row in rows) {
      if (row['geometry'] == null) continue;
      final featureNode = PolygonFeatureNode(row, this);
      features.add(featureNode);
    }

    return features;
  }

  // UI関連（baseIcon, baseIconColor）はNodePresenterに移動

  /// 指定したGeoPackageNodeの下に新しいPolygonレイヤを作成し、PolygonLayerNodeインスタンスを返す
  /// 重複名がある場合は自動的にナンバリング（例: "道路_2", "道路_3"）する
  static Future<PolygonLayerNode?> createIn(
    LayerTreeNode parent,
    String name,
  ) async {
    if (parent is! GeoPackageNode) return null;
    final gpkgFile = parent.geoPackageFile;
    final existingLayers = await gpkgFile.getLayerNames();

    // 重複しない名前を生成
    final uniqueName = LayerNameUtils.generateUniqueLayerName(
      name,
      existingLayers,
    );

    await gpkgFile.addLayer(uniqueName, GeometryType.polygon);
    final node = PolygonLayerNode(gpkgFile, uniqueName, parent: parent);
    parent.addChild(node);
    return node;
  }
}
