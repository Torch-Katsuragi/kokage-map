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
/// TruPulse 360R Bluetooth SPP 接続サービス
///
/// Bluetooth Classic SPP (38400baud) 経由でTruPulseと通信し、
/// 計測データ（HD, SD, VD, AZ, INC）をパースしてストリームで提供する。
/// - 前回接続機器の永続保存と起動時自動再接続
/// - 電波瞬断時のバックグラウンド自動再接続と接続・切断ログ記録
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/bluetooth_connection_coordinator.dart';
import '../../services/device_connection_log_service.dart';
import '../../utils/app_logger.dart';
import '../base/device_service.dart';
import '../base/serial_line_buffer.dart';
import 'trupulse_measurement.dart';
import 'trupulse_sentence.dart';

class TruPulseService extends ExternalDeviceService {
  static const String _tag = 'TruPulse';
  static const String _savedAddrKey = 'last_trupulse_device_address';
  static const String _savedNameKey = 'last_trupulse_device_name';

  // 接続
  BluetoothConnection? _connection;
  BluetoothDevice? _connectedDevice;
  BluetoothDevice? _reconnectTarget;
  bool _isConnecting = false;
  bool _isConnected = false;
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  StreamSubscription<Uint8List>? _dataSubscription;
  final SerialLineBuffer _lines = SerialLineBuffer();

  /// 予期せぬ切断／自動再接続成功のコールバック（通知センター表示用）
  void Function(String deviceName)? onUnexpectedDisconnect;
  void Function(String deviceName)? onReconnected;

  @visibleForTesting
  int maxReconnectAttempts = 5;

  @visibleForTesting
  List<Duration> reconnectBackoff = const [
    Duration(seconds: 3),
    Duration(seconds: 6),
    Duration(seconds: 12),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  /// テスト用: Bluetooth 実機接続の差し替えフック
  @visibleForTesting
  Future<void> Function(BluetoothDevice device)? connectOverride;

  // 計測ストリーム
  final _measurementController =
      StreamController<TruPulseMeasurement>.broadcast();
  TruPulseMeasurement? _lastMeasurement;
  int _measurementCount = 0;

  // 計測以外のシリアル応答を待つ問い合わせ
  Completer<String>? _pendingQuery;

  // 通信ログ（リングバッファ）
  static const int maxLogEntries = 500;
  final _log = <SerialLogEntry>[];
  final _logNotifier = StreamController<void>.broadcast();
  List<SerialLogEntry> get log => List.unmodifiable(_log);
  Stream<void> get logStream => _logNotifier.stream;

  // Public API
  @override
  String get deviceTypeName => 'TruPulse 360R';
  @override
  bool get isConnected => _isConnected;
  @override
  bool get isConnecting => _isConnecting;
  @override
  bool get isReconnecting => _isReconnecting;
  @override
  bool get hasStandbyDevice =>
      !_isConnected && !_isConnecting && !_isReconnecting && _reconnectTarget != null;

  @override
  Future<void> reconnectStandby() async {
    final dev = _reconnectTarget;
    if (dev == null || _isConnected || _isConnecting) return;
    _reconnectAttempt = 0;
    try {
      await connectToDevice(dev);
    } catch (e) {
      AppLogger.debug('$_tag: 手動再接続失敗: $e');
    }
  }
  BluetoothDevice? get connectedDevice => _connectedDevice ?? _reconnectTarget;
  TruPulseMeasurement? get lastMeasurement => _lastMeasurement;
  int get measurementCount => _measurementCount;
  Stream<TruPulseMeasurement> get measurementStream =>
      _measurementController.stream;

  @override
  Future<List<BluetoothDevice>> scanDevices() async {
    // ⚠ BLUETOOTH_CONNECT 無しの getBondedDevices はプラグインの権限要求の直後にネイティブで落ちる（bluetooth_gnss_service と同じ）
    if (!await Permission.bluetoothConnect.isGranted) return const [];
    final bonded = await FlutterBluetoothSerial.instance.getBondedDevices();
    return bonded.where((d) {
      final name = d.name?.toUpperCase() ?? '';
      return name.contains('TRUPULSE') ||
          name.contains('TP360') ||
          name.contains('LTI');
    }).toList();
  }

  /// アプリ起動時に前回接続していた TruPulse へ自動でつなぎ直す
  Future<void> restorePreviousConnection() async {
    if (_isConnected || _isConnecting) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAddr = prefs.getString(_savedAddrKey);
      if (savedAddr == null || savedAddr.isEmpty) return;
      final savedName = prefs.getString(_savedNameKey);

      BluetoothDevice target = BluetoothDevice(
        address: savedAddr,
        name: savedName ?? deviceTypeName,
      );
      if (connectOverride == null) {
        try {
          final scanned = await scanDevices();
          final matched =
              scanned.where((d) => d.address == savedAddr).firstOrNull;
          if (matched != null) target = matched;
        } catch (_) {}
      }

      try {
        await connectToDevice(target);
      } catch (e) {
        AppLogger.debug('$_tag: 起動時自動再接続失敗（バックグラウンド再試行へ）: $e');
        _reconnectTarget = target;
        DeviceConnectionLogService.instance.record(
          category: DeviceConnectionCategory.rangefinder,
          type: DeviceConnectionEventType.reconnectFailed,
          deviceName: target.name ?? deviceTypeName,
          deviceAddress: target.address,
          detail: 'startup: $e',
        );
        _scheduleReconnect('$e');
      }
    } catch (e) {
      AppLogger.debug('$_tag: 前回接続情報の読み込みエラー: $e');
    }
  }

