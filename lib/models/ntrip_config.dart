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

/// 内蔵 NTRIP クライアントの設定・SOURCETABLE マウントポイント解析・RTCM3 フレーム検査・GGA 整形
///
/// `dart:io` に依存しない純粋 Dart モジュール（Web ビルドでもそのまま通る）。
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../utils/geodesic.dart';

/// NTRIP キャスター接続設定（端末ローカルの SharedPreferences に保存）
@immutable
class NtripConfig {
  const NtripConfig({
    this.host = '',
    this.port = 2101,
    this.mountpoint = '',
    this.username = '',
    this.password = '',
    this.useTls = false,
    this.sendGga = true,
    this.ggaIntervalSeconds = 10,
    this.autoConnectWithGnss = true,
  });

  static const defaults = NtripConfig();

  static const List<int> ggaIntervalOptions = [5, 10, 30, 60];

  final String host;
  final int port;
  final String mountpoint;
  final String username;
  final String password;
  final bool useTls;

  /// VRS・最寄り基準局向けに NMEA `$GPGGA` を定期送信するか
  final bool sendGga;
  final int ggaIntervalSeconds;

  /// 外部 Bluetooth GNSS の接続に連動して NTRIP を自動開始・自動停止するか
  final bool autoConnectWithGnss;

  String get trimmedHost => host.trim();
  String get normalizedMountpoint {
    final m = mountpoint.trim();
    return m.startsWith('/') ? m.substring(1) : m;
  }

  bool get canFetchMountpoints => trimmedHost.isNotEmpty && port > 0 && port <= 65535;
  bool get isConfigured => canFetchMountpoints && normalizedMountpoint.isNotEmpty;

  NtripConfig copyWith({
    String? host,
    int? port,
    String? mountpoint,
    String? username,
    String? password,
    bool? useTls,
    bool? sendGga,
    int? ggaIntervalSeconds,
    bool? autoConnectWithGnss,
  }) =>
      NtripConfig(
        host: host ?? this.host,
        port: port ?? this.port,
        mountpoint: mountpoint ?? this.mountpoint,
        username: username ?? this.username,
        password: password ?? this.password,
        useTls: useTls ?? this.useTls,
        sendGga: sendGga ?? this.sendGga,
        ggaIntervalSeconds: ggaIntervalSeconds ?? this.ggaIntervalSeconds,
        autoConnectWithGnss: autoConnectWithGnss ?? this.autoConnectWithGnss,
      );

  Map<String, Object?> toJson() => {
        'host': host,
        'port': port,
        'mountpoint': mountpoint,
        'username': username,
        'password': password,
        'useTls': useTls,
        'sendGga': sendGga,
        'ggaIntervalSeconds': ggaIntervalSeconds,
        'autoConnectWithGnss': autoConnectWithGnss,
      };

  static NtripConfig fromJson(Map<dynamic, dynamic> j) => NtripConfig(
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 2101,
        mountpoint: j['mountpoint'] as String? ?? '',
        username: j['username'] as String? ?? '',
        password: j['password'] as String? ?? '',
        useTls: j['useTls'] as bool? ?? false,
        sendGga: j['sendGga'] as bool? ?? true,
        ggaIntervalSeconds: ((j['ggaIntervalSeconds'] as num?)?.toInt() ?? 10).clamp(1, 300),
        autoConnectWithGnss: j['autoConnectWithGnss'] as bool? ?? true,
      );

  @override
  bool operator ==(Object other) =>
      other is NtripConfig &&
      other.host == host &&
      other.port == port &&
      other.mountpoint == mountpoint &&
      other.username == username &&
      other.password == password &&
      other.useTls == useTls &&
      other.sendGga == sendGga &&
      other.ggaIntervalSeconds == ggaIntervalSeconds &&
      other.autoConnectWithGnss == autoConnectWithGnss;

  @override
  int get hashCode => Object.hash(
        host,
        port,
        mountpoint,
        username,
        password,
        useTls,
        sendGga,
        ggaIntervalSeconds,
        autoConnectWithGnss,
      );
}

