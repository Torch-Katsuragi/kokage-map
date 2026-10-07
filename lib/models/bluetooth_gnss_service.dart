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
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:location/location.dart';
import 'package:permission_handler/permission_handler.dart' show Permission, PermissionCheckShortcuts;
import 'package:root_maps/utils/app_logger.dart';

import '../devices/base/serial_line_buffer.dart';
import '../i18n/strings.g.dart';

/// Bluetooth GNSS接続サービス
///
/// SSP（Secure Simple Pairing）対応の外部GNSS受信機に接続し、
/// NMEA（GGA・RMC・GSA・GSV）を読んで位置・DOP・補正の種類を持つ。
/// 位置が更新されたら通知する（500ms に 1 回まで）。
class BluetoothGnssService extends ChangeNotifier {
  static const String _logTag = 'BluetoothGNSS';

  // 接続状態
  BluetoothConnection? _connection;
  bool _isConnecting = false;
  bool _isConnected = false;

  // データ受信関連
  StreamSubscription<Uint8List>? _dataSubscription;
  final SerialLineBuffer _lines = SerialLineBuffer();

  // 位置情報
  double? _latitude;
  double? _longitude;
  double? _altitude;
  double? _accuracy;
  double? _speed;
  double? _bearing;
  DateTime? _timestamp;

  // 衛星情報とDOP
  int? _satelliteCount;
  double? _hdop;
  double? _pdop;
  double? _vdop;
  int? _gpsQuality;

  // SBAS衛星情報
  final Set<int> _usedSatellites = {}; // 使用中の衛星PRN番号（複数のGSA文をまとめる）
  String? _detectedSbasSystem; // 検出されたSBASシステム名
  final Set<int> _sbasInView = {}; // 視野内のSBAS衛星（GSVから検出）
  int? _sbasPrn; // 検出されたSBAS衛星のPRN番号

  // DGPS基準局情報（GGA文フィールド14から取得）
  String? _dgpsStationId; // 差分基準局ID（0000-1023）

  // NMEAバッファリング（直近のセンテンスを保持）
  static const int _maxNmeaBufferSize = 20;
  final List<String> _nmeaBuffer = [];

  DateTime? _lastNotificationTime;

  // 接続前の位置情報の許可確認に使う
  final Location _location = Location();

  // Getters
  bool get isConnected => _isConnected;
  double? get latitude => _latitude;
  double? get longitude => _longitude;
  double? get altitude => _altitude;
  double? get accuracy => _accuracy;
  double? get speed => _speed;
  double? get bearing => _bearing;
  DateTime? get timestamp => _timestamp;

  // 衛星情報・DOP用のgetters
  int? get satelliteCount => _satelliteCount;
  double? get hdop => _hdop;
  double? get pdop => _pdop;
  double? get vdop => _vdop;
  int? get gpsQuality => _gpsQuality;

  /// 補正タイプを人間可読な文字列で取得
  /// GGA Quality Indicatorに基づき、SBAS衛星の使用状況も反映
  String get fixTypeString {
    final sbas = _detectedSbasSystem;
    return switch (_gpsQuality) {
      0 => 'No Fix',
      1 => 'GPS',
      // DGPSの場合、SBAS衛星を使用しているか確認
      2 => sbas != null ? 'DGPS($sbas)' : 'DGPS',
      3 => 'PPS',
      4 => 'RTK Fixed',
      5 => 'RTK Float',
      6 => 'Estimated',
      7 => 'Manual',
      8 => 'Simulation',
      // Quality=9はSBASを明示
      9 => sbas != null ? 'SBAS($sbas)' : 'SBAS',
      _ => 'Unknown',
    };
  }

