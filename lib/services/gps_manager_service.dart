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
/// 統合GPS管理サービス
///
/// 内蔵GPSと外部GNSS機器を統一的に管理し、GPS記録・追跡機能を提供
///
/// Features:
/// - 内蔵GPS: InternalGpsLocationStore に委譲（常に1ストリーム）
/// - 外部GNSS機器の切り替え管理
/// - 統一されたGPS位置情報取得API
/// - GPS記録の開始・停止機能
/// - オプション設定対応（取得インターバル、最短記録移動距離）
/// - GPS履歴データの管理・提供
/// - リアルタイム位置情報監視
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/bluetooth_gnss_service.dart';
import '../models/gps_position_record.dart';
import '../models/gps_track.dart';
import '../providers/gps_providers.dart';
import 'internal_gps_location_store.dart';

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

/// GPS記録オプション設定
class GpsRecordingOptions {
  /// 位置情報取得インターバル（秒）
  final int intervalSeconds;

  /// 最短記録移動距離（メートル）
  final double minDistanceMeters;

  /// 位置精度要求値（メートル）- この値以下の精度でないと記録しない
  final double? requiredAccuracy;

  /// 最大記録ポイント数（0の場合は無制限）
  final int maxRecordCount;

  const GpsRecordingOptions({
    this.intervalSeconds = 1,
    this.minDistanceMeters = 1.0,
    this.requiredAccuracy,
    this.maxRecordCount = 0,
  });

  /// デフォルト設定
  static const GpsRecordingOptions defaultOptions = GpsRecordingOptions();

  /// 高精度記録設定
  static const GpsRecordingOptions highAccuracy = GpsRecordingOptions(
    intervalSeconds: 1,
    minDistanceMeters: 0.5,
    requiredAccuracy: 5.0,
  );

  /// 省電力記録設定
  static const GpsRecordingOptions powerSaver = GpsRecordingOptions(
    intervalSeconds: 10,
    minDistanceMeters: 5.0,
    requiredAccuracy: 20.0,
  );
}

/// GPS管理サービス（シングルトン）
class GpsManagerService extends ChangeNotifier {
  static final GpsManagerService _instance = GpsManagerService._internal();
  factory GpsManagerService() => _instance;
  GpsManagerService._internal();

  static const String _logTag = 'GpsManagerService';

  Ref? _ref;

  void setRef(Ref ref) {
    _ref = ref;
  }

  // GPS機能の初期化状態
  bool _isInitialized = false;
  Completer<void>? _initCompleter;
  bool _isGpsActive = false;
  bool _isSurveyMode = false; // GPS測量モード

  // 現在のGPSソース設定
  GpsSourceType _currentSource = GpsSourceType.internal;

  // 内蔵GPS: InternalGpsLocationStore に委譲
  final InternalGpsLocationStore _locationStore = InternalGpsLocationStore();

  // Store の位置更新を監視するサブスクリプション
  StreamSubscription<GpsPositionRecord>? _storeSubscription;

  // 外部GNSS関連
  BluetoothGnssService? _externalGnssService;
  List<BluetoothDevice> _availableGnssDevices = [];
  BluetoothDevice? _selectedGnssDevice;

  // 記録機能関連
  bool _isRecording = false;
  GpsRecordingOptions _recordingOptions = GpsRecordingOptions.defaultOptions;
  Timer? _recordingTimer;
  final List<Map<String, dynamic>> _gpsHistory = [];
  DateTime? _recordingStartTime;
  GpsTrackPoint? _lastRecordedPoint;

  // 現在の位置情報（内蔵GPS時はStoreから取得、外部GNSS時は直接保持）
  double? _latitude;
  double? _longitude;
  double? _altitude;
  double? _accuracy;
  double? _speed;
  double? _bearing;
  DateTime? _timestamp;

  // 衛星情報・HDOP情報（外部GNSS用）
  int? _satelliteCount;
  double? _hdop;
  int? _gpsQuality;