/// NTRIP `SOURCETABLE` の `STR;`（ストリームレコード）1 件
@immutable
class NtripMountpoint {
  const NtripMountpoint({
    required this.mountpoint,
    required this.identifier,
    required this.format,
    required this.formatDetails,
    required this.carrier,
    required this.navSystem,
    required this.network,
    required this.country,
    this.latitude,
    this.longitude,
    this.requiresNmea = false,
    this.isNetworkSolution = false,
    this.authType = 'N',
  });

  final String mountpoint;
  final String identifier;
  final String format;
  final String formatDetails;
  final int carrier;
  final String navSystem;
  final String network;
  final String country;
  final double? latitude;
  final double? longitude;
  final bool requiresNmea;
  final bool isNetworkSolution;
  final String authType;

  /// 基準局の有効な概略座標（0, 0 の仮想基準点などは null）
  LatLng? get stationLocation {
    final lat = latitude;
    final lon = longitude;
    if (lat == null || lon == null) return null;
    if (lat == 0.0 && lon == 0.0) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return LatLng(lat, lon);
  }

  /// 現在位置 [from] からの距離（km）。座標不明・VRS なら null
  double? distanceKmFrom(LatLng? from) {
    final stn = stationLocation;
    if (from == null || stn == null) return null;
    return Geodesic.distance(from, stn) / 1000.0;
  }

  /// SOURCETABLE 応答テキストから `STR;` 行を抽出してパースする
  static List<NtripMountpoint> parseSourcetable(String rawText) {
    final results = <NtripMountpoint>[];
    for (final rawLine in rawText.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line == 'ENDSOURCETABLE') break;
      if (!line.startsWith('STR;')) continue;
      final p = line.split(';');
      if (p.length < 13) continue;
      final mp = p[1].trim();
      if (mp.isEmpty) continue;
      results.add(
        NtripMountpoint(
          mountpoint: mp,
          identifier: p[2].trim(),
          format: p[3].trim(),
          formatDetails: p[4].trim(),
          carrier: int.tryParse(p[5].trim()) ?? 0,
          navSystem: p[6].trim(),
          network: p[7].trim(),
          country: p[8].trim(),
          latitude: double.tryParse(p[9].trim()),
          longitude: double.tryParse(p[10].trim()),
          requiresNmea: p[11].trim() == '1',
          isNetworkSolution: p[12].trim() == '1',
          authType: p.length > 15 ? p[15].trim() : 'N',
        ),
      );
    }
    return results;
  }
}

/// RTCM 3.x バイナリストリームのフレーム検証・メッセージ番号集計器
///
/// 受信バイト列自体は遅延ゼロでそのまま外部 GNSS へ流しつつ、並行して
/// `0xD3` プリアンブル + 10bit 長 + CRC-24Q を検証し、有効フレーム数とメッセージ番号（1005, 1077, 1117 等）を数える。
class Rtcm3StreamInspector {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  int _validFrames = 0;
  final Set<int> _messageTypes = <int>{};

  int get validFrames => _validFrames;
  List<int> get sortedMessageTypes => _messageTypes.toList()..sort();

  void reset() {
    _buf.clear();
    _validFrames = 0;
    _messageTypes.clear();
  }

  void addChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _buf.add(chunk);
    final bytes = _buf.takeBytes();
    var offset = 0;

    while (offset < bytes.length) {
      // 0xD3 プリアンブルを探す
      if (bytes[offset] != 0xD3) {
        offset++;
        continue;
      }
      if (offset + 3 > bytes.length) break;

      // 上位 6bit の予約ビットは必ず 0
      final b1 = bytes[offset + 1];
      if ((b1 & 0xFC) != 0) {
        offset++;
        continue;
      }

      final payloadLen = ((b1 & 0x03) << 8) | bytes[offset + 2];
      final frameLen = 3 + payloadLen + 3; // ヘッダ3B + ペイロード + CRC24Q 3B
      if (offset + frameLen > bytes.length) {
        // 次のチャンク待ち
        break;
      }

      final expectedCrc = crc24q(bytes, offset, 3 + payloadLen);
      final c0 = bytes[offset + 3 + payloadLen];
      final c1 = bytes[offset + 3 + payloadLen + 1];
      final c2 = bytes[offset + 3 + payloadLen + 2];
      final actualCrc = (c0 << 16) | (c1 << 8) | c2;

      if (expectedCrc == actualCrc) {
        _validFrames++;
        if (payloadLen >= 2) {
          final msgNum = ((bytes[offset + 3] << 4) | (bytes[offset + 4] >> 4)) & 0xFFF;
          if (msgNum > 0) _messageTypes.add(msgNum);
        }
        offset += frameLen;
      } else {
        // 偽の 0xD3 バイトだったので 1 バイト進めて再同期
        offset++;
      }
    }

