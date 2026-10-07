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
// lib/services/geometry_conversion_service.dart
// ジオメトリ変換サービス（ポイント⇔ライン/ポリゴン）
import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../models/nodes/feature_node.dart';
import '../models/nodes/geopackage_node.dart';
import '../models/nodes/layer_node.dart';
import '../models/nodes/layer_tree_node.dart';
import 'survey/survey_chain_resolver.dart';
import 'survey/traverse_adjuster.dart';

/// ジオメトリ変換サービス
class GeometryConversionService {
  /// ポイントフィーチャ列をGeoJSON FeatureCollectionに変換する
  static String _buildSubTableGeoJson(List<PointFeatureNode> features) {
    final geoFeatures = <Map<String, dynamic>>[];
    for (final f in features) {
      final props = Map<String, dynamic>.from(f.turfFeature.properties ?? {});
      props.remove('id');
      geoFeatures.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [f.point.longitude, f.point.latitude],
        },
        'properties': props,
      });
    }
    return jsonEncode({
      'type': 'FeatureCollection',
      'features': geoFeatures,
    });
  }

  /// ポリゴンリングを閉じる（最初と最後の座標を同じにする）
  static List<LatLng> closeRing(List<LatLng> pts) {
    if (pts.length < 3) return [];
    final first = pts.first;
    final last = pts.last;
    final bool isClosed = (first.latitude == last.latitude) && (first.longitude == last.longitude);
    if (!isClosed) {
      return List<LatLng>.from(pts)..add(first);
    }
    return pts;
  }

  /// ノードツリーからライン/ポリゴンレイヤーを同期的に検索
  static void searchLineAndPolygonLayers(LayerTreeNode node, List<LayerNode> result) {
    // FeatureNodeは検索しない（パフォーマンス最適化）
    if (node is FeatureNode) {
      return;
    }
    
    if (node is LineLayerNode || node is PolygonLayerNode) {
      result.add(node as LayerNode);
      // レイヤーが見つかったら、その子（FeatureNode）は検索しない
      return;
    }
    
    // FolderNodeとGeoPackageNodeの子を再帰的に検索
    for (final child in node.children) {
      searchLineAndPolygonLayers(child, result);
    }
  }

  /// カレントディレクトリ直下のGeoPackage内のライン/ポリゴンレイヤーを検索
  static List<LayerNode> findTargetLayersForPoints(LayerTreeNode? currentDir) {
    final targetLayers = <LayerNode>[];
    if (currentDir == null) return targetLayers;
    
    // currentNodeの直接の子（GeoPackageNode）のみを検索
    for (final child in currentDir.children) {
      if (child is GeoPackageNode) {
        searchLineAndPolygonLayers(child, targetLayers);
      }
    }
    
    return targetLayers;
  }

  /// 元のポイント群を GeoJSON にし、変換先に sub_table 列を足す。作れなければ null
  static Future<String?> _prepareSubTable(
    PointLayerNode sourceLayer,
    LayerNode targetLayer,
  ) async {
    final features = sourceLayer.features.whereType<PointFeatureNode>().toList();
    if (features.isEmpty) return null;
    final String json;
    try {
      json = _buildSubTableGeoJson(features);
    } catch (e) {
      AppLogger.debug('[GeometryConversion] sub_table生成エラー: $e');
      return null;
    }
    try {
      await targetLayer.geoPackageFile
          .addAttributeColumn(targetLayer.layerName, 'sub_table', 'TEXT');
    } catch (_) {
      // 既にある
    }
    return json;
  }

  /// 変換先レイヤの種類に合わせて線か面（外環のみ・閉じる）を作る
  static Future<FeatureNode?> _createShape(
    LayerNode targetLayer,
    List<LatLng> points,
    String name,
  ) async {
    if (targetLayer is LineLayerNode) {
      return LineFeatureNode.createIn(targetLayer, points, name, null);
    }
    if (targetLayer is PolygonLayerNode) {
      final ring = closeRing(points);
      if (ring.isEmpty) return null;
      return PolygonFeatureNode.createIn(targetLayer, [ring], name, null);
    }
    return null;
  }

  /// 作った地物に属性を書き、すぐ DB に保存する（バックグラウンド保存を待たない）
  static Future<void> _writeAttributes(
    FeatureNode feature,
    Map<String, dynamic> attributes,
  ) async {
    if (attributes.isEmpty) return;
    try {
      await feature.setAttributeValues(attributes);
      await feature.flushChanges();
    } catch (e, stack) {
      AppLogger.debug('[GeometryConversion] 属性設定エラー: $e\n$stack');
    }
  }

  /// ポイントレイヤーをライン/ポリゴンに変換
  ///
  /// [sourceLayer] 変換元のポイントレイヤー
  /// [targetLayer] 変換先のライン/ポリゴンレイヤー
  /// [name] 作成するフィーチャの名前（省略時はデフォルト名）
  static Future<FeatureNode?> convertPointsToGeometry({
    required PointLayerNode sourceLayer,
    required LayerNode targetLayer,
    String? name,
  }) async {
    final points = sourceLayer.features.map((feature) => feature.centroid).toList();
    if (points.isEmpty) return null;

    final subTableJson = await _prepareSubTable(sourceLayer, targetLayer);
    final created = await _createShape(
      targetLayer,
      points,
      name ?? 'Converted from ${sourceLayer.name}',
    );
    if (created != null && subTableJson != null) {
      await _writeAttributes(created, {'sub_table': subTableJson});
    }
    return created;
  }

  /// 測量チェーンをライン/ポリゴンに変換（閉合補正対応）
  ///
  /// 生データから座標を再計算し、指定された補正を適用した上で
  /// ライン/ポリゴンフィーチャを作成する。
  static Future<FeatureNode?> convertSurveyPointsToGeometry({
    required PointLayerNode sourceLayer,
    required LayerNode targetLayer,
    required TraverseChain chain,
    required TraverseAdjustmentOptions options,
    String? name,
    bool closePath = false,
  }) async {
    if (chain.isEmpty) return null;

    // 開放トラバースの場合は閉合補正を強制的に無効化
    final effectiveOptions = closePath
        ? options
        : TraverseAdjustmentOptions(
            method: AdjustmentMethod.none,
            declination: options.declination,
            instrumentHeight: options.instrumentHeight,
            targetHeight: options.targetHeight,
          );

    // 補正を適用して座標を再計算
    final result = TraverseAdjuster.adjust(chain, effectiveOptions);
    final points = result.adjustedPositions;

    if (points.length < 2) return null;

    // sub_table: 元の測量データをGeoJSON FeatureCollectionで保存
    final subTableJson = await _prepareSubTable(sourceLayer, targetLayer);

    // メタデータ用カラムを追加
    final metaCols = ['survey_total_distance', 'survey_declination'];
    if (closePath) {
      metaCols.addAll(['survey_closure_ratio', 'survey_closure_error',
                       'survey_adjustment_method']);
    }
    for (final col in metaCols) {
      try {
        await targetLayer.geoPackageFile.addAttributeColumn(
          targetLayer.layerName, col, 'TEXT',
        );
      } catch (_) {}
    }

    final created = await _createShape(
      targetLayer,
      points,
      name ?? 'Survey from ${sourceLayer.name}',
    );
    if (created == null) return null;

    final attrs = <String, dynamic>{
      'survey_total_distance': result.totalDistance.toStringAsFixed(2),
      'survey_declination': options.declination.toString(),
      if (closePath) ...{
        'survey_closure_ratio': result.closureRatioN.isInfinite
            ? 'perfect'
            : '1/${result.closureRatioN.toStringAsFixed(0)}',
        'survey_closure_error': result.closureError.toStringAsFixed(4),
        'survey_adjustment_method': effectiveOptions.method.name,
      },
      'sub_table': ?subTableJson,
    };
    await _writeAttributes(created, attrs);
    return created;
  }
}
