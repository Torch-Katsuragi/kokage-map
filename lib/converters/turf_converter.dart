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
import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';
import 'package:root_maps/utils/geo_converter.dart';
import 'package:turf/turf.dart' as turf;

/// turf_dartオブジェクトとこかげマップのデータ形式間の変換を行うユーティリティクラス
class TurfConverter {
  // ============================================================
  // LatLng ↔ Position 変換
  // ============================================================

  static List<double> latlngToPosition(LatLng latlng) =>
      [latlng.longitude, latlng.latitude];

  static List<List<double>> latlngsToPositions(List<LatLng> latlngs) =>
      latlngs.map(latlngToPosition).toList();

  static List<turf.Position> _toRing(List<LatLng> line) =>
      [for (final p in line) p.toTurfPosition()];

  static List<LatLng> _fromRing(List<turf.Position> ring) =>
      [for (final p in ring) p.toLatLng()];

  // ============================================================
  // LatLng → turf Geometry
  // ============================================================

  static turf.Point createPoint(LatLng latlng) =>
      turf.Point(coordinates: latlng.toTurfPosition());

  static turf.LineString createLineString(List<LatLng> line) =>
      turf.LineString(coordinates: _toRing(line));

  static turf.Polygon createPolygon(List<List<LatLng>> rings) =>
      turf.Polygon(coordinates: rings.map(_toRing).toList());

  static turf.MultiLineString createMultiLineString(List<List<LatLng>> lines) =>
      turf.MultiLineString(coordinates: lines.map(_toRing).toList());

  static turf.MultiPolygon createMultiPolygon(List<List<List<LatLng>>> polygons) =>
      turf.MultiPolygon(
        coordinates: [for (final rings in polygons) rings.map(_toRing).toList()],
      );

  // ============================================================
  // turf Geometry → LatLng
  // ============================================================

  static LatLng pointToLatlng(turf.Point point) => point.coordinates.toLatLng();

  static List<LatLng> lineStringToLatlngs(turf.LineString ls) => _fromRing(ls.coordinates);

  static List<List<LatLng>> polygonToLatlngs(turf.Polygon poly) =>
      poly.coordinates.map(_fromRing).toList();

  static List<List<LatLng>> multiLineStringToLatlngs(turf.MultiLineString mls) =>
      mls.coordinates.map(_fromRing).toList();

  static List<List<List<LatLng>>> multiPolygonToLatlngs(turf.MultiPolygon mp) =>
      [for (final rings in mp.coordinates) rings.map(_fromRing).toList()];

  // ============================================================
  // Row → turf Feature（DB読み込み時）
  // ============================================================

  /// GeoPackageのrowデータからturf_dartのFeatureを作成
  /// geometryData は geobaseGeometryToLatLngs の戻り値
  static turf.Feature? createFeatureFromRow(
    Map<String, dynamic> rowData,
    String geometryType,
  ) {
    try {
      final geometryData = rowData['geometry'];
      if (geometryData == null) return null;

      final properties = Map<String, dynamic>.from(rowData)
        ..remove('geom')
        ..remove('geometry');

      turf.GeometryObject? geometry;
      final type = geometryType.toLowerCase();

      switch (type) {
        case 'point':
          if (geometryData is List<LatLng> && geometryData.isNotEmpty) {
            geometry = createPoint(geometryData.first);
          }

        case 'linestring':
          if (geometryData is List<List<LatLng>>) {
            // MultiLineString 中間データ
            geometry = createMultiLineString(geometryData);
          } else if (geometryData is List<LatLng>) {
            // 後方互換: 単一 LineString
            geometry = createLineString(geometryData);
          }

        case 'polygon':
          if (geometryData is List<List<List<LatLng>>>) {
            // MultiPolygon 中間データ
            geometry = createMultiPolygon(geometryData);
          } else if (geometryData is List<List<LatLng>>) {
            // 後方互換: 単一 Polygon
            geometry = createPolygon(geometryData);
          }
      }

      if (geometry == null) return null;
      return turf.Feature(geometry: geometry, properties: properties);
    } catch (e) {
      AppLogger.debug('[ERROR] TurfConverter.createFeatureFromRow: $e');
      return null;
    }
  }

  // ============================================================
  // turf Feature → Row データ
  // ============================================================

  static Map<String, dynamic>? featureToRowData(turf.Feature feature) {
    try {
      final rowData = <String, dynamic>{};
      if (feature.properties != null) {
        for (final entry in feature.properties!.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key == 'geometry' || key == 'geom') continue;
          if (value == null ||
              value is String ||
              value is num ||
              value is bool) {
            rowData[key] = value;
          } else if (value is Map) {
            rowData[key] = jsonEncode(value);
          }
        }
      }
      return rowData;
    } catch (e) {
      AppLogger.debug('[ERROR] TurfConverter.featureToRowData: $e');
      return null;
    }
  }

  // ============================================================
  // FeatureCollection ヘルパー
  // ============================================================

  static turf.FeatureCollection createFeatureCollection(
    List<turf.Feature> features,
  ) => turf.FeatureCollection(features: features);

  // ============================================================
  // 計算ユーティリティ
  // ============================================================

  /// Featureの重心を計算
  static LatLng? calculateCentroid(turf.Feature feature) {
    try {
      final centroid = turf.centroid(feature);
      if (centroid.geometry is turf.Point) {
        return pointToLatlng(centroid.geometry as turf.Point);
      }
      return null;
    } catch (e) {
      AppLogger.debug('[ERROR] TurfConverter.calculateCentroid: $e');
      return null;
    }
  }

  /// Featureの面積を計算（Polygon/MultiPolygon対応）
  static double? calculateArea(turf.Feature feature) {
    try {
      final g = feature.geometry;
      if (g is turf.Polygon || g is turf.MultiPolygon) {
        return turf.area(feature)?.toDouble();
      }
      return null;
    } catch (e) {
      AppLogger.debug('[ERROR] TurfConverter.calculateArea: $e');
      return null;
    }
  }

  /// Featureの長さを計算（LineString/MultiLineString対応）
  static double? calculateLength(turf.Feature feature) {
    try {
      final g = feature.geometry;
      if (g is turf.LineString) {
        return turf
            .length(
              turf.Feature(geometry: g, properties: feature.properties),
              turf.Unit.meters,
            )
            .toDouble();
      }
      if (g is turf.MultiLineString) {
        double total = 0;
        for (final coords in g.coordinates) {
          final sub = turf.Feature(
            geometry: turf.LineString(coordinates: coords),
          );
          total += turf.length(sub, turf.Unit.meters).toDouble();
        }
        return total;
      }
      return null;
    } catch (e) {
      AppLogger.debug('[ERROR] TurfConverter.calculateLength: $e');
      return null;
    }
  }
}
