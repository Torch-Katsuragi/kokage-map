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
// Root Maps: 統合EPSG座標系レジストリ
// 全プロジェクトのSingle Source of Truth
// JGD2011/JGD2000平面直角座標系、UTM、WGS84を統合管理

import 'package:latlong2/latlong.dart';

/// EPSG座標系の定義
class EpsgDefinition {
  final String code;
  final String name;
  final String proj4String;
  final List<String>? prefectures; // 対応する都道府県（JGD2011用）
  final LatLngBounds? bounds; // 適用範囲（UTM用、nullなら無制限）

  const EpsgDefinition({
    required this.code,
    required this.name,
    required this.proj4String,
    this.prefectures,
    this.bounds,
  });

  /// 指定された緯度経度がこの座標系の適用範囲内か（範囲未定義なら常にtrue）
  bool contains(LatLng point) => bounds?.contains(point) ?? true;

  /// EPSGコード番号部分を取得（例: "EPSG:6677" → "6677"）
  String get codeNumber => code.replaceFirst('EPSG:', '');

  /// 数値としてのEPSGコードを取得
  int? get codeInt => int.tryParse(codeNumber);

  @override
  String toString() => '$code - $name';

  /// 表示用文字列（EPSGコード + 名前）
  String get displayString => '$codeNumber $name';
}

/// 緯度経度の範囲
class LatLngBounds {
  final LatLng southwest;
  final LatLng northeast;

  const LatLngBounds(this.southwest, this.northeast);

  bool contains(LatLng point) {
    return point.latitude >= southwest.latitude &&
        point.latitude <= northeast.latitude &&
        point.longitude >= southwest.longitude &&
        point.longitude <= northeast.longitude;
  }
}

/// 統合EPSG座標系レジストリ（シングルトン）
class EpsgRegistry {
  static final EpsgRegistry instance = EpsgRegistry._internal();
  factory EpsgRegistry() => instance;
  EpsgRegistry._internal();

  /// 動的に登録された定義（実行時にGPKGやepsg.ioから解決されたもの）
  final List<EpsgDefinition> _dynamicDefinitions = [];

  /// 全EPSG定義のリスト（静的 + 動的）
  List<EpsgDefinition> get allDefinitions => [..._allDefinitions, ..._dynamicDefinitions];

  /// WGS84以外のEPSG定義（座標変換用、WGS84は変換先として不要）
  List<EpsgDefinition> get transformableDefinitions =>
      _allDefinitions.where((e) => e.code != 'EPSG:4326' && e.code != 'EPSG:6668').toList();

  /// EPSGコードで検索（静的 + 動的定義を探索）
  EpsgDefinition? getByCode(String code) {
    final normalizedCode = code.startsWith('EPSG:') ? code : 'EPSG:$code';
    // まず静的定義を検索
    final staticResult = _allDefinitions.cast<EpsgDefinition?>().firstWhere(
      (e) => e?.code == normalizedCode,
      orElse: () => null,
    );
    if (staticResult != null) return staticResult;

    // 動的定義を検索
    return _dynamicDefinitions.cast<EpsgDefinition?>().firstWhere(
      (e) => e?.code == normalizedCode,
      orElse: () => null,
    );
  }

  /// 動的にEPSG定義を登録（GPKGやepsg.ioから取得した定義）
  /// 既に同じコードが登録済みの場合はスキップ
  void registerDynamic(EpsgDefinition definition) {
    if (getByCode(definition.code) == null) {
      _dynamicDefinitions.add(definition);
    }
  }

  /// 動的定義をクリア
  void clearDynamic() => _dynamicDefinitions.clear();

