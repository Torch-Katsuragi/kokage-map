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
/// LatLng (latlong2) ↔ Geographic (geobase) 変換ユーティリティ
/// maplibre移行で座標型が異なるため、境界で変換する
library;

import 'package:geobase/geobase.dart';
import 'package:latlong2/latlong.dart';

extension LatLngToGeographic on LatLng {
  /// LatLng → Geographic 変換
  Geographic toGeographic() =>
      Geographic(lon: longitude, lat: latitude);
}

extension GeographicToLatLng on Geographic {
  /// Geographic → LatLng 変換
  LatLng toLatLng() => LatLng(lat, lon);
}

extension LatLngListToGeographic on List<LatLng> {
  /// LatLngリスト → Geographicリスト 変換
  List<Geographic> toGeographics() =>
      map((ll) => ll.toGeographic()).toList();
}

extension GeographicListToLatLng on List<Geographic> {
  /// Geographicリスト → LatLngリスト 変換
  List<LatLng> toLatLngs() =>
      map((g) => g.toLatLng()).toList();
}
