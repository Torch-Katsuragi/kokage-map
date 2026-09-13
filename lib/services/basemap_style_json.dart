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
/// 背景地図を埋め込んだMapLibreスタイルJSONの組み立て。
///
/// > [!IMPORTANT] web ではこれが**唯一**の背景地図の入れ方
/// > maplibre_web 0.3.5 の `StyleController.addSource()` は `RasterSource` を
/// > 渡すと `tiles` と `url` の**両方**をJSオブジェクトに書く。片方は必ず null に
/// > なるため、maplibre-gl の style バリデータが
/// > `sources.<id>.url: string expected, null found` で弾き、ソースが登録されない。
/// > 例外は飛ばず、タイルのリクエストも発生しないので**無言で地図が真っさらになる**。
/// >
/// > スタイルJSONに最初から書いてしまえばこの経路を通らない
/// > （`jsonDecode` → `jsify` で null が混ざらない）。
/// >
/// > **壊れているのは `addSource` だけ**で、`addLayer` は正常に動く。
/// > そこでスタイルJSONには**全プロバイダのソースだけ**を焼き込み、
/// > レイヤは native と同じく `_addBasemapSources()` が実行時に積む。
/// > こうすると背景地図の切り替えが（レイヤの付け外しだけで済むので）
/// > 再読み込みなしで効く。
library;

import 'dart:convert';

import '../models/basemap_provider.dart';

/// MapLibreのデフォルトフォント配信元（ネットワーク必須）
const _kFallbackGlyphs =
    'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf';

/// 背景色のみのレイヤID
const kBackgroundLayerId = 'bg';

/// プロバイダIDからソースIDを作る（`map_page.dart` の命名と一致させること）
String basemapSourceId(String providerId) => 'basemap-$providerId';

/// プロバイダIDからレイヤIDを作る（`map_page.dart` の命名と一致させること）
String basemapLayerId(String providerId) => 'basemap-layer-$providerId';

/// 背景地図の**ソース**を全プロバイダぶん焼き込んだスタイルJSONを返す。
///
/// レイヤは入れない（背景色の [kBackgroundLayerId] だけ）。
/// どのプロバイダをどの不透明度で見せるかは実行時に `addLayer` で決める。
///
/// > [!NOTE] 使わないソースを書いても転送量は増えない
/// > maplibre-gl はソースを宣言しただけではタイルを取りに行かない。
/// > そのソースを参照するレイヤが1枚でも付いて初めてリクエストが飛ぶ。
String buildBasemapStyleJson({
  List<BaseMapProvider> providers = BaseMapProvider.availableProviders,
  String glyphsUrl = _kFallbackGlyphs,
}) {
  final sources = <String, dynamic>{
    // 生成プロバイダ（等高線）は URL が無い（web の MapLibre には出せない）
    for (final provider in providers)
      if (provider.urlTemplate.isNotEmpty)
        basemapSourceId(provider.id): {
        'type': 'raster',
        'tiles': [provider.urlTemplate],
        'tileSize': 256,
        'minzoom': provider.minZoom,
        'maxzoom': provider.maxZoom,
        'attribution': provider.attribution,
      },
  };

  return jsonEncode({
    'version': 8,
    'glyphs': glyphsUrl,
    'sources': sources,
    'layers': [
      {
        'id': kBackgroundLayerId,
        'type': 'background',
        'paint': {'background-color': '#e8e8e8'},
      },
    ],
  });
}
