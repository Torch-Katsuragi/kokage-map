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
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'dem_grid.dart';
import 'terrain_worker.dart';
import 'web_mercator.dart';

/// 標高タイルの符号化
enum DemEncoding {
  /// Terrarium: `h = R*256 + G + B/256 - 32768`（AWS Terrain Tiles）
  terrarium,

  /// Mapbox Terrain-RGB: `h = -10000 + (R*65536 + G*256 + B) * 0.1`
  mapboxRgb,

  /// 地理院 標高タイル PNG: `x = 2^16 R + 2^8 G + B`、x < 2^23 なら `h = 0.01 x`、x > 2^23 なら `h = 0.01 (x − 2^24)`、
  /// x = 2^23（RGB = 128,0,0）は無効（海・データなし）
  gsiPng,
}

/// 標高タイルの出どころ（プリセット構造。アプリは中身を知らない）
class DemTileSource {
  const DemTileSource({
    required this.id,
    required this.urlTemplate,
    required this.encoding,
    required this.attribution,
    this.minZoom = 0,
    this.maxZoom = 15,
    this.lastResort = false,
    this.bbox,
    this.generated = false,
  });

  /// タイルキャッシュの擬似プロバイダ ID にも使う（重複不可）
  final String id;

  /// 前のソースが 1 枚も取れなかったときだけ取りに行く（遠くて遅い。海や整備範囲の縁の穴は埋めない）
  final bool lastResort;

  final String urlTemplate;
  final DemEncoding encoding;
  final String attribution;
  final int minZoom;
  final int maxZoom;

  /// 整備範囲の外接矩形 `(minLon, minLat, maxLon, maxLat)`。null なら全球／全国
  final (double minLon, double minLat, double maxLon, double maxLat)? bbox;

  /// アプリ内の生成器（Potree 2.0 展開など）で数値 PNG を作るソースか
  final bool generated;

  /// 指定の経緯度が [bbox] の中に入るか
  bool coversPoint(double lon, double lat) {
    final b = bbox;
    if (b == null) return true;
    return lon >= b.$1 && lon <= b.$3 && lat >= b.$2 && lat <= b.$4;
  }

  /// 指定の XYZ タイルが [bbox] と重なるか
  bool coversTile(int z, int x, int y) {
    final b = bbox;
    if (b == null) return true;
    final west = WebMercator.lonFromX(WebMercator.tileWest(x, z));
    final east = WebMercator.lonFromX(WebMercator.tileWest(x + 1, z));
    final north = WebMercator.latFromY(WebMercator.tileNorth(y, z));
    final south = WebMercator.latFromY(WebMercator.tileNorth(y + 1, z));
    return east >= b.$1 && west <= b.$3 && north >= b.$2 && south <= b.$4;
  }

  // ── 地域別の高精度 DEM（0.25m〜1.0m） ─────────────────────────

  /// 東京都全域 0.25m DEM（産総研シームレス標高タイル・23区/多摩/島しょ部）
  static const gsjTokyo025m = DemTileSource(
    id: 'gsj_tokyo_025m',
    urlTemplate: 'https://tiles.gsj.jp/tiles/elev/tokyo/{z}/{y}/{x}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '産総研 シームレス標高タイル（東京都 0.25m DEM）',
    minZoom: 16,
    maxZoom: 19,
    bbox: (138.9, 24.0, 154.0, 35.9),
  );

  /// 神奈川県全域 0.5m DEM（産総研シームレス標高タイル）
  static const gsjKanagawa05m = DemTileSource(
    id: 'gsj_kanagawa_05m',
    urlTemplate: 'https://tiles.gsj.jp/tiles/elev/kanagawa/{z}/{y}/{x}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '産総研 シームレス標高タイル（神奈川県 0.5m DEM）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (138.91, 35.12, 139.80, 35.68),
  );

  /// 静岡県全域（VIRTUAL SHIZUOKA）0.5m DEM（産総研シームレス標高タイル）
  static const gsjShizuoka05m = DemTileSource(
    id: 'gsj_shizuoka_05m',
    urlTemplate: 'https://tiles.gsj.jp/tiles/elev/shizuoka/{z}/{y}/{x}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '産総研 シームレス標高タイル（静岡県 VIRTUAL SHIZUOKA 0.5m DEM）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (137.47, 34.57, 139.18, 35.65),
  );

  /// 兵庫県全域 0.5m DEM（産総研シームレス標高タイル 1cm 精度数値 PNG 版）
  static const gsjHyogo05m = DemTileSource(
    id: 'gsj_hyogo_05m',
    urlTemplate: 'https://tiles.gsj.jp/tiles/elev/hyogodem/{z}/{y}/{x}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '産総研 シームレス標高タイル（兵庫県 0.5m DEM）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (134.25, 34.15, 135.47, 35.68),
  );