  // 連続測量（長押し測量）関連
  bool _isContinuousSurvey = false;
  void Function()? _onContinuousSurveyUpdate;
  final List<Map<String, dynamic>> _continuousSurveyData = [];
  DateTime? _continuousSurveyStartTime;

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isGpsActive => _isGpsActive;
  bool get isSurveyMode => _isSurveyMode;
  GpsSourceType get currentSource => _currentSource;
  List<BluetoothDevice> get availableGnssDevices =>
      List.unmodifiable(_availableGnssDevices);
  BluetoothDevice? get selectedGnssDevice => _selectedGnssDevice;
  bool get isRecording => _isRecording;

  /// 内蔵GPS位置情報ストアへのアクセス
  InternalGpsLocationStore get locationStore => _locationStore;

  /// 外部GNSS機器が実際にBluetooth接続されているかを確認
  bool get isExternalGnssConnected =>
      _currentSource == GpsSourceType.external &&
      _selectedGnssDevice != null &&
      _externalGnssService != null &&
      _externalGnssService!.isConnected;
  GpsRecordingOptions get recordingOptions => _recordingOptions;
  List<Map<String, dynamic>> get gpsHistory => List.unmodifiable(_gpsHistory);
  DateTime? get recordingStartTime => _recordingStartTime;
  int get historyCount => _gpsHistory.length;

  // 現在位置情報
  double? get latitude => _latitude;
  double? get longitude => _longitude;
  double? get altitude => _altitude;
  double? get accuracy => _accuracy;
  double? get speed => _speed;
  double? get bearing => _bearing;
  DateTime? get timestamp => _timestamp;

  // 連続測量関連
  bool get isContinuousSurvey => _isContinuousSurvey;
  List<Map<String, dynamic>> get continuousSurveyData =>
      List.unmodifiable(_continuousSurveyData);
  int get continuousSurveyPointCount => _continuousSurveyData.length;
  DateTime? get continuousSurveyStartTime => _continuousSurveyStartTime;

  /// 利用可能なGPSソースリストを取得
  List<Map<String, dynamic>> getAvailableGpsSources() {
    final sources = <Map<String, dynamic>>[];

    // 内蔵GPS（常に利用可能）
    sources.add({
      'type': GpsSourceType.internal,
      'name': GpsSourceType.internal.displayName,
      'description': t.gps.internalDescription,
      'isAvailable': true,
      'isSelected': _currentSource == GpsSourceType.internal,
    });

    // 外部GNSS機器
    for (final device in _availableGnssDevices) {
      sources.add({
        'type': GpsSourceType.external,
        'name': device.name ?? t.gps.unknownDevice,
        'description': 'Bluetooth GNSS機器 (${device.address})',
        'device': device,
        'isAvailable': true,
        'isSelected':
            _currentSource == GpsSourceType.external &&
            _selectedGnssDevice?.address == device.address,
      });
    }

    return sources;
  }