  /// 詳細な補正源情報を取得（様式用）
  /// 全世界スケールで適切な補正局情報を提供
  String get correctionSource {
    switch (_gpsQuality) {
      case 0:
        return t.gps.noCorrection;
      case 1:
        return t.gps.standalone;
      case 2:
      case 9:
        // SBAS/DGPS補正
        if (_detectedSbasSystem != null && _sbasPrn != null) {
          final satName = _sbasSatelliteNames[_sbasPrn!] ?? t.gps.satelliteUnknown;
          return '$_detectedSbasSystem (PRN $_sbasPrn, $satName)';
        } else if (_detectedSbasSystem != null) {
          return _detectedSbasSystem!;
        } else if (_dgpsStationId != null && _dgpsStationId!.isNotEmpty) {
          return t.gps.dgpsStation(id: _dgpsStationId!);
        }
        return t.gps.dgpsUnknown;
      case 4:
        return t.gps.rtkFixedNoBase; // NTRIP接続時に拡張可能
      case 5:
        return t.gps.rtkFloatNoBase;
      default:
        return t.gps.unknown;
    }
  }

  /// SBAS 衛星の PRN → システム名
  static const Map<int, String> _sbasSystems = {
    // MSAS（日本）
    129: 'MSAS', 137: 'MSAS',
    // WAAS（北米）
    131: 'WAAS', 133: 'WAAS', 135: 'WAAS', 138: 'WAAS',
    // EGNOS（欧州）
    120: 'EGNOS', 123: 'EGNOS', 124: 'EGNOS', 126: 'EGNOS', 136: 'EGNOS',
    // GAGAN（インド）
    127: 'GAGAN', 128: 'GAGAN', 132: 'GAGAN',
    // SDCM（ロシア）
    125: 'SDCM', 140: 'SDCM', 141: 'SDCM',
  };

  /// SBAS 衛星の PRN → 衛星名
  static const Map<int, String> _sbasSatelliteNames = {
    // MSAS（日本）
    129: 'MTSAT-1R', 137: 'MTSAT-2',
    // QZSS SLAS
    183: 'QZS-1', 184: 'QZS-2', 189: 'QZS-3', 185: 'QZS-4',
    // WAAS（北米）
    131: 'Eutelsat 117WB', 133: 'SES-15', 135: 'Inmarsat-4F3', 138: 'Anik F1R',
    // EGNOS（欧州）
    120: 'Inmarsat-3F2', 123: 'Astra 5B', 124: 'Eutelsat-5WB', 126: 'Inmarsat-4F2', 136: 'SES-5',
    // GAGAN（インド）
    127: 'GSAT-8', 128: 'GSAT-10', 132: 'GSAT-15',
    // SDCM（ロシア）
    125: 'Luch-5A', 140: 'Luch-5B', 141: 'Luch-4',
  };

  /// NMEA の衛星 ID（33-64）を SBAS の PRN（120-151）に直す
  static int _toSbasPrn(int id) => id < 100 ? id + 87 : id;

  /// 利用可能なBluetoothデバイスをスキャン
  ///
  /// Returns: ペアリング済みのBluetoothデバイスリスト
  Future<List<BluetoothDevice>> scanDevices() async {
    try {
      AppLogger.debug('$_logTag: デバイススキャンを開始');

      // Bluetooth許可を確認
      final bool isEnabled = await FlutterBluetoothSerial.instance.isEnabled ?? false;
      if (!isEnabled) {
        AppLogger.debug('$_logTag: Bluetoothが無効です');
        throw Exception(t.gps.bluetoothDisabled);
      }

      // ⚠ BLUETOOTH_CONNECT が無いまま getBondedDevices を呼ぶと、プラグインが位置情報の権限を要求し、
      // その許可の直後にネイティブ側で SecurityException → アプリごと落ちる（Android 12+）。先に確かめる
      if (!kIsWeb && !await Permission.bluetoothConnect.isGranted) {
        throw Exception(t.gps.bluetoothPermRequired);
      }

      // ペアリング済みデバイスを取得
      final List<BluetoothDevice> devices =
          await FlutterBluetoothSerial.instance.getBondedDevices();
      AppLogger.debug('$_logTag: ${devices.length}個のペアリング済みデバイスを発見');

      return devices;
    } catch (e) {
      AppLogger.debug('$_logTag: デバイススキャンエラー: $e');
      rethrow;
    }
  }