  /// クエリで検索（コード、名前、地域名で部分一致）
  List<EpsgDefinition> search(String query) {
    if (query.isEmpty) return transformableDefinitions;
    
    final lowerQuery = query.toLowerCase();
    return _allDefinitions.where((epsg) {
      // WGS84系は検索結果から除外（変換先としては不要）
      if (epsg.code == 'EPSG:4326' || epsg.code == 'EPSG:6668') return false;
      
      return epsg.codeNumber.contains(lowerQuery) ||
          epsg.name.toLowerCase().contains(lowerQuery) ||
          (epsg.prefectures?.any((p) => p.contains(query)) ?? false);
    }).toList();
  }

  /// 都道府県からJGD2011座標系を取得
  EpsgDefinition? getJgd2011FromPrefecture(String prefecture) {
    // 都道府県名を正規化（「県」「府」「都」「道」を含めて検索）
    final normalizedPref = prefecture.replaceAll(RegExp(r'[県府都道]$'), '');
    
    for (final epsg in _jgd2011Definitions) {
      if (epsg.prefectures?.any((p) => p.contains(normalizedPref)) ?? false) {
        return epsg;
      }
    }
    return null;
  }

  /// 軸入れ替えが必要か判定（日本の平面直角座標系）
  /// JGD2011/JGD2000では X=Northing, Y=Easting のため軸入れ替えが必要
  bool needsAxisSwap(String epsgCode) {
    final code = int.tryParse(epsgCode.replaceFirst('EPSG:', '')) ?? 0;
    // JGD2011 平面直角座標系 I-XIX系 (EPSG:6669-6687)
    if (code >= 6669 && code <= 6687) return true;
    // JGD2000 平面直角座標系 I-XIX系 (EPSG:2443-2461)
    if (code >= 2443 && code <= 2461) return true;
    return false;
  }

  /// 緯度経度からUTMゾーン番号を計算
  int calculateUtmZone(double longitude) => ((longitude + 180) / 6).floor() + 1;

  /// 緯度経度から最適なUTM座標系を取得
  EpsgDefinition getUtmZone(LatLng point) =>
      getUtmZoneDefinition(calculateUtmZone(point.longitude));

  /// UTMゾーン番号（1-60、北半球）からEPSG定義を取得
  /// レジストリ未登録のゾーンは動的に生成する
  EpsgDefinition getUtmZoneDefinition(int zone) {
    final epsgCode = 'EPSG:326${zone.toString().padLeft(2, '0')}';
    return getByCode(epsgCode) ??
        EpsgDefinition(
          code: epsgCode,
          name: 'WGS 84 / UTM zone ${zone}N',
          proj4String: '+proj=utm +zone=$zone +datum=WGS84 +units=m +no_defs',
          bounds: utmNorthBounds(zone),
        );
  }

  /// UTM北半球ゾーンの適用範囲（経度6度幅、緯度0〜84度）
  static LatLngBounds utmNorthBounds(int zone) => LatLngBounds(
        LatLng(0, (zone * 6 - 186).toDouble()),
        LatLng(84, (zone * 6 - 180).toDouble()),
      );

  // ========== JGD2011 平面直角座標系（全19系）==========

