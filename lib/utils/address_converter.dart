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
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

/// 住所情報を表すクラス
class Address {
  final String displayName;
  final String? houseNumber;
  final String? road;
  final String? suburb;
  final String? city;
  final String? county;
  final String? state;
  final String? postcode;
  final String? country;
  final String? countryCode;

  Address({
    required this.displayName,
    this.houseNumber,
    this.road,
    this.suburb,
    this.city,
    this.county,
    this.state,
    this.postcode,
    this.country,
    this.countryCode,
  });

  factory Address.fromJson(Map<String, dynamic> json) {
    final address = json['address'] as Map<String, dynamic>?;

    // 日本の場合、都道府県情報は複数のフィールドに格納される可能性がある
    String? state = address?['state'] as String?;
    state ??= address?['province'] as String?;
    state ??= address?['region'] as String?;
    state ??= address?['administrative'] as String?;

    AppLogger.debug('[Address] 住所フィールド詳細: ${address?.keys.toList()}');
    AppLogger.debug(
      '[Address] state候補: state=${address?['state']}, province=${address?['province']}, region=${address?['region']}',
    );

    return Address(
      displayName: json['display_name'] as String,
      houseNumber: address?['house_number'] as String?,
      road: address?['road'] as String?,
      suburb: address?['suburb'] as String?,
      city: address?['city'] as String?,
      county: address?['county'] as String?,
      state: state,
      postcode: address?['postcode'] as String?,
      country: address?['country'] as String?,
      countryCode: address?['country_code'] as String?,
    );
  }

  @override
  String toString() {
    return displayName;
  }
}

/// 住所変換を管理するクラス
class AddressConverter {
  /// 緯度経度から住所を取得
  static Future<Address?> getAddressFromLatLng(LatLng point) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?'
        'lat=${point.latitude}&'
        'lon=${point.longitude}&'
        'format=json&'
        'addressdetails=1',
      );

      final response = await http.get(
        url,
        headers: {
          'User-Agent': 'K_Maps/1.0', // アプリケーション名を指定
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        AppLogger.debug('Nominatim APIレスポンス: ${json.encode(data)}');
        final address = Address.fromJson(data);
        AppLogger.debug('住所取得成功: ${address.displayName}');
        return address;
      } else {
        AppLogger.debug('住所取得エラー: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      AppLogger.debug('住所取得エラー: $e');
      return null;
    }
  }

  /// 住所から緯度経度を取得
  static Future<LatLng?> getLatLngFromAddress(String address) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?'
        'q=${Uri.encodeComponent(address)}&'
        'format=json&'
        'limit=1',
      );

      final response = await http.get(
        url,
        headers: {
          'User-Agent': 'K_Maps/1.0', // アプリケーション名を指定
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as List;
        if (data.isNotEmpty) {
          final result = data.first;
          return LatLng(
            double.parse(result['lat']),
            double.parse(result['lon']),
          );
        }
      }
      return null;
    } catch (e) {
      AppLogger.debug('緯度経度取得エラー: $e');
      return null;
    }
  }
}

