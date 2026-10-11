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
// 標高タイルの取り方（3D 地形と、Z 付きレイヤの頂点の標高で共有）
import 'package:flutter/material.dart';

import '../core/terrain/dem_point_sampler.dart';
import '../core/terrain/dem_tiles.dart';
import '../core/terrain/terrain_world.dart' show DemFetcher;
import '../models/basemap_provider.dart';
import '../models/geopackage/vertex_z.dart';
import 'basemap_service.dart';

/// 標高タイルのソースごとの擬似プロバイダ（背景地図と同じ MBTiles キャッシュに入る。祖先フォールバックはしない）
final Map<String, BaseMapProvider> demTileProviders = {
  for (final s in DemTileSource.defaultCascade)
    s.id: BaseMapProvider(
      id: s.id,
      name: s.id,
      description: '標高タイル ${s.id}',
      urlTemplate: s.urlTemplate,
      attribution: s.attribution,
      minZoom: s.minZoom,
      maxZoom: s.maxZoom,
      type: BaseMapType.terrain,
      icon: Icons.terrain,
    ),
};

/// [service] のタイルキャッシュ → ネットで標高タイルを取る
DemFetcher baseMapDemFetcher(BaseMapService service) =>
    (source, z, x, y) => service.getTile(demTileProviders[source.id]!, z, x, y);

/// Z 付きレイヤへ書く頂点の標高を、3D 地形と同じ標高タイルから引くようにする（地図の初期化で 1 回）
void installDemElevationLookup(BaseMapService service) {
  final sampler = DemPointSampler(fetch: baseMapDemFetcher(service));
  VertexZ.elevationLookup = sampler.sample;
}