  static const List<EpsgDefinition> _jgd2011Definitions = [
    EpsgDefinition(
      code: 'EPSG:6669',
      name: 'JGD2011 / 平面直角 I系 (長崎・佐賀)',
      proj4String: '+proj=tmerc +lat_0=33 +lon_0=129.5 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['長崎県', '佐賀県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6670',
      name: 'JGD2011 / 平面直角 II系 (福岡・熊本・大分・宮崎・鹿児島)',
      proj4String: '+proj=tmerc +lat_0=33 +lon_0=131 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['福岡県', '熊本県', '大分県', '宮崎県', '鹿児島県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6671',
      name: 'JGD2011 / 平面直角 III系 (山口・島根・広島)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=132.166666666667 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['山口県', '島根県', '広島県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6672',
      name: 'JGD2011 / 平面直角 IV系 (香川・愛媛・徳島・高知)',
      proj4String: '+proj=tmerc +lat_0=33 +lon_0=133.5 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['香川県', '愛媛県', '徳島県', '高知県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6673',
      name: 'JGD2011 / 平面直角 V系 (兵庫・鳥取・岡山)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=134.333333333333 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['兵庫県', '鳥取県', '岡山県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6674',
      name: 'JGD2011 / 平面直角 VI系 (京都・大阪・福井・滋賀・三重・奈良・和歌山)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=136 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['京都府', '大阪府', '福井県', '滋賀県', '三重県', '奈良県', '和歌山県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6675',
      name: 'JGD2011 / 平面直角 VII系 (石川・富山・岐阜・愛知)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=137.166666666667 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['石川県', '富山県', '岐阜県', '愛知県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6676',
      name: 'JGD2011 / 平面直角 VIII系 (新潟・長野・山梨・静岡)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=138.5 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['新潟県', '長野県', '山梨県', '静岡県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6677',
      name: 'JGD2011 / 平面直角 IX系 (東京・福島・栃木・茨城・埼玉・千葉・群馬・神奈川)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=139.833333333333 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['東京都', '福島県', '栃木県', '茨城県', '埼玉県', '千葉県', '群馬県', '神奈川県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6678',
      name: 'JGD2011 / 平面直角 X系 (青森・秋田・山形・岩手・宮城)',
      proj4String: '+proj=tmerc +lat_0=40 +lon_0=140.833333333333 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['青森県', '秋田県', '山形県', '岩手県', '宮城県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6679',
      name: 'JGD2011 / 平面直角 XI系 (北海道西部)',
      proj4String: '+proj=tmerc +lat_0=44 +lon_0=140.25 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['北海道'],
    ),
    EpsgDefinition(
      code: 'EPSG:6680',
      name: 'JGD2011 / 平面直角 XII系 (北海道中央部)',
      proj4String: '+proj=tmerc +lat_0=44 +lon_0=142.25 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['北海道'],
    ),
    EpsgDefinition(
      code: 'EPSG:6681',
      name: 'JGD2011 / 平面直角 XIII系 (北海道東部)',
      proj4String: '+proj=tmerc +lat_0=44 +lon_0=144.25 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['北海道'],
    ),
    EpsgDefinition(
      code: 'EPSG:6682',
      name: 'JGD2011 / 平面直角 XIV系 (東京都・島しょ部)',
      proj4String: '+proj=tmerc +lat_0=26 +lon_0=142 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['東京都'],
    ),
    EpsgDefinition(
      code: 'EPSG:6683',
      name: 'JGD2011 / 平面直角 XV系 (沖縄本島)',
      proj4String: '+proj=tmerc +lat_0=26 +lon_0=127.5 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['沖縄県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6684',
      name: 'JGD2011 / 平面直角 XVI系 (沖縄・宮古島)',
      proj4String: '+proj=tmerc +lat_0=26 +lon_0=124 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['沖縄県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6685',
      name: 'JGD2011 / 平面直角 XVII系 (沖縄・石垣島)',
      proj4String: '+proj=tmerc +lat_0=26 +lon_0=131 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['沖縄県'],
    ),
    EpsgDefinition(
      code: 'EPSG:6686',
      name: 'JGD2011 / 平面直角 XVIII系 (小笠原諸島)',
      proj4String: '+proj=tmerc +lat_0=20 +lon_0=136 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['東京都'],
    ),
    EpsgDefinition(
      code: 'EPSG:6687',
      name: 'JGD2011 / 平面直角 XIX系 (南鳥島)',
      proj4String: '+proj=tmerc +lat_0=26 +lon_0=154 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['東京都'],
    ),
  ];

  // ========== JGD2000 平面直角座標系（互換性用、主要10系）==========