  /// GPS管理サービスを初期化（待機状態・二重実行防止）
  Future<void> initialize() async {
    if (_isInitialized) {
      AppLogger.debug('$_logTag: 既に初期化済みです');
      return;
    }

    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    try {
      AppLogger.debug('$_logTag: GPS管理サービスを初期化中...');

      // グローバル設定から前回の設定を読み込み（GPS開始はしない）
      await _loadSourceConfigOnly();

      _isInitialized = true;
      AppLogger.debug('$_logTag: GPS管理サービスの初期化完了（待機状態）');
      notifyListeners();
      _initCompleter!.complete();
    } catch (e) {
      AppLogger.debug('$_logTag: GPS管理サービス初期化エラー: $e');
      _isInitialized = false;
      _initCompleter!.completeError(e);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  /// GPS位置情報取得を開始
  Future<void> startGps() async {
    if (!_isInitialized) {
      await initialize();
    }

    if (_isGpsActive) {
      AppLogger.debug('$_logTag: GPS位置情報取得は既に開始されています');
      return;
    }

    try {
      AppLogger.debug('$_logTag: GPS位置情報取得を開始中...');

      switch (_currentSource) {
        case GpsSourceType.internal:
          await _startInternalGps();
        case GpsSourceType.external:
          if (_selectedGnssDevice != null) {
            await _startExternalGnss(_selectedGnssDevice!);
          } else {
            // 外部GNSS設定されているが機器がない場合は内蔵GPSにフォールバック
            AppLogger.debug('$_logTag: 外部GNSS機器が設定されていないため内蔵GPSにフォールバック');
            _currentSource = GpsSourceType.internal;
            await _startInternalGps();
          }
      }

      _isGpsActive = true;
      AppLogger.debug('$_logTag: GPS位置情報取得開始完了: ${_currentSource.displayName}');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: GPS位置情報取得開始エラー: $e');
      _isGpsActive = false;
      rethrow;
    }
  }

  /// GPS位置情報取得を停止
  Future<void> stopGps() async {
    if (!_isGpsActive) {
      AppLogger.debug('$_logTag: GPS位置情報取得は既に停止されています');
      return;
    }

    try {
      AppLogger.debug('$_logTag: GPS位置情報取得を停止中...');
      await _stopCurrentSource();
      _isGpsActive = false;
      _isSurveyMode = false; // 測量モードも終了
      AppLogger.debug('$_logTag: GPS位置情報取得停止完了');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: GPS位置情報取得停止エラー: $e');
    }
  }

  /// GPS測量専用開始（軌跡記録とは独立した位置取得）
  Future<Map<String, dynamic>?> startGpsSurveyWithWait({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      AppLogger.debug('$_logTag: GPS測量開始 - 測量専用GPS位置取得...');
      _isSurveyMode = true;

      // GPS測量専用開始（フォアグラウンドサービスとは独立）
      AppLogger.debug('$_logTag: 測量専用GPS開始');

      // 外部GNSS接続が既にある場合は再利用
      if (!_isGpsActive) {
        if (_currentSource == GpsSourceType.external &&
            _externalGnssService != null &&
            _externalGnssService!.isConnected) {
          // 既に外部GNSS接続があるので、位置監視のみ再開
          AppLogger.debug('$_logTag: 外部GNSS接続済み、位置監視のみ再開');
          _isGpsActive = true;
          notifyListeners();
        } else {
          // GPS開始が必要
          await startGps();
        }
      }

      // 位置情報取得まで待機（ポーリング方式）
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < timeout) {
        final gpsInfo = getCurrentGpsInfo();

        if (gpsInfo['isActive'] == true &&
            gpsInfo['latitude'] != null &&
            gpsInfo['longitude'] != null) {
          AppLogger.debug('$_logTag: GPS測量用位置取得成功（測量専用GPS）');
          notifyListeners();
          return gpsInfo;
        }

        // 500ms間隔でポーリング
        await Future.delayed(const Duration(milliseconds: 500));
      }

      AppLogger.debug('$_logTag: GPS測量用位置取得タイムアウト');
      return null;
    } catch (e) {
      AppLogger.debug('$_logTag: GPS測量開始エラー: $e');
      _isSurveyMode = false;
      rethrow;
    }
  }

  /// GPS測量専用停止
  Future<void> stopGpsSurvey() async {
    try {
      AppLogger.debug('$_logTag: GPS測量停止中...');
      _isSurveyMode = false;

      // Store（内蔵GPS）は常時稼働のため停止しない
      // 外部GNSSの場合も接続を維持

      AppLogger.debug('$_logTag: GPS測量停止完了 - 測量モード: $_isSurveyMode');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: GPS測量停止エラー: $e');
    }
  }

  /// 外部GNSS機器をスキャン
  Future<void> scanExternalGnssDevices() async {
    try {
      AppLogger.debug('$_logTag: 外部GNSS機器をスキャン中...');

      _externalGnssService ??= BluetoothGnssService();
      _availableGnssDevices = await _externalGnssService!.scanDevices();

      AppLogger.debug('$_logTag: ${_availableGnssDevices.length}個の外部GNSS機器を発見');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: 外部GNSS機器スキャンエラー: $e');
      rethrow;
    }
  }

  /// GPSソースを切り替え
  Future<void> switchGpsSource(
    GpsSourceType sourceType, [
    BluetoothDevice? device,
  ]) async {
    if (_isRecording) {
      throw Exception(t.gps.cannotChangeWhileRecording);
    }

    try {
      AppLogger.debug('$_logTag: GPSソースを${sourceType.displayName}に切り替え中...');

      // 現在のソースを停止
      await _stopCurrentSource();

      _currentSource = sourceType;

      switch (sourceType) {
        case GpsSourceType.internal:
          await _startInternalGps();
        case GpsSourceType.external:
          if (device == null) {
            throw ArgumentError(t.gps.externalDeviceRequired);
          }
          _selectedGnssDevice = device;
          await _startExternalGnss(device);
      }

      // グローバル設定に保存
      await _saveSourceToGlobalConfig();

      AppLogger.debug('$_logTag: GPSソース切り替え完了: ${sourceType.displayName}');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: GPSソース切り替えエラー: $e');
      rethrow;
    }
  }

  /// 参照GPS（基準GPS）切り替えメソッド
  Future<void> switchReferenceGps(
    GpsSourceType sourceType, [
    BluetoothDevice? device,
  ]) async {
    AppLogger.debug('$_logTag: 参照GPS（基準GPS）を${sourceType.displayName}に切り替え...');

    // Store は常時稼働のため停止不要。ソース切り替えのみ。
    await switchGpsSource(sourceType, device);

    AppLogger.debug('$_logTag: 参照GPS（基準GPS）切り替え完了: ${sourceType.displayName}');
  }

  /// 内蔵GPS開始（InternalGpsLocationStoreに委譲）
  Future<void> _startInternalGps() async {
    // Store が未起動の場合は起動
    if (!_locationStore.isActive) {
      await _locationStore.start();
    }

    // Store の位置更新を監視して内部状態を同期
    await _storeSubscription?.cancel();
    _storeSubscription = _locationStore.positionStream.listen(
      _onStorePositionUpdate,
    );

    AppLogger.debug('$_logTag: 内蔵GPS開始（Store委譲）');
  }

  /// 外部GNSS開始
  Future<void> _startExternalGnss(BluetoothDevice device) async {
    _externalGnssService ??= BluetoothGnssService();

    // デバイスに接続
    await _externalGnssService!.connectToDevice(device);

    // 位置情報更新監視
    _externalGnssService!.addListener(_onExternalGnssUpdate);
  }

  /// 現在のソースを停止
  Future<void> _stopCurrentSource() async {
    // Store監視を停止（Store自体は常時稼働のため停止しない）
    await _storeSubscription?.cancel();
    _storeSubscription = null;

    // 外部GNSS停止
    if (_externalGnssService != null) {
      _externalGnssService!.removeListener(_onExternalGnssUpdate);
      await _externalGnssService!.disconnect();
    }

    // 位置情報クリア
    _clearCurrentPosition();
  }

  /// Store位置更新コールバック（内蔵GPS）
  void _onStorePositionUpdate(GpsPositionRecord record) {
    if (_currentSource == GpsSourceType.internal) {
      _latitude = record.latitude;
      _longitude = record.longitude;
      _altitude = record.altitude;
      _accuracy = record.accuracy;
      _speed = record.speed;
      _bearing = record.bearing;
      _timestamp = record.timestamp;

      // 連続測量中の場合はデータを収集
      if (_isContinuousSurvey) {
        _collectContinuousSurveyData(
          latitude: record.latitude,
          longitude: record.longitude,
          altitude: record.altitude,
          accuracy: record.accuracy,
          speed: record.speed,
          bearing: record.bearing,
          timestamp: record.timestamp,
          sourceType: GpsSourceType.internal.sourceCode,
        );
      }

      notifyListeners();
    }
  }

  /// 外部GNSS位置更新コールバック
  void _onExternalGnssUpdate() {
    if (_currentSource == GpsSourceType.external &&
        _externalGnssService != null) {
      final service = _externalGnssService!;

      if (service.latitude != null && service.longitude != null) {
        _updateCurrentPosition(
          latitude: service.latitude!,
          longitude: service.longitude!,
          altitude: service.altitude,
          accuracy: service.accuracy,
          speed: service.speed,
          bearing: service.bearing,
          timestamp: service.timestamp ?? DateTime.now(),
          sourceType: GpsSourceType.external.sourceCode,
          satelliteCount: service.satelliteCount,
          hdop: service.hdop,
          pdop: service.pdop,
          vdop: service.vdop,
          gpsQuality: service.gpsQuality,
          fixType: service.fixTypeString,
          nmea: service.getNmeaBufferAsString(),
        );
      }
    }
  }

  /// 現在位置情報を更新（外部GNSS用）
  void _updateCurrentPosition({
    required double latitude,
    required double longitude,
    double? altitude,
    double? accuracy,
    double? speed,
    double? bearing,
    required DateTime timestamp,
    required String sourceType,
    int? satelliteCount,
    double? hdop,
    double? pdop,
    double? vdop,
    int? gpsQuality,
    String? fixType,
    String? nmea,
  }) {
    _latitude = latitude;
    _longitude = longitude;
    _altitude = altitude;
    _accuracy = accuracy;
    _speed = speed;
    _bearing = bearing;
    _timestamp = timestamp;
    _satelliteCount = satelliteCount;
    _hdop = hdop;
    _gpsQuality = gpsQuality;

    // 連続測量中の場合はデータを収集
    if (_isContinuousSurvey) {
      _collectContinuousSurveyData(
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        accuracy: accuracy,
        speed: speed,
        bearing: bearing,
        timestamp: timestamp,
        sourceType: sourceType,
        satelliteCount: satelliteCount,
        hdop: hdop,
        pdop: pdop,
        vdop: vdop,
        gpsQuality: gpsQuality,
        fixType: fixType,
        correctionSource: _externalGnssService?.correctionSource,
        nmea: nmea,
      );
    }

    notifyListeners();
  }

  /// 連続測量データを収集（位置更新時に呼び出される）
  void _collectContinuousSurveyData({
    required double latitude,
    required double longitude,
    double? altitude,
    double? accuracy,
    double? speed,
    double? bearing,
    required DateTime timestamp,
    required String sourceType,
    int? satelliteCount,
    double? hdop,
    double? pdop,
    double? vdop,
    int? gpsQuality,
    String? fixType,
    String? correctionSource,
    String? nmea,
  }) {
    final gpsData = {
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'accuracy': accuracy,
      'speed': speed,
      'bearing': bearing,
      'timestamp': timestamp.toIso8601String(),
      'sourceType': sourceType,
      'sourceName': _currentSource.displayName,
      'selectedDevice': _selectedGnssDevice?.name,
      'collectedAt': DateTime.now().toIso8601String(),
      // 外部GNSS機器の場合のみ衛星情報を追加
      if (satelliteCount != null) 'satelliteCount': satelliteCount,
      if (hdop != null) 'hdop': hdop,
      if (pdop != null) 'pdop': pdop,
      if (vdop != null) 'vdop': vdop,
      if (gpsQuality != null) 'gpsQuality': gpsQuality,
      if (fixType != null) 'fixType': fixType,
      if (correctionSource != null) 'correctionSource': correctionSource,
      if (nmea != null) 'nmea': nmea,
    };

    _continuousSurveyData.add(gpsData);

    AppLogger.debug(
      '$_logTag: 連続測量データ収集 - ${_continuousSurveyData.length}ポイント目 '
      '(Lat: ${latitude.toStringAsFixed(6)}, Lon: ${longitude.toStringAsFixed(6)})',
    );

    // 外部コールバック呼び出し（UI更新用）
    if (_onContinuousSurveyUpdate != null) {
      _onContinuousSurveyUpdate!();
    }
  }

  /// 現在位置情報をクリア
  void _clearCurrentPosition() {
    _latitude = null;
    _longitude = null;
    _altitude = null;
    _accuracy = null;
    _speed = null;
    _bearing = null;
    _timestamp = null;
    _satelliteCount = null;
    _hdop = null;
    _gpsQuality = null;
    notifyListeners();
  }

  /// 現在のGPS情報を取得
  Map<String, dynamic> getCurrentGpsInfo() {
    // 内蔵GPS使用時はStoreからhasNewUpdateを取得
    final bool hasNewUpdate;
    if (_currentSource == GpsSourceType.internal) {
      final response = _locationStore.requestPosition();
      hasNewUpdate = response.hasNewUpdate;
    } else {
      hasNewUpdate = true; // 外部GNSSは常に最新
    }

    final isExternal = _currentSource == GpsSourceType.external;
    return {
      'sourceType': _currentSource.sourceCode,
      'sourceName': _currentSource.displayName,
      'selectedDevice': _selectedGnssDevice?.name,
      'latitude': _latitude,
      'longitude': _longitude,
      'altitude': _altitude,
      'accuracy': _accuracy,
      'speed': _speed,
      'bearing': _bearing,
      'timestamp': _timestamp?.toIso8601String(),
      'isActive': _latitude != null && _longitude != null && _isGpsActive,
      'isGpsActive': _isGpsActive,
      'isInitialized': _isInitialized,
      'isSurveyMode': _isSurveyMode,
      'usesForegroundService': _locationStore.isDelegated,
      'hasNewUpdate': hasNewUpdate,
      // 外部GNSS機器の場合のみ衛星情報・NMEA情報を追加
      'satelliteCount': isExternal ? _satelliteCount : null,
      'hdop': isExternal ? _hdop : null,
      'pdop': isExternal ? _externalGnssService?.pdop : null,
      'vdop': isExternal ? _externalGnssService?.vdop : null,
      'gpsQuality': isExternal ? _gpsQuality : null,
      'fixType': isExternal ? _externalGnssService?.fixTypeString : null,
      'correctionSource':
          isExternal ? _externalGnssService?.correctionSource : null,
      'nmea': isExternal ? _externalGnssService?.getNmeaBufferAsString() : null,
    };
  }

  /// GPS記録を開始
  Future<void> startRecording([GpsRecordingOptions? options]) async {
    if (_isRecording) {
      throw Exception(t.gps.alreadyRecording);
    }

    if (_latitude == null || _longitude == null) {
      throw Exception(t.gps.noGpsPosition);
    }

    _recordingOptions = options ?? GpsRecordingOptions.defaultOptions;
    _isRecording = true;
    _recordingStartTime = DateTime.now();
    _gpsHistory.clear();
    _lastRecordedPoint = null;

    // 最初のポイントを即座に記録
    await _recordCurrentPosition();

    // 定期記録タイマー開始
    _recordingTimer = Timer.periodic(
      Duration(seconds: _recordingOptions.intervalSeconds),
      (_) => _recordCurrentPosition(),
    );

    AppLogger.debug(
      '$_logTag: GPS記録開始 - インターバル: ${_recordingOptions.intervalSeconds}秒, '
      '最短移動距離: ${_recordingOptions.minDistanceMeters}m',
    );
    notifyListeners();
  }

  /// GPS記録を停止
  Map<String, dynamic>? stopRecording() {
    if (!_isRecording) {
      return null;
    }

    _recordingTimer?.cancel();
    _recordingTimer = null;
    _isRecording = false;

    final recordingSummary = {
      'startTime': _recordingStartTime?.toIso8601String(),
      'endTime': DateTime.now().toIso8601String(),
      'totalPoints': _gpsHistory.length,
      'totalDistance': _calculateTotalDistance(),
      'duration':
          _recordingStartTime != null
              ? DateTime.now().difference(_recordingStartTime!).inSeconds
              : 0,
      'sourceType': _currentSource.sourceCode,
      'sourceName': _currentSource.displayName,
    };

    AppLogger.debug('$_logTag: GPS記録停止 - ${_gpsHistory.length}ポイント記録');
    notifyListeners();

    return recordingSummary;
  }

  /// 現在位置を記録
  Future<void> _recordCurrentPosition() async {
    if (!_isRecording || _latitude == null || _longitude == null) {
      return;
    }

    // 精度チェック
    if (_recordingOptions.requiredAccuracy != null &&
        _accuracy != null &&
        _accuracy! > _recordingOptions.requiredAccuracy!) {
      AppLogger.debug('$_logTag: 精度不足のため記録スキップ - 現在精度: ${_accuracy}m');
      return;
    }

    // 最短移動距離チェック
    if (_lastRecordedPoint != null) {
      final distance = _calculateDistance(
        _lastRecordedPoint!.latitude,
        _lastRecordedPoint!.longitude,
        _latitude!,
        _longitude!,
      );

      if (distance < _recordingOptions.minDistanceMeters) {
        return; // 移動距離が不足
      }
    }

    // ポイントを記録
    final point = GpsTrackPoint(
      latitude: _latitude!,
      longitude: _longitude!,
      altitude: _altitude,
      accuracy: _accuracy,
      speed: _speed,
      bearing: _bearing,
      timestamp: _timestamp ?? DateTime.now(),
      sourceType: _currentSource.sourceCode,
    );

    final pointData = point.toJson();
    pointData['sourceDisplayName'] = _currentSource.displayName;

    _gpsHistory.add(pointData);
    _lastRecordedPoint = point;

    // 最大記録数チェック
    if (_recordingOptions.maxRecordCount > 0 &&
        _gpsHistory.length > _recordingOptions.maxRecordCount) {
      _gpsHistory.removeAt(0); // 古いデータを削除
    }

    AppLogger.debug('$_logTag: 位置記録 - ${_gpsHistory.length}ポイント目');
  }

  /// 総移動距離を計算
  double _calculateTotalDistance() {
    if (_gpsHistory.length < 2) return 0.0;

    double totalDistance = 0.0;
    for (int i = 1; i < _gpsHistory.length; i++) {
      final prev = _gpsHistory[i - 1];
      final curr = _gpsHistory[i];

      totalDistance += _calculateDistance(
        prev['latitude'],
        prev['longitude'],
        curr['latitude'],
        curr['longitude'],
      );
    }

    return totalDistance;
  }

  /// 2点間の距離計算（ハバーサイン公式）
  double _calculateDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double R = 6371000; // 地球の半径（メートル）
    final dLat = (lat2 - lat1) * (math.pi / 180);
    final dLon = (lon2 - lon1) * (math.pi / 180);
    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * (math.pi / 180)) *
            math.cos(lat2 * (math.pi / 180)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  /// グローバル設定にソース設定を保存
  Future<void> _saveSourceToGlobalConfig() async {
    final sourceType =
        _currentSource == GpsSourceType.internal ? 'internal' : 'external';
    _ref?.read(preferredGpsSourceTypeProvider.notifier).set(sourceType);
    _ref?.read(selectedGnssDeviceAddressProvider.notifier)
        .set(_selectedGnssDevice?.address);
    _ref?.read(selectedGnssDeviceNameProvider.notifier)
        .set(_selectedGnssDevice?.name);

    AppLogger.debug(
      '$_logTag: GPS設定をグローバル設定に保存: $sourceType',
    );
  }

  /// グローバル設定からソース設定のみ読み込み（GPS開始はしない）
  Future<void> _loadSourceConfigOnly() async {
    final preferredSource =
        _ref?.read(preferredGpsSourceTypeProvider);
    final savedAddress =
        _ref?.read(selectedGnssDeviceAddressProvider);

    if (preferredSource == null) {
      _currentSource = GpsSourceType.internal;
      AppLogger.debug('$_logTag: 初回起動のため内蔵GPSを設定');
      return;
    }

    try {
      if (preferredSource == 'external' && savedAddress != null) {
        await scanExternalGnssDevices();

        final targetDevice =
            _availableGnssDevices
                .where((device) => device.address == savedAddress)
                .firstOrNull;

        if (targetDevice != null) {
          _currentSource = GpsSourceType.external;
          _selectedGnssDevice = targetDevice;
          AppLogger.debug('$_logTag: 外部GNSS設定を復元: ${targetDevice.name}');
        } else {
          AppLogger.debug('$_logTag: 保存されたGNSS機器が見つからないため内蔵GPSにフォールバック');
          _currentSource = GpsSourceType.internal;
        }
      } else if (preferredSource == 'internal') {
        _currentSource = GpsSourceType.internal;
        AppLogger.debug('$_logTag: 内蔵GPS設定を復元');
      }
    } catch (e) {
      AppLogger.debug('$_logTag: GPS設定の復元に失敗、内蔵GPSを使用: $e');
      _currentSource = GpsSourceType.internal;
    }
  }

  /// グローバル設定からソース設定を読み込み（GPS開始も行う）
  Future<void> loadSourceFromGlobalConfig() async {
    final preferredSource =
        _ref?.read(preferredGpsSourceTypeProvider);
    final savedAddress =
        _ref?.read(selectedGnssDeviceAddressProvider);

    if (preferredSource == null) {
      return;
    }

    try {
      if (preferredSource == 'external' && savedAddress != null) {
        await scanExternalGnssDevices();

        final targetDevice = _availableGnssDevices.firstWhere(
          (device) => device.address == savedAddress,
          orElse: () => throw Exception(t.gps.savedDeviceNotFound),
        );

        await switchGpsSource(GpsSourceType.external, targetDevice);
        AppLogger.debug(
          '$_logTag: 保存されたGPS設定を復元: 外部GNSS (${targetDevice.name})',
        );
      } else if (preferredSource == 'internal') {
        await switchGpsSource(GpsSourceType.internal);
        AppLogger.debug('$_logTag: 保存されたGPS設定を復元: 内蔵GPS');
      }
    } catch (e) {
      AppLogger.debug('$_logTag: 保存されたGPS設定の復元に失敗、内蔵GPSを使用: $e');
      await switchGpsSource(GpsSourceType.internal);
    }
  }

  /// 記録履歴をクリア
  void clearHistory() {
    if (_isRecording) {
      throw Exception(t.gps.cannotClearWhileRecording);
    }

    _gpsHistory.clear();
    _lastRecordedPoint = null;
    _recordingStartTime = null;

    AppLogger.debug('$_logTag: GPS記録履歴をクリア');
    notifyListeners();
  }

  /// 記録統計情報を取得
  Map<String, dynamic> getRecordingStatistics() {
    return {
      'isRecording': _isRecording,
      'startTime': _recordingStartTime?.toIso8601String(),
      'currentTime': DateTime.now().toIso8601String(),
      'totalPoints': _gpsHistory.length,
      'totalDistance': _calculateTotalDistance(),
      'duration':
          _recordingStartTime != null
              ? DateTime.now().difference(_recordingStartTime!).inSeconds
              : 0,
      'averageInterval':
          _gpsHistory.length > 1
              ? (DateTime.now().difference(_recordingStartTime!).inSeconds /
                  (_gpsHistory.length - 1))
              : 0,
      'sourceType': _currentSource.sourceCode,
      'sourceName': _currentSource.displayName,
      'options': {
        'intervalSeconds': _recordingOptions.intervalSeconds,
        'minDistanceMeters': _recordingOptions.minDistanceMeters,
        'requiredAccuracy': _recordingOptions.requiredAccuracy,
        'maxRecordCount': _recordingOptions.maxRecordCount,
      },
    };
  }

  /// 連続測量開始（位置更新ベース）
  void startContinuousSurvey({void Function()? onPositionUpdate}) {
    AppLogger.debug('$_logTag: 連続測量開始（位置更新ベース）');
    _isContinuousSurvey = true;
    _onContinuousSurveyUpdate = onPositionUpdate;
    _continuousSurveyData.clear();
    _continuousSurveyStartTime = DateTime.now();
    notifyListeners();
  }

  /// 連続測量停止
  void stopContinuousSurvey() {
    AppLogger.debug('$_logTag: 連続測量停止 - ${_continuousSurveyData.length}ポイント収集');
    _isContinuousSurvey = false;
    _onContinuousSurveyUpdate = null;
    notifyListeners();
  }

  /// 連続測量データをクリア
  void clearContinuousSurveyData() {
    _continuousSurveyData.clear();
    _continuousSurveyStartTime = null;
    AppLogger.debug('$_logTag: 連続測量データをクリア');
    notifyListeners();
  }

  /// 連続測量の収集データを取得
  List<Map<String, dynamic>> getContinuousSurveyData() {
    return List.unmodifiable(_continuousSurveyData);
  }

  @override
  void dispose() {
    AppLogger.debug('$_logTag: GPS管理サービスを停止中...');

    // タイマーをキャンセル
    _recordingTimer?.cancel();
    _recordingTimer = null;

    // Store監視を停止
    _storeSubscription?.cancel();
    _storeSubscription = null;

    // 外部GNSSサービスのクリーンアップ
    if (_externalGnssService != null) {
      _externalGnssService!.removeListener(_onExternalGnssUpdate);
      _externalGnssService!.dispose();
      _externalGnssService = null;
    }

    // 状態フラグをリセット
    _isGpsActive = false;
    _isSurveyMode = false;
    _isRecording = false;

    // 連続測量もクリーンアップ
    _isContinuousSurvey = false;
    _onContinuousSurveyUpdate = null;
    _continuousSurveyData.clear();

    // 履歴データをクリア
    _gpsHistory.clear();

    AppLogger.debug('$_logTag: GPS管理サービス停止完了');
    super.dispose();
  }
}