  /// 栃木県全域 0.5m DEM（産総研シームレス標高タイル 1cm 精度数値 PNG 版）
  static const gsjTochigi05m = DemTileSource(
    id: 'gsj_tochigi_05m',
    urlTemplate: 'https://tiles.gsj.jp/tiles/elev/tochigi/{z}/{y}/{x}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '産総研 シームレス標高タイル（栃木県 0.5m DEM）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (139.32, 36.19, 140.30, 37.16),
  );

  /// 高知県全域 0.5m DEM（産総研シームレス標高タイル 1cm 精度数値 PNG 版）
  static const gsjKochi05m = DemTileSource(
    id: 'gsj_kochi_05m',
    urlTemplate: 'https://tiles.gsj.jp/tiles/elev/kochi/{z}/{y}/{x}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '産総研 シームレス標高タイル（高知県 0.5m DEM）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (132.47, 32.70, 134.32, 33.89),
  );

  /// 鳥取県全域 0.5m DEM（鳥取県・林野庁 数値 PNG）
  static const rinyaTottori05m = DemTileSource(
    id: 'rinya_tottori_05m',
    urlTemplate: 'https://rinya-tottori.geospatial.jp/tile/rinya/2024/gridPNG_tottori/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '鳥取県・林野庁 0.5m DEM',
    minZoom: 16,
    maxZoom: 18,
    bbox: (133.13, 35.05, 134.51, 35.62),
  );

  /// 滋賀県全域 0.5m DEM（林野庁・滋賀県オープンデータ）
  static const forestgeoShiga05m = DemTileSource(
    id: 'forestgeo_shiga_05m',
    urlTemplate: 'https://forestgeo.info/opendata/25_shiga/dem_2023/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '滋賀県・林野庁 0.5m DEM（森林GISフォーラム）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (135.76, 34.79, 136.46, 35.71),
  );

  /// 京都府全域 0.5m DEM（林野庁・京都府オープンデータ）
  static const forestgeoKyoto05m = DemTileSource(
    id: 'forestgeo_kyoto_05m',
    urlTemplate: 'https://forestgeo.info/opendata/26_kyoto/dem_2024/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '京都府・林野庁 0.5m DEM（森林GISフォーラム）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (134.85, 34.70, 136.06, 35.78),
  );

  /// 愛媛県全域 0.5m DEM（林野庁・愛媛県オープンデータ）
  static const forestgeoEhime05m = DemTileSource(
    id: 'forestgeo_ehime_05m',
    urlTemplate: 'https://forestgeo.info/opendata/38_ehime/dem_2019/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '愛媛県・林野庁 0.5m DEM（森林GISフォーラム）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (132.01, 32.89, 133.70, 34.30),
  );

  /// 長崎県全域 0.5m DEM（林野庁・長崎県オープンデータ）
  static const forestgeoNagasaki05m = DemTileSource(
    id: 'forestgeo_nagasaki_05m',
    urlTemplate: 'https://forestgeo.info/opendata/42_nagasaki/dem_2022/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '長崎県・林野庁 0.5m DEM（森林GISフォーラム）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (128.58, 32.55, 130.40, 34.73),
  );

  /// 石川県（令和6年能登半島地震区域）0.5m DEM（林野庁 2025）
  static const rinyaIshikawaNoto05m = DemTileSource(
    id: 'rinya_ishikawa_noto_r06eq_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_r06eq_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（能登地域）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (136.58, 36.59, 137.40, 37.86),
  );

  /// 石川県能登地域 0.5m DEM（森林GISフォーラム 2024）
  static const forestgeoIshikawaNoto05m = DemTileSource(
    id: 'forestgeo_ishikawa_noto_05m',
    urlTemplate: 'https://forestgeo.info/opendata/17_ishikawa/noto/dem_2024/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '石川県・林野庁 0.5m DEM（森林GISフォーラム）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (136.58, 36.59, 137.40, 37.86),
  );