  static const List<EpsgDefinition> _jgd2000Definitions = [
    EpsgDefinition(
      code: 'EPSG:2443',
      name: 'JGD2000 / 平面直角 I系 (長崎・佐賀)',
      proj4String: '+proj=tmerc +lat_0=33 +lon_0=129.5 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['長崎県', '佐賀県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2444',
      name: 'JGD2000 / 平面直角 II系 (福岡・熊本・大分・宮崎・鹿児島)',
      proj4String: '+proj=tmerc +lat_0=33 +lon_0=131 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['福岡県', '熊本県', '大分県', '宮崎県', '鹿児島県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2445',
      name: 'JGD2000 / 平面直角 III系 (山口・島根・広島)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=132.166666666667 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['山口県', '島根県', '広島県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2446',
      name: 'JGD2000 / 平面直角 IV系 (香川・愛媛・徳島・高知)',
      proj4String: '+proj=tmerc +lat_0=33 +lon_0=133.5 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['香川県', '愛媛県', '徳島県', '高知県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2447',
      name: 'JGD2000 / 平面直角 V系 (兵庫・鳥取・岡山)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=134.333333333333 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['兵庫県', '鳥取県', '岡山県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2448',
      name: 'JGD2000 / 平面直角 VI系 (京都・大阪・福井・滋賀・三重・奈良・和歌山)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=136 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['京都府', '大阪府', '福井県', '滋賀県', '三重県', '奈良県', '和歌山県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2449',
      name: 'JGD2000 / 平面直角 VII系 (石川・富山・岐阜・愛知)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=137.166666666667 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['石川県', '富山県', '岐阜県', '愛知県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2450',
      name: 'JGD2000 / 平面直角 VIII系 (新潟・長野・山梨・静岡)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=138.5 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['新潟県', '長野県', '山梨県', '静岡県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2451',
      name: 'JGD2000 / 平面直角 IX系 (東京・福島・栃木・茨城・埼玉・千葉・群馬・神奈川)',
      proj4String: '+proj=tmerc +lat_0=36 +lon_0=139.833333333333 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['東京都', '福島県', '栃木県', '茨城県', '埼玉県', '千葉県', '群馬県', '神奈川県'],
    ),
    EpsgDefinition(
      code: 'EPSG:2452',
      name: 'JGD2000 / 平面直角 X系 (青森・秋田・山形・岩手・宮城)',
      proj4String: '+proj=tmerc +lat_0=40 +lon_0=140.833333333333 +k=0.9999 +x_0=0 +y_0=0 +ellps=GRS80 +units=m +no_defs',
      prefectures: ['青森県', '秋田県', '山形県', '岩手県', '宮城県'],
    ),
  ];

  // ========== UTM座標系（日本周辺）==========

  static const List<EpsgDefinition> _utmDefinitions = [
    EpsgDefinition(
      code: 'EPSG:32651',
      name: 'WGS 84 / UTM zone 51N (九州西部)',
      proj4String: '+proj=utm +zone=51 +datum=WGS84 +units=m +no_defs',
      bounds: LatLngBounds(LatLng(0, 120), LatLng(84, 126)),
    ),
    EpsgDefinition(
      code: 'EPSG:32652',
      name: 'WGS 84 / UTM zone 52N (九州・四国)',
      proj4String: '+proj=utm +zone=52 +datum=WGS84 +units=m +no_defs',
      bounds: LatLngBounds(LatLng(0, 126), LatLng(84, 132)),
    ),
    EpsgDefinition(
      code: 'EPSG:32653',
      name: 'WGS 84 / UTM zone 53N (本州西部)',
      proj4String: '+proj=utm +zone=53 +datum=WGS84 +units=m +no_defs',
      bounds: LatLngBounds(LatLng(0, 132), LatLng(84, 138)),
    ),
    EpsgDefinition(
      code: 'EPSG:32654',
      name: 'WGS 84 / UTM zone 54N (本州中部・東部)',
      proj4String: '+proj=utm +zone=54 +datum=WGS84 +units=m +no_defs',
      bounds: LatLngBounds(LatLng(0, 138), LatLng(84, 144)),
    ),
    EpsgDefinition(
      code: 'EPSG:32655',
      name: 'WGS 84 / UTM zone 55N (北海道・東北)',
      proj4String: '+proj=utm +zone=55 +datum=WGS84 +units=m +no_defs',
      bounds: LatLngBounds(LatLng(0, 144), LatLng(84, 150)),
    ),
    EpsgDefinition(
      code: 'EPSG:32656',
      name: 'WGS 84 / UTM zone 56N (千島列島)',
      proj4String: '+proj=utm +zone=56 +datum=WGS84 +units=m +no_defs',
      bounds: LatLngBounds(LatLng(0, 150), LatLng(84, 156)),
    ),
  ];

