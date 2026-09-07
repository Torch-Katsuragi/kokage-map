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
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:location/location.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../i18n/strings.g.dart';

/// Bluetooth GNSS接続サービス
///
/// SSP（Secure Simple Pairing）対応の外部GNSS受信機との接続を管理し、
/// NMEAデータを受信してMock Location Providerに位置情報を提供します。
///
/// Features:
/// - SSP（Secure Simple Pairing）対応のBluetooth接続
/// - NMEAデータの解析と位置情報変換
/// - Android Mock Location Provider連携
/// - 自動再接続機能
/// - リアルタイム接続状態監視
class BluetoothGnssService extends ChangeNotifier {
  static const String _logTag = 'BluetoothGNSS';

  // 接続状態
  BluetoothConnection? _connection;
  BluetoothDevice? _connectedDevice;
  bool _isConnecting = false;
  bool _isConnected = false;
  bool _isMockLocationEnabled = false;

  // データ受信関連
  StreamSubscription<Uint8List>? _dataSubscription;
  String _partialData = '';

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
  int? _fixMode; // GSAから取得: 1=No Fix, 2=2D, 3=3D

  // SBAS衛星情報
  List<int> _usedSatellites = []; // 使用中の衛星PRN番号
  String? _detectedSbasSystem; // 検出されたSBASシステム名
  final List<int> _sbasInView = []; // 視野内のSBAS衛星（GSVから検出）
  int? _sbasPrn; // 検出されたSBAS衛星のPRN番号

  // DGPS基準局情報（GGA文フィールド14から取得）
  String? _dgpsStationId; // 差分基準局ID（0000-1023）

  // NMEAバッファリング（直近のセンテンスを保持）
  static const int _maxNmeaBufferSize = 20;
  final List<String> _nmeaBuffer = [];

  // 統計情報
  int _receivedSentenceCount = 0;
  int _validPositionCount = 0;
  DateTime? _lastPositionUpdate;
  DateTime? _lastNotificationTime;

  // Location service for mock location
  final Location _location = Location();

  // Getters
  bool get isConnecting => _isConnecting;
  bool get isConnected => _isConnected;
  bool get isMockLocationEnabled => _isMockLocationEnabled;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  double? get latitude => _latitude;
  double? get longitude => _longitude;
  double? get altitude => _altitude;
  double? get accuracy => _accuracy;
  double? get speed => _speed;
  double? get bearing => _bearing;
  DateTime? get timestamp => _timestamp;
  int get receivedSentenceCount => _receivedSentenceCount;
  int get validPositionCount => _validPositionCount;
  DateTime? get lastPositionUpdate => _lastPositionUpdate;

  // 衛星情報・DOP用のgetters
  int? get satelliteCount => _satelliteCount;
  double? get hdop => _hdop;
  double? get pdop => _pdop;
  double? get vdop => _vdop;
  int? get gpsQuality => _gpsQuality;
  int? get fixMode => _fixMode;
  List<int> get usedSatellites => List.unmodifiable(_usedSatellites);
  String? get detectedSbasSystem => _detectedSbasSystem;
  int? get sbasPrn => _sbasPrn;
  String? get dgpsStationId => _dgpsStationId;
  List<int> get sbasInView => List.unmodifiable(_sbasInView);

  /// 直近のNMEAセンテンスを取得
  List<String> get recentNmeaSentences => List.unmodifiable(_nmeaBuffer);