  /// 山形県（庄内森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaYamagata028 = DemTileSource(
    id: 'rinya_yamagata_028_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_028_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（山形県庄内森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (139.50, 38.45, 140.25, 39.15),
  );

  /// 長野県（伊那谷森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaNagano067 = DemTileSource(
    id: 'rinya_nagano_067_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_067_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（長野県伊那谷森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (137.55, 35.18, 138.32, 36.12),
  );

  /// 愛知県（尾張西三河森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaAichi078 = DemTileSource(
    id: 'rinya_aichi_078_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_078_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（愛知県尾張西三河森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (136.68, 34.75, 137.58, 35.43),
  );

  /// 愛知県（東三河森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaAichi079 = DemTileSource(
    id: 'rinya_aichi_079_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_079_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（愛知県東三河森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (137.18, 34.57, 137.85, 35.25),
  );

  /// 三重県（北伊勢森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaMie081 = DemTileSource(
    id: 'rinya_mie_081_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_081_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（三重県北伊勢森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (136.32, 34.75, 136.75, 35.25),
  );

  /// 徳島県（吉野川森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaTokushima116 = DemTileSource(
    id: 'rinya_tokushima_116_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_116_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（徳島県吉野川森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (133.65, 33.80, 134.65, 34.25),
  );

  /// 徳島県（那賀・海部川森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaTokushima117 = DemTileSource(
    id: 'rinya_tokushima_117_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_117_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（徳島県那賀・海部川森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (134.00, 33.50, 134.70, 33.98),
  );

  /// 大分県（大分南部森林計画区）0.5m DEM（林野庁 2025）
  static const rinyaOita143 = DemTileSource(
    id: 'rinya_oita_143_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_143_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（大分県大分南部森林計画区）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (131.35, 32.70, 132.10, 33.25),
  );

  /// 岡山県・広島県（平成30年7月豪雨区域）0.5m DEM（林野庁 2025）
  static const rinyaOkahiroH3007tr = DemTileSource(
    id: 'rinya_okayama_hiroshima_h3007tr_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_h3007tr_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（岡山県・広島県）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (132.35, 34.15, 133.95, 35.05),
  );

  /// 熊本県（平成28年熊本地震区域）0.5m DEM（林野庁 2025）
  static const rinyaKumamotoH28eq = DemTileSource(
    id: 'rinya_kumamoto_h28eq_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_h28eq_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（熊本県阿蘇・益城地域）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (130.70, 32.65, 131.35, 33.10),
  );

  /// 熊本県（令和2年7月豪雨・球磨川区域）0.5m DEM（林野庁 2025）
  static const rinyaKumamotoR0207tr = DemTileSource(
    id: 'rinya_kumamoto_r0207tr_05m',
    urlTemplate: 'https://rinya-tiles.geospatial.jp/dem_r0207tr_2025/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '林野庁 0.5m DEM（熊本県球磨川地域）',
    minZoom: 16,
    maxZoom: 18,
    bbox: (130.45, 32.10, 131.05, 32.58),
  );

  /// 和歌山県全域 1.0m グリッド（平面直角座標系第 VI 系 原典 TIN 無補間・構造物保持、Potree 2.0 Octree 経由）
  static const wakayama1gPotree = DemTileSource(
    id: 'wakayama_1g_potree',
    urlTemplate: 'https://3d.wakayamaken.geocloud.jp/outside/GridData/Common/3DData/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '和歌山県 3次元点群データ（1mグリッド）',
    minZoom: 16,
    maxZoom: 17,
    bbox: (135.06, 33.43, 136.01, 34.39),
    generated: true,
  );

  // ── 全国ベースライン DEM ──────────────────────────────────────

  /// AWS Terrain Tiles（全球・キー不要・Terrarium）。日本は 30m 級を引き伸ばしたもの。最後の受け皿
  static const aws = DemTileSource(
    id: 'aws_terrarium',
    urlTemplate: 'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png',
    encoding: DemEncoding.terrarium,
    attribution: 'Terrain Tiles (Mapzen / AWS Open Data)',
    maxZoom: 15,
    lastResort: true,
  );

  /// 地理院 標高タイル DEM1A（航空レーザ 1m メッシュ、精度 0.3m 以内、整備範囲のみ。2025-03 に範囲拡大）
  static const gsiDem1a = DemTileSource(
    id: 'gsi_dem1a_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem1a_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 17,
  );

  /// 地理院 標高タイル DEM5A（航空レーザ 5m メッシュ、精度 0.3m 以内、整備範囲のみ）
  static const gsiDem5a = DemTileSource(
    id: 'gsi_dem5a_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem5a_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 15,
  );

  /// 地理院 標高タイル DEM5B（写真測量 5m メッシュ、整備範囲のみ）
  static const gsiDem5b = DemTileSource(
    id: 'gsi_dem5b_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem5b_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 15,
  );

  /// 地理院 標高タイル DEM5C（写真測量 5m メッシュ、整備範囲のみ）
  static const gsiDem5c = DemTileSource(
    id: 'gsi_dem5c_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem5c_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 15,
  );

  /// 地理院 標高タイル DEM10B（1/2.5 万地形図の等高線由来、全国）
  static const gsiDem10b = DemTileSource(
    id: 'gsi_dem10b_png',
    urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/dem_png/{z}/{x}/{y}.png',
    encoding: DemEncoding.gsiPng,
    attribution: '地理院タイル（標高タイル）',
    minZoom: 2,
    maxZoom: 14,
  );

  /// 既定の並び: 細かい方から試し、無ければ次へ（DEM1A → DEM5A → DEM10B → AWS）
  static const defaultCascade = [gsiDem1a, gsiDem5a, gsiDem10b, aws];

  /// 高度な 3D 地図の並び: 地域別の最高精度データ（0.25m → 0.5m → 和歌山 1.0m 原典）→ 全国 DEM1A/5A/5B/5C/10B → AWS
  static const highPrecisionCascade = [
    gsjTokyo025m,
    gsjKanagawa05m,
    gsjShizuoka05m,
    gsjHyogo05m,
    gsjTochigi05m,
    gsjKochi05m,
    rinyaTottori05m,
    forestgeoShiga05m,
    forestgeoKyoto05m,
    forestgeoEhime05m,
    forestgeoNagasaki05m,
    rinyaIshikawaNoto05m,
    forestgeoIshikawaNoto05m,
    rinyaYamagata028,
    rinyaNagano067,
    rinyaAichi078,
    rinyaAichi079,
    rinyaMie081,
    rinyaTokushima116,
    rinyaTokushima117,
    rinyaOita143,
    rinyaOkahiroH3007tr,
    rinyaKumamotoH28eq,
    rinyaKumamotoR0207tr,
    wakayama1gPotree,
    gsiDem1a,
    gsiDem5a,
    gsiDem5b,
    gsiDem5c,
    gsiDem10b,
    aws,
  ];

  /// 全ソース一覧（キャッシュプロバイダ登録用）
  static const allSources = highPrecisionCascade;

  /// 設定に応じたカスケードを返す
  static List<DemTileSource> cascadeFor({required bool highPrecision}) =>
      highPrecision ? highPrecisionCascade : defaultCascade;

  /// 無効値は NaN
  double decode(int r, int g, int b, [int a = 255]) => decodeWith(encoding, r, g, b, a);

  /// [encoding] の RGBA → 標高（m）。無効値（alpha = 0 または形式固有の NoData）は NaN（isolate の組み立てからも呼ぶ）
  static double decodeWith(DemEncoding encoding, int r, int g, int b, [int a = 255]) {
    if (a == 0) return double.nan;
    return switch (encoding) {
      DemEncoding.terrarium => r * 256 + g + b / 256 - 32768,
      DemEncoding.mapboxRgb => (r == 0 && g == 0 && b == 0) ? double.nan : -10000 + (r * 65536 + g * 256 + b) * 0.1,
      DemEncoding.gsiPng => _decodeGsi((r << 16) | (g << 8) | b),
    };
  }

  static double _decodeGsi(int x) {
    const half = 1 << 23;
    if (x == half) return double.nan;
    return (x < half ? x : x - (1 << 24)) * 0.01;
  }
}