  /// GNSS受信機に接続
  Future<void> connectToDevice(BluetoothDevice device) async {
    if (_isConnecting || _isConnected) {
      AppLogger.debug('$_logTag: 既に接続中または接続済みです');
      return;
    }

    try {
      _isConnecting = true;
      notifyListeners();

      AppLogger.debug('$_logTag: ${device.name} (${device.address}) に接続中...');

      // 位置情報の許可を確認
      await _ensureLocationPermission();

      // Bluetooth接続（SSP対応）
      _connection = await BluetoothConnection.toAddress(device.address);
      _isConnected = true;
      _isConnecting = false;

      AppLogger.debug('$_logTag: ${device.name}に接続成功');

      // データ受信開始
      _startDataReceiving();

      notifyListeners();
    } catch (e) {
      _isConnecting = false;
      _isConnected = false;
      AppLogger.debug('$_logTag: 接続エラー: $e');
      notifyListeners();
      rethrow;
    }
  }

  /// 接続を切断
  Future<void> disconnect() async {
    try {
      AppLogger.debug('$_logTag: 接続を切断中...');

      // データ受信停止
      await _dataSubscription?.cancel();
      _dataSubscription = null;

      // Bluetooth接続切断
      await _connection?.close();
      _connection = null;

      // 状態リセット
      _isConnected = false;
      _isConnecting = false;
      _lines.clear();

      AppLogger.debug('$_logTag: 接続を切断しました');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: 切断エラー: $e');
    }
  }

