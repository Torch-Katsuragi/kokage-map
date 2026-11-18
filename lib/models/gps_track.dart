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
// GPS / 外部GNSS 追跡の位置情報ポイント
import 'package:latlong2/latlong.dart';

/// GPS / 外部GNSS 軌跡の1つの測位ポイント
class GpsTrackPoint {
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? accuracy;
  final String? accuracySource;
  final double? speed;
  final double? bearing;
  final DateTime timestamp;
  final String sourceType; // 'GPS' または 'GNSS'

  // 外部GNSS詳細テレメトリ（GNSS軌跡 `gnss_track_details` 用）
  final int? gpsQuality;
  final String? fixType;
  final String? correctionSource;
  final int? satelliteCount;
  final double? hdop;
  final double? pdop;
  final double? vdop;
  final String? gnssDevice;
  final String? ntripMountpoint;
  final String? rawGga;

  GpsTrackPoint({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
    this.accuracySource,
    this.speed,
    this.bearing,
    required this.timestamp,
    required this.sourceType,
    this.gpsQuality,
    this.fixType,
    this.correctionSource,
    this.satelliteCount,
    this.hdop,
    this.pdop,
    this.vdop,
    this.gnssDevice,
    this.ntripMountpoint,
    this.rawGga,
  });

  /// LatLng形式に変換
  LatLng toLatLng() => LatLng(latitude, longitude);
}
