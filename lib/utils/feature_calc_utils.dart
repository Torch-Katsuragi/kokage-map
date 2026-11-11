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
// 依存: geobase, latlong2

import 'dart:math' as math;

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../models/nodes/feature_node.dart';
import 'geodesic.dart';

/// degree・metre変換系（球。[GeometryCalc.distancePointToSegment] の当たり判定・間引き用。
/// 見せる長さ・距離は [Geodesic]）
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

enum _PipResult { inside, outside, onEdge }

/// 距離・長さ・面積・重心計算
class GeometryCalc {
  /// 平均地球半径 [m]（Haversine 距離用）
  static const double _earthRadius = 6371008.8;
  static const double _degToRad = math.pi / 180.0;

  static double _calcDistanceCoords(
    double lat1Deg,
    double lon1Deg,
    double lat2Deg,
    double lon2Deg,
  ) {
    if (lat1Deg == lat2Deg && lon1Deg == lon2Deg) return 0.0;
    final dLat = (lat2Deg - lat1Deg) * _degToRad;
    final dLon = (lon2Deg - lon1Deg) * _degToRad;
    final lat1 = lat1Deg * _degToRad;
    final lat2 = lat2Deg * _degToRad;
    final sdLat = math.sin(dLat / 2);
    final sdLon = math.sin(dLon / 2);
    final h = sdLat * sdLat + sdLon * sdLon * math.cos(lat1) * math.cos(lat2);
    return 2 * _earthRadius * math.atan2(math.sqrt(h), math.sqrt(math.max(0.0, 1.0 - h)));
  }

  /// 2点間の距離（メートル）を計算（球面 Haversine、R = 6371008.8 m）
  ///
  /// タップの当たり判定・線の間引きのしきい値に使う（楕円体との差は 0.5% 未満）。
  /// 利用者に見せる距離は [Geodesic.distance]（WGS84 楕円体、QGIS と同じ値）を使うこと
  static double calcDistance(LatLng a, LatLng b) =>
      _calcDistanceCoords(a.latitude, a.longitude, b.latitude, b.longitude);

  /// 線分（`List<LatLng>`）の長さ（メートル）を計算
  /// [line]: 線分の座標リスト
  /// 戻り値: 総距離（m）
  static double calcLineLength(List<LatLng> line) => Geodesic.lineLength(line);

  /// ポリゴン（外環＋穴リスト）の面積（m^2。WGS84 楕円体の上で測る → [Geodesic]）
  /// [polygon]: 外環＋穴リスト（`List<List<LatLng>>`）
  static double calcPolygonArea(List<List<LatLng>> polygon) {
    if (polygon.isEmpty || polygon[0].length < 3) return 0.0;
    return Geodesic.polygonArea(polygon);
  }

  /// `geobase` ジオメトリの重心を計算（空ジオメトリは null）
  ///
  /// ポリゴンのリングは閉じ点（先頭と同じ末尾）を除外して頂点平均を取る。
  static LatLng? calcGeoCentroid(geo.Geometry? geom) {
    if (geom == null) return null;
    if (geom is geo.Point) {
      return LatLng(geom.position.y, geom.position.x);
    }

    var sumLon = 0.0;
    var sumLat = 0.0;
    var count = 0;

    void addSeries(geo.PositionSeries s, {required bool excludeClosing}) {
      var n = s.positionCount;
      if (excludeClosing && n >= 2 && s.x(0) == s.x(n - 1) && s.y(0) == s.y(n - 1)) {
        n--;
      }
      for (var i = 0; i < n; i++) {
        sumLon += s.x(i);
        sumLat += s.y(i);
      }
      count += n;
    }

    if (geom is geo.MultiPoint) {
      for (final p in geom.positions) {
        sumLon += p.x;
        sumLat += p.y;
        count++;
      }
    } else if (geom is geo.LineString) {
      addSeries(geom.chain, excludeClosing: false);
    } else if (geom is geo.MultiLineString) {
      for (final c in geom.chains) {
        addSeries(c, excludeClosing: false);
      }
    } else if (geom is geo.Polygon) {
      for (final r in geom.rings) {
        addSeries(r, excludeClosing: true);
      }
    } else if (geom is geo.MultiPolygon) {
      for (final rings in geom.ringArrays) {
        for (final r in rings) {
          addSeries(r, excludeClosing: true);
        }
      }
    }

    if (count == 0) return null;
    return LatLng(sumLat / count, sumLon / count);
  }

