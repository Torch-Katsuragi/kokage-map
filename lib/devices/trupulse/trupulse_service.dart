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
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../utils/app_logger.dart';
import '../base/device_service.dart';
import '../base/serial_line_buffer.dart';
import 'trupulse_measurement.dart';
import 'trupulse_sentence.dart';

class TruPulseService extends ExternalDeviceService {
  static const String _tag = 'TruPulse';
  /// プロトコル仕様: Bluetooth SPP 38400 baud

  // 接続
  BluetoothConnection? _connection;
  BluetoothDevice? _connectedDevice;
  bool _isConnecting = false;
  bool _isConnected = false;
  StreamSubscription<Uint8List>? _dataSubscription;
  final SerialLineBuffer _lines = SerialLineBuffer();

  // 計測ストリーム
  final _measurementController =
      StreamController<TruPulseMeasurement>.broadcast();
  TruPulseMeasurement? _lastMeasurement;
  int _measurementCount = 0;
  final _heightController = StreamController<double>.broadcast();

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
  BluetoothDevice? get connectedDevice => _connectedDevice;
  TruPulseMeasurement? get lastMeasurement => _lastMeasurement;
  int get measurementCount => _measurementCount;
  Stream<TruPulseMeasurement> get measurementStream =>
      _measurementController.stream;

  /// 高さルーチン（本体の HT モード）の結果（m）。docs/devices/trupulse-360r.md「高さ（HT）」
  Stream<double> get heightStream => _heightController.stream;

  /// 毎木調査の画面が計測を受け取っている間 true。地図の TruPulse ツールは点を作らない
  bool claimedByTally = false;

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

  @override
  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_isConnecting || _isConnected) return;

    try {
      _isConnecting = true;
      notifyListeners();

      AppLogger.debug('$_tag: ${device.name} (${device.address}) に接続中...');

      _connection = await BluetoothConnection.toAddress(device.address);
      _connectedDevice = device;
      _isConnected = true;
      _isConnecting = false;
      _measurementCount = 0;
      _lastMeasurement = null;

      AppLogger.debug('$_tag: ${device.name}に接続成功');

      _startDataReceiving();
      await _sendInitCommands();

      notifyListeners();
    } catch (e) {
      _isConnecting = false;
      _isConnected = false;
      _connectedDevice = null;
      AppLogger.debug('$_tag: 接続エラー: $e');
      notifyListeners();
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      AppLogger.debug('$_tag: 接続を切断中...');
      await _dataSubscription?.cancel();
      _dataSubscription = null;
      await _connection?.close();
      _connection = null;
      _isConnected = false;
      _isConnecting = false;
      _connectedDevice = null;
      _lines.clear();
      AppLogger.debug('$_tag: 切断完了');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_tag: 切断エラー: $e');
    }
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
      return await _pendingQuery!.future
          .timeout(const Duration(seconds: 5));
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
        disconnect();
      },
      onDone: () {
        AppLogger.debug('$_tag: データストリーム終了');
        disconnect();
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
  /// HV は計測、HT は高さルーチンの結果として流す。ML（2点間の連結ベクトル）は器械点からの位置ではないので流さない
  void _parseLine(String line) {
    _addLog(SerialDirection.rx, line);
    if (line.startsWith('\$OK')) return;

    final sentence = TruPulseSentence.parse(line);
    if (sentence is TruPulseVector) {
      final measurement = TruPulseMeasurement(
        hd: sentence.hd, sd: sentence.sd, vd: sentence.vd, az: sentence.az, inc: sentence.inc,
        timestamp: DateTime.now(),
      );
      _lastMeasurement = measurement;
      _measurementCount++;
      _measurementController.add(measurement);
      notifyListeners();
      AppLogger.debug('$_tag: 計測 #$_measurementCount: $measurement');
      return;
    }
    if (sentence is TruPulseHeight) {
      _heightController.add(sentence.heightM);
      notifyListeners();
      AppLogger.debug('$_tag: 高さ ${sentence.heightM.toStringAsFixed(2)} m');
      return;
    }
    if (sentence is TruPulseMissingLine) return;
    // 読めなかった計測の文（低品質ターゲットで距離が空の HV・チェックサム違い）は問い合わせの応答ではない。
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

  @override
  void dispose() {
    disconnect();
    _measurementController.close();
    _heightController.close();
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
