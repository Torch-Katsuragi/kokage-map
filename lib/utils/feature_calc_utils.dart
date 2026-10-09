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
// Root Maps: フィーチャ計算ユーティリティ
// 点・線・面の重心、距離、長さ、面積、最近傍feature取得など
//
// 本ファイルの関数は全て静的関数として利用可能
// 主要な地理空間計算はturf_dartライブラリを使用して高精度化
//
// 依存: latlong2, turf

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:turf/turf.dart';

import '../converters/turf_converter.dart';
import '../models/nodes/feature_node.dart';
import 'geo_converter.dart';

/// degree・metre変換系
class _DegreeMeterConverter {
  /// 緯度1度あたりの距離（メートル）
  static double metersPerDegreeLat() {
    // 地球半径R=6378137m, 1度=π/180ラジアン
    const double degToRad = math.pi / 180.0;
    const double R = 6378137.0;
    return degToRad * R;
  }

  /// 経度1度あたりの距離（メートル）
  /// [lat]: 緯度（degree）
  static double metersPerDegreeLng(double lat) {
    const double degToRad = math.pi / 180.0;
    const double R = 6378137.0;
    final double latRad = lat * degToRad;
    return degToRad * R * math.cos(latRad);
  }
}

/// 距離・長さ・面積・重心計算
class GeometryCalc {
  /// 2点間の距離（メートル）を計算
  /// [a], [b]: LatLng
  /// 戻り値: 距離（m）
  static double calcDistance(LatLng a, LatLng b) {
    // turf_dartを使用した高精度な距離計算
    final pointA = Point(coordinates: a.toTurfPosition());
    final pointB = Point(coordinates: b.toTurfPosition());
    return distance(pointA, pointB, Unit.meters).toDouble();
  }

  /// 線分（`List<LatLng>`）の長さ（メートル）を計算
  /// [line]: 線分の座標リスト
  /// 戻り値: 総距離（m）
  static double calcLineLength(List<LatLng> line) {
    if (line.length < 2) return 0.0;

    final feature = Feature(geometry: TurfConverter.createLineString(line));
    return length(feature, Unit.meters).toDouble();
  }

  /// ポリゴン（外環＋穴リスト）の面積（m^2）
  /// [polygon]: 外環＋穴リスト（`List<List<LatLng>>`）
  /// 戻り値: 面積（m^2）
  static double calcPolygonArea(List<List<LatLng>> polygon) {
    if (polygon.isEmpty || polygon[0].length < 3) return 0.0;

    final feature = Feature(geometry: TurfConverter.createPolygon(polygon));
    return area(feature)?.toDouble() ?? 0.0; // デフォルトで平方メートル
  }

  /// 線分（`List<LatLng>`）の重心（中点）を計算
  /// [line]: 線分の座標リスト
  /// 戻り値: 重心座標（LatLng）
  static LatLng calcLineCentroid(List<LatLng> line) {
    if (line.isEmpty) return const LatLng(0, 0);
    if (line.length == 1) return line.first;

    final center = centroid(Feature(geometry: TurfConverter.createLineString(line)));
    return center.geometry!.coordinates.toLatLng();
  }

  /// ポリゴン（外環＋穴リスト）の重心を計算
  /// [polygon]: 外環＋穴リスト（`List<List<LatLng>>`）
  /// 戻り値: 重心座標（LatLng）
  static LatLng calcPolygonCentroid(List<List<LatLng>> polygon) {
    if (polygon.isEmpty || polygon[0].isEmpty) return const LatLng(0, 0);

    final center = centroid(Feature(geometry: TurfConverter.createPolygon(polygon)));
    return center.geometry!.coordinates.toLatLng();
  }

  /// 点集合（`List<LatLng>`）の重心を計算
  static LatLng calcPointsCentroid(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    if (points.length == 1) return points.first;

    final multiPoint = MultiPoint(coordinates: [for (final p in points) p.toTurfPosition()]);
    final center = centroid(Feature(geometry: multiPoint));
    return center.geometry!.coordinates.toLatLng();
  }

