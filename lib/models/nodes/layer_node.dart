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
import 'dart:convert';

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:turf/turf.dart' as turf;

import '../../core/node_types.dart';
import '../../services/kmeta_service.dart';
import '../geometry_type.dart';
import '../geopackage/feature_repository.dart' show toGeoMultiLine, toGeoMultiPolygon, toGeoPoint;
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

  /// dispose済みフラグ（null参照対策）
  bool _isDisposed = false;

  /// updateChildren進行中のCompleter（二重実行防止＋完了待ち）
  Completer<void>? _updateChildrenCompleter;

  /// 進行中に呼ばれた（終わったら読み直す）
  bool _rerunRequested = false;

  /// DB からフィーチャを一度でも読んだか。空のレイヤと未ロードのレイヤを区別する
  bool _featuresLoaded = false;
  bool get featuresLoaded => _featuresLoaded;

  /// dispose済みかどうかを取得
  bool get isDisposed => _isDisposed;

  /// 親のGeoPackageNodeを取得
  GeoPackageNode get geoPackageNode =>
      ancestorOf<GeoPackageNode>() ??
      (throw StateError('LayerNode must have a GeoPackageNode parent'));

  /// 親のFolderNodeを取得
  FolderNode? get folderNode => ancestorOf<FolderNode>();

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

  /// フォルダ設定（`.qgs`） から View 定義を読み直す。
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
    _restStyleKey = null;

    if (views.isEmpty) return;
    final layerStyle = await getKmetaStyle();

    for (final view in views) {
      if (!view.visible) continue;
      // View に指定が無い項目はレイヤの値（項目ごとの合成。丸ごと差し替えではない）
      final style = view.style == null ? layerStyle : view.style!.mergeWith(layerStyle);
      if (style == null || style.isEmpty) continue;

      // 描画で使うキー。viewKey（gpkg名/レイヤ名/View名）には dir が入らないので、別の dir にある
      // 同名の gpkg・レイヤ（複製した dir 等）と地図全体で1つに畳まれ、片方の色で両方描いていた
      // （2026-09-30、Pixel 9 で Kitayama-2026 とその下の Kitayama-2026-demo）。gpkg のパスを添える
      final key = '${geoPackageFile.getAbsolutePath() ?? ''}|${view.viewKey}';
      styleGroups[key] = style;

      if (!view.hasFilter) {
        // フィルタ無しの View は残り全部を受け持つ（あとから足した地物も）
        _restStyleKey ??= key;
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
    if (styleGroups.isEmpty) {
      styleKeyByRowId.clear();
      _restStyleKey = null;
    }
  }

  /// フィルタ無しの View のキー。取り直しの後に足した地物（描いた面など）はここに落とす。
  /// 無いと既定のスタイル（黒 10%）で描かれ、レイヤの色が付いていなかった（2026-10-02）
  String? _restStyleKey;

  /// [rowId] のフィーチャが属するスタイルグループのキー。既定なら空文字。
  String styleKeyOf(int rowId) => styleKeyByRowId[rowId] ?? _restStyleKey ?? '';

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

  /// 現在の [views] を フォルダ設定（`.qgs`） に書き戻す。
  ///
  /// 既定View1枚だけの状態は「View未定義」と同じ意味なので、書かずに消す。
  /// 既定 View の見え方はレイヤのスタイルそのもの。既定 View に付いたスタイル（QGIS からの読み込み・旧データ）は
  /// レイヤのスタイルへ移す（前は既定 1 枚のとき View ごと捨てていて、変えた色が開き直すと元に戻っていた）
  Future<void> persistViews() async {
    final folder = folderNode;
    if (folder == null) return;
    final folderPath = folder.getAbsoluteFilePath();
    if (folderPath == null) return;

    final isJustDefault = views.length == 1 && views.first.isDefaultView;
    final defaultView = views.where((v) => v.isDefaultView).firstOrNull;
    final defaultStyle = defaultView?.style;
    if (defaultView != null && defaultStyle != null) {
      final existing = (await KMetaService.instance.getMeta(folderPath)).styles.layers[layerKey];
      await KMetaService.instance.setLayerStyle(folderPath, layerKey, defaultStyle.mergeWith(existing));
      defaultView.style = null;
      invalidateKmetaStyleCache();
    }
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

  /// KMetaスタイルがキャッシュ済みかどうか
  bool get isKmetaStyleLoaded => _kmetaStyleLoaded;

  /// 読み込み済みならその値、未ロードなら null（描画の同期経路用）
  KMetaLayerStyle? get kmetaStyleIfLoaded => _cachedKmetaStyle;

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
  }

  /// Featureを削除（内部用、null参照対策含む）
  void _removeFeatureFromMap(int rowId) {
    if (_isDisposed) {
      AppLogger.debug('[WARNING] LayerNode is disposed, cannot remove feature');
      return;
    }
    _featureMap.remove(rowId);
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
    return true;
  }

  /// このレイヤに含まれるFeatureNodeリスト（型安全なchildren、dispose済みを除外）
  List<FeatureNode> get features =>
      super.children
          .whereType<FeatureNode>()
          .where((f) => !f.isDisposed) // dispose済みを除外
          .toList();

  /// 地物の数（地図に読み込んだ分）。[features] のように一覧を複製しない（レイヤ一覧の行が組み立てのたびに数える）
  int get featureCount => _featureMap.length;

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

  /// 行から地物のノードを作る（形の種類ごと）
  FeatureNode _featureFromRow(Map<String, dynamic> row);

  /// 1クエリで全フィーチャをジオメトリパース済みで取得。
  /// 表示中Viewのフィルタがあれば WHERE で絞る（[activeViewFilter]）
  Future<List<FeatureNode>> _loadFeaturesFromDB() async {
    final rows = await geoPackageFile.getFeaturesWithGeometry(
      layerName,
      where: activeViewFilter,
    );
    return [
      for (final row in rows)
        if (row['geometry'] != null) _featureFromRow(row),
    ];
  }

  /// [parent] の GeoPackage に新しいレイヤを作ってノードを返す。
  /// 重複名がある場合は自動的にナンバリング（例: "道路_2", "道路_3"）する
  static Future<T?> _createIn<T extends LayerNode>(
    LayerTreeNode parent,
    String name,
    GeometryType type,
    T Function(GeoPackageFile file, String name, GeoPackageNode parent) create,
  ) async {
    if (parent is! GeoPackageNode) return null;
    final gpkgFile = parent.geoPackageFile;
    final uniqueName = LayerNameUtils.generateUniqueLayerName(
      name,
      await gpkgFile.getLayerNames(),
    );
    await gpkgFile.addLayer(uniqueName, type);
    final node = create(gpkgFile, uniqueName, parent);
    parent.addChild(node);
    return node;
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

  /// コンストラクタ
  LayerNode(
    this.geoPackageFile,
    this.layerName, {
    super.visible,
    super.parent,
  }) : super(
         layerName,
         nodeType: NodeType.layer,
       );

  /// （サブクラスでoverride推奨）親ノード直下の自分型インスタンスリストを返す（非同期化）
  static Future<List<LayerTreeNode>> loadNodes(LayerTreeNode? parent) async {
    if (parent is! GeoPackageNode) return [];
    final file = parent.geoPackageFile;
    return [
      for (final MapEntry(key: table, value: type) in (await file.getLayerGeometryTypes()).entries)
        ?switch (type) {
          GeometryType.point => PointLayerNode(file, table, visible: true, parent: parent),
          GeometryType.linestring => LineLayerNode(file, table, visible: true, parent: parent),
          GeometryType.polygon => PolygonLayerNode(file, table, visible: true, parent: parent),
          null => null,
        },
    ];
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

    // 実行中なら完了を待ってから**もう一度読む**。進行中の読み込みは古い WHERE（View を消灯する前の
    // activeViewFilter）で走っていることがあり、その結果をそのまま返すと消灯した View のフィーチャが
    // 地図に残る（2026-09-01 実機で確認した「View を hide しても消えない」の原因）
    if (_updateChildrenCompleter != null) {
      AppLogger.debug(
        '[LayerNode] updateChildren already in progress for $layerName, waiting then reloading',
      );
      _rerunRequested = true;
      try {
        await _updateChildrenCompleter!.future;
      } catch (_) {
        // 進行中の失敗は向こうの呼び出し元が受け取る。こちらは読み直す
      }
      if (_updateChildrenCompleter != null) return _updateChildrenCompleter!.future; // 別の待ち手が再実行を始めた
      if (!_rerunRequested) return; // 再実行済み
      return updateChildren();
    }

    _rerunRequested = false;
    _updateChildrenCompleter = Completer<void>();

    try {
      final featureList = await _loadFeaturesFromDB();
      _featuresLoaded = true;

      // 新しいノードはコンストラクタで _featureMap に登録（上書き）済み。読み直しで無くなった行だけ落とす
      // （以前は新しい分を別の Map に写してから入れ直していた。1.5 万件で 2 回の写し）
      final loadedIds = {for (final node in featureList) node.rowId};

      // 同期的にスワップ（ここでは await しない）
      children.clear();
      _featureMap.removeWhere((rowId, _) => !loadedIds.contains(rowId));

      for (final node in featureList) {
        super.addChild(node);
      }

      // 子ノードの変更があったためキャッシュをクリア
      clearColumnNamesCache();
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
      final (migratedFeatureCount, sourceCount) = await _migrateFeatureData(
        targetGeoPackage,
        targetLayerName,
        geometryType,
      );

      AppLogger.debug('[LayerNode] フィーチャデータ移植完了: $migratedFeatureCount / $sourceCount 個のフィーチャ');
      // 全部渡らなかったら移し先の途中までの写しを消して失敗にする（移し元は消さない）。
      // ⚠ 以前は取りこぼしがあっても移し元を消していた（2026-10-07）
      if (migratedFeatureCount < sourceCount) {
        AppLogger.debug('[LayerNode] 移植失敗: ${sourceCount - migratedFeatureCount} 個が渡らなかったので取り消す');
        await targetGeoPackage.geoPackageFile.removeLayer(targetLayerName);
        await targetGeoPackage.updateChildren();
        return null;
      }

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
  ///
  /// 移植元を 1 回で読み（形は WGS84 に直してある）、1000 件ずつ書く。
  /// 形は Multi のまま渡す（以前は最初の 1 部分しか取れず、線・面は Multi で読めるので 1 件も渡らなかった）
  /// 戻り値: (書けた数, 移植元の行数)
  Future<(int, int)> _migrateFeatureData(
    GeoPackageNode targetGeoPackage,
    String targetLayerName,
    GeometryType geometryType,
  ) async {
    try {
      final sourceFeatures = await geoPackageFile.getFeaturesWithGeometry(layerName);
      if (sourceFeatures.isEmpty) {
        AppLogger.debug('[LayerNode] 移植するフィーチャがありません');
        return (0, 0);
      }
      AppLogger.debug('[LayerNode] 移植対象フィーチャ数: ${sourceFeatures.length}個');

      const batchSize = 1000;
      final batch = <(geo.Geometry, Map<String, dynamic>)>[];
      var migratedCount = 0;
      var skippedCount = 0;

      Future<void> flush() async {
        migratedCount += (await targetGeoPackage.geoPackageFile.addGeometries(targetLayerName, batch)).length;
        batch.clear();
      }

      for (final row in sourceFeatures) {
        final geometry = _toGeoGeometry(row['geometry'], geometryType);
        if (geometry == null) {
          AppLogger.debug('[LayerNode] ジオメトリ抽出失敗 ID=${row['id']}, type=$geometryType');
          skippedCount++;
          continue;
        }
        // 属性（主キー・形の列は書く側が捨てる）。メタデータは読むときに JSON を解いているので文字列に戻す
        batch.add((
          geometry,
          {
            for (final MapEntry(:key, :value) in row.entries)
              if (key != 'geometry') key: value is Map ? jsonEncode(value) : value,
          },
        ));
        if (batch.length >= batchSize) await flush();
      }
      if (batch.isNotEmpty) await flush();

      AppLogger.debug(
        '[LayerNode] 移植完了: $migratedCount個成功, $skippedCount個スキップ',
      );
      return (migratedCount, sourceFeatures.length);
    } catch (e, stack) {
      AppLogger.debug('[LayerNode] フィーチャデータ移植エラー: $e');
      AppLogger.debug('[LayerNode] スタックトレース: $stack');
      return (0, 1); // 読み書きに失敗したら取り消す側へ
    }
  }

  /// 読み出した形（[geobaseGeometryToLatLngs] の LatLng の入れ子）を書き込み用の形に戻す。部分は落とさない
  static geo.Geometry? _toGeoGeometry(Object? data, GeometryType type) {
    geo.Geographic g(LatLng p) => geo.Geographic(lon: p.longitude, lat: p.latitude);
    switch (type) {
      case GeometryType.point:
        if (data is List<LatLng> && data.isNotEmpty) {
          return data.length == 1 ? toGeoPoint(data.single) : geo.MultiPoint.from(data.map(g));
        }
      case GeometryType.linestring:
        if (data is List<List<LatLng>> && data.isNotEmpty) {
          return geo.MultiLineString.from([for (final line in data) line.map(g)]);
        }
        if (data is List<LatLng> && data.isNotEmpty) return toGeoMultiLine(data);
      case GeometryType.polygon:
        if (data is List<List<List<LatLng>>> && data.isNotEmpty) {
          return geo.MultiPolygon.from([
            for (final polygon in data) [for (final ring in polygon) ring.map(g)],
          ]);
        }
        if (data is List<List<LatLng>> && data.isNotEmpty) return toGeoMultiPolygon(data);
    }
    return null;
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
  FeatureNode _featureFromRow(Map<String, dynamic> row) => PointFeatureNode(row, this);

  static Future<PointLayerNode?> createIn(LayerTreeNode parent, String name) =>
      LayerNode._createIn(
        parent,
        name,
        GeometryType.point,
        (file, name, parent) => PointLayerNode(file, name, parent: parent),
      );
}

/// ラインレイヤノード
class LineLayerNode extends LayerNode {
  LineLayerNode(super.file, super.name, {super.visible, super.parent});

  @override
  FeatureNode _featureFromRow(Map<String, dynamic> row) => LineFeatureNode(row, this);

  static Future<LineLayerNode?> createIn(LayerTreeNode parent, String name) =>
      LayerNode._createIn(
        parent,
        name,
        GeometryType.linestring,
        (file, name, parent) => LineLayerNode(file, name, parent: parent),
      );
}

/// ポリゴンレイヤノード
class PolygonLayerNode extends LayerNode {
  PolygonLayerNode(super.file, super.name, {super.visible, super.parent});

  @override
  FeatureNode _featureFromRow(Map<String, dynamic> row) => PolygonFeatureNode(row, this);

  static Future<PolygonLayerNode?> createIn(LayerTreeNode parent, String name) =>
      LayerNode._createIn(
        parent,
        name,
        GeometryType.polygon,
        (file, name, parent) => PolygonLayerNode(file, name, parent: parent),
      );
}