  // ========== 地理座標系 ==========

  static const List<EpsgDefinition> _geographicDefinitions = [
    EpsgDefinition(
      code: 'EPSG:4326',
      name: 'WGS 84 (GPS/Webマップ標準)',
      proj4String: '+proj=longlat +datum=WGS84 +no_defs',
    ),
    EpsgDefinition(
      code: 'EPSG:3857',
      name: 'Web Mercator (Google Maps等)',
      proj4String: '+proj=merc +a=6378137 +b=6378137 +lat_ts=0 +lon_0=0 +x_0=0 +y_0=0 +k=1 +units=m +nadgrids=@null +wktext +no_defs',
    ),
    EpsgDefinition(
      code: 'EPSG:6668',
      name: 'JGD2011 地理座標系',
      proj4String: '+proj=longlat +ellps=GRS80 +no_defs',
    ),
  ];

  // ========== 全定義の統合リスト ==========

  static final List<EpsgDefinition> _allDefinitions = [
    ..._geographicDefinitions,
    ..._jgd2011Definitions,
    ..._jgd2000Definitions,
    ..._utmDefinitions,
  ];

  // ========== WKT文字列生成（PRJファイル用）==========

  /// EPSGコードからESRI互換WKT文字列を取得
  /// Shapefileの.prjファイル出力用
  String? getWktString(String epsgCode) {
    final normalizedCode = epsgCode.startsWith('EPSG:') ? epsgCode : 'EPSG:$epsgCode';
    return _wktDefinitions[normalizedCode];
  }

