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
/// 内蔵GPSと外部GNSS機器を統一的に管理し、GPS測量・現在地表示・軌跡記録に位置を渡す
///
/// - 内蔵GPS: InternalGpsLocationStore に委譲（常に1ストリーム）
/// - 外部GNSS機器の切り替え・永続化・起動時自動再接続・瞬断時の自動再接続
/// - 外部GNSS切断時は無断で内蔵GPSへ切り替えず、警告音・通知で知らせ、明示操作でのみ一時フォールバックする
/// - 今の状態は [GpsManagerService.currentInfo]（[GpsInfo]）で読む
/// - 長押し測量の点集め
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';
import '../models/app_notification.dart';
import '../models/bluetooth_gnss_service.dart';
import '../models/gps_info.dart';
import '../models/gps_position_record.dart';
import '../models/ntrip_config.dart';
import '../providers/gps_providers.dart';
import '../providers/notification_providers.dart';
import '../providers/ui_state_providers.dart';
import 'bluetooth_connection_coordinator.dart';
import 'device_connection_log_service.dart';
import 'internal_gps_location_store.dart';
import 'ntrip/gnss_fix_sound_monitor.dart';
import 'ntrip/ntrip_client_service.dart';

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
  GpsManagerService._internal() {
    NtripClientService.instance.onRtcmData = sendRtcmToExternalGnss;
    NtripClientService.instance.ggaProvider = buildLatestGgaForNtrip;
  }

  static const String _logTag = 'GpsManagerService';

  Ref? _ref;
  GnssFixSoundMonitor _fixSoundMonitor = GnssFixSoundMonitor();

  @visibleForTesting
  set debugFixSoundMonitor(GnssFixSoundMonitor monitor) {
    _fixSoundMonitor = monitor;
  }

  @visibleForTesting
  GnssFixSoundMonitor get debugFixSoundMonitor => _fixSoundMonitor;

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

  /// 外部GNSS選択中に切断が起き、ユーザーが明示的に内蔵GPSへの一時切替を選んだ状態
  bool _isFallbackInternal = false;

  /// 外部GNSSへのバックグラウンド自動再接続状態
  bool _isExternalReconnecting = false;
  Timer? _externalReconnectTimer;
  int _externalReconnectAttempt = 0;

  @visibleForTesting
  int maxExternalReconnectAttempts = 5;

  @visibleForTesting
  List<Duration> externalReconnectBackoff = const [
    Duration(seconds: 3),
    Duration(seconds: 6),
    Duration(seconds: 12),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  /// テスト用: Bluetooth 実機接続の差し替えフック
  @visibleForTesting
  Future<void> Function(BluetoothDevice device)? externalConnectOverride;

  /// テスト用: ペアリング済みデバイス列挙の差し替えフック
  @visibleForTesting
  Future<List<BluetoothDevice>> Function()? scanDevicesOverride;

  /// テスト用: 内蔵GPS Store 起動の差し替えフック
  @visibleForTesting
  Future<void> Function()? internalStartOverride;

  // 内蔵GPS: InternalGpsLocationStore に委譲
  final InternalGpsLocationStore _locationStore = InternalGpsLocationStore();

  // Store の位置更新を監視するサブスクリプション
  StreamSubscription<GpsPositionRecord>? _storeSubscription;

  /// 現在有効な測位ソース（外部GNSS / 内蔵GPS / 一時切替内蔵GPS）の位置ストリーム
  final StreamController<GpsPositionRecord> _activePositionController =
      StreamController<GpsPositionRecord>.broadcast();

  Stream<GpsPositionRecord> get activePositionStream =>
      _activePositionController.stream;

  /// 外部GNSS受信機から垂れ流される全有効測位のストリーム（地図常時表示・`gnss_tracks` 詳細保管用）
  final StreamController<GpsInfo> _externalGnssFixController =
      StreamController<GpsInfo>.broadcast();

  Stream<GpsInfo> get externalGnssFixStream =>
      _externalGnssFixController.stream;

  GnssMapMarker? _currentExternalMarker;

  /// 外部GNSSが接続かつ有効測位（Fixあり）のとき、地図上に描画するライブ位置マーカー
  GnssMapMarker? get currentExternalMarker => _currentExternalMarker;

  // 外部GNSS関連
  BluetoothGnssService? _externalGnssService;
  List<BluetoothDevice> _availableGnssDevices = [];
  BluetoothDevice? _selectedGnssDevice;

  @visibleForTesting
  BluetoothGnssService get ensureExternalServiceForTesting =>
      _ensureExternalGnssService();

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
  bool get isFallbackInternal => _isFallbackInternal;
  bool get isExternalReconnecting =>
      _currentSource == GpsSourceType.external && _isExternalReconnecting;
  bool get isExternalConnected =>
      _currentSource == GpsSourceType.external &&
      (_externalGnssService?.isConnected ?? false);
  bool get isExternalConnecting =>
      _currentSource == GpsSourceType.external &&
      (_externalGnssService?.isConnecting ?? false);
  bool get hasExternalStandby =>
      _currentSource == GpsSourceType.external &&
      _selectedGnssDevice != null &&
      !isExternalConnected &&
      !isExternalConnecting &&
      !_isExternalReconnecting;
  List<BluetoothDevice> get availableGnssDevices =>
      List.unmodifiable(_availableGnssDevices);
  BluetoothDevice? get selectedGnssDevice => _selectedGnssDevice;

  BluetoothGnssService _ensureExternalGnssService() {
    final svc = _externalGnssService ??= BluetoothGnssService();
    svc.onUnexpectedDisconnect = _onExternalUnexpectedDisconnect;
    return svc;
  }

  /// 利用可能なGPSソースリストを取得
  List<GpsSourceOption> getAvailableGpsSources() {
    final devices = <BluetoothDevice>[..._availableGnssDevices];
    if (_selectedGnssDevice != null &&
        !devices.any((d) => d.address == _selectedGnssDevice!.address)) {
      devices.insert(0, _selectedGnssDevice!);
    }
    return [
      // 内蔵GPS（常に利用可能）
      (
        type: GpsSourceType.internal,
        name: GpsSourceType.internal.displayName,
        description: t.gps.internalDescription,
        device: null,
        isSelected: _currentSource == GpsSourceType.internal,
      ),
      // 外部GNSS機器
      for (final device in devices)
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
          _isGpsActive = true;
        case GpsSourceType.external:
          if (_isFallbackInternal) {
            await _startInternalGps();
            _isGpsActive = true;
          } else if (_selectedGnssDevice != null) {
            try {
              await _startExternalGnss(_selectedGnssDevice!);
              _isGpsActive = true;
            } catch (e) {
              // ⚠ 無断で内蔵GPSへフォールバックしない！警告を出して自動再接続ループに入る
              AppLogger.debug('$_logTag: 起動時の外部GNSS接続失敗（自動再接続へ移行）: $e');
              _isGpsActive = false;
              final dev = _selectedGnssDevice!;
              final devName = dev.name ?? t.gps.externalGnssName;
              DeviceConnectionLogService.instance.record(
                category: DeviceConnectionCategory.gnss,
                type: DeviceConnectionEventType.reconnectFailed,
                deviceName: devName,
                deviceAddress: dev.address,
                detail: 'startup: $e',
              );
              _notifyUser(
                title: t.gps.externalDisconnectedTitle(name: devName),
                detail: t.gps.externalDisconnectedDetail,
                level: NotificationLevel.warning,
              );
              _scheduleExternalReconnect('$e');
            }
          } else {
            _currentSource = GpsSourceType.internal;
            await _startInternalGps();
            _isGpsActive = true;
          }
      }

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
    _cancelExternalReconnect();
    if (!_isGpsActive && !_isExternalReconnecting) {
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

      // 外部GNSSモードかつ一時フォールバックしていないのに未接続の場合、
      // 勝手に内蔵GPSへ切り替えず即座に1回再接続を試み、ダメなら明示的にブロックする
      if (_currentSource == GpsSourceType.external && !_isFallbackInternal) {
        if (!isExternalConnected) {
          if (_selectedGnssDevice != null && !isExternalConnecting) {
            try {
              await _startExternalGnss(_selectedGnssDevice!);
              _isGpsActive = true;
            } catch (_) {
              _notifyUser(
                title: t.gps.externalDisconnectedRecordBlocked,
                level: NotificationLevel.warning,
              );
              _scheduleExternalReconnect('survey_attempt');
              _isSurveyMode = false;
              notifyListeners();
              return null;
            }
          } else {
            _notifyUser(
              title: t.gps.externalDisconnectedRecordBlocked,
              level: NotificationLevel.warning,
            );
            _isSurveyMode = false;
            notifyListeners();
            return null;
          }
        } else {
          _isGpsActive = true;
        }
      } else if (!_isGpsActive) {
        await startGps();
      }

      // 位置情報取得まで待機（ポーリング方式）
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < timeout) {
        if (_currentSource == GpsSourceType.external &&
            !_isFallbackInternal &&
            !isExternalConnected) {
          // 待機中に外部GNSSが切れた場合も即中断
          _isSurveyMode = false;
          return null;
        }
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

      if (scanDevicesOverride != null) {
        _availableGnssDevices = await scanDevicesOverride!();
      } else {
        final svc = _ensureExternalGnssService();
        _availableGnssDevices = await svc.scanDevices();
      }

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
      _cancelExternalReconnect();
      _isFallbackInternal = false;

      // 現在のソースを停止（手動切替なので切断ログに manual を残す）
      final prevExternal =
          _currentSource == GpsSourceType.external && isExternalConnected
              ? _selectedGnssDevice
              : null;
      await _stopCurrentSource();
      if (prevExternal != null && sourceType == GpsSourceType.internal) {
        DeviceConnectionLogService.instance.record(
          category: DeviceConnectionCategory.gnss,
          type: DeviceConnectionEventType.disconnected,
          deviceName: prevExternal.name ?? t.gps.externalGnssName,
          deviceAddress: prevExternal.address,
          detail: 'manual',
        );
      }

      _currentSource = sourceType;

      switch (sourceType) {
        case GpsSourceType.internal:
          _selectedGnssDevice = null;
          await _startInternalGps();
          _isGpsActive = true;
        case GpsSourceType.external:
          if (device == null) {
            throw ArgumentError(t.gps.externalDeviceRequired);
          }
          _selectedGnssDevice = device;
          await _startExternalGnss(device);
          _isGpsActive = true;
      }

      // グローバル設定に永続保存
      await _saveSourceToGlobalConfig();

      AppLogger.debug('$_logTag: GPSソース切り替え完了: ${sourceType.displayName}');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: GPSソース切り替えエラー: $e');
      rethrow;
    }
  }

  /// 外部GNSS切断中に、ユーザーの明示選択で端末内蔵GPSへ一時切替する
  ///
  /// 元の外部GNSS設定は保持し、バックグラウンドで外部GNSSへの自動再接続も継続する。
  /// この間に記録した点には `gps_source = 'internal_fallback'` が刻まれる。
  Future<void> enableTemporaryInternalFallback() async {
    if (_currentSource != GpsSourceType.external) return;
    _isFallbackInternal = true;
    _position = null;
    await _startInternalGps();
    _isGpsActive = true;

    final dev = _selectedGnssDevice;
    DeviceConnectionLogService.instance.record(
      category: DeviceConnectionCategory.gnss,
      type: DeviceConnectionEventType.fallbackInternal,
      deviceName: dev?.name ?? t.gps.externalGnssName,
      deviceAddress: dev?.address,
    );
    _notifyUser(
      title: t.gps.switchedToFallbackInternal,
      level: NotificationLevel.warning,
    );
    notifyListeners();
  }

  /// 一時切替していた内蔵GPSを終了し、外部GNSSへの復帰（即時再接続）を試みる
  Future<void> resumeExternalGnssFromFallback() async {
    if (_currentSource != GpsSourceType.external) return;
    _isFallbackInternal = false;
    await _storeSubscription?.cancel();
    _storeSubscription = null;
    _position = null;
    _isGpsActive = false;
    _externalReconnectTimer?.cancel();
    _externalReconnectTimer = null;
    _externalReconnectAttempt = 0;
    notifyListeners();

    final dev = _selectedGnssDevice;
    if (dev != null) {
      await _attemptExternalReconnectNow();
    }
  }

  /// 自動再接続の上限到達後（電源OFF／待機中）に、1タップで外部GNSSへ即座に再接続を試みる
  Future<void> reconnectExternalGnssNow() async {
    final dev = _selectedGnssDevice;
    if (_currentSource != GpsSourceType.external || dev == null) return;
    if (isExternalConnected || isExternalConnecting) return;
    _externalReconnectTimer?.cancel();
    _externalReconnectTimer = null;
    _isExternalReconnecting = false;
    _externalReconnectAttempt = 0;
    await _attemptExternalReconnectNow(manual: true);
  }

  /// 内蔵GPS開始（InternalGpsLocationStoreに委譲）
  Future<void> _startInternalGps() async {
    if (internalStartOverride != null) {
      await internalStartOverride!();
    } else if (!_locationStore.isActive) {
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
    _fixSoundMonitor.reset();
    final wasFallback = _isFallbackInternal;
    final svc = _ensureExternalGnssService();
    svc.removeListener(_onExternalGnssUpdate);
    svc.addListener(_onExternalGnssUpdate);

    try {
      if (externalConnectOverride != null) {
        await BluetoothConnectionCoordinator.instance.runSerializedConnect(
          'GNSS:${device.address}',
          () => externalConnectOverride!(device),
          applySettleDelay: false,
        );
      } else {
        await svc.connectToDevice(device);
      }
      _cancelExternalReconnect();
      if (wasFallback || _isFallbackInternal) {
        _isFallbackInternal = false;
        await _storeSubscription?.cancel();
        _storeSubscription = null;
        _position = null;
      }

      final devName = device.name ?? t.gps.externalGnssName;
      DeviceConnectionLogService.instance.record(
        category: DeviceConnectionCategory.gnss,
        type: wasFallback
            ? DeviceConnectionEventType.resumedExternal
            : DeviceConnectionEventType.connected,
        deviceName: devName,
        deviceAddress: device.address,
      );

      final ntripCfg = _ref?.read(ntripConfigSettingProvider);
      if (ntripCfg != null &&
          ntripCfg.autoConnectWithGnss &&
          ntripCfg.isConfigured &&
          !NtripClientService.instance.isActive) {
        unawaited(NtripClientService.instance.connect(ntripCfg));
      }
    } catch (_) {
      svc.removeListener(_onExternalGnssUpdate);
      rethrow;
    }
  }

  void _onExternalUnexpectedDisconnect(String reason) {
    if (_currentSource != GpsSourceType.external) return;
    final dev = _selectedGnssDevice;
    final devName = dev?.name ?? t.gps.externalGnssName;

    DeviceConnectionLogService.instance.record(
      category: DeviceConnectionCategory.gnss,
      type: DeviceConnectionEventType.disconnected,
      deviceName: devName,
      deviceAddress: dev?.address,
      detail: reason,
    );

    final soundEnabled = _ref?.read(gnssFixSoundSettingProvider) ?? true;
    unawaited(_fixSoundMonitor.playDisconnectAlert(enabled: soundEnabled));

    _currentExternalMarker = null;
    if (!_isFallbackInternal) {
      _position = null;
      _isGpsActive = false;
      if (_isContinuousSurvey) {
        stopContinuousSurvey();
      }
    }

    _notifyUser(
      title: t.gps.externalDisconnectedTitle(name: devName),
      detail: t.gps.externalDisconnectedDetail,
      level: NotificationLevel.error,
    );

    _scheduleExternalReconnect(reason);
    notifyListeners();
  }

  void _scheduleExternalReconnect(String reason) {
    if (_currentSource != GpsSourceType.external ||
        _selectedGnssDevice == null) {
      return;
    }
    _externalReconnectTimer?.cancel();

    // 手動電源OFF・オートパワーオフ時に Bluetooth ページスキャンで電池と 2.4GHz 帯域を食い続けないよう上限で打ち切る
    if (_externalReconnectAttempt >= maxExternalReconnectAttempts) {
      _isExternalReconnecting = false;
      final dev = _selectedGnssDevice!;
      DeviceConnectionLogService.instance.record(
        category: DeviceConnectionCategory.gnss,
        type: DeviceConnectionEventType.reconnectFailed,
        deviceName: dev.name ?? t.gps.externalGnssName,
        deviceAddress: dev.address,
        detail:
            'auto_reconnect_stopped_after_${_externalReconnectAttempt}_attempts (power_off_or_out_of_range)',
      );
      notifyListeners();
      return;
    }

    final idx = _externalReconnectAttempt.clamp(
      0,
      externalReconnectBackoff.length - 1,
    );
    final delay = externalReconnectBackoff[idx];
    _externalReconnectAttempt++;
    _isExternalReconnecting = true;

    final dev = _selectedGnssDevice!;
    DeviceConnectionLogService.instance.record(
      category: DeviceConnectionCategory.gnss,
      type: DeviceConnectionEventType.reconnecting,
      deviceName: dev.name ?? t.gps.externalGnssName,
      deviceAddress: dev.address,
      detail:
          '$reason (attempt $_externalReconnectAttempt/$maxExternalReconnectAttempts in ${delay.inSeconds}s)',
    );
    notifyListeners();

    _externalReconnectTimer = Timer(delay, () {
      unawaited(_attemptExternalReconnectNow());
    });
  }

  Future<void> _attemptExternalReconnectNow({bool manual = false}) async {
    final dev = _selectedGnssDevice;
    if (_currentSource != GpsSourceType.external || dev == null) {
      _cancelExternalReconnect();
      return;
    }
    if (isExternalConnected || isExternalConnecting) return;

    if (externalConnectOverride == null) {
      final btOn = await FlutterBluetoothSerial.instance.isEnabled ?? false;
      if (!btOn) {
        _cancelExternalReconnect();
        notifyListeners();
        return;
      }
    }

    try {
      await _startExternalGnss(dev);
      _isGpsActive = true;
      final devName = dev.name ?? t.gps.externalGnssName;
      _notifyUser(
        title: t.gps.externalReconnectedTitle(name: devName),
        level: NotificationLevel.success,
      );
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: 外部GNSS再接続失敗 (manual=$manual): $e');
      if (manual) {
        _isExternalReconnecting = false;
        DeviceConnectionLogService.instance.record(
          category: DeviceConnectionCategory.gnss,
          type: DeviceConnectionEventType.reconnectFailed,
          deviceName: dev.name ?? t.gps.externalGnssName,
          deviceAddress: dev.address,
          detail: 'manual_reconnect_failed: $e',
        );
        _notifyUser(
          title: t.devices.connectionFailed(error: '$e'),
          level: NotificationLevel.warning,
        );
        notifyListeners();
        return;
      }
      if (_currentSource == GpsSourceType.external &&
          _selectedGnssDevice != null) {
        _scheduleExternalReconnect('$e');
      }
    }
  }

  void _cancelExternalReconnect() {
    _externalReconnectTimer?.cancel();
    _externalReconnectTimer = null;
    _isExternalReconnecting = false;
    _externalReconnectAttempt = 0;
  }

  void _notifyUser({
    required String title,
    String? detail,
    required NotificationLevel level,
  }) {
    try {
      _ref?.read(notificationCenterProvider.notifier).add(
            title: title,
            detail: detail,
            level: level,
          );
    } catch (_) {}
  }

  /// 現在のソースを停止
  Future<void> _stopCurrentSource() async {
    _fixSoundMonitor.reset();
    // Store監視を停止（Store自体は常時稼働のため停止しない）
    await _storeSubscription?.cancel();
    _storeSubscription = null;

    // 外部GNSS停止（自動連動が有効なら NTRIP も一緒に止める）
    if (_externalGnssService != null) {
      _externalGnssService!.removeListener(_onExternalGnssUpdate);
      await _externalGnssService!.disconnect();
    }
    final ntripCfg = _ref?.read(ntripConfigSettingProvider);
    if ((ntripCfg?.autoConnectWithGnss ?? true) &&
        NtripClientService.instance.isActive) {
      await NtripClientService.instance.disconnect();
    }

    // 位置情報クリア
    _position = null;
    _currentExternalMarker = null;
    _satelliteCount = null;
    _hdop = null;
    _gpsQuality = null;
    notifyListeners();
  }

  /// Store位置更新コールバック（内蔵GPS または 一時フォールバック内蔵GPS）
  void _onStorePositionUpdate(GpsPositionRecord record) {
    final acceptsInternal =
        _currentSource == GpsSourceType.internal ||
        (_currentSource == GpsSourceType.external && _isFallbackInternal);
    if (!acceptsInternal) return;
    _onPosition(record);
  }

  /// 外部GNSS位置・状態更新コールバック
  void _onExternalGnssUpdate() {
    final service = _externalGnssService;
    if (_currentSource != GpsSourceType.external || service == null) return;

    _satelliteCount = service.satelliteCount;
    _hdop = service.hdop;
    _gpsQuality = service.gpsQuality;

    // RTK FIX 取得／喪失の効果音判定
    final soundEnabled = _ref?.read(gnssFixSoundSettingProvider) ?? true;
    unawaited(
      _fixSoundMonitor.onExternalFixState(
        enabled: soundEnabled,
        connected: service.isConnected,
        gpsQuality: service.gpsQuality,
      ),
    );

    // 外部GNSSが切断された場合は古い測位を残さず即座に画面へ知らせる
    if (!service.isConnected && !service.isConnecting) {
      _currentExternalMarker = null;
      if (!_isFallbackInternal) {
        _position = null;
        _isGpsActive = false;
      }
      notifyListeners();
      return;
    }

    // 外部GNSSが繋がっている間は一時フォールバックを解除
    if (service.isConnected && _isFallbackInternal) {
      _isFallbackInternal = false;
      unawaited(_storeSubscription?.cancel());
      _storeSubscription = null;
    }

    final latitude = service.latitude;
    final longitude = service.longitude;
    // 未測位（No Fix / 接続直後）でも衛星数・接続状態の変化を画面へ知らせる
    if (latitude == null || longitude == null || service.gpsQuality == 0) {
      _currentExternalMarker = null;
      if (service.gpsQuality == 0 && !_isFallbackInternal) _position = null;
      notifyListeners();
      return;
    }

    final ts = service.timestamp ?? DateTime.now();
    _currentExternalMarker = GnssMapMarker(
      position: LatLng(latitude, longitude),
      gpsQuality: service.gpsQuality,
      deviceName: _selectedGnssDevice?.name,
    );

    if (!_externalGnssFixController.isClosed) {
      _externalGnssFixController.add(
        GpsInfo(
          sourceType: GpsSourceType.external,
          selectedDevice: _selectedGnssDevice?.name,
          latitude: latitude,
          longitude: longitude,
          altitude: service.altitude,
          accuracy: service.accuracy,
          accuracySource: service.accuracySource,
          speed: service.speed,
          bearing: service.bearing,
          timestamp: ts,
          isGpsActive: true,
          isInitialized: _isInitialized,
          isExternalConnected: true,
          satelliteCount: service.satelliteCount,
          hdop: service.hdop,
          pdop: service.pdop,
          vdop: service.vdop,
          gpsQuality: service.gpsQuality,
          fixType: service.fixTypeString,
          correctionSource: service.correctionSource,
          nmea: service.latestGgaSentence,
        ),
      );
    }

    _isGpsActive = true;
    _onPosition(
      GpsPositionRecord(
        latitude: latitude,
        longitude: longitude,
        altitude: service.altitude,
        accuracy: service.accuracy,
        speed: service.speed,
        bearing: service.bearing,
        timestamp: ts,
      ),
    );
  }

  /// 位置が届いた（内蔵・外部共通）。連続測量中ならその時点の状態を 1 点として集める
  void _onPosition(GpsPositionRecord position) {
    _position = position;
    if (!_activePositionController.isClosed) {
      _activePositionController.add(position);
    }

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

  /// テスト用: 内蔵GPSの位置更新を直接注入する
  @visibleForTesting
  void debugInjectInternalPosition(GpsPositionRecord record) =>
      _onStorePositionUpdate(record);

  /// NTRIP から届いた RTCM バイト列を接続中の外部 GNSS へ流す
  bool sendRtcmToExternalGnss(Uint8List data) {
    final gnss = _externalGnssService;
    if (_currentSource != GpsSourceType.external || gnss == null) return false;
    return gnss.sendRtcm(data);
  }

  /// NTRIP VRS アップリンク用の最新 `$GPGGA` 文（外部 GNSS の生 GGA → 現在測位 → 地図中心の順で補完）
  String? buildLatestGgaForNtrip() {
    final rawGga = _externalGnssService?.latestGgaSentence;
    if (rawGga != null) return rawGga;
    final p = _position;
    if (p != null) {
      return NtripGgaFormatter.buildGga(
        latitude: p.latitude,
        longitude: p.longitude,
        altitude: p.altitude ?? 0.0,
        quality: _gpsQuality ?? 1,
        satellites: _satelliteCount ?? 8,
        hdop: _hdop ?? 1.0,
      );
    }
    try {
      final camCenter = _ref?.read(mapControllerHolderProvider)?.camera.center;
      if (camCenter != null) {
        return NtripGgaFormatter.buildGga(
          latitude: camCenter.latitude,
          longitude: camCenter.longitude,
        );
      }
    } catch (_) {}
    return null;
  }

  /// 現在のGPS情報
  GpsInfo get currentInfo => _buildInfo();

  /// [withNmea] は測量で記録するときだけ（NMEA の連結を毎回しない）
  GpsInfo _buildInfo({bool withNmea = false}) {
    final p = _position;
    final useExternalFields =
        _currentSource == GpsSourceType.external && !_isFallbackInternal;
    final gnss = useExternalFields ? _externalGnssService : null;
    final isExternalMode = _currentSource == GpsSourceType.external;
    return GpsInfo(
      sourceType: _currentSource,
      selectedDevice: _selectedGnssDevice?.name,
      latitude: p?.latitude,
      longitude: p?.longitude,
      altitude: p?.altitude,
      accuracy: p?.accuracy,
      accuracySource: gnss?.accuracySource,
      speed: p?.speed,
      bearing: p?.bearing,
      timestamp: p?.timestamp,
      isGpsActive: _isGpsActive,
      isInitialized: _isInitialized,
      isSurveyMode: _isSurveyMode,
      usesForegroundService: _locationStore.isDelegated,
      isExternalConnected:
          isExternalMode && (_externalGnssService?.isConnected ?? false),
      isExternalConnecting:
          isExternalMode && (_externalGnssService?.isConnecting ?? false),
      isExternalReconnecting: isExternalMode && _isExternalReconnecting,
      isFallbackInternal: isExternalMode && _isFallbackInternal,
      // 外部GNSS機器で実際に測位している場合のみ衛星情報・NMEA情報を入れる
      satelliteCount: useExternalFields ? _satelliteCount : null,
      hdop: useExternalFields ? _hdop : null,
      pdop: gnss?.pdop,
      vdop: gnss?.vdop,
      gpsQuality: useExternalFields ? _gpsQuality : null,
      fixType: gnss?.fixTypeString,
      correctionSource: gnss?.correctionSource,
      nmea: withNmea ? gnss?.getNmeaBufferAsString() : null,
    );
  }

  /// グローバル設定にソース設定を永続保存
  Future<void> _saveSourceToGlobalConfig() async {
    final sourceType =
        _currentSource == GpsSourceType.internal ? 'internal' : 'external';
    await _ref?.read(preferredGpsSourceTypeProvider.notifier).set(sourceType);
    await _ref
        ?.read(selectedGnssDeviceAddressProvider.notifier)
        .set(_selectedGnssDevice?.address);
    await _ref
        ?.read(selectedGnssDeviceNameProvider.notifier)
        .set(_selectedGnssDevice?.name);

    AppLogger.debug(
      '$_logTag: GPS設定をグローバル設定に保存: $sourceType (${_selectedGnssDevice?.address})',
    );
  }

  /// グローバル設定からソース設定のみ読み込み（GPS開始はしない）
  Future<void> _loadSourceConfigOnly() async {
    final r = _ref;
    if (r != null) {
      if (r.read(preferredGpsSourceTypeProvider) == null) {
        await r.read(preferredGpsSourceTypeProvider.notifier).load();
      }
      if (r.read(selectedGnssDeviceAddressProvider) == null) {
        await r.read(selectedGnssDeviceAddressProvider.notifier).load();
      }
      if (r.read(selectedGnssDeviceNameProvider) == null) {
        await r.read(selectedGnssDeviceNameProvider.notifier).load();
      }
    }

    final preferredSource = _ref?.read(preferredGpsSourceTypeProvider);
    final savedAddress = _ref?.read(selectedGnssDeviceAddressProvider);
    final savedName = _ref?.read(selectedGnssDeviceNameProvider);

    if (preferredSource == null) {
      _currentSource = GpsSourceType.internal;
      AppLogger.debug('$_logTag: 初回起動のため内蔵GPSを設定');
      return;
    }

    if (preferredSource == 'external' &&
        savedAddress != null &&
        savedAddress.isNotEmpty) {
      _currentSource = GpsSourceType.external;
      _isFallbackInternal = false;
      try {
        await scanExternalGnssDevices();
      } catch (e) {
        AppLogger.debug('$_logTag: 起動時スキャン失敗（保存アドレスで復元継続）: $e');
      }

      final targetDevice =
          _availableGnssDevices
              .where((device) => device.address == savedAddress)
              .firstOrNull ??
          BluetoothDevice(address: savedAddress, name: savedName);

      _selectedGnssDevice = targetDevice;
      AppLogger.debug(
        '$_logTag: 外部GNSS設定を復元: ${targetDevice.name ?? savedAddress}',
      );
      return;
    }

    _currentSource = GpsSourceType.internal;
    AppLogger.debug('$_logTag: 内蔵GPS設定を復元');
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

  /// 連続測量でいちばん最近集めた点（測量していなければ null）
  GpsSurveySample? get latestContinuousSample =>
      _isContinuousSurvey ? _continuousSurveyData.lastOrNull : null;

  /// 連続測量の収集データ（測量の記録に書く形）
  List<Map<String, dynamic>> getContinuousSurveyData() =>
      [for (final sample in _continuousSurveyData) sample.toMap()];

  @visibleForTesting
  void resetForTesting() {
    _cancelExternalReconnect();
    _storeSubscription?.cancel();
    _storeSubscription = null;
    if (_externalGnssService != null) {
      _externalGnssService!.removeListener(_onExternalGnssUpdate);
      _externalGnssService!.onUnexpectedDisconnect = null;
      _externalGnssService = null;
    }
    _isInitialized = false;
    _isGpsActive = false;
    _isSurveyMode = false;
    _currentSource = GpsSourceType.internal;
    _isFallbackInternal = false;
    _availableGnssDevices = [];
    _selectedGnssDevice = null;
    _position = null;
    _currentExternalMarker = null;
    _satelliteCount = null;
    _hdop = null;
    _gpsQuality = null;
    _isContinuousSurvey = false;
    _onContinuousSurveyUpdate = null;
    _continuousSurveyData.clear();
    externalConnectOverride = null;
    scanDevicesOverride = null;
    internalStartOverride = null;
    maxExternalReconnectAttempts = 5;
    externalReconnectBackoff = const [
      Duration(seconds: 3),
      Duration(seconds: 6),
      Duration(seconds: 12),
      Duration(seconds: 20),
      Duration(seconds: 30),
    ];
    _fixSoundMonitor.reset();
  }

  @override
  void dispose() {
    AppLogger.debug('$_logTag: GPS管理サービスを停止中...');
    _cancelExternalReconnect();

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
    _isFallbackInternal = false;

    // 連続測量もクリーンアップ
    _isContinuousSurvey = false;
    _onContinuousSurveyUpdate = null;
    _continuousSurveyData.clear();
    _fixSoundMonitor.dispose();
    unawaited(NtripClientService.instance.disconnect());

    AppLogger.debug('$_logTag: GPS管理サービス停止完了');
    super.dispose();
  }
}