  /// 点と線分（`List<LatLng>`）の最短距離（メートル）を計算
  /// [pt]: 判定点
  /// [line]: 線分
  /// 戻り値: 最短距離（m）
  static double calcPointToLineDistance(LatLng pt, List<LatLng> line) {
    double minDist = double.infinity;
    for (int i = 1; i < line.length; i++) {
      final d = distancePointToSegment(pt, line[i - 1], line[i]);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  /// 点とポリゴン（外環＋穴リスト）の最短距離（メートル）を計算
  /// [pt]: 判定点
  /// [polygon]: 外環＋穴リスト
  /// 戻り値: 最短距離（m）（ポリゴン内なら0）
  static double calcPointToPolygonDistance(
    LatLng pt,
    List<List<LatLng>> polygon,
  ) {
    if (polygon.isEmpty) return double.infinity;
    // 外環・穴すべてのリングとの最短距離
    double minDist = double.infinity;
    for (final ring in polygon) {
      for (int i = 1; i < ring.length; i++) {
        final d = distancePointToSegment(pt, ring[i - 1], ring[i]);
        if (d < minDist) minDist = d;
      }
    }
    // 外環内かつどの穴にも含まれなければ距離0
    if (pointInPolygonWithHoles(pt, polygon)) return 0.0;
    return minDist;
  }

  /// 点が外環＋穴リストのポリゴン内にあるか判定
  static bool pointInPolygonWithHoles(LatLng pt, List<List<LatLng>> polygon) {
    if (polygon.isEmpty) return false;

    try {
      // turf_dartのbooleanPointInPolygon関数を使用
      final pointPos = pt.toTurfPosition();
      
      // 各リングを閉じる（最初と最後の座標が同じでない場合は最初の座標を追加）
      final closedPolygon = polygon.map((ring) {
        if (ring.length < 3) return ring; // 3点未満はそのまま
        
        final first = ring.first;
        final last = ring.last;
        final isClosed = (first.latitude == last.latitude) && 
                        (first.longitude == last.longitude);
        
        if (!isClosed) {
          // 閉じていない場合は最初の座標を最後に追加
          return List<LatLng>.from(ring)..add(first);
        }
        return ring;
      }).toList();
      
      final feature = Feature(geometry: TurfConverter.createPolygon(closedPolygon));

      return booleanPointInPolygon(pointPos, feature);
    } catch (e) {
      // ポリゴンが壊れている場合でもエラーを出さずfalseを返す
      AppLogger.debug('[WARNING] pointInPolygonWithHoles: エラー発生（壊れたポリゴン？）: $e');
      return false;
    }
  }

  /// 点と線分の最短距離（メートル）
  static double distancePointToSegment(LatLng p, LatLng a, LatLng b) {
    // 線分が点の場合
    if (a.latitude == b.latitude && a.longitude == b.longitude) {
      return calcDistance(p, a);
    }

    // 緯度経度をメートル単位の平面座標に変換して計算
    final centerLat = (a.latitude + b.latitude) / 2;
    final mPerDegLat = _DegreeMeterConverter.metersPerDegreeLat();
    final mPerDegLng = _DegreeMeterConverter.metersPerDegreeLng(centerLat);

    // メートル単位の座標に変換
    final x0 = p.longitude * mPerDegLng;
    final y0 = p.latitude * mPerDegLat;
    final x1 = a.longitude * mPerDegLng;
    final y1 = a.latitude * mPerDegLat;
    final x2 = b.longitude * mPerDegLng;
    final y2 = b.latitude * mPerDegLat;

    final dx = x2 - x1;
    final dy = y2 - y1;

    // 線分の長さの二乗
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) return calcDistance(p, a);

    // 線分上の最近点を求める
    final t = ((x0 - x1) * dx + (y0 - y1) * dy) / lengthSquared;

    if (t < 0) {
      // 最近点が線分の開始点側
      return calcDistance(p, a);
    } else if (t > 1) {
      // 最近点が線分の終了点側
      return calcDistance(p, b);
    } else {
      // 最近点が線分上にある
      final projX = x1 + t * dx;
      final projY = y1 + t * dy;

      // メートル単位での距離を直接計算
      final distX = x0 - projX;
      final distY = y0 - projY;
      return math.sqrt(distX * distX + distY * distY);
    }
  }
}

/// feature距離・最近傍feature検索
class FeatureSearch {
  /// 点とfeature（点・線・面）の最短距離（メートル）を計算
  /// featureType: 'point'|'line'|'polygon'
  static double calcPointToFeatureDistance(
    LatLng pt,
    Object geometry,
    String featureType,
  ) {
    if (featureType == 'point') {
      if (geometry is List<LatLng> && geometry.isNotEmpty) {
        return GeometryCalc.calcDistance(pt, geometry.first);
      }
    } else if (featureType == 'line') {
      if (geometry is List<LatLng>) {
        double minDist = double.infinity;
        for (int i = 0; i < geometry.length - 1; i++) {
          final line = [geometry[i], geometry[i + 1]];
          final d = GeometryCalc.calcPointToLineDistance(pt, line);
          // AppLogger.debug(d);
          if (d < minDist) minDist = d;
        }
        return minDist;
      }
    } else if (featureType == 'polygon') {
      if (geometry is List<List<LatLng>>) {
        return GeometryCalc.calcPointToPolygonDistance(pt, geometry);
      }
    }
    return double.infinity;
  }
}

/// ポリゴン合成処理
class PolygonMerge {
  /// 複数のポリゴンFeatureNodeを合成
  /// 最も面積の大きいポリゴンを外形とし、それ以外を穴として扱う
  /// [features]: 合成対象のPolygonFeatureNodeリスト
  /// 戻り値: 合成ポリゴン（外環＋穴リスト）
  static List<List<LatLng>> mergePolygonFeatures(List<FeatureNode> features) {
    if (features.isEmpty) return [];

    // PolygonFeatureNodeのみを抽出し、面積と共にリスト化
    final polygonFeatures = <({double area, List<List<LatLng>> polygon})>[];

    for (final feature in features) {
      if (feature is PolygonFeatureNode) {
        final polygon = feature.polygon;
        if (polygon.isNotEmpty && polygon[0].length >= 3) {
          final area = GeometryCalc.calcPolygonArea(polygon);
          polygonFeatures.add((area: area, polygon: polygon));
        }
      }
    }

    if (polygonFeatures.isEmpty) return [];

    // 面積の降順でソート（最も面積の大きいものが最初）
    polygonFeatures.sort((a, b) => b.area.compareTo(a.area));

    // 最も面積の大きいポリゴンの外環を使用
    final largestPolygon = polygonFeatures.first.polygon;
    final outerRing = largestPolygon[0];

    // 合成結果のポリゴン（外環＋穴リスト）
    final mergedPolygon = <List<LatLng>>[outerRing];

    // 最も面積の大きいポリゴンの既存の穴も追加
    if (largestPolygon.length > 1) {
      mergedPolygon.addAll(largestPolygon.skip(1));
    }

    // それ以外のポリゴンを穴として追加
    for (int i = 1; i < polygonFeatures.length; i++) {
      final polygon = polygonFeatures[i].polygon;
      // 外環のみを穴として追加（既存の穴は無視）
      mergedPolygon.add(polygon[0]);
    }

    AppLogger.debug('[PolygonMerge] 合成完了: 外環1個 + 穴${mergedPolygon.length - 1}個');
    return mergedPolygon;
  }