/// XYZ タイルの矩形範囲
class TileRange {
  const TileRange({required this.z, required this.x0, required this.y0, required this.x1, required this.y1});

  final int z;
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  int get width => x1 - x0 + 1;
  int get height => y1 - y0 + 1;
  int get count => width * height;

  /// 中心 (lon, lat) を含み、その周りに [tilesAcross] × [tilesAcross] 枚
  ///
  /// 中心がタイルの端に寄らないよう、小数部で隣を選ぶ
  factory TileRange.around(double lonDeg, double latDeg, int z, int tilesAcross) {
    final fx = WebMercator.tileXFraction(lonDeg, z);
    final fy = WebMercator.tileYFraction(latDeg, z);
    final n = 1 << z;
    final cx = (fx - tilesAcross / 2).round().clamp(0, n - tilesAcross);
    final cy = (fy - tilesAcross / 2).round().clamp(0, n - tilesAcross);
    return TileRange(z: z, x0: cx, y0: cy, x1: cx + tilesAcross - 1, y1: cy + tilesAcross - 1);
  }

  /// この範囲をズーム [dz] 段深くしたときの範囲
  TileRange zoomIn(int dz) => TileRange(
        z: z + dz,
        x0: x0 << dz,
        y0: y0 << dz,
        x1: ((x1 + 1) << dz) - 1,
        y1: ((y1 + 1) << dz) - 1,
      );

