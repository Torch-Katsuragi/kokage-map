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
/// 座標型の相互変換: LatLng (latlong2) / geobase / turf
///
/// 点 1 つの変換は拡張メソッド、turf の形 → geobase の変換は関数で置く。
/// どれも x=経度, y=緯度 として扱う（投影座標は扱わない）
library;

import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:turf/turf.dart' as turf;

extension LatLngConvert on LatLng {
  geo.Geographic toGeographic() => geo.Geographic(lon: longitude, lat: latitude);

  turf.Position toTurfPosition() => turf.Position(longitude, latitude);
}

extension GeoPositionToLatLng on geo.Position {
  LatLng toLatLng() => LatLng(y, x);
}

extension TurfPositionConvert on turf.Position {
  LatLng toLatLng() => LatLng(lat.toDouble(), lng.toDouble());

  geo.Geographic toGeographic() =>
      geo.Geographic(lon: lng.toDouble(), lat: lat.toDouble());
}

geo.Geographic _toGeographic(turf.Position p) => p.toGeographic();

/// LineString / MultiLineString を geobase に変換する。それ以外は null
geo.Geometry? turfLineToGeo(turf.GeometryObject? geom) {
  if (geom is turf.MultiLineString) {
    return geo.MultiLineString.from(
      geom.coordinates.map((line) => line.map(_toGeographic)),
    );
  }
  if (geom is turf.LineString) {
    return geo.LineString.from(geom.coordinates.map(_toGeographic));
  }
  return null;
}

/// Polygon / MultiPolygon を geobase に変換する。それ以外は null
geo.Geometry? turfPolygonToGeo(turf.GeometryObject? geom) {
  if (geom is turf.MultiPolygon) {
    return geo.MultiPolygon.from(
      geom.coordinates.map(
        (rings) => rings.map((ring) => ring.map(_toGeographic)),
      ),
    );
  }
  if (geom is turf.Polygon) {
    return geo.Polygon.from(
      geom.coordinates.map((ring) => ring.map(_toGeographic)),
    );
  }
  return null;
}

/// ラインの全頂点（MultiLineString は全パートを連結）。ライン以外は空
List<geo.Geographic> turfLineVertices(turf.GeometryObject? geom) {
  if (geom is turf.MultiLineString) {
    return [
      for (final line in geom.coordinates)
        for (final p in line) _toGeographic(p),
    ];
  }
  if (geom is turf.LineString) {
    return geom.coordinates.map(_toGeographic).toList();
  }
  return const [];
}

/// ポリゴンの全頂点。各リングの閉じ点（先頭と同じ末尾）は除く。ポリゴン以外は空
List<geo.Geographic> turfPolygonVertices(turf.GeometryObject? geom) {
  final pts = <geo.Geographic>[];
  void addRing(List<turf.Position> ring) {
    var n = ring.length;
    if (n >= 2 &&
        ring.first.lat == ring.last.lat &&
        ring.first.lng == ring.last.lng) {
      n--;
    }
    for (var i = 0; i < n; i++) {
      pts.add(_toGeographic(ring[i]));
    }
  }

  if (geom is turf.MultiPolygon) {
    for (final rings in geom.coordinates) {
      rings.forEach(addRing);
    }
  } else if (geom is turf.Polygon) {
    geom.coordinates.forEach(addRing);
  }
  return pts;
}