  /// ポリゴンが有効かどうかをチェック
  /// [polygon]: チェック対象のポリゴン
  /// 戻り値: 有効ならtrue
  static bool isValidPolygon(List<List<LatLng>> polygon) {
    if (polygon.isEmpty) return false;

    // 外環は最低3点必要
    if (polygon[0].length < 3) return false;

    // すべてのリング（穴）も最低3点必要
    for (int i = 1; i < polygon.length; i++) {
      if (polygon[i].length < 3) return false;
    }

    return true;
  }

  /// 合成可能なポリゴンFeatureNodeの数をカウント
  /// [features]: チェック対象のFeatureNodeリスト
  /// 戻り値: 合成可能なポリゴンの数
  static int countMergeablePolygons(List<FeatureNode> features) {
    int count = 0;
    for (final feature in features) {
      if (feature is PolygonFeatureNode) {
        if (isValidPolygon(feature.polygon)) {
          count++;
        }
      }
    }
    return count;
  }
}

/// ライン簡略化処理
class LineSimplification {
  /// Douglas-Peucker アルゴリズムによるライン簡略化
  /// [line]: 簡略化対象のライン座標リスト
  /// [tolerance]: 許容誤差（メートル）
  /// 戻り値: 簡略化されたライン座標リスト
  static List<LatLng> simplifyLineDouglasPeucker(
    List<LatLng> line,
    double tolerance,
  ) {
    if (line.length <= 2) {
      return List.from(line);
    }

    // 現在は元の実装を使用（turf_dartのsimplifyは後で実装）
    final result = _douglasPeuckerRecursive(line, tolerance);

    AppLogger.debug(
      '[LineSimplification] 簡略化完了: ${line.length}点 → ${result.length}点 (許容誤差: ${tolerance}m)',
    );

    return result;
  }