  /// 1 段粗い親の範囲
  TileRange get parent => TileRange(z: z - 1, x0: x0 >> 1, y0: y0 >> 1, x1: x1 >> 1, y1: y1 >> 1);

  /// 周りに [margin] 枚の余白を足した範囲（世界の端で切る）
  TileRange grow(int margin) {
    if (margin <= 0) return this;
    final n = 1 << z;
    return TileRange(
      z: z,
      x0: (x0 - margin).clamp(0, n - 1),
      y0: (y0 - margin).clamp(0, n - 1),
      x1: (x1 + margin).clamp(0, n - 1),
      y1: (y1 + margin).clamp(0, n - 1),
    );
  }

  bool contains(int tz, int tx, int ty) => tz == z && tx >= x0 && tx <= x1 && ty >= y0 && ty <= y1;

  /// 西端・南端の Mercator 座標
  double get west => WebMercator.tileWest(x0, z);
  double get south => WebMercator.tileNorth(y1 + 1, z);
  double get widthMeters => width * WebMercator.tileSpan(z);
}

/// 進捗通知（読み込んだ枚数 / 全枚数）
typedef TileProgress = void Function(int done, int total);

/// タイル 1 枚の取得。取れなければ null
///
/// 既定は URL テンプレートへの http。アプリでは `BaseMapService.getTile`
/// （キャッシュ → ネット → 祖先タイルからの切り出し）を渡して同じ絵・同じオフライン挙動にする。
typedef TileFetcher = Future<Uint8List?> Function(int z, int x, int y);

/// URL テンプレートから http で取る [TileFetcher]
TileFetcher httpTileFetcher(String urlTemplate, {http.Client? client, Map<String, String>? headers}) {
  final c = client ?? http.Client();
  return (z, x, y) async {
    final uri = Uri.parse(
      urlTemplate.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y'),
    );
    try {
      final res = await c.get(uri, headers: headers);
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null; // 取れなかったタイルは null（DEM は 0m、テクスチャは空）
    }
  };
}

/// [range] の全タイルを並列に取ってくる（行優先・北から）
Future<List<Uint8List?>> _fetchRange(
  TileFetcher fetch,
  TileRange range, {
  int concurrency = 8,
  TileProgress? onProgress,
}) async {
  final coords = <(int, int)>[];
  for (var ty = range.y0; ty <= range.y1; ty++) {
    for (var tx = range.x0; tx <= range.x1; tx++) {
      coords.add((tx, ty));
    }
  }
  final results = List<Uint8List?>.filled(coords.length, null);
  var next = 0;
  var done = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= coords.length) return;
      final (tx, ty) = coords[i];
      results[i] = await fetch(range.z, tx, ty);
      done++;
      onProgress?.call(done, coords.length);
    }
  }

  await Future.wait([for (var k = 0; k < concurrency; k++) worker()]);
  return results;
}

/// 標高タイルを [DemGrid] に組み立てる
class DemTileLoader {
  DemTileLoader({required this.source, TileFetcher? fetcher})
      : _fetch = fetcher ?? httpTileFetcher(source.urlTemplate);

  final DemTileSource source;
  final TileFetcher _fetch;

  /// [range] の全タイルを 1 枚の格子にする。格子点はピクセル中心。1 枚でも取れなければ例外
  Future<DemGrid> load(TileRange range, {TileProgress? onProgress}) async {
    final dem = await tryLoad(range, onProgress: onProgress);
    if (dem == null) throw StateError('DEM タイルが取れない: ${range.z}/${range.x0}/${range.y0}');
    return dem;
  }

  /// [load] の null 版。1 枚でも取れなければ null
  /// （⚠ 以前は取れなかったタイルが 0m の平面になっていた）
  ///
  /// [fillInvalid] が false なら無効値（地理院タイルの海・データなし）を NaN のまま返す
  /// （呼び出し側が別ソースで埋める）。true なら [fillInvalidHeights] で埋める
  Future<DemGrid?> tryLoad(TileRange range, {TileProgress? onProgress, bool fillInvalid = true}) async {
    final z = range.z;
    final sw = Stopwatch()..start();
    final bytesList = await _fetchRange(_fetch, range, onProgress: onProgress);
    if (bytesList.any((b) => b == null)) return null;
    final fetchMs = sw.elapsedMilliseconds;
    // PNG のデコードと格子の組み立ては純 Dart で数百 ms 掛かるので isolate へ（web では同じスレッド）
    final heights = await TerrainWorker.instance.run(
      _assembleHeights,
      _AssembleArgs(bytesList: bytesList, width: range.width, height: range.height, encoding: source.encoding),
    );
    if (sw.elapsedMilliseconds > 800) {
      debugPrint('[3D] dem ${range.z}/${range.x0}/${range.y0} fetch ${fetchMs}ms assemble ${sw.elapsedMilliseconds - fetchMs}ms');
    }
    if (fillInvalid) fillInvalidHeights(heights, cols: range.width * WebMercator.tileSize);
    const ts = WebMercator.tileSize;
    final cols = range.width * ts;
    final rows = range.height * ts;
    final mpp = WebMercator.metersPerPixel(z);
    return DemGrid(
      cols: cols,
      rows: rows,
      originX: range.west + mpp / 2,
      originY: range.south + mpp / 2,
      cellSize: mpp,
      heights: heights,
    );
  }
}

