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
// Root Maps: フィーチャキャッシュMixin
// 可視レイヤのフィーチャを集め、地図に流す GeoJSON（FeatureGeoJsonCache）を組み直す
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../editing/edit_session.dart';
import '../../../models/map_style_group.dart';
import '../../../models/nodes/external_overlay_image_node.dart';
import '../../../models/nodes/feature_node.dart';
import '../../../models/nodes/image_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/layer_tree_node.dart';
import '../../../models/nodes/overlay_image_node.dart';
import '../../../providers/selection_providers.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../services/geotiff_service.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/label_template.dart';
import '../../layer_style_settings_screen.dart'
    show layerStyleSettings, labelEnabledDef, labelPropertyDef, lineVertexPointsEnabledDef, polygonVertexPointsEnabledDef;
import '../feature_geojson_cache.dart';
import '../map_page_state_base.dart';
import 'map_style_mixin.dart';

/// フィーチャキャッシュMixin
/// 地図上に表示するフィーチャの収集と、地図に流す GeoJSON の組み直しを担当
mixin MapFeatureCacheMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T>, MapStyleMixin<T> {
  // =============================================
  // フィーチャ更新処理
  // =============================================

  /// 実行の世代。await をまたぐ間に次の実行が始まったら、古いほうの結果は捨てる
  /// （削除直後に 2 回呼ばれると、削除前の一覧で組んだ古い結果が後から着地しうる）
  int _featuresRun = 0;

  /// フィーチャデータを非同期で更新（キャッシュに保存）
  /// KMetaスタイル読み込みとDB読み込みを並列実行し、最後にフィーチャを分類
  @override
  Future<void> updateFeatures() async {
    final run = ++_featuresRun;
    final folderTree = ref.read(folderTreeProvider);
    final visibleLayers =
        folderTree != null ? folderTree.getVisibleLayerNodes() : <LayerNode>[];

    final newPhotoNodes = <ImageNode>[];
    final newOverlayNodes = <OverlayImageNode>[];
    if (folderTree != null) {
      _collectImageNodes(folderTree, newPhotoNodes, newOverlayNodes);
    }

    // LayerNodeのみ抽出
    final allLayers = visibleLayers.whereType<LayerNode>().toList();

    // View定義の読み込み（未ロードのぶんだけ）。
    // View はフィーチャのWHERE句を決めるので、DB読み込みより先に要る。
    await Future.wait(
      allLayers.where((l) => l.views.isEmpty).map((l) => l.loadViews()),
    );

    // Viewを全部消灯したレイヤは、レイヤ自体が可視でも何も描かない
    final layers = allLayers.where((l) => l.hasVisibleView).toList();

    // KMetaスタイルの事前読み込みを並列実行
    await Future.wait(
      layers
          .where((l) => !l.isKmetaStyleLoaded)
          .map((l) => l.getKmetaStyle()),
    );

    // 初回読み込みが必要なレイヤのDB読み込みを並列実行。
    // ⚠ 「子が空なら読み直す」にしてはいけない。最後の1件を削除した直後の
    //   リフレッシュで DB を読み直し、削除が終わっていない行を復活させていた。
    //   本当に 0 件のレイヤを毎回読み直す無駄も無くなる
    final layersNeedingLoad = layers.where((l) => !l.featuresLoaded).toList();

    if (layersNeedingLoad.isNotEmpty) {
      await Future.wait(
        layersNeedingLoad.map((l) => l.updateChildren()),
      );
    }

    // 全レイヤからフィーチャを分類・収集
    final newPointFeatures = <PointFeatureNode>[];
    final newLineFeatures = <LineFeatureNode>[];
    final newPolygonFeatures = <PolygonFeatureNode>[];

    for (final layer in layers) {
      final activeFeatures = layer.children
          .whereType<FeatureNode>()
          .where((f) => !f.isDisposed);

      if (layer is PointLayerNode) {
        newPointFeatures.addAll(activeFeatures.whereType<PointFeatureNode>());
      } else if (layer is LineLayerNode) {
        newLineFeatures.addAll(activeFeatures.whereType<LineFeatureNode>());
      } else if (layer is PolygonLayerNode) {
        newPolygonFeatures.addAll(activeFeatures.whereType<PolygonFeatureNode>());
      }
    }

    AppLogger.debug(
      '[Features] P:${newPointFeatures.length} L:${newLineFeatures.length} Pg:${newPolygonFeatures.length} Ph:${newPhotoNodes.length} Ov:${newOverlayNodes.length}',
    );

    // GeoTIFF オーバーレイの PNG キャッシュを事前生成（3D の地図面はこれを読む。web はアプリのキャッシュ領域が無いので元ファイルを直接読む）
    // QGIS / GDAL のラスタは GDAL でワープした PNG を作る（web も。GDAL は別スレッド／worker で動く）
    for (final node in newOverlayNodes.whereType<ExternalOverlayImageNode>()) {
      try {
        await node.ensureRendered();
      } catch (e) {
        AppLogger.debug('[Features] ${node.name} の PNG を作れない: $e');
      }
    }
    if (!kIsWeb) {
      for (final node in newOverlayNodes) {
        if (node is ExternalOverlayImageNode) continue;
        final absPath = node.getAbsoluteFilePath();
        if (absPath == null) continue;
        final lower = absPath.toLowerCase();
        if (lower.endsWith('.tif') || lower.endsWith('.tiff')) {
          node.cachedPngPath = await GeoTiffService.ensurePngCache(absPath);
        }
      }
    }

    if (run != _featuresRun) {
      AppLogger.debug('[Features] 古い実行 #$run を捨てる（最新 #$_featuresRun）');
      return;
    }
    if (mounted) {
      triggerSetState(() {
        pointFeatures = newPointFeatures;
        lineFeatures = newLineFeatures;
        polygonFeatures = newPolygonFeatures;
        photoNodes = newPhotoNodes;
        overlayImageNodes = newOverlayNodes;
      });
      invalidateLayerCache();
    }
  }

  /// ImageNodeを再帰的に集める。OverlayImageNodeは別リストに分ける
  void _collectImageNodes(
    LayerTreeNode node,
    List<ImageNode> photos,
    List<OverlayImageNode> overlays,
  ) {
    if (node is ImageNode && node.visible && node.isVisibleRecursive()) {
      if (node is OverlayImageNode) {
        overlays.add(node);
      } else {
        photos.add(node);
      }
    }

    // 子ノードを再帰的に処理（レイヤの子は地物だけなので降りない。1.5 万面を毎回たどっていた）
    if (node is LayerNode) return;
    for (final child in node.children) {
      _collectImageNodes(child, photos, overlays);
    }
  }

  // =============================================
  // IMapState実装
  // =============================================

  /// フィーチャデータの公開更新メソッド（外部から呼び出し可能）
  @override
  void refreshFeatures() {
    updateFeatures();
  }

  /// マップUI更新処理
  /// フィーチャの追加・更新・削除後にマップ表示を更新
  /// 【重要】childrenはクリアせず、メモリ上のインスタンスから読み込む（DBアクセスなし）
  ///
  /// ⚠ 先に一覧を空にして組み直さない。以前はそうしていて、空の組み直しで全フィーチャが
  ///   「消えた」扱いになり、続く組み直しが最初の組み立て扱い（全部変わった）になって、
  ///   描いた地物を確定するたびに 3D の焼き込み済みテクスチャを全部作り直していた
  @override
  void refreshMapUI() {
    AppLogger.debug('[MAP] マップUI更新開始（インスタンスベース）');

    // フィーチャデータを再読み込み（最後に GeoJSON を組み直す）
    updateFeatures().then((_) {
      if (mounted) {
        AppLogger.debug('[MAP] マップUI更新完了');
      }
    }).catchError((Object error) {
      AppLogger.debug('[ERROR] マップUI更新エラー: $error');
    });
  }

  // =============================================
  // 地図に流す GeoJSON
  // =============================================

  /// フィーチャの一覧・スタイルが変わり、GeoJSON の全件を組み直す必要があるか
  bool _featuresDirty = true;

  /// 前回組み直したときの選択（同一性で比べる）
  List<LayerTreeNode>? _lastSelection;

  /// フィーチャの一覧・スタイルが変わった。その場で GeoJSON を組み直して地図に流す
  @override
  void invalidateLayerCache() {
    _featuresDirty = true;
    syncFeatureSources();
  }

  /// GeoJSON を組み直して 3D 地図面に流す（変わったときだけ）。
  /// 通常ソースは常に全フィーチャ、選択ソースは選択分だけ上乗せするので、
  /// 選択だけが変わったときは選択ソースだけ組み直す（通常ソースは前のまま）
  void syncFeatureSources() {
    final currentSelection = ref.read(selectedFeaturesProvider);
    final selectionChanged = !identical(_lastSelection, currentSelection);

    if (!_featuresDirty && !selectionChanged) return;
    final dataChanged = _featuresDirty;
    _featuresDirty = false;
    _lastSelection = currentSelection;

    // View / レイヤのスタイル指定を持ち直す。
    // ⚠ フィーチャを組み立てる**前**に済ませること。`k-style` を載せるかどうかの
    //   判断が [styleGroups] を見ているため。
    setStyleGroups(buildStyleGroups());

    final input = FeatureGeoJsonInput(
      lines: _viewOrdered(lineFeatures),
      polygons: _viewOrdered(polygonFeatures),
      points: pointFeatures,
      photos: photoNodes,
      selected: currentSelection.toSet(),
      hidden: {?ref.read(featureEditorProvider)?.feature},
      // 固有スタイルが1つでもあれば、フィーチャに「どのグループのものか」を載せる
      styleKeyOf: styleGroups.isEmpty ? null : (f) => f.parent.styleKeyOf(f.rowId),
      stylePropKey: kStyleProp,
      labelOf: _labelFor,
      lineVertices: layerStyleSettings.getBool(lineVertexPointsEnabledDef),
      polygonVertices: layerStyleSettings.getBool(polygonVertexPointsEnabledDef),
    );

    if (dataChanged) {
      geoJson.rebuildAll(input);
    } else {
      // 選択のみ変更: 選択ソースだけ再構築（通常ソースは不変→送信スキップ）
      geoJson.rebuildSelection(input);
    }
    // 3D 地図面にシーンを組み直させる
    terrainSceneRevision.value++;
  }

  /// 同じレイヤの中を View の順に並べる（上の View ほど後＝手前に描く。どの View にも当たらないものはいちばん下）。
  /// レイヤどうしの順（ツリーの並び）は変えない。固有スタイルが 1 つも無ければそのまま返す
  List<F> _viewOrdered<F extends FeatureNode>(List<F> fs) {
    if (styleGroups.isEmpty || fs.isEmpty) return fs;
    final byLayer = <LayerNode, List<F>>{};
    for (final f in fs) {
      (byLayer[f.parent] ??= []).add(f);
    }
    final out = <F>[];
    for (final MapEntry(key: layer, value: list) in byLayer.entries) {
      final keys = layer.styleGroups.keys.toList();
      if (keys.length < 2) {
        out.addAll(list);
        continue;
      }
      final rank = {for (var i = 0; i < keys.length; i++) keys[i]: i};
      // 順位ごとに振り分けて下から積む（同じ View の中は元の順のまま）
      final buckets = List.generate(keys.length + 1, (_) => <F>[]);
      for (final f in list) {
        buckets[rank[layer.styleKeyOf(f.rowId)] ?? keys.length].add(f);
      }
      for (final b in buckets.reversed) {
        out.addAll(b);
      }
    }
    return out;
  }

  /// フィーチャに出すラベル。View 固有 → レイヤ固有 → 全体設定の順で解決する
  String? _labelFor(FeatureNode f) {
    final layer = f.parent;
    final kmeta =
        layer.styleGroups[layer.styleKeyOf(f.rowId)] ?? layer.kmetaStyleIfLoaded;
    if (!layerStyleSettings.resolveBool(labelEnabledDef, kmeta)) return null;
    return renderLabelTemplate(
      layerStyleSettings.resolveString(labelPropertyDef, kmeta),
      f.turfFeature.properties,
    );
  }
}