  /// 各点が [simplifyLineDouglasPeucker] で消える許容幅（m）。両端は消えないので無限大。
  ///
  /// 許容幅 ε で残るのは、この値が ε より大きい点だけ（DP が分ける距離を、分けた先へは親の値で頭打ちにして配る）。
  /// 簡略化のつまみを「消える点の数」の段にするのに使う
  static List<double> douglasPeuckerThresholds(List<LatLng> line) {
    final out = List<double>.filled(line.length, double.infinity);
    void walk(int start, int end, double cap) {
      if (end - start < 2) return;
      var maxDistance = 0.0;
      var maxIndex = start + 1;
      for (var i = start + 1; i < end; i++) {
        final d = GeometryCalc.distancePointToSegment(line[i], line[start], line[end]);
        if (d > maxDistance) {
          maxDistance = d;
          maxIndex = i;
        }
      }
      final t = maxDistance < cap ? maxDistance : cap;
      out[maxIndex] = t;
      walk(start, maxIndex, t);
      walk(maxIndex, end, t);
    }

    walk(0, line.length - 1, double.infinity);
    return out;
  }

  /// Douglas-Peucker アルゴリズムの再帰実装（標準的な実装）
  static List<LatLng> _douglasPeuckerRecursive(
    List<LatLng> points,
    double tolerance,
  ) {
    if (points.length < 3) {
      return List.from(points);
    }

    // 開始点と終了点を結ぶ線分を作成
    final startPoint = points.first;
    final endPoint = points.last;

    // 中間点の中で線分から最も離れた点を探す
    double maxDistance = 0.0;
    int maxDistanceIndex = 0;

    for (int i = 1; i < points.length - 1; i++) {
      final distance = GeometryCalc.distancePointToSegment(points[i], startPoint, endPoint);

      if (distance > maxDistance) {
        maxDistance = distance;
        maxDistanceIndex = i;
      }
    }

    // 最大距離が許容誤差より大きい場合は分割して再帰処理
    if (maxDistance > tolerance) {
      // 前半部分を再帰的に処理（最大距離の点を含む）
      final leftPart = _douglasPeuckerRecursive(
        points.sublist(0, maxDistanceIndex + 1),
        tolerance,
      );

      // 後半部分を再帰的に処理（最大距離の点から終了まで）
      final rightPart = _douglasPeuckerRecursive(
        points.sublist(maxDistanceIndex),
        tolerance,
      );

      // 結果を結合（重複する分岐点を除く）
      final result = <LatLng>[];
      result.addAll(leftPart);
      // 重複する中間点（maxDistanceIndex）を除いて結合
      result.addAll(rightPart.skip(1));

      return result;
    } else {
      // 許容誤差以下なら開始点と終了点のみ
      return [startPoint, endPoint];
    }
  }

  /// ライン簡略化の統計情報を取得
  /// [originalLine]: 元のライン
  /// [simplifiedLine]: 簡略化後のライン
  /// 戻り値: 簡略化統計のMap
  static Map<String, dynamic> getSimplificationStats(
    List<LatLng> originalLine,
    List<LatLng> simplifiedLine,
  ) {
    final originalLength = GeometryCalc.calcLineLength(originalLine);
    final simplifiedLength = GeometryCalc.calcLineLength(simplifiedLine);
    final pointReduction = originalLine.length - simplifiedLine.length;
    final pointReductionPercent = (pointReduction / originalLine.length * 100)
        .toStringAsFixed(1);
    final lengthError = (originalLength - simplifiedLength).abs();
    final lengthErrorPercent = (lengthError / originalLength * 100)
        .toStringAsFixed(1);

    return {
      'originalPoints': originalLine.length,
      'simplifiedPoints': simplifiedLine.length,
      'pointReduction': pointReduction,
      'pointReductionPercent': '$pointReductionPercent%',
      'originalLength': originalLength,
      'simplifiedLength': simplifiedLength,
      'lengthError': lengthError,
      'lengthErrorPercent': '$lengthErrorPercent%',
    };
  }
}
