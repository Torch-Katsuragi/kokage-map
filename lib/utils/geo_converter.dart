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
/// 座標型・ジオメトリの相互変換: LatLng (latlong2) ↔ geobase
///
/// 点 1 つの変換は拡張メソッド、パックされた座標列（`PositionSeries` / `Float64List`）との
/// 相互変換および DB 行との変換は関数で置く。
/// どれも x=経度, y=緯度 として扱う（投影座標は扱わない）
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/feature_row.dart';
import 'package:root_maps/utils/app_logger.dart';

extension LatLngConvert on LatLng {
  geo.Geographic toGeographic() => geo.Geographic(lon: longitude, lat: latitude);
}

extension GeoPositionToLatLng on geo.Position {
  LatLng toLatLng() => LatLng(y, x);
}

// ============================================================
// LatLng ↔ PositionSeries / geobase Geometry
// ============================================================

/// `List<LatLng>` をパックされた `PositionSeries`（`Float64List`）に変換する
geo.PositionSeries latLngsToSeries(List<LatLng> points) {
  if (points.isEmpty) return geo.PositionSeries.empty();
  final buf = Float64List(points.length * 2);
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    buf[i * 2] = p.longitude;
    buf[i * 2 + 1] = p.latitude;
  }
  return geo.PositionSeries.view(buf, type: geo.Coords.xy);
}

/// `PositionSeries` から `List<LatLng>` を取り出す
List<LatLng> seriesToLatLngs(geo.PositionSeries series) {
  final n = series.positionCount;
  if (n == 0) return <LatLng>[];
  return [for (var i = 0; i < n; i++) LatLng(series.y(i), series.x(i))];
}

geo.Point createGeoPoint(LatLng latlng) => geo.Point(latlng.toGeographic());

geo.MultiPoint createGeoMultiPoint(List<LatLng> points) =>
    geo.MultiPoint([for (final p in points) p.toGeographic()]);

/// `List<LatLng>` から線ジオメトリを作る（1 点だけの退化線は assert 回避のため MultiLineString に包む）
geo.Geometry createGeoLine(List<LatLng> line) {
  final series = latLngsToSeries(line);
  if (line.length == 1) return geo.MultiLineString([series]);
  return geo.LineString(series);
}

geo.LineString createGeoLineString(List<LatLng> line) =>
    geo.LineString(latLngsToSeries(line));

geo.MultiLineString createGeoMultiLineString(List<List<LatLng>> lines) =>
    geo.MultiLineString([for (final line in lines) latLngsToSeries(line)]);

geo.Polygon createGeoPolygon(List<List<LatLng>> rings) =>
    geo.Polygon([for (final ring in rings) latLngsToSeries(ring)]);

geo.MultiPolygon createGeoMultiPolygon(List<List<List<LatLng>>> polygons) =>
    geo.MultiPolygon([
      for (final rings in polygons) [for (final ring in rings) latLngsToSeries(ring)],
    ]);

LatLng geoPointToLatLng(geo.Point point) => point.position.toLatLng();

List<LatLng> geoLineToLatLngs(geo.LineString ls) => seriesToLatLngs(ls.chain);

List<List<LatLng>> geoMultiLineToLatLngs(geo.MultiLineString mls) =>
    [for (final c in mls.chains) seriesToLatLngs(c)];

List<List<LatLng>> geoPolygonToLatLngs(geo.Polygon poly) =>
    [for (final r in poly.rings) seriesToLatLngs(r)];

List<List<List<LatLng>>> geoMultiPolygonToLatLngs(geo.MultiPolygon mp) => [
      for (final rings in mp.ringArrays) [for (final r in rings) seriesToLatLngs(r)],
    ];

// ============================================================
// 地図描画用フィルタ・頂点抽出
// ============================================================

/// LineString / MultiLineString ならそのまま返す（再確保しない）。それ以外は null
geo.Geometry? asGeoLine(geo.Geometry? geom) =>
    geom is geo.LineString || geom is geo.MultiLineString ? geom : null;

/// Polygon / MultiPolygon ならそのまま返す（再確保しない）。それ以外は null
geo.Geometry? asGeoPolygon(geo.Geometry? geom) =>
    geom is geo.Polygon || geom is geo.MultiPolygon ? geom : null;