  /// 補正タイプを人間可読な文字列で取得
  /// GGA Quality Indicatorに基づき、SBAS衛星の使用状況も反映
  String get fixTypeString {
    switch (_gpsQuality) {
      case 0:
        return 'No Fix';
      case 1:
        return 'GPS';
      case 2:
        // DGPSの場合、SBAS衛星を使用しているか確認
        if (_detectedSbasSystem != null) {
          return 'DGPS($_detectedSbasSystem)';
        }
        return 'DGPS';
      case 3:
        return 'PPS';
      case 4:
        return 'RTK Fixed';
      case 5:
        return 'RTK Float';
      case 6:
        return 'Estimated';
      case 7:
        return 'Manual';
      case 8:
        return 'Simulation';
      case 9:
        // Quality=9はSBASを明示
        if (_detectedSbasSystem != null) {
          return 'SBAS($_detectedSbasSystem)';
        }
        return 'SBAS';
      default:
        return 'Unknown';
    }
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
          final satName = _getSbasSatelliteName(_sbasPrn!);
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

  /// SBAS衛星PRN番号から衛星名を取得
  String _getSbasSatelliteName(int prn) {
    // MSAS（日本）
    if (prn == 129) return 'MTSAT-1R';
    if (prn == 137) return 'MTSAT-2';
    // QZSS SLAS
    if (prn == 183) return 'QZS-1';
    if (prn == 184) return 'QZS-2';
    if (prn == 189) return 'QZS-3';
    if (prn == 185) return 'QZS-4';
    // WAAS（北米）
    if (prn == 131) return 'Eutelsat 117WB';
    if (prn == 133) return 'SES-15';
    if (prn == 135) return 'Inmarsat-4F3';
    if (prn == 138) return 'Anik F1R';
    // EGNOS（欧州）
    if (prn == 120) return 'Inmarsat-3F2';
    if (prn == 123) return 'Astra 5B';
    if (prn == 124) return 'Eutelsat-5WB';
    if (prn == 126) return 'Inmarsat-4F2';
    if (prn == 136) return 'SES-5';
    // GAGAN（インド）
    if (prn == 127) return 'GSAT-8';
    if (prn == 128) return 'GSAT-10';
    if (prn == 132) return 'GSAT-15';
    // SDCM（ロシア）
    if (prn == 125) return 'Luch-5A';
    if (prn == 140) return 'Luch-5B';
    if (prn == 141) return 'Luch-4';
    // NMEA ID（33-64）からの変換
    final actualPrn = prn < 100 ? prn + 87 : prn;
    if (actualPrn != prn) {
      return _getSbasSatelliteName(actualPrn);
    }
    return t.gps.satelliteUnknown;
  }

  /// SBAS衛星のPRN番号からシステム名を判定
  /// PRN範囲: 120-158（NMEA衛星IDでは33-64として報告される場合あり）
  String? _detectSbasSystem(List<int> satellites) {
    for (final prn in satellites) {
      // NMEAでの衛星ID（33-64）をPRNに変換する場合も考慮
      final actualPrn = prn < 100 ? prn + 87 : prn;

      // MSAS（日本）: PRN 129, 137
      if (actualPrn == 129 || actualPrn == 137) {
        return 'MSAS';
      }
      // WAAS（北米）: PRN 131, 133, 135, 138
      if ([131, 133, 135, 138].contains(actualPrn)) {
        return 'WAAS';
      }
      // EGNOS（欧州）: PRN 120, 123, 124, 126, 136
      if ([120, 123, 124, 126, 136].contains(actualPrn)) {
        return 'EGNOS';
      }
      // GAGAN（インド）: PRN 127, 128, 132
      if ([127, 128, 132].contains(actualPrn)) {
        return 'GAGAN';
      }
      // SDCM（ロシア）: PRN 125, 140, 141
      if ([125, 140, 141].contains(actualPrn)) {
        return 'SDCM';
      }
    }
    return null;
  }

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
  ///
  /// [device] 接続対象のBluetoothデバイス
  /// [enableMockLocation] Mock Location Providerを有効にするかどうか
  Future<void> connectToDevice(
    BluetoothDevice device, {
    bool enableMockLocation = true,
  }) async {
    if (_isConnecting || _isConnected) {
      AppLogger.debug('$_logTag: 既に接続中または接続済みです');
      return;
    }

    try {
      _isConnecting = true;
      notifyListeners();

      AppLogger.debug('$_logTag: ${device.name} (${device.address}) に接続中...');

      // Mock Location許可を設定
      if (enableMockLocation) {
        await _setupMockLocation();
      }

      // Bluetooth接続（SSP対応）
      _connection = await BluetoothConnection.toAddress(device.address);
      _connectedDevice = device;
      _isConnected = true;
      _isConnecting = false;

      AppLogger.debug('$_logTag: ${device.name}に接続成功');

      // データ受信開始
      _startDataReceiving();

      notifyListeners();
    } catch (e) {
      _isConnecting = false;
      _isConnected = false;
      _connectedDevice = null;
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
      _connectedDevice = null;
      _partialData = '';

      AppLogger.debug('$_logTag: 接続を切断しました');
      notifyListeners();
    } catch (e) {
      AppLogger.debug('$_logTag: 切断エラー: $e');
    }
  }

  /// Mock Location Providerの設定
  Future<void> _setupMockLocation() async {
    try {
      // 位置情報許可を確認
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

      _isMockLocationEnabled = true;
      AppLogger.debug('$_logTag: Mock Location Providerを設定しました');
    } catch (e) {
      AppLogger.debug('$_logTag: Mock Location設定エラー: $e');
      _isMockLocationEnabled = false;
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

  /// 受信データの処理
  void _onDataReceived(Uint8List data) {
    try {
      final String dataString = utf8.decode(data);
      _partialData += dataString;

      // NMEA文を行ごとに処理
      final List<String> lines = _partialData.split('\n');
      _partialData = lines.last; // 最後の不完全な行を保持

      for (int i = 0; i < lines.length - 1; i++) {
        final String line = lines[i].trim();
        if (line.isNotEmpty) {
          _processNmeaSentence(line);
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: データ処理エラー: $e');
    }
  }

  /// NMEA文の処理
  void _processNmeaSentence(String sentence) {
    try {
      _receivedSentenceCount++;

      // NMEAバッファに追加（サイズ制限）
      _nmeaBuffer.add(sentence);
      if (_nmeaBuffer.length > _maxNmeaBufferSize) {
        _nmeaBuffer.removeAt(0);
      }

      // NMEA解析（GGA, RMC, GSA, GSVに対応）
      if (sentence.startsWith('\$GPGGA') || sentence.startsWith('\$GNGGA')) {
        _processGgaSentence(sentence);
      } else if (sentence.startsWith('\$GPRMC') ||
          sentence.startsWith('\$GNRMC')) {
        _processRmcSentence(sentence);
      } else if (sentence.startsWith('\$GPGSA') ||
          sentence.startsWith('\$GNGSA')) {
        _processGsaSentence(sentence);
      } else if (sentence.contains('GSV')) {
        _processGsvSentence(sentence);
      }
    } catch (e) {
      AppLogger.debug('$_logTag: NMEA処理エラー: $sentence - $e');
    }
  }

  /// GGA文の処理（位置情報）
  void _processGgaSentence(String sentence) {
    try {
      final List<String> parts = sentence.split(',');
      if (parts.length >= 15) {
        // 緯度の処理
        if (parts[2].isNotEmpty && parts[3].isNotEmpty) {
          double lat = _parseDMSToDecimal(parts[2]);
          if (parts[3] == 'S') lat = -lat;
          _latitude = lat;
        }

        // 経度の処理
        if (parts[4].isNotEmpty && parts[5].isNotEmpty) {
          double lon = _parseDMSToDecimal(parts[4]);
          if (parts[5] == 'W') lon = -lon;
          _longitude = lon;
        }

        // 高度の処理
        if (parts[9].isNotEmpty) {
          _altitude = double.tryParse(parts[9]);
        }

        // 品質インジケータ
        final int quality = int.tryParse(parts[6]) ?? 0;
        final double hdop = double.tryParse(parts[8]) ?? 1.0;
        _gpsQuality = quality;
        _hdop = hdop;
        _accuracy = _calculateAccuracy(quality, hdop);

        // 衛星数の取得（GGA文の7番目のフィールド）
        if (parts.length > 7 && parts[7].isNotEmpty) {
          _satelliteCount = int.tryParse(parts[7]);
        }

        // 差分基準局ID（GGA文の14番目のフィールド、DGPS使用時のみ）
        // フォーマット: 0000-1023
        if (parts.length > 14 && parts[14].isNotEmpty) {
          final stationIdStr = parts[14].split('*').first; // チェックサム除去
          if (stationIdStr.isNotEmpty) {
            _dgpsStationId = stationIdStr;
          }
        }

        if (_latitude != null && _longitude != null) {
          _timestamp = DateTime.now();
          _lastPositionUpdate = _timestamp;
          _validPositionCount++;

          // Mock Locationに位置情報を送信
          if (_isMockLocationEnabled) {
            _sendToMockLocation();
          }

          // 重複通知を防ぐため、最小間隔（500ms）でnotifyListenersを制限
          final now = DateTime.now();
          if (_lastNotificationTime == null ||
              now.difference(_lastNotificationTime!).inMilliseconds >= 500) {
            _lastNotificationTime = now;
            notifyListeners();
          }
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: GGA処理エラー: $e');
    }
  }

  /// RMC文の処理（推奨最小データ）
  void _processRmcSentence(String sentence) {
    try {
      final List<String> parts = sentence.split(',');
      if (parts.length >= 13) {
        // 有効性チェック
        if (parts[2] != 'A') return; // 'A' = active, 'V' = void

        // 緯度の処理
        if (parts[3].isNotEmpty && parts[4].isNotEmpty) {
          double lat = _parseDMSToDecimal(parts[3]);
          if (parts[4] == 'S') lat = -lat;
          _latitude = lat;
        }

        // 経度の処理
        if (parts[5].isNotEmpty && parts[6].isNotEmpty) {
          double lon = _parseDMSToDecimal(parts[5]);
          if (parts[6] == 'W') lon = -lon;
          _longitude = lon;
        }

        // 速度（ノット）
        if (parts[7].isNotEmpty) {
          final double speedKnots = double.tryParse(parts[7]) ?? 0.0;
          _speed = speedKnots * 0.514444; // ノットからm/sに変換
        }

        // 方位角
        if (parts[8].isNotEmpty) {
          _bearing = double.tryParse(parts[8]);
        }

        if (_latitude != null && _longitude != null) {
          _timestamp = DateTime.now();
          _lastPositionUpdate = _timestamp;
          _validPositionCount++;

          // Mock Locationに位置情報を送信
          if (_isMockLocationEnabled) {
            _sendToMockLocation();
          }

          // 重複通知を防ぐため、最小間隔（500ms）でnotifyListenersを制限
          final now = DateTime.now();
          if (_lastNotificationTime == null ||
              now.difference(_lastNotificationTime!).inMilliseconds >= 500) {
            _lastNotificationTime = now;
            notifyListeners();
          }
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: RMC処理エラー: $e');
    }
  }

  /// GSA文の処理（衛星選択・DOP情報）
  /// フォーマット: $GPGSA,A,3,01,02,03,...(12個),PDOP,HDOP,VDOP*CS
  void _processGsaSentence(String sentence) {
    try {
      final List<String> parts = sentence.split(',');
      if (parts.length >= 18) {
        // Fix Mode: 1=No Fix, 2=2D, 3=3D
        if (parts[2].isNotEmpty) {
          _fixMode = int.tryParse(parts[2]);
        }

        // 使用衛星のPRN番号を抽出（フィールド3-14、最大12個）
        final satellites = <int>[];
        for (int i = 3; i <= 14 && i < parts.length; i++) {
          if (parts[i].isNotEmpty) {
            final prn = int.tryParse(parts[i]);
            if (prn != null && prn > 0) {
              satellites.add(prn);
            }
          }
        }

        // 既存のSBAS検出を維持しつつ、新しい衛星リストをマージ
        // （複数のGSA文が送られる場合に対応）
        if (_usedSatellites.isEmpty) {
          _usedSatellites = satellites;
        } else {
          // 既存リストに新しい衛星を追加（重複除去）
          final mergedSet = {..._usedSatellites, ...satellites};
          _usedSatellites = mergedSet.toList();
        }

        // SBAS衛星を検出（まだ検出されていない場合のみ）
        _detectedSbasSystem ??= _detectSbasSystem(_usedSatellites);

        // PDOP（位置15）, HDOP（位置16）, VDOP（位置17、チェックサム除去）
        // 注: フィールド位置は0-indexedなので、parts[15]はPDOP
        if (parts.length > 15 && parts[15].isNotEmpty) {
          _pdop = double.tryParse(parts[15]);
        }
        if (parts.length > 16 && parts[16].isNotEmpty) {
          _hdop = double.tryParse(parts[16]);
        }
        // VDOPはチェックサム付きの場合があるので除去
        if (parts.length > 17 && parts[17].isNotEmpty) {
          final String vdopStr = parts[17].split('*').first;
          _vdop = double.tryParse(vdopStr);
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: GSA処理エラー: $e');
    }
  }

  /// GSV文の処理（視野内衛星情報）
  /// フォーマット: $GPGSV,総文数,文番号,視野内衛星数,{PRN,仰角,方位角,SNR}*最大4衛星,*CS
  void _processGsvSentence(String sentence) {
    try {
      final List<String> parts = sentence.split(',');
      if (parts.length < 8) return;

      // 衛星情報は4衛星分ずつ、各衛星4フィールド（PRN,仰角,方位角,SNR）
      // フィールド4から開始
      for (int i = 4; i + 3 < parts.length; i += 4) {
        if (parts[i].isNotEmpty) {
          final prn = int.tryParse(parts[i]);
          if (prn != null && prn > 0) {
            // SBAS衛星かどうかチェック（PRN 33-64 または 120-158）
            if ((prn >= 33 && prn <= 64) || (prn >= 120 && prn <= 158)) {
              if (!_sbasInView.contains(prn)) {
                _sbasInView.add(prn);
                final sbasName = _detectSbasSystemFromPrn(prn);

                // SBAS衛星が視野内にあれば、検出システムとPRNを更新
                if (_detectedSbasSystem == null && sbasName != null) {
                  _detectedSbasSystem = sbasName;
                  // PRN番号を保存（NMEA IDの場合は変換）
                  _sbasPrn = prn < 100 ? prn + 87 : prn;
                }
              }
            }
          }
        }
      }
    } catch (e) {
      AppLogger.debug('$_logTag: GSV処理エラー: $e');
    }
  }

  /// 単一のPRN番号からSBASシステム名を判定
  String? _detectSbasSystemFromPrn(int prn) {
    // NMEAでの衛星ID（33-64）をPRNに変換
    final actualPrn = prn < 100 ? prn + 87 : prn;

    // MSAS（日本）: PRN 129, 137
    if (actualPrn == 129 || actualPrn == 137) return 'MSAS';
    // WAAS（北米）: PRN 131, 133, 135, 138
    if ([131, 133, 135, 138].contains(actualPrn)) return 'WAAS';
    // EGNOS（欧州）: PRN 120, 123, 124, 126, 136
    if ([120, 123, 124, 126, 136].contains(actualPrn)) return 'EGNOS';
    // GAGAN（インド）: PRN 127, 128, 132
    if ([127, 128, 132].contains(actualPrn)) return 'GAGAN';
    // SDCM（ロシア）: PRN 125, 140, 141
    if ([125, 140, 141].contains(actualPrn)) return 'SDCM';

    return 'SBAS'; // 不明なSBAS衛星
  }

  /// DMS（度分秒）形式を小数度に変換
  double _parseDMSToDecimal(String dms) {
    if (dms.length < 4) return 0.0;

    try {
      // NMEAフォーマット: 緯度: ddmm.mmmm 経度: dddmm.mmmm
      // 小数点の位置を見つけて正確に分割
      final int dotIndex = dms.indexOf('.');
      if (dotIndex == -1) {
        AppLogger.debug('$_logTag: DMS変換エラー - 小数点が見つかりません: $dms');
        return 0.0;
      }

      // 小数点前の桁数から度の桁数を判定
      int degreeLength;
      if (dotIndex == 4) {
        degreeLength = 2; // 緯度: ddmm.mmmm
      } else if (dotIndex == 5) {
        degreeLength = 3; // 経度: dddmm.mmmm
      } else {
        AppLogger.debug('$_logTag: DMS変換エラー - 無効なフォーマット: $dms');
        return 0.0;
      }

      // 度と分を分離
      final String degreesPart = dms.substring(0, degreeLength);
      final String minutesPart = dms.substring(degreeLength);

      final double degrees = double.parse(degreesPart);
      final double minutes = double.parse(minutesPart);

      final double result = degrees + (minutes / 60.0);

      return result;
    } catch (e) {
      AppLogger.debug('$_logTag: DMS変換エラー: $dms - $e');
      return 0.0;
    }
  }

  /// 精度の計算
  double _calculateAccuracy(int? quality, double? hdop) {
    // GPS品質とHDOPから精度を推定
    if (quality == null || hdop == null) return 10.0;

    switch (quality) {
      case 0:
        return 50.0; // 無効
      case 1:
        return hdop * 5.0; // 標準GPS
      case 2:
        return hdop * 2.0; // DGPS
      case 3:
        return hdop * 1.0; // RTK固定解
      case 4:
        return hdop * 2.0; // RTK浮動小数点解
      case 5:
        return hdop * 5.0; // 推測航法
      default:
        return hdop * 5.0;
    }
  }

  /// Mock Location Providerに位置情報を送信
  Future<void> _sendToMockLocation() async {
    if (!_isMockLocationEnabled || _latitude == null || _longitude == null) {
      return;
    }

    try {
      // Androidのネイティブコードを呼び出してMock Locationを設定
      // 実装はAndroidプラットフォーム固有のコードが必要
    } catch (e) {
      AppLogger.debug('$_logTag: Mock Location送信エラー: $e');
    }
  }

  /// 接続状態の統計情報を取得
  Map<String, dynamic> getConnectionStats() {
    return {
      'isConnected': _isConnected,
      'connectedDevice': _connectedDevice?.name,
      'deviceAddress': _connectedDevice?.address,
      'receivedSentences': _receivedSentenceCount,
      'validPositions': _validPositionCount,
      'lastUpdate': _lastPositionUpdate?.toIso8601String(),
      'currentPosition': {
        'latitude': _latitude,
        'longitude': _longitude,
        'altitude': _altitude,
        'accuracy': _accuracy,
        'speed': _speed,
        'bearing': _bearing,
        'satelliteCount': _satelliteCount,
        'hdop': _hdop,
        'pdop': _pdop,
        'vdop': _vdop,
        'gpsQuality': _gpsQuality,
        'fixMode': _fixMode,
        'fixType': fixTypeString,
      },
    };
  }

  /// NMEAバッファをクリア
  void clearNmeaBuffer() {
    _nmeaBuffer.clear();
  }

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