  @override
  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_isConnecting || _isConnected) return;

    final wasReconnecting = _isReconnecting;
    try {
      _isConnecting = true;
      notifyListeners();

      AppLogger.debug('$_tag: ${device.name} (${device.address}) に接続中...');

      if (connectOverride != null) {
        await BluetoothConnectionCoordinator.instance.runSerializedConnect(
          'TruPulse:${device.address}',
          () => connectOverride!(device),
          applySettleDelay: false,
        );
      } else {
        _connection =
            await BluetoothConnectionCoordinator.instance.runSerializedConnect(
          'TruPulse:${device.address}',
          () => BluetoothConnection.toAddress(device.address),
        );
      }
      _connectedDevice = device;
      _reconnectTarget = device;
      _isConnected = true;
      _isConnecting = false;
      _cancelReconnect();

      AppLogger.debug('$_tag: ${device.name}に接続成功');
      await _saveLastDevice(device);
      DeviceConnectionLogService.instance.record(
        category: DeviceConnectionCategory.rangefinder,
        type: DeviceConnectionEventType.connected,
        deviceName: device.name ?? deviceTypeName,
        deviceAddress: device.address,
        detail: wasReconnecting ? 'auto_reconnected' : null,
      );

      if (_connection != null) {
        _startDataReceiving();
        await _sendInitCommands();
      }

      if (wasReconnecting) {
        onReconnected?.call(device.name ?? deviceTypeName);
      }
      notifyListeners();
    } catch (e) {
      _isConnecting = false;
      _isConnected = false;
      if (!wasReconnecting) {
        _connectedDevice = null;
      }
      AppLogger.debug('$_tag: 接続エラー: $e');
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> disconnect({bool unexpected = false, String? reason}) async {
    final wasConnected = _isConnected;
    final prevDevice = _connectedDevice ?? _reconnectTarget;
    try {
      AppLogger.debug('$_tag: 接続を切断中... (unexpected=$unexpected)');
      if (!unexpected) {
        _cancelReconnect();
        _reconnectTarget = null;
        await _clearSavedDevice();
      }
      await _dataSubscription?.cancel();
      _dataSubscription = null;
      await _connection?.close();
      _connection = null;
      _isConnected = false;
      _isConnecting = false;
      if (!unexpected) {
        _connectedDevice = null;
      }
      _lines.clear();

      if (wasConnected && prevDevice != null) {
        DeviceConnectionLogService.instance.record(
          category: DeviceConnectionCategory.rangefinder,
          type: DeviceConnectionEventType.disconnected,
          deviceName: prevDevice.name ?? deviceTypeName,
          deviceAddress: prevDevice.address,
          detail: unexpected ? (reason ?? 'stream_closed') : 'manual',
        );
      }

      if (unexpected && wasConnected && prevDevice != null) {
        _reconnectTarget = prevDevice;
        onUnexpectedDisconnect?.call(prevDevice.name ?? deviceTypeName);
        _scheduleReconnect(reason ?? 'stream_closed');
      }

      AppLogger.debug('$_tag: 切断完了');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_tag: 切断エラー: $e');
    }
  }

  void _scheduleReconnect(String reason) {
    final target = _reconnectTarget;
    if (target == null) return;
    _reconnectTimer?.cancel();

    // 手動電源OFF・オートパワーオフ時に Bluetooth ページスキャンで電池と 2.4GHz 帯域を食い続けないよう上限で打ち切る
    if (_reconnectAttempt >= maxReconnectAttempts) {
      _isReconnecting = false;
      DeviceConnectionLogService.instance.record(
        category: DeviceConnectionCategory.rangefinder,
        type: DeviceConnectionEventType.reconnectFailed,
        deviceName: target.name ?? deviceTypeName,
        deviceAddress: target.address,
        detail:
            'auto_reconnect_stopped_after_${_reconnectAttempt}_attempts (power_off_or_out_of_range)',
      );
      notifyListeners();
      return;
    }

    final idx = _reconnectAttempt.clamp(0, reconnectBackoff.length - 1);
    final delay = reconnectBackoff[idx];
    _reconnectAttempt++;
    _isReconnecting = true;

    DeviceConnectionLogService.instance.record(
      category: DeviceConnectionCategory.rangefinder,
      type: DeviceConnectionEventType.reconnecting,
      deviceName: target.name ?? deviceTypeName,
      deviceAddress: target.address,
      detail: '$reason (attempt $_reconnectAttempt/$maxReconnectAttempts in ${delay.inSeconds}s)',
    );
    notifyListeners();

    _reconnectTimer = Timer(delay, () async {
      if (!_isReconnecting || _isConnected || _isConnecting) return;
      final dev = _reconnectTarget;
      if (dev == null) return;
      if (connectOverride == null) {
        final btOn = await FlutterBluetoothSerial.instance.isEnabled ?? false;
        if (!btOn) {
          _isReconnecting = false;
          notifyListeners();
          return;
        }
      }
      try {
        await connectToDevice(dev);
      } catch (e) {
        if (_isReconnecting) {
          _scheduleReconnect('$e');
        }
      }
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isReconnecting = false;
    _reconnectAttempt = 0;
  }

  Future<void> _saveLastDevice(BluetoothDevice device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedAddrKey, device.address);
      if (device.name != null && device.name!.isNotEmpty) {
        await prefs.setString(_savedNameKey, device.name!);
      }
    } catch (_) {}
  }

  Future<void> _clearSavedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_savedAddrKey);
      await prefs.remove(_savedNameKey);
    } catch (_) {}
  }

  /// TruPulse初期設定コマンドを送信
  Future<void> _sendInitCommands() async {
    await sendCommand('DU,0'); // Distance Units: meters
    await sendCommand('AU,0'); // Angle Units: degrees
    await sendCommand('MM,0'); // Measurement Mode: HD
  }

  Future<void> sendCommand(String cmd) async {
    try {
      final raw = '\$$cmd';
      _addLog(SerialDirection.tx, raw);
      _connection?.output.add(utf8.encode('$raw\r\n'));
      await _connection?.output.allSent;
      await Future.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      AppLogger.debug('$_tag: コマンド送信エラー ($cmd): $e');
    }
  }

  /// コマンド送信後、最初の非OK応答を返す（5秒タイムアウト）
  Future<String> query(String cmd) async {
    _pendingQuery = Completer<String>();
    await sendCommand(cmd);
    try {
      return await _pendingQuery!.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _pendingQuery = null;
      rethrow;
    }
  }

  void _startDataReceiving() {
    _dataSubscription = _connection!.input!.listen(
      _onDataReceived,
      onError: (error) {
        AppLogger.debug('$_tag: データ受信エラー: $error');
        unawaited(disconnect(unexpected: true, reason: '$error'));
      },
      onDone: () {
        AppLogger.debug('$_tag: データストリーム終了');
        unawaited(disconnect(unexpected: true, reason: 'stream_closed'));
      },
    );
  }

  void _onDataReceived(Uint8List data) {
    try {
      _lines.add(data).forEach(_parseLine);
    } catch (e) {
      AppLogger.debug('$_tag: データ処理エラー: $e');
    }
  }

  /// TruPulseの出力行をパース（文の形は [TruPulseSentence]）
  ///
  /// HV だけを計測として流す。HT（高さルーチンの結果）・ML（2点間の連結ベクトル）は器械点からの位置ではないので流さない
  void _parseLine(String line) {
    _addLog(SerialDirection.rx, line);
    if (line.startsWith('\$OK')) return;

    final sentence = TruPulseSentence.parse(line);
    if (sentence is TruPulseVector) {
      final measurement = TruPulseMeasurement(
        hd: sentence.hd,
        sd: sentence.sd,
        vd: sentence.vd,
        az: sentence.az,
        inc: sentence.inc,
        timestamp: DateTime.now(),
      );
      _lastMeasurement = measurement;
      _measurementCount++;
      _measurementController.add(measurement);
      notifyListeners();
      AppLogger.debug('$_tag: 計測 #$_measurementCount: $measurement');
      return;
    }
    if (sentence is TruPulseMissingLine) return;
    // HT の文と読めなかった計測の文（低品質ターゲットで距離が空の HV・チェックサム違い）は問い合わせの応答ではない。
    // 応答として渡すと `$ID` の問い合わせが計測の文を受け取ってしまう（ID の応答も `$PLTIT,ID,…` なので種類で見る）
    if (TruPulseSentence.isMeasurementLine(line)) return;

    // 計測以外のレスポンス → pendingQuery
    AppLogger.debug('$_tag: response: $line');
    if (_pendingQuery != null && !_pendingQuery!.isCompleted) {
      _pendingQuery!.complete(line);
      _pendingQuery = null;
    }
  }

  // --- Serial commands (TruPulse 360R manual Section 8) ---

  Future<String> queryId() => query('ID');

  /// Measurement Mode: 0=HD, 1=VD, 2=SD, 3=INC, 4=HT, 5=AZ, 6=ML
  Future<void> setMeasurementMode(int mode) => sendCommand('MM,$mode');

  Future<void> remoteFire() => sendCommand('GO');
  Future<void> stopMeasurement() => sendCommand('ST');

  void _addLog(SerialDirection dir, String text) {
    _log.add(SerialLogEntry(dir, text, DateTime.now()));
    if (_log.length > maxLogEntries) _log.removeAt(0);
    _logNotifier.add(null);
  }

  void clearLog() => _log.clear();

  /// テスト用: 受け取った 1 行を処理する
  @visibleForTesting
  void debugReceiveLine(String line) => _parseLine(line);

  /// テスト用: 電波断による予期せぬ切断を模擬する
  @visibleForTesting
  Future<void> debugSimulateUnexpectedDisconnect([String reason = 'link_loss']) =>
      disconnect(unexpected: true, reason: reason);

  @override
  void dispose() {
    _cancelReconnect();
    _reconnectTarget = null;
    unawaited(_dataSubscription?.cancel());
    unawaited(_connection?.close());
    _measurementController.close();
    _logNotifier.close();
    super.dispose();
  }
}

enum SerialDirection { tx, rx }

class SerialLogEntry {
  final SerialDirection direction;
  final String text;
  final DateTime timestamp;
  const SerialLogEntry(this.direction, this.text, this.timestamp);
}
