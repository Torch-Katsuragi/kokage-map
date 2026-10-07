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
/// 内蔵GPSと外部GNSS機器を統一的に管理し、GPS測量に位置を渡す
///
/// - 内蔵GPS: InternalGpsLocationStore に委譲（常に1ストリーム）
/// - 外部GNSS機器の切り替え管理
/// - 今の状態は [GpsManagerService.currentInfo]（[GpsInfo]）で読む
/// - 長押し測量の点集め
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/bluetooth_gnss_service.dart';
import '../models/gps_info.dart';
import '../models/gps_position_record.dart';
import '../providers/gps_providers.dart';
import 'internal_gps_location_store.dart';

export '../models/gps_info.dart';

/// GPS 設定画面のソース一覧の 1 行
typedef GpsSourceOption = ({
  GpsSourceType type,
  String name,
  String description,
  BluetoothDevice? device,
  bool isSelected,
});

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

  /// 最新の位置（内蔵 GPS・外部 GNSS 共通）
  GpsPositionRecord? _position;

  // 外部 GNSS: 位置が届いたときの衛星数・HDOP・品質
  int? _satelliteCount;
  double? _hdop;
  int? _gpsQuality;

  // 連続測量（長押し測量）関連
  bool _isContinuousSurvey = false;
  VoidCallback? _onContinuousSurveyUpdate;
  final List<GpsSurveySample> _continuousSurveyData = [];

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isGpsActive => _isGpsActive;
  bool get isSurveyMode => _isSurveyMode;
  GpsSourceType get currentSource => _currentSource;
  List<BluetoothDevice> get availableGnssDevices =>
      List.unmodifiable(_availableGnssDevices);
  BluetoothDevice? get selectedGnssDevice => _selectedGnssDevice;

  /// 利用可能なGPSソースリストを取得
  List<GpsSourceOption> getAvailableGpsSources() => [
    // 内蔵GPS（常に利用可能）
    (
      type: GpsSourceType.internal,
      name: GpsSourceType.internal.displayName,
      description: t.gps.internalDescription,
      device: null,
      isSelected: _currentSource == GpsSourceType.internal,
    ),
    // 外部GNSS機器
    for (final device in _availableGnssDevices)
      (
        type: GpsSourceType.external,
        name: device.name ?? t.gps.unknownDevice,
        description: 'Bluetooth GNSS機器 (${device.address})',
        device: device,
        isSelected:
            _currentSource == GpsSourceType.external &&
            _selectedGnssDevice?.address == device.address,
      ),
  ];

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

  /// GPS測量専用開始（軌跡記録とは独立した位置取得）。
  /// 位置が取れたらそのときの状態（NMEA 付き）を返す。[timeout] までに取れなければ null
  Future<GpsInfo?> startGpsSurveyWithWait({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      AppLogger.debug('$_logTag: GPS測量開始 - 測量専用GPS位置取得...');
      _isSurveyMode = true;

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
        if (_position != null && _isGpsActive) {
          AppLogger.debug('$_logTag: GPS測量用位置取得成功（測量専用GPS）');
          notifyListeners();
          return _buildInfo(withNmea: true);
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
  ///
  /// Store（内蔵GPS）は常時稼働、外部GNSSも接続を維持するので、測量モードを下ろすだけ
  Future<void> stopGpsSurvey() async {
    _isSurveyMode = false;
    AppLogger.debug('$_logTag: GPS測量停止');
    notifyListeners();
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

  /// 参照GPS（基準GPS）を切り替える。Store は常時稼働なので止めず、購読先だけ替える
  Future<void> switchGpsSource(
    GpsSourceType sourceType, [
    BluetoothDevice? device,
  ]) async {
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
      _saveSourceToGlobalConfig();

      AppLogger.debug('$_logTag: GPSソース切り替え完了: ${sourceType.displayName}');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: GPSソース切り替えエラー: $e');
      rethrow;
    }
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
    _position = null;
    _satelliteCount = null;
    _hdop = null;
    _gpsQuality = null;
    notifyListeners();
  }

  /// Store位置更新コールバック（内蔵GPS）
  void _onStorePositionUpdate(GpsPositionRecord record) {
    if (_currentSource != GpsSourceType.internal) return;
    _onPosition(record);
  }

  /// 外部GNSS位置更新コールバック
  void _onExternalGnssUpdate() {
    final service = _externalGnssService;
    if (_currentSource != GpsSourceType.external || service == null) return;
    final latitude = service.latitude;
    final longitude = service.longitude;
    if (latitude == null || longitude == null) return;

    _satelliteCount = service.satelliteCount;
    _hdop = service.hdop;
    _gpsQuality = service.gpsQuality;
    _onPosition(
      GpsPositionRecord(
        latitude: latitude,
        longitude: longitude,
        altitude: service.altitude,
        accuracy: service.accuracy,
        speed: service.speed,
        bearing: service.bearing,
        timestamp: service.timestamp ?? DateTime.now(),
      ),
    );
  }

  /// 位置が届いた（内蔵・外部共通）。連続測量中ならその時点の状態を 1 点として集める
  void _onPosition(GpsPositionRecord position) {
    _position = position;

    if (_isContinuousSurvey) {
      _continuousSurveyData.add(
        GpsSurveySample(_buildInfo(withNmea: true), DateTime.now()),
      );
      AppLogger.debug(
        '$_logTag: 連続測量データ収集 - ${_continuousSurveyData.length}ポイント目 '
        '(Lat: ${position.latitude.toStringAsFixed(6)}, Lon: ${position.longitude.toStringAsFixed(6)})',
      );
      // 外部コールバック呼び出し（UI更新用）
      _onContinuousSurveyUpdate?.call();
    }

    notifyListeners();
  }

  /// 現在のGPS情報
  GpsInfo get currentInfo => _buildInfo();

  /// [withNmea] は測量で記録するときだけ（NMEA の連結を毎回しない）
  GpsInfo _buildInfo({bool withNmea = false}) {
    final p = _position;
    final gnss =
        _currentSource == GpsSourceType.external ? _externalGnssService : null;
    final isExternal = _currentSource == GpsSourceType.external;
    return GpsInfo(
      sourceType: _currentSource,
      selectedDevice: _selectedGnssDevice?.name,
      latitude: p?.latitude,
      longitude: p?.longitude,
      altitude: p?.altitude,
      accuracy: p?.accuracy,
      speed: p?.speed,
      bearing: p?.bearing,
      timestamp: p?.timestamp,
      isGpsActive: _isGpsActive,
      isInitialized: _isInitialized,
      isSurveyMode: _isSurveyMode,
      usesForegroundService: _locationStore.isDelegated,
      // 外部GNSS機器の場合のみ衛星情報・NMEA情報を入れる
      satelliteCount: isExternal ? _satelliteCount : null,
      hdop: isExternal ? _hdop : null,
      pdop: gnss?.pdop,
      vdop: gnss?.vdop,
      gpsQuality: isExternal ? _gpsQuality : null,
      fixType: gnss?.fixTypeString,
      correctionSource: gnss?.correctionSource,
      nmea: withNmea ? gnss?.getNmeaBufferAsString() : null,
    );
  }

  /// グローバル設定にソース設定を保存
  void _saveSourceToGlobalConfig() {
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

  /// 連続測量開始（位置更新ベース）
  void startContinuousSurvey({VoidCallback? onPositionUpdate}) {
    AppLogger.debug('$_logTag: 連続測量開始（位置更新ベース）');
    _isContinuousSurvey = true;
    _onContinuousSurveyUpdate = onPositionUpdate;
    _continuousSurveyData.clear();
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
    AppLogger.debug('$_logTag: 連続測量データをクリア');
    notifyListeners();
  }

  /// 連続測量中に集めた点の数（点が届くたびに一覧を複製しないで済むように）。
  /// 測量していないときは 0（前の測量の点を数えない）
  int get continuousSurveyCount =>
      _isContinuousSurvey ? _continuousSurveyData.length : 0;

  /// 連続測量の収集データ（測量の記録に書く形）
  List<Map<String, dynamic>> getContinuousSurveyData() =>
      [for (final sample in _continuousSurveyData) sample.toMap()];

  @override
  void dispose() {
    AppLogger.debug('$_logTag: GPS管理サービスを停止中...');

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

    // 連続測量もクリーンアップ
    _isContinuousSurvey = false;
    _onContinuousSurveyUpdate = null;
    _continuousSurveyData.clear();

    AppLogger.debug('$_logTag: GPS管理サービス停止完了');
    super.dispose();
  }
}