class _AssembleArgs {
  const _AssembleArgs({required this.bytesList, required this.width, required this.height, required this.encoding});

  final List<Uint8List?> bytesList;
  final int width;
  final int height;
  final DemEncoding encoding;
}

/// タイル画像列 → 標高格子（南が 0 行目）。isolate で走る
/// 親タイル（[levels] 段上）の高さから、子タイル (childX, childY) の 256×256 を高さの空間で双一次補間して作る
///
/// PNG の RGB を拡大すると 2×2〜8×8 のブロック状の階段になる（Terrarium の桁が独立に補間される）。
/// 高さに直してから補間すれば、粗いだけで滑らかな地形になる
class UpsampleArgs {
  const UpsampleArgs({required this.parent, required this.levels, required this.childX, required this.childY});

  /// 親の高さ（256×256・南が 0 行目）
  final Float32List parent;
  final int levels;
  final int childX;
  final int childY;
}

Float32List upsampleFromParent(UpsampleArgs a) {
  const n = WebMercator.tileSize;
  final f = 1 << a.levels; // 親 1 枚に子が f×f
  final sub = n ~/ f; // 子 1 枚ぶんの親の格子点数
  final cx = a.childX & (f - 1);
  final cyNorth = a.childY & (f - 1); // タイル y は北から。DemGrid は南が 0 行目
  final c0 = cx * sub;
  final r0 = (f - 1 - cyNorth) * sub;
  final out = Float32List(n * n);
  // 子の格子点 i（ピクセル中心）は親の格子座標で (i + 0.5) / f - 0.5
  for (var r = 0; r < n; r++) {
    final py = r0 + (r + 0.5) / f - 0.5;
    final ry0 = py.floor().clamp(0, n - 1);
    final ry1 = (ry0 + 1).clamp(0, n - 1);
    final ty = (py - ry0).clamp(0.0, 1.0);
    for (var c = 0; c < n; c++) {
      final px = c0 + (c + 0.5) / f - 0.5;
      final cx0 = px.floor().clamp(0, n - 1);
      final cx1 = (cx0 + 1).clamp(0, n - 1);
      final tx = (px - cx0).clamp(0.0, 1.0);
      final h00 = a.parent[ry0 * n + cx0];
      final h10 = a.parent[ry0 * n + cx1];
      final h01 = a.parent[ry1 * n + cx0];
      final h11 = a.parent[ry1 * n + cx1];
      out[r * n + c] = (h00 * (1 - tx) + h10 * tx) * (1 - ty) + (h01 * (1 - tx) + h11 * tx) * ty;
    }
  }
  return out;
}

Float32List _assembleHeights(_AssembleArgs a) {
  const ts = WebMercator.tileSize;
  final cols = a.width * ts;
  final rows = a.height * ts;
  final heights = Float32List(cols * rows);
  var k = 0;
  for (var ty = 0; ty < a.height; ty++) {
    for (var tx = 0; tx < a.width; tx++) {
      final bytes = a.bytesList[k++];
      if (bytes == null) continue;
      final decoded = img.decodePng(bytes);
      if (decoded == null) continue;
      final rgba = decoded.convert(format: img.Format.uint8, numChannels: 4).toUint8List();
      final baseC = tx * ts;
      // タイル画像は北が 0 行目。DemGrid は南が 0 行目
      final baseR = (a.height - 1 - ty) * ts;
      for (var iy = 0; iy < ts; iy++) {
        final r = baseR + (ts - 1 - iy);
        final rowOff = r * cols + baseC;
        final src = iy * ts * 4;
        for (var ix = 0; ix < ts; ix++) {
          final p = src + ix * 4;
          heights[rowOff + ix] = DemTileSource.decodeWith(a.encoding, rgba[p], rgba[p + 1], rgba[p + 2], rgba[p + 3]);
        }
      }
    }
  }
  return heights;
}

