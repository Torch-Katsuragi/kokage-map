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
// こかげマップ: turf のジオメトリを geobase（maplibre が受け取る型）へ変換する純粋関数
library;

import 'package:geobase/geobase.dart' as geo;
import 'package:turf/turf.dart' as turf;

geo.Geographic _toGeographic(turf.Position p) =>
    geo.Geographic(lon: p.lng.toDouble(), lat: p.lat.toDouble());

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