    if (offset < bytes.length) {
      // 異常に長いゴミが残らないよう最大 2048 バイトに制限
      final keepStart = (bytes.length - offset > 2048) ? bytes.length - 2048 : offset;
      _buf.add(Uint8List.sublistView(bytes, keepStart));
    }
  }

  /// RTCM 10403.x CRC-24Q（生成多項式 `0x1864CFB`）
  static int crc24q(Uint8List data, int start, int length) {
    var crc = 0;
    for (var i = 0; i < length; i++) {
      crc ^= data[start + i] << 16;
      for (var b = 0; b < 8; b++) {
        crc <<= 1;
        if ((crc & 0x1000000) != 0) {
          crc ^= 0x1864CFB;
        }
      }
    }
    return crc & 0xFFFFFF;
  }

  /// テスト用: 指定したメッセージ番号・ペイロードで正当な CRC-24Q 付き RTCM3 フレームを組み立てる
  @visibleForTesting
  static Uint8List buildTestFrame(int messageNumber, {int extraPayloadBytes = 6}) {
    final payloadLen = 2 + extraPayloadBytes;
    final total = Uint8List(3 + payloadLen + 3);
    total[0] = 0xD3;
    total[1] = (payloadLen >> 8) & 0x03;
    total[2] = payloadLen & 0xFF;
    total[3] = (messageNumber >> 4) & 0xFF;
    total[4] = (messageNumber & 0x0F) << 4;
    final crc = crc24q(total, 0, 3 + payloadLen);
    total[3 + payloadLen] = (crc >> 16) & 0xFF;
    total[3 + payloadLen + 1] = (crc >> 8) & 0xFF;
    total[3 + payloadLen + 2] = crc & 0xFF;
    return total;
  }
}

/// VRS・最寄り基準局キャスターへ送る NMEA-0183 `$GPGGA` 文の生成ヘルパー
abstract final class NtripGgaFormatter {
  /// 緯度・経度からチェックサム付きの `$GPGGA,...*XX\r\n` を組み立てる
  static String buildGga({
    required double latitude,
    required double longitude,
    double altitude = 0.0,
    int quality = 1,
    int satellites = 8,
    double hdop = 1.0,
    DateTime? utcTime,
  }) {
    final t = (utcTime ?? DateTime.now()).toUtc();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    final timeStr = '$hh$mm$ss.00';

    final ns = latitude >= 0 ? 'N' : 'S';
    final ew = longitude >= 0 ? 'E' : 'W';
    final latStr = _formatDms(latitude.abs(), degreeDigits: 2);
    final lonStr = _formatDms(longitude.abs(), degreeDigits: 3);
    final q = quality.clamp(1, 5);
    final sats = satellites.clamp(0, 99).toString().padLeft(2, '0');

    final body =
        'GPGGA,$timeStr,$latStr,$ns,$lonStr,$ew,$q,$sats,${hdop.toStringAsFixed(1)},${altitude.toStringAsFixed(1)},M,0.0,M,,';
    final cs = _xorChecksum(body);
    return '\$$body*$cs\r\n';
  }

  static String _formatDms(double absDeg, {required int degreeDigits}) {
    final deg = absDeg.floor();
    final min = (absDeg - deg) * 60.0;
    final degStr = deg.toString().padLeft(degreeDigits, '0');
    final minFixed = min.toStringAsFixed(4);
    final dot = minFixed.indexOf('.');
    final minInt = minFixed.substring(0, dot).padLeft(2, '0');
    final minFrac = minFixed.substring(dot);
    return '$degStr$minInt$minFrac';
  }

  static String _xorChecksum(String body) {
    var xor = 0;
    for (var i = 0; i < body.length; i++) {
      xor ^= body.codeUnitAt(i);
    }
    return xor.toRadixString(16).toUpperCase().padLeft(2, '0');
  }
}
