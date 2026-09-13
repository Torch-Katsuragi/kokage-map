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
/// 背景地図プロバイダー定義
/// OpenStreetMap、国土地理院地図などの背景地図を管理
library;
import 'package:flutter/material.dart';

import '../core/terrain/contour_tiles.dart' show ContourTiles;

/// タイル取得時の User-Agent（Android/iOS のみ。webはブラウザが付ける）。
///
/// ⚠ OSMのタイル利用ポリシーは「アプリを特定できる固有のUA＋連絡先」を要求し、
/// 汎用UA・偽装UAは**予告なくブロック**される。以前の `com.example.k_maps` は
/// これに引っかかり、全タイルが 403 "Access blocked" になっていた
/// （2026-08-28 Pixel 9 で確認）。文字列を変えるときはポリシーを読み直すこと:
/// https://operations.osmfoundation.org/policies/tiles/
const String kTileUserAgent =
    'KokageMap/1.0 (+https://kokage-map.sleeptree.jp; k-root@googlegroups.com)';

/// 背景地図の種類を定義するenum
enum BaseMapType {
  /// 標高タイル（背景地図ではない。3D 地形モードが `BaseMapService.getTile` のキャッシュを借りるためのもの）
  terrain,

  /// アプリ内で作るタイル（等高線など）。ネットからは取らず、`BaseMapService.registerTileGenerator` の生成器が作り、
  /// 背景地図と同じタイルキャッシュに入る
  generated,
  openStreetMap,
  gsiStandard,
  gsiPale,
  gsiPhoto,
  gsiRelief,
  gsiRedRelief,
  gsiBlank,
}

/// 背景地図プロバイダーの情報を格納するクラス
class BaseMapProvider {
  final String id;
  final String name;
  final String description;
  final String urlTemplate;
  final int maxZoom;
  final int minZoom;
  final String attribution;
  final BaseMapType type;
  final IconData icon;

  /// タイルキャッシュ（MBTiles）の名前。普通は [id] と同じ。生成プロバイダは絵を変えたら版を上げて古いキャッシュと混ぜない
  /// （[id] は設定の重ね合わせの鍵なので変えない）
  final String cacheId;

  const BaseMapProvider({
    required this.id,
    required this.name,
    required this.description,
    required this.urlTemplate,
    this.maxZoom = 18,
    this.minZoom = 1,
    required this.attribution,
    required this.type,
    required this.icon,
    String? cacheId,
  }) : cacheId = cacheId ?? id;

  /// 等高線（生成プロバイダ）。生成器の登録先
  static BaseMapProvider get contourOverlay => availableProviders.firstWhere((p) => p.id == 'contours');