  /// 位置情報サービスと許可を確かめる（無ければ求める）
  Future<void> _ensureLocationPermission() async {
    try {
      bool serviceEnabled = await _location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _location.requestService();
        if (!serviceEnabled) {
          throw Exception(t.gps.locationServiceDisabled);
        }
      }

      PermissionStatus permissionGranted = await _location.hasPermission();
      if (permissionGranted == PermissionStatus.denied) {
        permissionGranted = await _location.requestPermission();
        if (permissionGranted != PermissionStatus.granted) {
          throw Exception(t.gps.locationPermissionRequired);
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: 位置情報の許可確認エラー: $e');
      rethrow;
    }
  }

  /// データ受信開始
  void _startDataReceiving() {
    _dataSubscription = _connection!.input!.listen(
      _onDataReceived,
      onError: (error) {
        AppLogger.debug('$_logTag: データ受信エラー: $error');
        disconnect();
      },
      onDone: () {
        AppLogger.debug('$_logTag: データストリーム終了');
        disconnect();
      },
    );

    AppLogger.debug('$_logTag: データ受信を開始しました');
  }

  /// 受信したことにする（テスト用。接続せずに NMEA の解析を確かめる）
  @visibleForTesting
  void debugReceive(Uint8List data) => _onDataReceived(data);

  /// 受信データの処理（NMEA 文を行ごとに）
  void _onDataReceived(Uint8List data) {
    try {
      for (final line in _lines.add(data)) {
        _processNmeaSentence(line);
      }
    } catch (e) {
      AppLogger.debug('$_logTag: データ処理エラー: $e');
    }
  }

  /// NMEA文の処理
  void _processNmeaSentence(String sentence) {
    try {
      // NMEAバッファに追加（サイズ制限）
      _nmeaBuffer.add(sentence);
      if (_nmeaBuffer.length > _maxNmeaBufferSize) {
        _nmeaBuffer.removeAt(0);
      }

      // GGA・RMC・GSA は GPS（GP）と複数系統（GN）だけ、GSV はどの系統でも読む
      if (_isGpOrGn(sentence, 'GGA')) {
        _processGgaSentence(sentence);
      } else if (_isGpOrGn(sentence, 'RMC')) {
        _processRmcSentence(sentence);
      } else if (_isGpOrGn(sentence, 'GSA')) {
        _processGsaSentence(sentence);
      } else if (sentence.contains('GSV')) {
        _processGsvSentence(sentence);
      }
    } catch (e) {
      AppLogger.debug('$_logTag: NMEA処理エラー: $sentence - $e');
    }
  }

  static bool _isGpOrGn(String sentence, String type) =>
      sentence.startsWith('\$GP$type') || sentence.startsWith('\$GN$type');

  /// 緯度・経度（ddmm.mmmm / dddmm.mmmm と N/S・E/W）を読む。空なら null
  double? _parseCoordinate(String value, String hemisphere, String negative) {
    if (value.isEmpty || hemisphere.isEmpty) return null;
    final degrees = _parseDMSToDecimal(value);
    return hemisphere == negative ? -degrees : degrees;
  }

  /// GGA文の処理（位置情報）
  void _processGgaSentence(String sentence) {
    final List<String> parts = sentence.split(',');
    if (parts.length < 15) return;

    _latitude = _parseCoordinate(parts[2], parts[3], 'S') ?? _latitude;
    _longitude = _parseCoordinate(parts[4], parts[5], 'W') ?? _longitude;

    // 高度の処理
    if (parts[9].isNotEmpty) {
      _altitude = double.tryParse(parts[9]);
    }

    // 品質インジケータ
    final int quality = int.tryParse(parts[6]) ?? 0;
    final double hdop = double.tryParse(parts[8]) ?? 1.0;
    _gpsQuality = quality;
    _hdop = hdop;
    _accuracy = calculateAccuracy(quality, hdop);

    // 衛星数（フィールド7）
    if (parts[7].isNotEmpty) {
      _satelliteCount = int.tryParse(parts[7]);
    }

    // 差分基準局ID（フィールド14、DGPS使用時のみ。0000-1023）
    final stationId = parts[14].split('*').first; // チェックサム除去
    if (stationId.isNotEmpty) {
      _dgpsStationId = stationId;
    }

    _onFix();
  }

  /// RMC文の処理（推奨最小データ）
  void _processRmcSentence(String sentence) {
    final List<String> parts = sentence.split(',');
    if (parts.length < 13) return;

    // 有効性チェック
    if (parts[2] != 'A') return; // 'A' = active, 'V' = void

    _latitude = _parseCoordinate(parts[3], parts[4], 'S') ?? _latitude;
    _longitude = _parseCoordinate(parts[5], parts[6], 'W') ?? _longitude;

    // 速度（ノット → m/s）
    if (parts[7].isNotEmpty) {
      final double speedKnots = double.tryParse(parts[7]) ?? 0.0;
      _speed = speedKnots * 0.514444;
    }

    // 方位角
    if (parts[8].isNotEmpty) {
      _bearing = double.tryParse(parts[8]);
    }

    _onFix();
  }

  /// 位置が更新された（GGA・RMC 共通）。重複通知を防ぐため通知は 500ms に 1 回まで
  void _onFix() {
    if (_latitude == null || _longitude == null) return;
    final now = DateTime.now();
    _timestamp = now;
    if (_lastNotificationTime == null ||
        now.difference(_lastNotificationTime!).inMilliseconds >= 500) {
      _lastNotificationTime = now;
      notifyListeners();
    }
  }

  /// GSA文の処理（衛星選択・DOP情報）
  /// フォーマット: $GPGSA,A,3,01,02,03,...(12個),PDOP,HDOP,VDOP*CS
  void _processGsaSentence(String sentence) {
    final List<String> parts = sentence.split(',');
    if (parts.length < 18) return;

    // 使用衛星のPRN番号（フィールド3-14、最大12個）。複数のGSA文が送られるのでまとめる
    for (int i = 3; i <= 14; i++) {
      final prn = int.tryParse(parts[i]);
      if (prn != null && prn > 0) _usedSatellites.add(prn);
    }

    // SBAS衛星を検出（まだ検出されていない場合のみ）
    _detectedSbasSystem ??= _usedSatellites
        .map((prn) => _sbasSystems[_toSbasPrn(prn)])
        .nonNulls
        .firstOrNull;

    // PDOP（15）, HDOP（16）, VDOP（17、チェックサム除去）
    if (parts[15].isNotEmpty) {
      _pdop = double.tryParse(parts[15]);
    }
    if (parts[16].isNotEmpty) {
      _hdop = double.tryParse(parts[16]);
    }
    if (parts[17].isNotEmpty) {
      _vdop = double.tryParse(parts[17].split('*').first);
    }
  }

  /// GSV文の処理（視野内衛星情報）
  /// フォーマット: $GPGSV,総文数,文番号,視野内衛星数,{PRN,仰角,方位角,SNR}*最大4衛星,*CS
  void _processGsvSentence(String sentence) {
    final List<String> parts = sentence.split(',');
    if (parts.length < 8) return;

    // 衛星情報は4衛星分ずつ、各衛星4フィールド（PRN,仰角,方位角,SNR）。フィールド4から
    for (int i = 4; i + 3 < parts.length; i += 4) {
      final prn = int.tryParse(parts[i]);
      if (prn == null || prn <= 0) continue;
      // SBAS衛星かどうか（PRN 33-64 または 120-158）
      final isSbas = (prn >= 33 && prn <= 64) || (prn >= 120 && prn <= 158);
      if (!isSbas || !_sbasInView.add(prn)) continue;

      // SBAS衛星が視野内にあれば、検出システムとPRNを更新（知らない衛星は 'SBAS'）
      if (_detectedSbasSystem == null) {
        _detectedSbasSystem = _sbasSystems[_toSbasPrn(prn)] ?? 'SBAS';
        _sbasPrn = _toSbasPrn(prn);
      }
    }
  }

  /// DMS（度分秒）形式を小数度に変換
  double _parseDMSToDecimal(String dms) {
    if (dms.length < 4) return 0.0;

    try {
      // NMEAフォーマット: 緯度: ddmm.mmmm 経度: dddmm.mmmm
      // 小数点前の桁数から度の桁数を判定
      final int degreeLength = switch (dms.indexOf('.')) {
        4 => 2, // 緯度: ddmm.mmmm
        5 => 3, // 経度: dddmm.mmmm
        _ => -1,
      };
      if (degreeLength < 0) {
        AppLogger.debug('$_logTag: DMS変換エラー - 無効なフォーマット: $dms');
        return 0.0;
      }

      final double degrees = double.parse(dms.substring(0, degreeLength));
      final double minutes = double.parse(dms.substring(degreeLength));
      return degrees + (minutes / 60.0);
    } catch (e) {
      AppLogger.debug('$_logTag: DMS変換エラー: $dms - $e');
      return 0.0;
    }
  }

  /// GPS品質とHDOPから精度を推定
  /// （GGA の品質番号: 0 無効・1 単独・2 DGPS・3 PPS・4 RTK 固定解・5 RTK 浮動解・6 推測航法・9 SBAS）
  ///
  /// ⚠ 以前は 3〜5 を一つずつずらして読んでいて、RTK 固定解（4）を浮動解の ×2、浮動解（5）を推測航法の ×5 で
  ///   記録していた（2026-10-07 に修正）
  @visibleForTesting
  static double calculateAccuracy(int quality, double hdop) => switch (quality) {
        0 => 50.0,
        4 => hdop * 1.0,
        5 || 2 || 3 || 9 => hdop * 2.0,
        _ => hdop * 5.0, // 単独・推測航法ほか
      };

  /// 現在のNMEAバッファを文字列として取得
  String getNmeaBufferAsString() {
    return _nmeaBuffer.join('\n');
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