/// 無効値（NaN。地理院タイルの海・データなし・水面）を周りから補間して埋める。
/// [cols] を渡すと格子として扱う: 行の中は左右の有効値の間を線形補間（片側しか無ければその値）、
/// 行ごと無効なら上下の有効な行の間を列ごとに補間。全部無効なら 0（海面）。
/// [cols] が無ければ従来の「直前の有効値」（先頭が無効なら最初の有効値）。
///
/// ⚠ 「直前の値」で埋めると、タイルの先頭（南）の行が丸ごと無効なとき（川が南の縁を横切る等）に
/// タイルの最初の有効値の**台地**（垂直の壁つき）になる（2026-09-13 に河川で観測）。
/// 世界（TerrainWorld）は先に次のソース・親の近似・最後の砦で埋め、残りだけこれで埋める
void fillInvalidHeights(Float32List h, {int cols = 0}) {
  if (cols <= 0 || h.length % cols != 0) {
    var last = 0.0;
    for (var i = 0; i < h.length; i++) {
      if (!h[i].isNaN) {
        last = h[i];
        break;
      }
    }
    for (var i = 0; i < h.length; i++) {
      final v = h[i];
      if (v.isNaN) {
        h[i] = last;
      } else {
        last = v;
      }
    }
    return;
  }
  final rows = h.length ~/ cols;
  final rowValid = List<bool>.filled(rows, false);
  // 1. 行の中で左右から補間
  for (var r = 0; r < rows; r++) {
    final base = r * cols;
    var c = 0;
    while (c < cols) {
      if (!h[base + c].isNaN) {
        rowValid[r] = true;
        c++;
        continue;
      }
      final start = c;
      while (c < cols && h[base + c].isNaN) {
        c++;
      }
      final end = c; // [start, end) が無効
      final left = start > 0 ? h[base + start - 1] : double.nan;
      final right = end < cols ? h[base + end] : double.nan;
      if (left.isNaN && right.isNaN) continue; // 行ごと無効（2 で埋める）
      rowValid[r] = true;
      for (var i = start; i < end; i++) {
        if (left.isNaN) {
          h[base + i] = right;
        } else if (right.isNaN) {
          h[base + i] = left;
        } else {
          final t = (i - start + 1) / (end - start + 1);
          h[base + i] = left + (right - left) * t;
        }
      }
    }
  }
  // 2. 行ごと無効: 上下の有効な行の間を列ごとに補間（片側しか無ければ写す。1 行も無ければ 0）
  if (!rowValid.any((v) => v)) {
    h.fillRange(0, h.length, 0);
    return;
  }
  var r = 0;
  while (r < rows) {
    if (rowValid[r]) {
      r++;
      continue;
    }
    final start = r;
    while (r < rows && !rowValid[r]) {
      r++;
    }
    final end = r; // [start, end) が無効な行
    final above = start > 0 ? start - 1 : -1;
    final below = end < rows ? end : -1;
    for (var rr = start; rr < end; rr++) {
      final t = (rr - start + 1) / (end - start + 1);
      for (var c = 0; c < cols; c++) {
        final a = above >= 0 ? h[above * cols + c] : double.nan;
        final b = below >= 0 ? h[below * cols + c] : double.nan;
        h[rr * cols + c] = a.isNaN ? b : (b.isNaN ? a : a + (b - a) * t);
      }
      rowValid[rr] = true;
    }
  }
}

/// テクスチャに上描きする手（オーバーレイ画像など）。canvas は [range] の左上が原点、1 タイル = 256px
typedef TextureDecorator = void Function(ui.Canvas canvas, TileRange range);

/// 合成する 1 層: タイルの取り方・不透明度（0〜1）・合成モード（お絵描きソフトのレイヤと同じ。一番下の層のモードは効かない）
typedef TextureLayer = (TileFetcher fetch, double opacity, ui.BlendMode blend);

/// ラスタタイル（背景地図）を 1 枚の画像に合成する
///
/// 設計どおり「表示範囲のタイルを 1 枚に合成してから ImageShader で貼る」。
class RasterTileComposer {
  RasterTileComposer({String? urlTemplate, TileFetcher? fetcher, this._imageCache})
      : assert(urlTemplate != null || fetcher != null),
        _fetch = fetcher ?? httpTileFetcher(urlTemplate!);

  final TileFetcher _fetch;
  final TileImageCache? _imageCache;

  /// [range] のタイルを敷き詰めた画像を返す（幅 = width×256）
  Future<ui.Image> compose(TileRange range, {TileProgress? onProgress, TextureDecorator? decorate}) =>
      composeLayers(range, [(_fetch, 1.0, ui.BlendMode.srcOver)], onProgress: onProgress, decorate: decorate);

