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
// Root Maps: 統合座標変換サービス
// EpsgRegistryを使用した座標変換機能を提供
// WGS84 ⇔ 他座標系の変換、住所ベースの座標系自動判定、都道府県名抽出

import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart';

import '../../utils/address_converter.dart';
import '../../utils/app_logger.dart';
import 'epsg_registry.dart';

/// 統合座標変換サービス（シングルトン）
class CoordinateService {
  static final CoordinateService instance = CoordinateService._internal();
  factory CoordinateService() => instance;
  CoordinateService._internal();

  /// Projectionキャッシュ
  final Map<String, Projection> _projectionCache = {};

  /// EPSGレジストリへの参照
  EpsgRegistry get registry => EpsgRegistry.instance;

  // ========== 座標変換 ==========

  /// WGS84からXY座標に変換
  /// 戻り値: {'x': double, 'y': double} または変換失敗時はnull
  Map<String, double>? transformToXY(LatLng point, EpsgDefinition epsg) {
    try {
      // WGS84の場合はそのまま緯度経度を返す
      if (epsg.code == 'EPSG:4326' || epsg.code == 'EPSG:6668') {
        return {'x': point.longitude, 'y': point.latitude};
      }

      final wgs84 = _getOrCreateProjection('EPSG:4326', '+proj=longlat +datum=WGS84 +no_defs');
      final target = _getOrCreateProjection(epsg.code, epsg.proj4String);

      if (wgs84 == null || target == null) {
        AppLogger.debug('[CoordinateService] Projection作成失敗: ${epsg.code}');
        return null;
      }

      final p = Point(x: point.longitude, y: point.latitude);
      final result = wgs84.transform(target, p);

      // 日本の平面直角座標系は軸入れ替えが必要
      if (registry.needsAxisSwap(epsg.code)) {
        return {'x': result.y, 'y': result.x};
      }

      return {'x': result.x, 'y': result.y};
    } catch (e) {
      AppLogger.debug('[CoordinateService] 座標変換エラー: $e');
      return null;
    }
  }

  /// WGS84からXY座標に変換（フォーマット済み文字列）
  Map<String, String> transformToXYFormatted(LatLng point, EpsgDefinition epsg, {int decimals = 3}) {
    final xy = transformToXY(point, epsg);
    if (xy == null) {
      return {'x': 'Error', 'y': 'Error'};
    }

    // WGS84の場合は小数点以下6桁
    final d = (epsg.code == 'EPSG:4326' || epsg.code == 'EPSG:6668') ? 6 : decimals;
    return {
      'x': xy['x']!.toStringAsFixed(d),
      'y': xy['y']!.toStringAsFixed(d),
    };
  }

  /// XY座標からWGS84に変換
  LatLng? transformToLatLng(double x, double y, EpsgDefinition epsg) {
    try {
      // WGS84の場合はそのまま返す
      if (epsg.code == 'EPSG:4326' || epsg.code == 'EPSG:6668') {
        return LatLng(y, x);
      }

      final source = _getOrCreateProjection(epsg.code, epsg.proj4String);
      final wgs84 = _getOrCreateProjection('EPSG:4326', '+proj=longlat +datum=WGS84 +no_defs');

      if (source == null || wgs84 == null) {
        AppLogger.debug('[CoordinateService] Projection作成失敗: ${epsg.code}');
        return null;
      }

      // 日本の平面直角座標系は軸入れ替えが必要（逆変換時は逆に）
      final px = registry.needsAxisSwap(epsg.code) ? y : x;
      final py = registry.needsAxisSwap(epsg.code) ? x : y;

      final p = Point(x: px, y: py);
      final result = source.transform(wgs84, p);

      return LatLng(result.y, result.x);
    } catch (e) {
      AppLogger.debug('[CoordinateService] 逆変換エラー: $e');
      return null;
    }
  }

  // ========== 座標系自動判定 ==========

  /// 緯度経度から最適な座標系を取得（住所ベース）
  /// 日本国内ならJGD2011、海外ならUTMを返す
  Future<EpsgDefinition?> getBestCoordinateSystem(LatLng point, {String? cachedState}) async {
    try {
      // キャッシュされた都道府県情報がある場合
      if (cachedState != null) {
        final jgd2011 = registry.getJgd2011FromPrefecture(cachedState);
        if (jgd2011 != null) {
          AppLogger.debug('[CoordinateService] キャッシュから座標系取得: ${jgd2011.code}');
          return jgd2011;
        }
      }

      // 住所を取得して座標系を判定
      final address = await AddressConverter.getAddressFromLatLng(point);
      if (address != null) {
        final state = address.state ?? extractPrefecture(address.displayName);
        if (state != null) {
          final jgd2011 = registry.getJgd2011FromPrefecture(state);
          if (jgd2011 != null) {
            AppLogger.debug('[CoordinateService] 住所から座標系取得: ${jgd2011.code}');
            return jgd2011;
          }
        }
      }

      // フォールバック: UTM座標系
      final utmZone = registry.getUtmZone(point);
      AppLogger.debug('[CoordinateService] フォールバック: ${utmZone.code}');
      return utmZone;
    } catch (e) {
      AppLogger.debug('[CoordinateService] 座標系判定エラー: $e');
      return null;
    }
  }

  /// 都道府県名からJGD2011座標系を取得（同期版）
  EpsgDefinition? getJgd2011FromPrefecture(String prefecture) {
    return registry.getJgd2011FromPrefecture(prefecture);
  }

  // ========== 都道府県抽出 ==========

  /// 都道府県名の一覧（住所文字列からの抽出用）
  static const List<String> prefectureNames = [
    '北海道', '青森県', '岩手県', '宮城県', '秋田県', '山形県', '福島県',
    '茨城県', '栃木県', '群馬県', '埼玉県', '千葉県', '東京都', '神奈川県',
    '新潟県', '富山県', '石川県', '福井県', '山梨県', '長野県',
    '岐阜県', '静岡県', '愛知県', '三重県',
    '滋賀県', '京都府', '大阪府', '兵庫県', '奈良県', '和歌山県',
    '鳥取県', '島根県', '岡山県', '広島県', '山口県',
    '徳島県', '香川県', '愛媛県', '高知県',
    '福岡県', '佐賀県', '長崎県', '熊本県', '大分県', '宮崎県', '鹿児島県', '沖縄県',
  ];

  /// 住所文字列から都道府県名を抽出（最初に一致したものを返す、なければnull）
  static String? extractPrefecture(String text) {
    for (final prefecture in prefectureNames) {
      if (text.contains(prefecture)) {
        return prefecture;
      }
    }
    return null;
  }

  // ========== 内部ヘルパー ==========

  /// Projectionを取得または作成（キャッシュ付き）
  Projection? _getOrCreateProjection(String code, String proj4String) {
    if (_projectionCache.containsKey(code)) {
      return _projectionCache[code];
    }

    try {
      // まず既存のProjectionを確認、なければ新規作成
      final proj = Projection.get(code) ?? Projection.add(code, proj4String);
      _projectionCache[code] = proj;
      return proj;
    } catch (e) {
      AppLogger.debug('[CoordinateService] Projection作成エラー ($code): $e');
      return null;
    }
  }

  /// キャッシュをクリア
  void clearCache() {
    _projectionCache.clear();
  }
}