  /// WKT文字列の定義マップ
  static const Map<String, String> _wktDefinitions = {
    // WGS84
    'EPSG:4326': 'GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]]',

    // Web Mercator
    'EPSG:3857': 'PROJCS["WGS_1984_Web_Mercator_Auxiliary_Sphere",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Mercator_Auxiliary_Sphere"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",0.0],PARAMETER["Standard_Parallel_1",0.0],PARAMETER["Auxiliary_Sphere_Type",0.0],UNIT["Meter",1.0]]',

    // JGD2011 平面直角座標系 I〜XIX系
    'EPSG:6669': 'PROJCS["JGD2011 / Japan Plane Rectangular CS I",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",129.5],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",33.0],UNIT["Meter",1.0]]',
    'EPSG:6670': 'PROJCS["JGD2011 / Japan Plane Rectangular CS II",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",131.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",33.0],UNIT["Meter",1.0]]',
    'EPSG:6671': 'PROJCS["JGD2011 / Japan Plane Rectangular CS III",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",132.166666666667],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:6672': 'PROJCS["JGD2011 / Japan Plane Rectangular CS IV",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",133.5],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",33.0],UNIT["Meter",1.0]]',
    'EPSG:6673': 'PROJCS["JGD2011 / Japan Plane Rectangular CS V",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",134.333333333333],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:6674': 'PROJCS["JGD2011 / Japan Plane Rectangular CS VI",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",136.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:6675': 'PROJCS["JGD2011 / Japan Plane Rectangular CS VII",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",137.166666666667],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:6676': 'PROJCS["JGD2011 / Japan Plane Rectangular CS VIII",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",138.5],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:6677': 'PROJCS["JGD2011 / Japan Plane Rectangular CS IX",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",139.833333333333],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:6678': 'PROJCS["JGD2011 / Japan Plane Rectangular CS X",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",140.833333333333],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",40.0],UNIT["Meter",1.0]]',
    'EPSG:6679': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XI",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",140.25],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",44.0],UNIT["Meter",1.0]]',
    'EPSG:6680': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XII",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",142.25],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",44.0],UNIT["Meter",1.0]]',
    'EPSG:6681': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XIII",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",144.25],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",44.0],UNIT["Meter",1.0]]',
    'EPSG:6682': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XIV",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",142.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",26.0],UNIT["Meter",1.0]]',
    'EPSG:6683': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XV",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",127.5],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",26.0],UNIT["Meter",1.0]]',
    'EPSG:6684': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XVI",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",124.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",26.0],UNIT["Meter",1.0]]',
    'EPSG:6685': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XVII",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",131.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",26.0],UNIT["Meter",1.0]]',
    'EPSG:6686': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XVIII",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",136.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",20.0],UNIT["Meter",1.0]]',
    'EPSG:6687': 'PROJCS["JGD2011 / Japan Plane Rectangular CS XIX",GEOGCS["JGD2011",DATUM["Japanese_Geodetic_Datum_2011",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",154.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",26.0],UNIT["Meter",1.0]]',

    // JGD2000 平面直角座標系 I〜X系（主要10系）
    'EPSG:2443': 'PROJCS["JGD2000 / Japan Plane Rectangular CS I",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",129.5],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",33.0],UNIT["Meter",1.0]]',
    'EPSG:2444': 'PROJCS["JGD2000 / Japan Plane Rectangular CS II",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",131.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",33.0],UNIT["Meter",1.0]]',
    'EPSG:2445': 'PROJCS["JGD2000 / Japan Plane Rectangular CS III",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",132.166666666667],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:2446': 'PROJCS["JGD2000 / Japan Plane Rectangular CS IV",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",133.5],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",33.0],UNIT["Meter",1.0]]',
    'EPSG:2447': 'PROJCS["JGD2000 / Japan Plane Rectangular CS V",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",134.333333333333],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:2448': 'PROJCS["JGD2000 / Japan Plane Rectangular CS VI",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",136.0],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:2449': 'PROJCS["JGD2000 / Japan Plane Rectangular CS VII",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",137.166666666667],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:2450': 'PROJCS["JGD2000 / Japan Plane Rectangular CS VIII",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",138.5],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:2451': 'PROJCS["JGD2000 / Japan Plane Rectangular CS IX",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",139.833333333333],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",36.0],UNIT["Meter",1.0]]',
    'EPSG:2452': 'PROJCS["JGD2000 / Japan Plane Rectangular CS X",GEOGCS["JGD2000",DATUM["Japanese_Geodetic_Datum_2000",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",140.833333333333],PARAMETER["Scale_Factor",0.9999],PARAMETER["Latitude_Of_Origin",40.0],UNIT["Meter",1.0]]',

    // UTM座標系（日本周辺）
    'EPSG:32651': 'PROJCS["WGS 84 / UTM zone 51N",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",123],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",0],UNIT["metre",1]]',
    'EPSG:32652': 'PROJCS["WGS 84 / UTM zone 52N",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",129],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",0],UNIT["metre",1]]',
    'EPSG:32653': 'PROJCS["WGS 84 / UTM zone 53N",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",135],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",0],UNIT["metre",1]]',
    'EPSG:32654': 'PROJCS["WGS 84 / UTM zone 54N",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",141],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",0],UNIT["metre",1]]',
    'EPSG:32655': 'PROJCS["WGS 84 / UTM zone 55N",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",147],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",0],UNIT["metre",1]]',
    'EPSG:32656': 'PROJCS["WGS 84 / UTM zone 56N",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",153],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",0],UNIT["metre",1]]',
  };
}
