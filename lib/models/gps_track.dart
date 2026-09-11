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
// GPS追跡軌跡データ管理クラス
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

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

/// GPS軌跡全体を管理するクラス
class GpsTrack {
  final List<GpsTrackPoint> _points = [];
  final DateTime _startTime = DateTime.now();
  String? _trackName;

  /// 軌跡開始時刻
  DateTime get startTime => _startTime;

  /// 軌跡名（デフォルトは開始時刻ベース）
  String get trackName =>
      _trackName ?? 'GPS軌跡_${_startTime.toIso8601String().substring(0, 19)}';

  set trackName(String name) => _trackName = name;

  /// 現在のポイント数
  int get pointCount => _points.length;

  /// 全ポイントのリスト（読み取り専用）
  List<GpsTrackPoint> get points => List.unmodifiable(_points);

  /// 最新のポイント
  GpsTrackPoint? get lastPoint => _points.isNotEmpty ? _points.last : null;

  /// 軌跡が空かどうか
  bool get isEmpty => _points.isEmpty;

  /// ポイントを追加
  void addPoint(GpsTrackPoint point) {
    _points.add(point);
  }

  /// 軌跡をクリア
  void clear() {
    _points.clear();
  }

  /// 軌跡の総距離（メートル）
  double get totalDistance {
    if (_points.length < 2) return 0.0;

    double distance = 0.0;
    for (int i = 1; i < _points.length; i++) {
      distance += _calculateDistance(
        _points[i - 1].latitude,
        _points[i - 1].longitude,
        _points[i].latitude,
        _points[i].longitude,
      );
    }
    return distance;
  }

  /// 軌跡の継続時間
  Duration get duration {
    if (_points.isEmpty) return Duration.zero;
    final endTime = _points.last.timestamp;
    return endTime.difference(_startTime);
  }

  /// LatLngのリストとして取得（地図表示用）
  List<LatLng> toLatLngList() => _points.map((p) => p.toLatLng()).toList();

  /// LineString形式のWKT生成（GeoPackage保存用）
  String toWkt() {
    if (_points.isEmpty) return 'LINESTRING EMPTY';

    final coords = _points
        .map((p) => '${p.longitude} ${p.latitude} ${p.altitude ?? 0}')
        .join(', ');

    return 'LINESTRING Z ($coords)';
  }

  /// 軌跡の統計情報
  Map<String, dynamic> getStatistics() {
    if (_points.isEmpty) {
      return {
        'pointCount': 0,
        'totalDistance': 0.0,
        'duration': Duration.zero,
        'averageSpeed': 0.0,
        'maxSpeed': 0.0,
        'gpsPoints': 0,
        'gnssPoints': 0,
      };
    }

    final gpsPoints = _points.where((p) => p.sourceType == 'GPS').length;
    final gnssPoints = _points.where((p) => p.sourceType == 'GNSS').length;
    final distance = totalDistance;
    final dur = duration;
    final avgSpeed = dur.inSeconds > 0 ? distance / dur.inSeconds : 0.0;
    final maxSpeed = _points
        .where((p) => p.speed != null)
        .map((p) => p.speed!)
        .fold(0.0, (max, speed) => speed > max ? speed : max);

    return {
      'pointCount': pointCount,
      'totalDistance': distance,
      'duration': dur,
      'averageSpeed': avgSpeed,
      'maxSpeed': maxSpeed,
      'gpsPoints': gpsPoints,
      'gnssPoints': gnssPoints,
    };
  }

  /// 2点間の距離計算（ハバーサイン公式）
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double R = 6371000; // 地球の半径（メートル）
    final dLat = (lat2 - lat1) * (3.14159265359 / 180);
    final dLon = (lon2 - lon1) * (3.14159265359 / 180);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * (3.14159265359 / 180)) *
            math.cos(lat2 * (3.14159265359 / 180)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }
}

/// GPS軌跡の管理クラス（シングルトン）
class GpsTrackManager {
  static final GpsTrackManager _instance = GpsTrackManager._internal();
  factory GpsTrackManager() => _instance;
  GpsTrackManager._internal();

  GpsTrack? _currentTrack;
  bool _isTracking = false;

  /// 現在の軌跡
  GpsTrack? get currentTrack => _currentTrack;

  /// 追跡中かどうか
  bool get isTracking => _isTracking;

  /// 追跡開始
  void startTracking() {
    _currentTrack = GpsTrack();
    _isTracking = true;
    AppLogger.debug('[GpsTrackManager] 軌跡追跡開始: ${_currentTrack!.startTime}');
  }

  /// 追跡停止
  GpsTrack? stopTracking() {
    if (!_isTracking || _currentTrack == null) return null;

    _isTracking = false;
    final track = _currentTrack!;
    AppLogger.debug('[GpsTrackManager] 軌跡追跡停止: ${track.pointCount}ポイント');
    return track;
  }

  /// ポイント追加
  void addPoint(GpsTrackPoint point) {
    if (_isTracking && _currentTrack != null) {
      _currentTrack!.addPoint(point);
    }
  }

  /// 軌跡をクリア
  void clearCurrentTrack() {
    _currentTrack = null;
    _isTracking = false;
  }
}

