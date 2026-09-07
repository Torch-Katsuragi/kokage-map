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
// 地図表示用のフィーチャキャッシュを効率的に管理
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/nodes/feature_node.dart';
import '../../../models/nodes/image_node.dart';
import '../../../models/nodes/layer_node.dart';
import '../../../models/nodes/layer_tree_node.dart';
import '../../../models/nodes/overlay_image_node.dart';
import '../../../providers/ui_state_providers.dart';
import '../../../services/geotiff_service.dart';
import '../../../utils/app_logger.dart';
import '../map_page_state_base.dart';

/// フィーチャキャッシュMixin
/// 地図上に表示するフィーチャのキャッシュ管理を提供
mixin MapFeatureCacheMixin<T extends ConsumerStatefulWidget> on MapPageStateBase<T> {
  
  // =============================================
  // フィーチャ更新処理
  // =============================================
  
  /// フィーチャデータを非同期で更新（キャッシュに保存）
  /// KMetaスタイル読み込みとDB読み込みを並列実行し、最後にフィーチャを分類
  Future<void> updateFeaturesImpl() async {
    final folderTree = ref.read(folderTreeProvider);
    final visibleLayers =
        folderTree != null ? folderTree.getVisibleLayerNodes() : <LayerNode>[];

    final newPhotoNodes = <ImageNode>[];
    final newOverlayNodes = <OverlayImageNode>[];
    if (folderTree != null) {
      collectImageNodesRecursive(folderTree, newPhotoNodes, newOverlayNodes);
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

    // GeoTIFFオーバーレイのPNGキャッシュを事前生成
    // MapLibreはTIFF非対応のため、file://で参照できるPNGが必要
    for (final node in newOverlayNodes) {
      final absPath = node.getAbsoluteFilePath();
      if (absPath != null) {
        final lower = absPath.toLowerCase();
        if (lower.endsWith('.tif') || lower.endsWith('.tiff')) {
          final pngPath = await GeoTiffService.ensurePngCache(absPath);
          node.cachedPngPath = pngPath;
        }
      }
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
  
  /// ImageNodeを再帰的に収集する補助メソッド
  /// OverlayImageNodeは別リストに分離
  void collectImageNodesRecursive(
    LayerTreeNode node,
    List<ImageNode> photos,
    List<OverlayImageNode> overlays,
  ) {
    // 現在のノードがOverlayImageNodeならオーバーレイリストに追加
    if (node is OverlayImageNode && node.visible && node.isVisibleRecursive()) {
      overlays.add(node);
    }
    // 通常のImageNodeなら写真リストに追加
    else if (node is ImageNode && node.visible && node.isVisibleRecursive()) {
      photos.add(node);
    }
    
    // 子ノードを再帰的に処理
    for (final child in node.children) {
      collectImageNodesRecursive(child, photos, overlays);
    }
  }
  
  // =============================================
  // IMapState実装
  // =============================================
  
  /// フィーチャデータの公開更新メソッド（外部から呼び出し可能）
  @override
  void refreshFeatures() {
    updateFeaturesImpl();
  }
  
  /// マップの強制更新処理（外部から呼び出し可能）
  @override
  void forceMapRefresh() {
    refreshMapUI();
  }
  
  // =============================================
  // マップUI更新
  // =============================================
  
  /// マップUI更新処理
  /// フィーチャの追加・更新・削除後にマップ表示を更新
  /// 【重要】childrenはクリアせず、メモリ上のインスタンスから読み込む（DBアクセスなし）
  void refreshMapUI() {
    AppLogger.debug('[MAP] マップUI更新開始（インスタンスベース）');
    
    // 1. フィーチャデータのキャッシュをクリア
    pointFeatures.clear();
    lineFeatures.clear();
    polygonFeatures.clear();
    photoNodes.clear();
    overlayImageNodes.clear();
    invalidateLayerCache();
    
    // 2. 【重要】LayerNodeのchildrenはクリアしない（メモリ上のインスタンスを維持）
    
    // 3. フィーチャデータを再読み込み（updateFeaturesImpl内でsyncFeatureSourcesが呼ばれる）
    updateFeaturesImpl().then((_) {
      if (mounted) {
        AppLogger.debug('[MAP] マップUI更新完了');
      }
    }).catchError((error) {
      AppLogger.debug('[ERROR] マップUI更新エラー: $error');
    });
  }
}