  /// 線分（`List<LatLng>`）の重心（頂点平均）を計算
  /// [line]: 線分の座標リスト
  /// 戻り値: 重心座標（LatLng）
  static LatLng calcLineCentroid(List<LatLng> line) => calcPointsCentroid(line);

  /// ポリゴン（外環＋穴リスト）の重心を計算
  /// [polygon]: 外環＋穴リスト（`List<List<LatLng>>`）
  /// 戻り値: 重心座標（LatLng）
  static LatLng calcPolygonCentroid(List<List<LatLng>> polygon) {
    if (polygon.isEmpty || polygon[0].isEmpty) return const LatLng(0, 0);

    var sumLat = 0.0;
    var sumLon = 0.0;
    var count = 0;

    // 閉じているリングは末尾の閉じ点を飛ばし、閉じていないリングは全実頂点を数える
    for (final ring in polygon) {
      var n = ring.length;
      if (n >= 2 &&
          ring.first.latitude == ring.last.latitude &&
          ring.first.longitude == ring.last.longitude) {
        n--;
      }
      for (var i = 0; i < n; i++) {
        sumLat += ring[i].latitude;
        sumLon += ring[i].longitude;
      }
      count += n;
    }

    if (count == 0) return const LatLng(0, 0);
    return LatLng(sumLat / count, sumLon / count);
  }

