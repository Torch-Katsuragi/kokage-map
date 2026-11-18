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
import 'package:latlong2/latlong.dart';

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
    this.accuracySource,
    this.speed,
    this.bearing,
    this.timestamp,
    this.isGpsActive = false,
    this.isInitialized = false,
    this.isSurveyMode = false,
    this.usesForegroundService = false,
    this.isExternalConnected = false,
    this.isExternalConnecting = false,
    this.isExternalReconnecting = false,
    this.isFallbackInternal = false,
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

  /// 外部 GNSS の [accuracy] の出どころ（`gst`・`hdop`。GnssAccuracySource）。端末の GPS は null
  final String? accuracySource;
  final double? speed;
  final double? bearing;
  final DateTime? timestamp;

  final bool isGpsActive;
  final bool isInitialized;
  final bool isSurveyMode;
  final bool usesForegroundService;
  final bool isExternalConnected;
  final bool isExternalConnecting;

  /// 外部 GNSS の切断後、バックグラウンドで自動再接続を試みているか
  final bool isExternalReconnecting;

  /// 外部 GNSS の切断中、ユーザーの明示操作で端末内蔵 GPS へ一時切替しているか
  final bool isFallbackInternal;

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

  /// 測れている位置。測れていなければ [fallback]（地図の現在位置など、最後に分かった位置）
  LatLng? positionOr(LatLng? fallback) => isActive ? LatLng(latitude!, longitude!) : fallback;

  bool get isExternal => sourceType == GpsSourceType.external && !isFallbackInternal;

  /// 記録用の測位ソース識別子（`external` / `internal_fallback` / `internal`）
  String get gpsSourceCode {
    if (isFallbackInternal) return 'internal_fallback';
    return sourceType == GpsSourceType.external ? 'external' : 'internal';
  }

  /// 表示に関わる値が同じか（時刻と NMEA は見ない）
  bool sameDisplayAs(GpsInfo other) =>
      latitude == other.latitude &&
      longitude == other.longitude &&
      altitude == other.altitude &&
      accuracy == other.accuracy &&
      accuracySource == other.accuracySource &&
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
      isExternalConnected == other.isExternalConnected &&
      isExternalConnecting == other.isExternalConnecting &&
      isExternalReconnecting == other.isExternalReconnecting &&
      isFallbackInternal == other.isFallbackInternal &&
      isSurveyMode == other.isSurveyMode;

  /// 測量の記録に書く形（以前の `getCurrentGpsInfo()` と同じキー）
  Map<String, dynamic> toMap() => {
    'sourceType': isFallbackInternal ? GpsSourceType.internal.sourceCode : sourceType.sourceCode,
    'sourceName': isFallbackInternal ? GpsSourceType.internal.displayName : sourceName,
    'gpsSource': gpsSourceCode,
    'isFallbackInternal': isFallbackInternal,
    'selectedDevice': selectedDevice,
    'latitude': latitude,
    'longitude': longitude,
    'altitude': altitude,
    'accuracy': accuracy,
    'accuracySource': accuracySource,
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

  /// 測量の記録（`usedGpsData`）に書く形。外部 GNSS やフォールバックの値は該当するときだけ書く
  Map<String, dynamic> toMap() => {
    'latitude': info.latitude,
    'longitude': info.longitude,
    'altitude': info.altitude,
    'accuracy': info.accuracy,
    'speed': info.speed,
    'bearing': info.bearing,
    'timestamp': info.timestamp?.toIso8601String(),
    'sourceType': info.isFallbackInternal ? GpsSourceType.internal.sourceCode : info.sourceType.sourceCode,
    'sourceName': info.isFallbackInternal ? GpsSourceType.internal.displayName : info.sourceName,
    'selectedDevice': info.selectedDevice,
    'collectedAt': collectedAt.toIso8601String(),
    if (info.isFallbackInternal || info.sourceType == GpsSourceType.external)
      'gpsSource': info.gpsSourceCode,
    if (info.isFallbackInternal) 'isFallbackInternal': true,
    'accuracySource': ?info.accuracySource,
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

/// 地図面（[TerrainMapLayer]）に常時描画する外部GNSSライブ位置マーカー情報
@immutable
class GnssMapMarker {
  const GnssMapMarker({
    required this.position,
    this.gpsQuality,
    this.deviceName,
  });

  final LatLng position;
  final int? gpsQuality;
  final String? deviceName;

  @override
  bool operator ==(Object other) =>
      other is GnssMapMarker &&
      other.position == position &&
      other.gpsQuality == gpsQuality &&
      other.deviceName == deviceName;

  @override
  int get hashCode => Object.hash(position, gpsQuality, deviceName);
}
