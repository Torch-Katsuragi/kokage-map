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
// 書き出す地物の形を、形式によらない LatLng の並びにする
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../../../models/geometry_type.dart';
import '../../../utils/wkb_utils.dart';

/// 地物（GeoPackage の行）の `geom` 列から形を取り出す。
///
/// 部分の並びで返す: 点は部分 1 つ・点 1 つ、線は 1 本、面はリング（先頭が外周）。
/// 多重の形は最初の 1 つだけを返す。形が無い・読めないときは null
List<List<LatLng>>? featureParts(Map<String, dynamic> feature, GeometryType type) {
  final geom = feature['geom'];
  final bytes = switch (geom) {
    Uint8List() => geom,
    List<int>() => Uint8List.fromList(geom),
    _ => null,
  };
  if (bytes == null) return null;
  final geometry = parseGpkgGeometry(bytes);
  if (geometry == null) return null;
  final parsed = geobaseGeometryToLatLngs(geometry);

  switch (type) {
    case GeometryType.point:
      if (parsed is! List<LatLng> || parsed.isEmpty) return null;
      return [
        [parsed.first],
      ];
    case GeometryType.linestring:
      final List<List<LatLng>>? lines = switch (parsed) {
        List<List<LatLng>>() => parsed,
        List<LatLng>() => [parsed],
        _ => null,
      };
      if (lines == null || lines.isEmpty) return null;
      return [lines.first];
    case GeometryType.polygon:
      final List<List<LatLng>>? rings = switch (parsed) {
        List<List<List<LatLng>>>() => parsed.isNotEmpty ? parsed.first : null,
        List<List<LatLng>>() => parsed,
        _ => null,
      };
      if (rings == null || rings.isEmpty) return null;
      return rings;
  }
}
