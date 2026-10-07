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
/// GPS座標レコード（タイムスタンプ付き）
///
/// 内蔵GPS・外部GNSSの位置を型で表すモデル。
/// ForegroundServiceイベントやGeolocator Positionからの変換をサポート。
library;

import 'package:geolocator/geolocator.dart';

/// GPS座標レコード
class GpsPositionRecord {
  /// 緯度
  final double latitude;

  /// 経度
  final double longitude;

  /// 高度（メートル）
  final double? altitude;

  /// 精度（メートル）
  final double? accuracy;

  /// 速度（m/s）
  final double? speed;

  /// 方位（度）
  final double? bearing;

  /// GPS fix時刻
  final DateTime timestamp;

  const GpsPositionRecord({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    this.speed,
    this.bearing,
    required this.timestamp,
  });

  /// Geolocator Positionからの変換
  factory GpsPositionRecord.fromPosition(Position position) {
    return GpsPositionRecord(
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      accuracy: position.accuracy,
      speed: position.speed,
      bearing: position.heading,
      timestamp: position.timestamp,
    );
  }

  /// ForegroundServiceイベント(Map)からの変換
  factory GpsPositionRecord.fromServiceEvent(Map<String, dynamic> event) {
    return GpsPositionRecord(
      latitude: (event['latitude'] as num).toDouble(),
      longitude: (event['longitude'] as num).toDouble(),
      altitude: (event['altitude'] as num?)?.toDouble(),
      accuracy: (event['accuracy'] as num?)?.toDouble(),
      speed: (event['speed'] as num?)?.toDouble(),
      bearing: (event['bearing'] as num?)?.toDouble(),
      timestamp: event['timestamp'] is String
          ? DateTime.parse(event['timestamp'] as String)
          : (event['timestamp'] as DateTime?) ?? DateTime.now(),
    );
  }

  @override
  String toString() =>
      'GpsPositionRecord(lat: ${latitude.toStringAsFixed(6)}, '
      'lon: ${longitude.toStringAsFixed(6)}, '
      'acc: ${accuracy?.toStringAsFixed(1)}m, '
      'ts: $timestamp)';
}
