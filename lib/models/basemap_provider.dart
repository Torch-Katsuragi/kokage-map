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

  /// 利用者が足した XYZ タイル（任意の URL。設定画面か `.qgs` の読み戻しで足す。端末の prefs に持つ）
  custom,
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
    this.tms = false,
  }) : cacheId = cacheId ?? id;

  /// `{y}` を TMS の向き（南が 0）で数えるか。テンプレートに `{-y}` を書いた場合はこれに関係なくそこだけ南から数える
  final bool tms;

  /// 利用者が足した地図か（[BaseMapType.custom]）
  bool get isCustom => type == BaseMapType.custom;

  /// タイルの URL（[urlTemplate] の `{z}` `{x}` `{y}` `{-y}` `{bbox-epsg-3857}` を埋める）
  String tileUrl(int z, int x, int y) => expandTileUrl(urlTemplate, z, x, y, tms: tms);

  /// URL テンプレートを埋める。
  ///
  /// - `{-y}`: TMS の y（QGIS の XYZ と同じ書き方）
  /// - `{bbox-epsg-3857}`: タイルの範囲（Web メルカトルの m、`minx,miny,maxx,maxy`）。WMS の GetMap をタイルとして引くとき用
  ///   （MapLibre と同じ書き方）
  static String expandTileUrl(String template, int z, int x, int y, {bool tms = false}) {
    final n = 1 << z;
    final flipped = n - 1 - y;
    var s = template
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{-y}', '$flipped')
        .replaceAll('{y}', '${tms ? flipped : y}');
    if (s.contains('{bbox-epsg-3857}')) {
      const half = 20037508.342789244; // 赤道の半周（m）
      final size = 2 * half / n;
      String f(double v) => v.toStringAsFixed(3);
      final minX = -half + x * size;
      final maxY = half - y * size;
      s = s.replaceAll('{bbox-epsg-3857}', '${f(minX)},${f(maxY - size)},${f(minX + size)},${f(maxY)}');
    }
    return s;
  }

  /// URL テンプレートとして使えるか（http(s) で、`{z}` `{x}` と `{y}`/`{-y}`、または `{bbox-epsg-3857}` を持つ）
  static bool isValidTemplate(String url) {
    final u = url.trim();
    if (!RegExp('^https?://[^/]+', caseSensitive: false).hasMatch(u)) return false;
    if (u.contains('{bbox-epsg-3857}')) return true;
    return u.contains('{z}') && u.contains('{x}') && (u.contains('{y}') || u.contains('{-y}'));
  }

  /// 配布アプリからの利用を規約で禁じているタイル（QGIS でよく敷かれる Google・Bing の航空写真など）か。
  /// 利用者が足すのも `.qgs` から持ち込むのも断る
  static bool isForbiddenTileHost(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    return RegExp(r'(^|\.)(google\.[a-z.]+|googleapis\.com|gstatic\.com|virtualearth\.net|bing\.com)$').hasMatch(host);
  }

  /// 利用者が足す地図を作る。id は URL から決める（同じ URL は同じ id。キャッシュも同じものを引く）
  static BaseMapProvider custom({
    required String name,
    required String urlTemplate,
    int minZoom = 0,
    int maxZoom = 18,
    String attribution = '',
    bool tms = false,
  }) {
    final url = urlTemplate.trim();
    final lo = minZoom.clamp(0, 24);
    return BaseMapProvider(
      id: customIdFor(url, tms: tms),
      name: name.trim().isEmpty ? (Uri.tryParse(url)?.host ?? url) : name.trim(),
      description: Uri.tryParse(url)?.host ?? url,
      urlTemplate: url,
      minZoom: lo,
      maxZoom: maxZoom.clamp(lo, 24),
      attribution: attribution.trim(),
      type: BaseMapType.custom,
      icon: Icons.add_photo_alternate_outlined,
      tms: tms,
    );
  }

  /// 利用者の地図の id: `custom_` + URL（[_tileUrlKey] で揃えたもの）の FNV-1a。端末をまたいでも同じになる。
  /// ⚠ web の数は double なので、素数（2^24 + 0x193）との掛け算を 2^53 を超えない形に割って掛ける
  static String customIdFor(String url, {bool tms = false}) {
    var h = 0x811c9dc5;
    for (final c in '${_tileUrlKey(url)}${tms ? '|tms' : ''}'.codeUnits) {
      h = (h ^ c) & 0xffffffff;
      h = ((((h & 0xff) << 24) & 0xffffffff) + h * 0x193) & 0xffffffff;
    }
    return 'custom_${h.toRadixString(16).padLeft(8, '0')}';
  }

  /// prefs に書く形（利用者の地図だけ）
  Map<String, Object?> toJson() => {
        'name': name,
        'url': urlTemplate,
        'minZoom': minZoom,
        'maxZoom': maxZoom,
        'attribution': attribution,
        if (tms) 'tms': true,
      };

  static BaseMapProvider? fromJson(Map<String, Object?> j) {
    final url = j['url'];
    if (url is! String || !isValidTemplate(url)) return null;
    return custom(
      name: j['name'] as String? ?? '',
      urlTemplate: url,
      minZoom: (j['minZoom'] as num? ?? 0).toInt(),
      maxZoom: (j['maxZoom'] as num? ?? 18).toInt(),
      attribution: j['attribution'] as String? ?? '',
      tms: j['tms'] == true,
    );
  }

  // --- 利用者の地図の一覧（`BaseMapService` が prefs から読んで入れる）---
  static List<BaseMapProvider> _customProviders = const [];

  /// 利用者が足した地図（足した順）
  static List<BaseMapProvider> get customProviders => _customProviders;

  /// 利用者の地図を差し替える（`BaseMapService` から。テストからも）
  static set customProviders(List<BaseMapProvider> list) => _customProviders = List.unmodifiable(list);

  /// 組み込みと利用者の地図
  static List<BaseMapProvider> get allProviders => [...availableProviders, ..._customProviders];

  /// 組み込み → 利用者の地図の順に探す（タイルごとに呼ばれるので一覧を作らない）
  static BaseMapProvider? _find(bool Function(BaseMapProvider) test) {
    for (final p in availableProviders) {
      if (test(p)) return p;
    }
    for (final p in _customProviders) {
      if (test(p)) return p;
    }
    return null;
  }

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
    // 内部では生成プロバイダ（BaseMapType.generated）だが、一覧では普通の背景地図として振る舞う（ユーザー 2026-09-13）
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
  static BaseMapProvider? getProviderByCacheId(String cacheId) => _find((p) => p.cacheId == cacheId);

  /// IDから背景地図プロバイダーを取得
  static BaseMapProvider? getProviderById(String id) => _find((p) => p.id == id);

  /// XYZ タイルの URL テンプレートから（QGIS の XYZ レイヤの読み戻し・利用者の地図の重複の判定）。
  /// 組み込みにも利用者の地図にも無ければ null。
  ///
  /// 突き合わせは http/https、ホスト名の大小、OSM の `a.` `{s}.` などのサブドメインを無視する
  static BaseMapProvider? findByTileUrl(String url) {
    final key = _tileUrlKey(url);
    if (key.isEmpty) return null;
    return _find((p) => p.urlTemplate.isNotEmpty && _tileUrlKey(p.urlTemplate) == key);
  }

  static String _tileUrlKey(String url) {
    var s = url.trim();
    s = s.replaceFirst(RegExp('^https?://', caseSensitive: false), '');
    final slash = s.indexOf('/');
    final host = (slash < 0 ? s : s.substring(0, slash)).toLowerCase().replaceFirst(RegExp(r'^(\{s\}|[abc])\.'), '');
    return slash < 0 ? host : '$host${s.substring(slash)}';
  }

  /// デフォルトの背景地図プロバイダー（国土地理院 標準地図）
  ///
  /// OSMを既定にしない: タイル利用ポリシー上、配布アプリの既定として
  /// community運営サーバへ全ユーザーのトラフィックを向けるのは避ける
  /// （2026-08-28 変更。OSMは選択肢としては残る）。
  static BaseMapProvider get defaultProvider =>
      availableProviders.firstWhere((p) => p.id == 'gsi_std');

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
