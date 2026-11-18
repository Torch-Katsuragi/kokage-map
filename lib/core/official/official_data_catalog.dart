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

/// 公式オープンデータ（森林区画・国有林・地質図・高精細オルソ）の地域カスケード定義。
///
/// 3D 地形の [DemTileSource] と同じく、`bbox` とズーム範囲の並びでタイルごとに最適な公開元を選ぶ。
/// 利用者は都道府県や省庁ごとの違いを意識せず、テーマ単位で `System`（`sys`）や背景地図から重ねられる。
library;

import 'package:flutter/material.dart';

import '../terrain/web_mercator.dart';

/// 地域カスケードの矩形 `(minLon, minLat, maxLon, maxLat)` が指定経緯度を含むか
bool bboxCoversPoint((double, double, double, double)? bbox, double lon, double lat) {
  if (bbox == null) return true;
  return lon >= bbox.$1 && lon <= bbox.$3 && lat >= bbox.$2 && lat <= bbox.$4;
}

/// 地域カスケードの矩形 `(minLon, minLat, maxLon, maxLat)` が XYZ タイルと重なるか
bool bboxCoversTile((double, double, double, double)? bbox, int z, int x, int y) {
  if (bbox == null) return true;
  final west = WebMercator.lonFromX(WebMercator.tileWest(x, z));
  final east = WebMercator.lonFromX(WebMercator.tileWest(x + 1, z));
  final north = WebMercator.latFromY(WebMercator.tileNorth(y, z));
  final south = WebMercator.latFromY(WebMercator.tileNorth(y + 1, z));
  return east >= bbox.$1 && west <= bbox.$3 && north >= bbox.$2 && south <= bbox.$4;
}

/// 公式レイヤの描画・照会方式
enum OfficialLayerKind {
  /// ベクトルタイル（`.pbf` MVT または `.pmtiles`）からポリゴン・線・ラベルを描き、タップで属性を返す
  vectorTile,

  /// ラスタタイルで地形を染めつつ、タップ地点は公式 JSON API で属性（岩石・地質年代など）を照会する
  rasterWithPointApi,
}

/// ベクトルタイル／PMTiles の配信元 1 件（地域別 `bbox` カスケードの要素）
class OfficialVectorSource {
  const OfficialVectorSource({
    required this.id,
    required this.urlTemplate,
    required this.attribution,
    this.sourceLayer,
    this.minZoom = 12,
    this.maxZoom = 16,
    this.bbox,
  });

  final String id;

  /// `{z}/{x}/{y}.pbf` の XYZ テンプレート、または `.pmtiles` アーカイブの単一 URL
  final String urlTemplate;
  final String attribution;
  final String? sourceLayer;
  final int minZoom;
  final int maxZoom;
  final (double minLon, double minLat, double maxLon, double maxLat)? bbox;

  bool get isPmTiles => urlTemplate.toLowerCase().split('?').first.endsWith('.pmtiles');

  bool coversTile(int z, int x, int y) => bboxCoversTile(bbox, z, x, y);
  bool coversPoint(double lon, double lat) => bboxCoversPoint(bbox, lon, lat);
}

/// `System`（`sys`）に追加できる公式データレイヤの定義
class OfficialLayerSpec {
  const OfficialLayerSpec({
    required this.id,
    required this.kind,
    required this.icon,
    required this.accentColor,
    required this.attribution,
    this.vectorSources = const [],
    this.rasterProviderId,
    this.pointApiUrlTemplate,
    this.minDisplayZoom = 12,
  });

  final String id;
  final OfficialLayerKind kind;
  final IconData icon;
  final Color accentColor;
  final String attribution;

  /// 地域別の高精度ソース → 全国フォールバックの順で並べる（[DemTileSource] と同じ規則）
  final List<OfficialVectorSource> vectorSources;

  /// [OfficialLayerKind.rasterWithPointApi] のときに重ねる背景プロバイダ ID
  final String? rasterProviderId;

  /// `{lat}` `{lon}` を埋める地点照会 API URL
  final String? pointApiUrlTemplate;

  /// これより引いた段ではベクトルタイルを取りに行かない
  final int minDisplayZoom;