  /// 点集合（`List<LatLng>`）の重心を計算
  static LatLng calcPointsCentroid(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    if (points.length == 1) return points.first;

    var sumLat = 0.0;
    var sumLon = 0.0;
    for (final p in points) {
      sumLat += p.latitude;
      sumLon += p.longitude;
    }
    return LatLng(sumLat / points.length, sumLon / points.length);
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

  static double _calcPointToSeriesDistance(LatLng pt, geo.PositionSeries series) {
    final n = series.positionCount;
    var minDist = double.infinity;
    for (var i = 1; i < n; i++) {
      final d = _distancePointToSegmentCoords(
        pt.latitude,
        pt.longitude,
        series.y(i - 1),
        series.x(i - 1),
        series.y(i),
        series.x(i),
      );
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
    // 外環内かつどの穴にも含まれなければ距離0
    if (pointInPolygonWithHoles(pt, polygon)) return 0.0;
    // 外環・穴すべてのリングとの最短距離（閉じていないリングの閉じ辺も含める）
    double minDist = double.infinity;
    for (final ring in polygon) {
      if (ring.length < 2) continue;
      for (int i = 1; i < ring.length; i++) {
        final d = distancePointToSegment(pt, ring[i - 1], ring[i]);
        if (d < minDist) minDist = d;
      }
      if (ring.length >= 3 &&
          (ring.first.latitude != ring.last.latitude ||
              ring.first.longitude != ring.last.longitude)) {
        final d = distancePointToSegment(pt, ring.last, ring.first);
        if (d < minDist) minDist = d;
      }
    }
    return minDist;
  }

  static double _calcPointToGeoRingsDistance(LatLng pt, List<geo.PositionSeries> rings) {
    if (rings.isEmpty) return double.infinity;
    if (pointInGeoRings(pt, rings)) return 0.0;
    var minDist = double.infinity;
    for (final ring in rings) {
      final n = ring.positionCount;
      if (n < 2) continue;
      final d = _calcPointToSeriesDistance(pt, ring);
      if (d < minDist) minDist = d;
      if (n >= 3 && (ring.x(0) != ring.x(n - 1) || ring.y(0) != ring.y(n - 1))) {
        final closeDist = _distancePointToSegmentCoords(
          pt.latitude,
          pt.longitude,
          ring.y(n - 1),
          ring.x(n - 1),
          ring.y(0),
          ring.x(0),
        );
        if (closeDist < minDist) minDist = closeDist;
      }
    }
    return minDist;
  }

  /// Hao & Sun の半直線交差法による単一リング内外判定（境界・頂点上は [_PipResult.onEdge]）
  static _PipResult _pipLatLngRing(double px, double py, List<LatLng> ring) {
    final rawLen = ring.length;
    if (rawLen < 3) return _PipResult.outside;
    final isClosed =
        ring.first.latitude == ring.last.latitude && ring.first.longitude == ring.last.longitude;
    final n = isClosed ? rawLen - 1 : rawLen;
    if (n < 3) return _PipResult.outside;

    var inside = false;
    for (var i = 0; i < n; i++) {
      final p1 = ring[i];
      final p2 = ring[(i + 1) % n];
      final u1 = p1.longitude - px;
      final v1 = p1.latitude - py;
      final u2 = p2.longitude - px;
      final v2 = p2.latitude - py;

      if ((u1 == 0 && v1 == 0) || (u2 == 0 && v2 == 0)) {
        return _PipResult.onEdge;
      }
      if ((v1 < 0 && v2 < 0) || (v1 > 0 && v2 > 0)) {
        continue;
      }
      final f = u1 * v2 - u2 * v1;
      if (v2 > 0 && v1 <= 0) {
        if (f == 0) return _PipResult.onEdge;
        if (f > 0) inside = !inside;
      } else if (v1 > 0 && v2 <= 0) {
        if (f == 0) return _PipResult.onEdge;
        if (f < 0) inside = !inside;
      } else if (v2 == 0 && v1 == 0) {
        if ((u2 <= 0 && u1 >= 0) || (u1 <= 0 && u2 >= 0)) {
          return _PipResult.onEdge;
        }
      }
    }
    return inside ? _PipResult.inside : _PipResult.outside;
  }

  static _PipResult _pipGeoRing(double px, double py, geo.PositionSeries ring) {
    final rawLen = ring.positionCount;
    if (rawLen < 3) return _PipResult.outside;
    final isClosed = ring.x(0) == ring.x(rawLen - 1) && ring.y(0) == ring.y(rawLen - 1);
    final n = isClosed ? rawLen - 1 : rawLen;
    if (n < 3) return _PipResult.outside;

    var inside = false;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final u1 = ring.x(i) - px;
      final v1 = ring.y(i) - py;
      final u2 = ring.x(j) - px;
      final v2 = ring.y(j) - py;

      if ((u1 == 0 && v1 == 0) || (u2 == 0 && v2 == 0)) {
        return _PipResult.onEdge;
      }
      if ((v1 < 0 && v2 < 0) || (v1 > 0 && v2 > 0)) {
        continue;
      }
      final f = u1 * v2 - u2 * v1;
      if (v2 > 0 && v1 <= 0) {
        if (f == 0) return _PipResult.onEdge;
        if (f > 0) inside = !inside;
      } else if (v1 > 0 && v2 <= 0) {
        if (f == 0) return _PipResult.onEdge;
        if (f < 0) inside = !inside;
      } else if (v2 == 0 && v1 == 0) {
        if ((u2 <= 0 && u1 >= 0) || (u1 <= 0 && u2 >= 0)) {
          return _PipResult.onEdge;
        }
      }
    }
    return inside ? _PipResult.inside : _PipResult.outside;
  }

  /// 点が外環＋穴リストのポリゴン内（境界上を含む）にあるか判定
  static bool pointInPolygonWithHoles(LatLng pt, List<List<LatLng>> polygon) {
    if (polygon.isEmpty) return false;
    try {
      final px = pt.longitude;
      final py = pt.latitude;
      final outer = _pipLatLngRing(px, py, polygon.first);
      if (outer == _PipResult.outside) return false;
      if (outer == _PipResult.onEdge) return true;

      for (var i = 1; i < polygon.length; i++) {
        final hole = _pipLatLngRing(px, py, polygon[i]);
        if (hole == _PipResult.onEdge) return true;
        if (hole == _PipResult.inside) return false;
      }
      return true;
    } catch (e) {
      // ポリゴンが壊れている場合でもエラーを出さずfalseを返す
      AppLogger.debug('[WARNING] pointInPolygonWithHoles: エラー発生（壊れたポリゴン？）: $e');
      return false;
    }
  }

  /// 点が `geobase` の外環＋穴リング群（単一ポリゴン）内にあるか判定
  static bool pointInGeoRings(LatLng pt, List<geo.PositionSeries> rings) {
    if (rings.isEmpty) return false;
    final px = pt.longitude;
    final py = pt.latitude;
    final outer = _pipGeoRing(px, py, rings.first);
    if (outer == _PipResult.outside) return false;
    if (outer == _PipResult.onEdge) return true;

    for (var i = 1; i < rings.length; i++) {
      final hole = _pipGeoRing(px, py, rings[i]);
      if (hole == _PipResult.onEdge) return true;
      if (hole == _PipResult.inside) return false;
    }
    return true;
  }

  /// 点が `geobase` の Polygon / MultiPolygon 内にあるか判定
  static bool pointInGeoPolygon(LatLng pt, geo.Geometry? geom) {
    if (geom is geo.Polygon) {
      return pointInGeoRings(pt, geom.rings);
    }
    if (geom is geo.MultiPolygon) {
      return geom.ringArrays.any((rings) => pointInGeoRings(pt, rings));
    }
    return false;
  }

  static double _distancePointToSegmentCoords(
    double pLat,
    double pLon,
    double aLat,
    double aLon,
    double bLat,
    double bLon,
  ) {
    // 線分が点の場合
    if (aLat == bLat && aLon == bLon) {
      return _calcDistanceCoords(pLat, pLon, aLat, aLon);
    }

    // 緯度経度をメートル単位の平面座標に変換して計算
    final centerLat = (aLat + bLat) / 2;
    final mPerDegLat = _DegreeMeterConverter.metersPerDegreeLat();
    final mPerDegLng = _DegreeMeterConverter.metersPerDegreeLng(centerLat);

    // メートル単位の座標に変換
    final x0 = pLon * mPerDegLng;
    final y0 = pLat * mPerDegLat;
    final x1 = aLon * mPerDegLng;
    final y1 = aLat * mPerDegLat;
    final x2 = bLon * mPerDegLng;
    final y2 = bLat * mPerDegLat;

    final dx = x2 - x1;
    final dy = y2 - y1;

    // 線分の長さの二乗
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) return _calcDistanceCoords(pLat, pLon, aLat, aLon);

    // 線分上の最近点を求める
    final t = ((x0 - x1) * dx + (y0 - y1) * dy) / lengthSquared;

    if (t < 0) {
      // 最近点が線分の開始点側
      return _calcDistanceCoords(pLat, pLon, aLat, aLon);
    } else if (t > 1) {
      // 最近点が線分の終了点側
      return _calcDistanceCoords(pLat, pLon, bLat, bLon);
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

  /// 点と線分の最短距離（メートル）
  static double distancePointToSegment(LatLng p, LatLng a, LatLng b) =>
      _distancePointToSegmentCoords(
        p.latitude,
        p.longitude,
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );
}

/// feature距離・最近傍feature検索
class FeatureSearch {
  /// 点とfeature（点・線・面）の最短距離（メートル）を計算
  /// featureType: 'point'|'line'|'polygon'
  /// [geometry] には `geo.Geometry`（推奨・中間リスト確保なし）または `LatLng` リストを渡せる
  static double calcPointToFeatureDistance(
    LatLng pt,
    Object? geometry,
    String featureType,
  ) {
    if (geometry == null) return double.infinity;

    if (geometry is geo.Geometry) {
      if (featureType == 'point') {
        if (geometry is geo.Point) {
          return GeometryCalc._calcDistanceCoords(
            pt.latitude,
            pt.longitude,
            geometry.position.y,
            geometry.position.x,
          );
        }
        if (geometry is geo.MultiPoint) {
          var minDist = double.infinity;
          for (final p in geometry.positions) {
            final d = GeometryCalc._calcDistanceCoords(pt.latitude, pt.longitude, p.y, p.x);
            if (d < minDist) minDist = d;
          }
          return minDist;
        }
      } else if (featureType == 'line') {
        if (geometry is geo.LineString) {
          return GeometryCalc._calcPointToSeriesDistance(pt, geometry.chain);
        }
        if (geometry is geo.MultiLineString) {
          var minDist = double.infinity;
          for (final chain in geometry.chains) {
            final d = GeometryCalc._calcPointToSeriesDistance(pt, chain);
            if (d < minDist) minDist = d;
          }
          return minDist;
        }
      } else if (featureType == 'polygon') {
        if (geometry is geo.Polygon) {
          return GeometryCalc._calcPointToGeoRingsDistance(pt, geometry.rings);
        }
        if (geometry is geo.MultiPolygon) {
          var minDist = double.infinity;
          for (final rings in geometry.ringArrays) {
            final d = GeometryCalc._calcPointToGeoRingsDistance(pt, rings);
            if (d == 0.0) return 0.0;
            if (d < minDist) minDist = d;
          }
          return minDist;
        }
      }
      return double.infinity;
    }

    if (featureType == 'point') {
      if (geometry is List<LatLng> && geometry.isNotEmpty) {
        return GeometryCalc.calcDistance(pt, geometry.first);
      }
    } else if (featureType == 'line') {
      if (geometry is List<LatLng>) {
        return GeometryCalc.calcPointToLineDistance(pt, geometry);
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