/// ラインの全頂点（MultiLineString は全パートを連結）。ライン以外は空
List<geo.Geographic> geoLineVertices(geo.Geometry? geom) {
  final pts = <geo.Geographic>[];
  void addSeries(geo.PositionSeries s) {
    final n = s.positionCount;
    for (var i = 0; i < n; i++) {
      pts.add(geo.Geographic(lon: s.x(i), lat: s.y(i)));
    }
  }

  if (geom is geo.MultiLineString) {
    geom.chains.forEach(addSeries);
  } else if (geom is geo.LineString) {
    addSeries(geom.chain);
  }
  return pts;
}

/// ポリゴンの全頂点。各リングの閉じ点（先頭と同じ末尾）は除く。ポリゴン以外は空
List<geo.Geographic> geoPolygonVertices(geo.Geometry? geom) {
  final pts = <geo.Geographic>[];
  void addRing(geo.PositionSeries ring) {
    var n = ring.positionCount;
    if (n >= 2 && ring.x(0) == ring.x(n - 1) && ring.y(0) == ring.y(n - 1)) {
      n--;
    }
    for (var i = 0; i < n; i++) {
      pts.add(geo.Geographic(lon: ring.x(i), lat: ring.y(i)));
    }
  }

  if (geom is geo.MultiPolygon) {
    for (final rings in geom.ringArrays) {
      rings.forEach(addRing);
    }
  } else if (geom is geo.Polygon) {
    geom.rings.forEach(addRing);
  }
  return pts;
}

// ============================================================
// DB Row ↔ geobase Feature
// ============================================================

/// GeoPackage の row データから `geo.Feature<geo.Geometry>` を作成する。
/// `rowData[featureGeometryKey]` は `geobaseGeometryToLatLngs` の戻り値または `geo.Geometry`。
geo.Feature<geo.Geometry>? createGeoFeatureFromRow(
  Map<String, dynamic> rowData,
  String geometryType,
) {
  try {
    final geometryData = rowData[featureGeometryKey];
    if (geometryData == null) return null;

    // 形の列（geom・Shape など表ごとの名前）は読むときに抜いてある（FeatureRepository）。
    // geom・geometry という名前のふつうの列は属性として残す。
    // 解いた形（[featureGeometryKey]）と地物番号（[featureIdKey]）は列ではないので属性に入れない（地物番号は FeatureNode が持つ）
    final properties = Map<String, dynamic>.from(rowData)
      ..remove(featureGeometryKey)
      ..remove(featureIdKey);

    geo.Geometry? geometry;
    if (geometryData is geo.Geometry) {
      geometry = geometryData;
    } else {
      switch (geometryType.toLowerCase()) {
        case 'point':
          if (geometryData is List<LatLng> && geometryData.isNotEmpty) {
            geometry = geometryData.length == 1
                ? createGeoPoint(geometryData.first)
                : createGeoMultiPoint(geometryData);
          }

        case 'linestring':
          if (geometryData is List<List<LatLng>>) {
            geometry = createGeoMultiLineString(geometryData);
          } else if (geometryData is List<LatLng>) {
            geometry = createGeoLine(geometryData);
          }

        case 'polygon':
          if (geometryData is List<List<List<LatLng>>>) {
            geometry = createGeoMultiPolygon(geometryData);
          } else if (geometryData is List<List<LatLng>>) {
            geometry = createGeoPolygon(geometryData);
          }
      }
    }

    if (geometry == null) return null;
    return geo.Feature<geo.Geometry>(geometry: geometry, properties: properties);
  } catch (e) {
    AppLogger.debug('[ERROR] createGeoFeatureFromRow: $e');
    return null;
  }
}

/// 地物の属性マップを DB 保存用の row データに変換する（属性のみ。ジオメトリは含まない）
Map<String, dynamic>? propertiesToRowData(Map<String, dynamic>? properties) {
  try {
    final rowData = <String, dynamic>{};
    if (properties != null) {
      for (final entry in properties.entries) {
        final key = entry.key;
        final value = entry.value;
        // 形の列は書き手（FeatureRepository.updateFeatureAttributes）が表ごとの名前で外す。
        // geometry という名前のふつうの列（形の列が geom の表）は書く
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
    AppLogger.debug('[ERROR] propertiesToRowData: $e');
    return null;
  }
}
