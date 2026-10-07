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
/// GPS の今の状態（[GpsManagerService.currentInfo] が返す）と、長押し測量で集める 1 点
library;

import 'package:flutter/foundation.dart';

import '../i18n/strings.g.dart';

/// GPS データソースの種類
enum GpsSourceType {
  internal('GPS'),
  external('GNSS');

  const GpsSourceType(this.sourceCode);

  final String sourceCode;

  String get displayName => switch (this) {
    GpsSourceType.internal => t.gps.internalGpsName,
    GpsSourceType.external => t.gps.externalGnssName,
  };
}

/// GPS の今の状態。衛星数・DOP・補正の種類などは外部 GNSS のときだけ入る
@immutable
class GpsInfo {
  const GpsInfo({
    required this.sourceType,
    this.selectedDevice,
    this.latitude,
    this.longitude,
    this.altitude,
    this.accuracy,
    this.speed,
    this.bearing,
    this.timestamp,
    this.isGpsActive = false,
    this.isInitialized = false,
    this.isSurveyMode = false,
    this.usesForegroundService = false,
    this.satelliteCount,
    this.hdop,
    this.pdop,
    this.vdop,
    this.gpsQuality,
    this.fixType,
    this.correctionSource,
    this.nmea,
  });

  final GpsSourceType sourceType;

  /// 外部 GNSS 機器の名前
  final String? selectedDevice;

  final double? latitude;
  final double? longitude;
  final double? altitude;
  final double? accuracy;
  final double? speed;
  final double? bearing;
  final DateTime? timestamp;

  final bool isGpsActive;
  final bool isInitialized;
  final bool isSurveyMode;
  final bool usesForegroundService;

  final int? satelliteCount;
  final double? hdop;
  final double? pdop;
  final double? vdop;
  final int? gpsQuality;
  final String? fixType;
  final String? correctionSource;

  /// 直近の NMEA 文（測量で記録するときだけ入れる）
  final String? nmea;

  String get sourceName => sourceType.displayName;

  /// 位置が取れていて、GPS も動いている
  bool get isActive => latitude != null && longitude != null && isGpsActive;

  bool get isExternal => sourceType == GpsSourceType.external;

  /// 表示に関わる値が同じか（時刻と NMEA は見ない）
  bool sameDisplayAs(GpsInfo other) =>
      latitude == other.latitude &&
      longitude == other.longitude &&
      altitude == other.altitude &&
      accuracy == other.accuracy &&
      speed == other.speed &&
      bearing == other.bearing &&
      isGpsActive == other.isGpsActive &&
      sourceType == other.sourceType &&
      selectedDevice == other.selectedDevice &&
      satelliteCount == other.satelliteCount &&
      hdop == other.hdop &&
      gpsQuality == other.gpsQuality &&
      fixType == other.fixType &&
      correctionSource == other.correctionSource &&
      isSurveyMode == other.isSurveyMode;

  /// 測量の記録に書く形（以前の `getCurrentGpsInfo()` と同じキー）
  Map<String, dynamic> toMap() => {
    'sourceType': sourceType.sourceCode,
    'sourceName': sourceName,
    'selectedDevice': selectedDevice,
    'latitude': latitude,
    'longitude': longitude,
    'altitude': altitude,
    'accuracy': accuracy,
    'speed': speed,
    'bearing': bearing,
    'timestamp': timestamp?.toIso8601String(),
    'isActive': isActive,
    'isGpsActive': isGpsActive,
    'isInitialized': isInitialized,
    'isSurveyMode': isSurveyMode,
    'usesForegroundService': usesForegroundService,
    'satelliteCount': satelliteCount,
    'hdop': hdop,
    'pdop': pdop,
    'vdop': vdop,
    'gpsQuality': gpsQuality,
    'fixType': fixType,
    'correctionSource': correctionSource,
    'nmea': nmea,
  };

  @override
  String toString() => 'GpsInfo(${toMap()..remove('nmea')})';
}

/// 長押し測量で位置が届くたびに集める 1 点
@immutable
class GpsSurveySample {
  const GpsSurveySample(this.info, this.collectedAt);

  /// 位置が届いたときの状態（位置は必ず入っている）
  final GpsInfo info;
  final DateTime collectedAt;

  /// 測量の記録（`usedGpsData`）に書く形。外部 GNSS の値は入っているものだけ書く
  Map<String, dynamic> toMap() => {
    'latitude': info.latitude,
    'longitude': info.longitude,
    'altitude': info.altitude,
    'accuracy': info.accuracy,
    'speed': info.speed,
    'bearing': info.bearing,
    'timestamp': info.timestamp?.toIso8601String(),
    'sourceType': info.sourceType.sourceCode,
    'sourceName': info.sourceName,
    'selectedDevice': info.selectedDevice,
    'collectedAt': collectedAt.toIso8601String(),
    'satelliteCount': ?info.satelliteCount,
    'hdop': ?info.hdop,
    'pdop': ?info.pdop,
    'vdop': ?info.vdop,
    'gpsQuality': ?info.gpsQuality,
    'fixType': ?info.fixType,
    'correctionSource': ?info.correctionSource,
    'nmea': ?info.nmea,
  };
}
