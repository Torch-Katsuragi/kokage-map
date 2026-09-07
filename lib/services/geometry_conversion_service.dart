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

  /// sub_table GeoJSONからポイント座標と属性を復元する
  ///
  /// 旧フォーマット（2D配列）にも後方互換対応。
  static List<({LatLng point, Map<String, dynamic> properties})>?
      _parseSubTable(String json) {
    try {
      final decoded = jsonDecode(json);

      // 新フォーマット: GeoJSON FeatureCollection
      if (decoded is Map && decoded['type'] == 'FeatureCollection') {
        final features = decoded['features'] as List;
        return features.map((f) {
          final geom = f['geometry'] as Map<String, dynamic>;
          final coords = geom['coordinates'] as List;
          final lon = (coords[0] as num).toDouble();
          final lat = (coords[1] as num).toDouble();
          final props = Map<String, dynamic>.from(
            (f['properties'] as Map?) ?? {},
          );
          return (point: LatLng(lat, lon), properties: props);
        }).toList();
      }

      // 旧フォーマット: [[headers], [row1], ...]
      if (decoded is List && decoded.isNotEmpty && decoded.first is List) {
        final headers = (decoded.first as List).cast<String>();
        return decoded.skip(1).map((row) {
          final r = row as List;
          final props = <String, dynamic>{};
          for (int i = 0; i < headers.length && i < r.length; i++) {
            if (headers[i] == 'id' || headers[i] == 'geom') continue;
            props[headers[i]] = r[i];
          }
          return (point: const LatLng(0, 0), properties: props);
        }).toList();
      }
    } catch (e) {
      AppLogger.debug('[GeometryConversion] sub_table parse error: $e');
    }
    return null;
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

  /// ノードツリーからポイントレイヤーを検索
  static void searchPointLayers(LayerTreeNode node, List<PointLayerNode> result) {
    if (node is FeatureNode) return;
    
    if (node is PointLayerNode) {
      result.add(node);
      return;
    }
    
    for (final child in node.children) {
      searchPointLayers(child, result);
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

  /// カレントディレクトリ直下のGeoPackage内のポイントレイヤーを検索
  static List<PointLayerNode> findTargetLayersForGeometry(LayerTreeNode? currentDir) {
    final pointLayers = <PointLayerNode>[];
    if (currentDir == null) return pointLayers;
    
    // currentNodeの直接の子（GeoPackageNode）のみを検索
    for (final child in currentDir.children) {
      if (child is GeoPackageNode) {
        searchPointLayers(child, pointLayers);
      }
    }
    
    return pointLayers;
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
    // ポイントの座標リストを作成
    final points = sourceLayer.features.map((feature) => feature.centroid).toList();
    
    if (points.isEmpty) {
      return null;
    }

    // ポイントレイヤーのフィーチャをGeoJSON FeatureCollectionに変換
    String? subTableJson;
    try {
      final features = sourceLayer.features.whereType<PointFeatureNode>().toList();
      if (features.isNotEmpty) {
        subTableJson = _buildSubTableGeoJson(features);
        AppLogger.debug('[GeometryConversion] sub_table GeoJSON生成: ${features.length}フィーチャ');
      }
    } catch (e) {
      AppLogger.debug('[GeometryConversion] sub_table生成エラー: $e');
    }

    // 変換先レイヤーにsub_tableカラムを追加（存在しない場合）
    if (subTableJson != null) {
      try {
        await targetLayer.geoPackageFile.addAttributeColumn(
          targetLayer.layerName,
          'sub_table',
          'TEXT',
        );
        AppLogger.debug('[GeometryConversion] sub_tableカラムを追加');
      } catch (e) {
        AppLogger.debug('[GeometryConversion] sub_tableカラム追加エラー（既存の可能性）: $e');
      }
    }

    // フィーチャ名を決定（指定がなければデフォルト名）
    final featureName = name ?? 'Converted from ${sourceLayer.name}';
    
    // レイヤータイプに応じてフィーチャを作成
    FeatureNode? createdFeature;
    if (targetLayer is LineLayerNode) {
      // ラインフィーチャを作成
      createdFeature = await LineFeatureNode.createIn(
        targetLayer,
        points,
        featureName,
        null,
      );
    } else if (targetLayer is PolygonLayerNode) {
      // ポリゴンフィーチャを作成（外環のみ、穴なし）
      // リングを閉じる（最初と最後の座標を同じにする）
      final closedPoints = closeRing(points);
      if (closedPoints.isEmpty) {
        return null;
      }
      final rings = [closedPoints]; // 閉じた外環のみのリスト
      createdFeature = await PolygonFeatureNode.createIn(
        targetLayer,
        rings,
        featureName,
        null,
      );
    }

    // sub_table属性を設定
    if (createdFeature != null && subTableJson != null) {
      try {
        AppLogger.debug('[GeometryConversion] sub_table設定開始: rowId=${createdFeature.rowId}, layer=${createdFeature.layerName}');
        AppLogger.debug('[GeometryConversion] 親レイヤーのfeature数: ${targetLayer.features.length}');
        
        // 少し待機（フィーチャが完全に登録されるまで）
        await Future.delayed(const Duration(milliseconds: 50));
        
        await createdFeature.setAttributeValue('sub_table', subTableJson);
        AppLogger.debug('[GeometryConversion] sub_table属性を設定完了（メモリ）');
        
        // 即座にDBに保存（バックグラウンド保存を待たない）
        await createdFeature.flushChanges();
        AppLogger.debug('[GeometryConversion] sub_table属性をDBに即座保存完了');
      } catch (e, stack) {
        AppLogger.debug('[GeometryConversion] sub_table属性設定エラー: $e');
        AppLogger.debug('[GeometryConversion] スタックトレース: $stack');
      }
    }
    
    return createdFeature;
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
    String? subTableJson;
    try {
      final features = sourceLayer.features.whereType<PointFeatureNode>().toList();
      if (features.isNotEmpty) {
        subTableJson = _buildSubTableGeoJson(features);
      }
    } catch (e) {
      AppLogger.debug('[SurveyConversion] sub_table生成エラー: $e');
    }

    // sub_tableカラムを追加
    if (subTableJson != null) {
      try {
        await targetLayer.geoPackageFile.addAttributeColumn(
          targetLayer.layerName, 'sub_table', 'TEXT',
        );
      } catch (_) {}
    }

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

    final featureName = name ?? 'Survey from ${sourceLayer.name}';

    FeatureNode? createdFeature;
    if (targetLayer is LineLayerNode) {
      createdFeature = await LineFeatureNode.createIn(
        targetLayer, points, featureName, null,
      );
    } else if (targetLayer is PolygonLayerNode) {
      final closedPoints = closeRing(points);
      if (closedPoints.isEmpty) return null;
      createdFeature = await PolygonFeatureNode.createIn(
        targetLayer, [closedPoints], featureName, null,
      );
    }

    if (createdFeature == null) return null;

    // 属性を設定
    await Future.delayed(const Duration(milliseconds: 50));

    final attrs = <String, dynamic>{
      'survey_total_distance': result.totalDistance.toStringAsFixed(2),
      'survey_declination': options.declination.toString(),
    };
    if (closePath) {
      attrs['survey_closure_ratio'] = result.closureRatioN.isInfinite
          ? 'perfect'
          : '1/${result.closureRatioN.toStringAsFixed(0)}';
      attrs['survey_closure_error'] = result.closureError.toStringAsFixed(4);
      attrs['survey_adjustment_method'] = effectiveOptions.method.name;
    }
    if (subTableJson != null) {
      attrs['sub_table'] = subTableJson;
    }

    try {
      await createdFeature.setAttributeValues(attrs);
      await createdFeature.flushChanges();
    } catch (e, stack) {
      AppLogger.debug('[SurveyConversion] 属性設定エラー: $e\n$stack');
    }

    return createdFeature;
  }

  /// ライン/ポリゴンフィーチャをポイントに変換
  static Future<List<PointFeatureNode>> convertGeometryToPoints({
    required FeatureNode sourceFeature,
    required PointLayerNode targetLayer,
  }) async {
    // 座標リストを取得
    List<LatLng> points = [];
    
    if (sourceFeature is LineFeatureNode) {
      // ラインの場合：全頂点を取得
      points = sourceFeature.line;
    } else if (sourceFeature is PolygonFeatureNode) {
      // ポリゴンの場合：外環（最初のリング）を取得
      final geometry = sourceFeature.geometry as List<List<LatLng>>?;
      if (geometry != null && geometry.isNotEmpty) {
        final outerRing = geometry.first;
        
        // 閉じたポリゴンの場合、最後の座標が最初と同じなら削除
        if (outerRing.length >= 2) {
          final first = outerRing.first;
          final last = outerRing.last;
          if (first.latitude == last.latitude && first.longitude == last.longitude) {
            // 最後の座標を除外
            points = outerRing.sublist(0, outerRing.length - 1);
          } else {
            points = outerRing;
          }
        } else {
          points = outerRing;
        }
      }
    }

    if (points.isEmpty) {
      return [];
    }

    // sub_table属性から復元データを取得（GeoJSON / 旧2D配列 両対応）
    List<({LatLng point, Map<String, dynamic> properties})>? subTableRows;
    try {
      final subTableValue = await sourceFeature.getAttributeValue('sub_table');
      if (subTableValue != null && subTableValue is String && subTableValue.isNotEmpty) {
        subTableRows = _parseSubTable(subTableValue);
        if (subTableRows != null) {
          AppLogger.debug('[GeometryConversion] sub_table復元: ${subTableRows.length}行');
        }
      }
    } catch (e) {
      AppLogger.debug('[GeometryConversion] sub_table復元エラー: $e');
    }

    // 復元データからカラム名を収集して、変換先レイヤーに追加
    if (subTableRows != null && subTableRows.isNotEmpty) {
      final allKeys = <String>{};
      for (final row in subTableRows) {
        allKeys.addAll(row.properties.keys);
      }
      for (final key in allKeys) {
        try {
          await targetLayer.geoPackageFile.addAttributeColumn(
            targetLayer.layerName, key, 'TEXT',
          );
        } catch (_) {}
      }
    }

    final sourceFeatureName = sourceFeature.name;
    final defaultDescription = sourceFeatureName.isNotEmpty
        ? 'imported from $sourceFeatureName'
        : null;

    final createdFeatures = <PointFeatureNode>[];
    final totalPoints = points.length;

    for (int i = 0; i < totalPoints; i++) {
      final pointFeature = await PointFeatureNode.createIn(
        targetLayer, points[i], '', null,
      );
      if (pointFeature == null) continue;
      createdFeatures.add(pointFeature);

      // 属性を復元
      if (subTableRows != null && i < subTableRows.length) {
        try {
          final attrs = Map<String, dynamic>.from(subTableRows[i].properties);
          if ((!attrs.containsKey('description') ||
                  attrs['description'] == null ||
                  attrs['description'].toString().isEmpty) &&
              defaultDescription != null) {
            attrs['description'] = defaultDescription;
          }
          if (attrs.isNotEmpty) {
            await pointFeature.setAttributeValues(attrs);
            await pointFeature.flushChanges();
          }
        } catch (e) {
          AppLogger.debug('[GeometryConversion] ポイント${i + 1}の属性復元エラー: $e');
        }
      } else if (defaultDescription != null) {
        try {
          await pointFeature.setAttributeValues({'description': defaultDescription});
          await pointFeature.flushChanges();
        } catch (_) {}
      }
    }

    AppLogger.debug('[GeometryConversion] ポイント変換完了: ${createdFeatures.length}個作成');

    return createdFeatures;
  }
}