  /// 林野庁「森林計画対象森林レイヤ」（全国の国有林・民有林の林班境界）
  static const rinyaForestPlan = OfficialLayerSpec(
    id: 'rinya_forest_plan',
    kind: OfficialLayerKind.vectorTile,
    icon: Icons.forest_outlined,
    accentColor: Color(0xFF2E7D32),
    attribution: '林野庁「森林計画対象森林レイヤ」（公共データ利用規約第1.0版）',
    minDisplayZoom: 12,
    vectorSources: [
      OfficialVectorSource(
        id: 'rinya_fr_layer_2025',
        urlTemplate: 'https://rinya-tiles.geospatial.jp/fr_layer_pbf_2025/{z}/{x}/{y}.pbf',
        sourceLayer: '森林計画対象森林レイヤ',
        minZoom: 12,
        maxZoom: 16,
        attribution: '林野庁「森林計画対象森林レイヤ」',
      ),
    ],
  );

  /// 産総研 地質調査総合センター「20万分の1 日本シームレス地質図 V2」（ラスタ重ね合わせ＋タップ凡例 API）
  static const gsjSeamlessGeology = OfficialLayerSpec(
    id: 'gsj_seamless_geology',
    kind: OfficialLayerKind.rasterWithPointApi,
    icon: Icons.layers_outlined,
    accentColor: Color(0xFF8D6E63),
    attribution: '産総研 地質調査総合センター「20万分の1日本シームレス地質図V2」',
    rasterProviderId: 'gsj_geology_v2',
    pointApiUrlTemplate: 'https://gbank.gsj.jp/seamless/v2/api/1.3.1/legend.json?point={lat},{lon}',
    minDisplayZoom: 5,
  );

  /// 組み込みの公式レイヤカタログ
  static const List<OfficialLayerSpec> catalog = [
    rinyaForestPlan,
    gsjSeamlessGeology,
  ];

  static OfficialLayerSpec? byId(String id) {
    for (final s in catalog) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// 航空写真オルソの地域カスケード定義（高精細な公開オルソがあれば優先し、無ければ地理院 `seamlessphoto` へフォールバック）
class RegionalRasterSource {
  const RegionalRasterSource({
    required this.id,
    required this.urlTemplate,
    required this.attribution,
    this.minZoom = 2,
    this.maxZoom = 18,
    this.bbox,
  });

  final String id;
  final String urlTemplate;
  final String attribution;
  final int minZoom;
  final int maxZoom;
  final (double minLon, double minLat, double maxLon, double maxLat)? bbox;

  bool coversTile(int z, int x, int y) =>
      z >= minZoom && z <= maxZoom && bboxCoversTile(bbox, z, x, y);

  /// 全国最新オルソ＋地域高精細オルソ優先カスケード
  static const List<RegionalRasterSource> highResOrthoCascade = [
    // 国交省 Project PLATEAU 2024 整備都市オルソ（整備外タイルは即 404 → 次段へ）
    RegionalRasterSource(
      id: 'plateau_ortho_2024',
      urlTemplate: 'https://tile.plateauview.mlit.go.jp/tiles/plateau-ortho-2024/{z}/{x}/{y}.png',
      attribution: '国土交通省 Project PLATEAU（PLATEAU-Ortho）',
      minZoom: 14,
      maxZoom: 19,
      bbox: (127.5, 26.0, 145.9, 45.6),
    ),
    // 国交省 Project PLATEAU 2023 整備都市オルソ
    RegionalRasterSource(
      id: 'plateau_ortho_2023',
      urlTemplate: 'https://tile.plateauview.mlit.go.jp/tiles/plateau-ortho-2023/{z}/{x}/{y}.png',
      attribution: '国土交通省 Project PLATEAU（PLATEAU-Ortho）',
      minZoom: 14,
      maxZoom: 19,
      bbox: (127.5, 26.0, 145.9, 45.6),
    ),
    // 全国フォールバック: 国土地理院 全国最新写真（シームレス。林野庁空中写真・都道府県森林写真・災害正射画像も統合済）
    RegionalRasterSource(
      id: 'gsi_seamlessphoto_base',
      urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg',
      attribution: '国土地理院',
      minZoom: 2,
      maxZoom: 18,
    ),
  ];
}
