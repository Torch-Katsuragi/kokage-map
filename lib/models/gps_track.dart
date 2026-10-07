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
// lib/models/gps_track.dart
// GPS追跡の位置情報ポイント
import 'package:latlong2/latlong.dart';

/// GPS追跡の1つの位置情報ポイント
class GpsTrackPoint {
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? accuracy;
  final double? speed;
  final double? bearing;
  final DateTime timestamp;
  final String sourceType; // 'GPS' または 'GNSS'

  GpsTrackPoint({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    this.speed,
    this.bearing,
    required this.timestamp,
    required this.sourceType,
  });

  /// LatLng形式に変換
  LatLng toLatLng() => LatLng(latitude, longitude);

  /// JSON形式に変換
  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'altitude': altitude,
    'accuracy': accuracy,
    'speed': speed,
    'bearing': bearing,
    'timestamp': timestamp.toIso8601String(),
    'sourceType': sourceType,
  };

  /// JSONから復元
  factory GpsTrackPoint.fromJson(Map<String, dynamic> json) => GpsTrackPoint(
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    altitude: (json['altitude'] as num?)?.toDouble(),
    accuracy: (json['accuracy'] as num?)?.toDouble(),
    speed: (json['speed'] as num?)?.toDouble(),
    bearing: (json['bearing'] as num?)?.toDouble(),
    timestamp: DateTime.parse(json['timestamp'] as String),
    sourceType: json['sourceType'] as String? ?? 'GPS',
  );
}