  /// 複数のタイル層を下から順に不透明度と合成モードで重ねて 1 枚にする（背景地図のレイヤ）。
  /// 層は透明な板の上に重ね（一番下の層の合成モードは効かない。お絵描きソフトと同じ）、最後に灰色の下地に載せる
  /// （タイルが無い所は灰色）。[decorate] は最後に呼ばれ、オーバーレイ画像などを上に描ける（座標は範囲左上原点のピクセル）
  Future<ui.Image> composeLayers(
    TileRange range,
    List<TextureLayer> layers, {
    TileProgress? onProgress,
    TextureDecorator? decorate,
  }) async {
    const ts = WebMercator.tileSize;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final bounds = ui.Rect.fromLTWH(0, 0, range.width * ts * 1.0, range.height * ts * 1.0);
    canvas.drawRect(bounds, ui.Paint()..color = const ui.Color(0xFFDDDDDD));
    canvas.saveLayer(bounds, ui.Paint());
    final owned = <ui.Image>[]; // キャッシュに入れなかった画像（合成後に捨てる）
    var doneTotal = 0;
    final total = range.count * layers.length;
    for (var li = 0; li < layers.length; li++) {
      final (fetch, opacity, blend) = layers[li];
      final cache = _imageCache;
      // キャッシュに無いタイルだけ取る
      final missing = <(int, int)>[];
      for (var ty = range.y0; ty <= range.y1; ty++) {
        for (var tx = range.x0; tx <= range.x1; tx++) {
          if (cache == null || cache.get(li, range.z, tx, ty) == null) missing.add((tx, ty));
        }
      }
      final fetched = <(int, int), Uint8List?>{};
      if (missing.isNotEmpty) {
        var next = 0;
        var done = 0;
        Future<void> worker() async {
          while (true) {
            final i = next++;
            if (i >= missing.length) return;
            final (tx, ty) = missing[i];
            fetched[(tx, ty)] = await fetch(range.z, tx, ty);
            done++;
            onProgress?.call(doneTotal + done, total);
          }
        }

        await Future.wait([for (var k = 0; k < 8; k++) worker()]);
      }
      doneTotal += range.count;
      final paint = ui.Paint()
        ..color = ui.Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0))
        ..blendMode = blend;
      for (var ty = range.y0; ty <= range.y1; ty++) {
        for (var tx = range.x0; tx <= range.x1; tx++) {
          var image = cache?.get(li, range.z, tx, ty);
          if (image == null) {
            final bytes = fetched[(tx, ty)];
            if (bytes == null) continue;
            try {
              final codec = await ui.instantiateImageCodec(bytes);
              final frame = await codec.getNextFrame();
              codec.dispose(); // 絵は frame が持つ。コーデックは GC の後始末を待たずに手放す
              image = frame.image;
            } catch (_) {
              continue; // 壊れたタイルは飛ばす
            }
            if (cache != null) {
              cache.put(li, range.z, tx, ty, image);
            } else {
              owned.add(image);
            }
          }
          canvas.drawImage(
            image,
            ui.Offset((tx - range.x0) * ts * 1.0, (ty - range.y0) * ts * 1.0),
            paint,
          );
        }
      }
    }
    canvas.restore();
    decorate?.call(canvas, range);
    final picture = recorder.endRecording();
    final image = await picture.toImage(range.width * ts, range.height * ts);
    picture.dispose();
    for (final i in owned) {
      i.dispose();
    }
    return image;
  }
}

/// デコード済みタイル画像の LRU（層番号・z・x・y で引く）
///
/// パンで隣へ読み直すとき、重なるタイルを再取得・再デコードしないため。
class TileImageCache {
  TileImageCache({this.capacity = 512});

  final int capacity;
  final _map = <String, ui.Image>{};

  String _key(int layer, int z, int x, int y) => '$layer/$z/$x/$y';

  ui.Image? get(int layer, int z, int x, int y) {
    final k = _key(layer, z, x, y);
    final v = _map.remove(k);
    if (v != null) _map[k] = v; // 末尾へ（最近使った）
    return v;
  }

  void put(int layer, int z, int x, int y, ui.Image image) {
    _map[_key(layer, z, x, y)] = image;
    while (_map.length > capacity) {
      final oldest = _map.keys.first;
      _map.remove(oldest)?.dispose();
    }
  }

  void clear() {
    for (final i in _map.values) {
      i.dispose();
    }
    _map.clear();
  }
}