  /// 利用可能な背景地図プロバイダーのリスト
  static const List<BaseMapProvider> availableProviders = [
    // OpenStreetMap
    // ⚠ 一括ダウンロードは不可（ポリシーで prefetch がブロック対象）。
    //   既定地図にもしない（community運営サーバへの負荷配慮）。
    BaseMapProvider(
      id: 'osm',
      name: 'OpenStreetMap',
      description: 'オープンソースの世界地図',
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      maxZoom: 19,
      attribution: '© OpenStreetMap contributors',
      type: BaseMapType.openStreetMap,
      icon: Icons.public,
    ),

    // 国土地理院地図 - 標準地図
    BaseMapProvider(
      id: 'gsi_std',
      name: '国土地理院（標準）',
      description: '国土地理院の標準地図',
      urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/std/{z}/{x}/{y}.png',
      maxZoom: 18,
      attribution: '国土地理院',
      type: BaseMapType.gsiStandard,
      icon: Icons.map,
    ),

    // 国土地理院地図 - 淡色地図
    BaseMapProvider(
      id: 'gsi_pale',
      name: '国土地理院（淡色）',
      description: '国土地理院の淡色地図（背景用）',
      urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png',
      maxZoom: 18,
      attribution: '国土地理院',
      type: BaseMapType.gsiPale,
      icon: Icons.layers_outlined,
    ),

    // 国土地理院地図 - 写真
    BaseMapProvider(
      id: 'gsi_photo',
      name: '国土地理院（写真）',
      description: '国土地理院の航空写真',
      urlTemplate:
          'https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg',
      maxZoom: 18,
      attribution: '国土地理院',
      type: BaseMapType.gsiPhoto,
      icon: Icons.satellite_alt,
    ),

    // 国土地理院地図 - 色別標高図
    BaseMapProvider(
      id: 'gsi_relief',
      name: '国土地理院（標高）',
      description: '国土地理院の色別標高図',
      urlTemplate:
          'https://cyberjapandata.gsi.go.jp/xyz/relief/{z}/{x}/{y}.png',
      maxZoom: 15,
      attribution: '国土地理院',
      type: BaseMapType.gsiRelief,
      icon: Icons.terrain,
    ),

    // 国土地理院地図 - 赤色立体地図
    BaseMapProvider(
      id: 'gsi_red_relief',
      name: '国土地理院（赤色立体図）',
      description: '地形の起伏を立体的に表現（アジア航測）',
      urlTemplate:
          'https://cyberjapandata.gsi.go.jp/xyz/sekishoku/{z}/{x}/{y}.png',
      maxZoom: 14,
      minZoom: 2,
      attribution: '国土地理院・アジア航測株式会社',
      type: BaseMapType.gsiRedRelief,
      icon: Icons.landscape,
    ),

    // 国土地理院地図 - 白地図
    BaseMapProvider(
      id: 'gsi_blank',
      name: '国土地理院（白地図）',
      description: '国土地理院の白地図',
      urlTemplate: 'https://cyberjapandata.gsi.go.jp/xyz/blank/{z}/{x}/{y}.png',
      maxZoom: 14,
      attribution: '国土地理院',
      type: BaseMapType.gsiBlank,
      icon: Icons.crop_landscape,
    ),
    // 等高線（標高タイルからアプリ内で作る。`contour_tiles.dart`）。他の背景地図と重ねて使う（高度な設定）。
    // 内部では生成プロバイダ（BaseMapType.generated）だが、一覧では普通の背景地図として振る舞う（松本 2026-09-13）
    BaseMapProvider(
      id: 'contours',
      cacheId: 'contours_v${ContourTiles.version}', // 絵を変えたら版が上がり、古いキャッシュは `BaseMapService` が消す
      name: '等高線',
      description: '標高タイルから作る等高線（他の地図と重ねて使う）',
      urlTemplate: '',
      minZoom: 9,
      maxZoom: 19,
      attribution: '',
      type: BaseMapType.generated,
      icon: Icons.stacked_line_chart,
    ),
  ];

  /// タイルキャッシュの名前（[cacheId]）から。キャッシュ一覧の表示用。版の古い生成プロバイダのキャッシュは null
  static BaseMapProvider? getProviderByCacheId(String cacheId) {
    for (final p in availableProviders) {
      if (p.cacheId == cacheId) return p;
    }
    return null;
  }

  /// IDから背景地図プロバイダーを取得
  static BaseMapProvider? getProviderById(String id) {
    try {
      return availableProviders.firstWhere((provider) => provider.id == id);
    } catch (e) {
      return null;
    }
  }

  /// デフォルトの背景地図プロバイダー（国土地理院 標準地図）
  ///
  /// OSMを既定にしない: タイル利用ポリシー上、配布アプリの既定として
  /// community運営サーバへ全ユーザーのトラフィックを向けるのは避ける
  /// （2026-08-28 変更。OSMは選択肢としては残る）。
  static BaseMapProvider get defaultProvider =>
      availableProviders.firstWhere((p) => p.id == 'gsi_std');

  /// 国土地理院地図のプロバイダーのみを取得
  static List<BaseMapProvider> get gsiProviders =>
      availableProviders
          .where(
            (provider) =>
                provider.type.toString().startsWith('BaseMapType.gsi'),
          )
          .toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BaseMapProvider &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'BaseMapProvider(id: $id, name: $name)';
}
