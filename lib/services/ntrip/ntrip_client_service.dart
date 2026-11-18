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

/// 内蔵 NTRIP v1 / v2 クライアントサービス
///
/// - `ICY 200 OK`（単一 CRLF 直後のバイナリ開始および複数ヘッダ応答の両対応）と
///   `HTTP/1.x 200 OK`（`Transfer-Encoding: chunked` デコード対応）の両方を処理する
/// - 受信した RTCM バイト列は遅延ゼロで [onRtcmData]（Bluetooth 外部 GNSS）へ流す
/// - 並行して [Rtcm3StreamInspector] で CRC-24Q 検証済みフレーム数とメッセージ番号を集計する
/// - 401 認証エラーやマウントポイント不在（`SOURCETABLE 200 OK`）では自動再接続を即時停止し、
///   一時的な回線断のみ指数バックオフ（10s → 20s → 40s → 60s）で再接続して RTK2go 等での IP バンを防ぐ
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../i18n/strings.g.dart';
import '../../models/ntrip_config.dart';
import '../../utils/app_logger.dart';
import '../device_connection_log_service.dart';
import 'ntrip_socket.dart';

enum NtripStatus {
  disconnected,
  connecting,
  streaming,
  reconnecting,
  error,
}

class NtripClientService extends ChangeNotifier {
  NtripClientService._() : connector = connectDefaultNtripSocket;

  @visibleForTesting
  NtripClientService.forTesting({
    required this.connector,
  });

  static final NtripClientService instance = NtripClientService._();

  static const String _logTag = '[NTRIP]';
  static const String userAgent = 'NTRIP KokageMap/0.16';
  static const List<int> _backoffSeconds = [10, 20, 40, 60];

  final NtripSocketConnector connector;

  NtripStatus _status = NtripStatus.disconnected;
  String? _errorMessage;
  NtripConfig _activeConfig = NtripConfig.defaults;

  NtripSocket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  Timer? _ggaTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  int _reconnectDelaySec = 0;
  bool _manualStop = false;

  int _receivedBytes = 0;
  final Rtcm3StreamInspector _inspector = Rtcm3StreamInspector();
  DateTime? _lastStatsNotify;

  /// 受信した RTCM バイナリチャンクの転送先（Bluetooth 外部 GNSS）
  void Function(Uint8List rtcmBytes)? onRtcmData;

  /// VRS 等へ定期送信する最新 `$GPGGA` 文の供給元
  String? Function()? ggaProvider;

  NtripStatus get status => _status;
  String? get errorMessage => _errorMessage;
  NtripConfig get activeConfig => _activeConfig;
  int get receivedBytes => _receivedBytes;
  int get validRtcmFrames => _inspector.validFrames;
  List<int> get messageTypes => _inspector.sortedMessageTypes;
  int get reconnectDelaySeconds => _reconnectDelaySec;
  bool get isActive =>
      _status == NtripStatus.connecting ||
      _status == NtripStatus.streaming ||
      _status == NtripStatus.reconnecting;

  /// キャスターから `SOURCETABLE` を取得してマウントポイント一覧を返す
  Future<List<NtripMountpoint>> fetchMountpoints(
    NtripConfig config, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!config.canFetchMountpoints) {
      throw ArgumentError(t.ntrip.errInvalidConfig);
    }
    final sock = await connector(
      config.trimmedHost,
      config.port,
      useTls: config.useTls,
      timeout: timeout,
    );
    final buf = BytesBuilder(copy: false);
    final completer = Completer<String>();

    late final StreamSubscription<Uint8List> sub;
    sub = sock.stream.listen(
      (chunk) {
        buf.add(chunk);
        if (buf.length > 512 * 1024) {
          if (!completer.isCompleted) {
            completer.complete(latin1.decode(buf.takeBytes(), allowInvalid: true));
          }
          return;
        }
        final text = utf8.decode(buf.toBytes(), allowMalformed: true);
        if (text.contains('ENDSOURCETABLE')) {
          if (!completer.isCompleted) completer.complete(text);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(utf8.decode(buf.takeBytes(), allowMalformed: true));
        }
      },
    );

    try {
      sock.write(ascii.encode(_buildRequest(config, path: '/')));
      final raw = await completer.future.timeout(timeout);
      if (raw.contains('401 Unauthorized') || raw.contains('ERROR - Bad Password')) {
        throw Exception(t.ntrip.errAuth);
      }
      return NtripMountpoint.parseSourcetable(raw);
    } finally {
      await sub.cancel();
      await sock.close();
    }
  }

  /// RTCM ストリーム受信を開始する
  Future<void> connect(NtripConfig config) async {
    await disconnect();
    if (!config.isConfigured) {
      _status = NtripStatus.error;
      _errorMessage = t.ntrip.errInvalidConfig;
      notifyListeners();
      return;
    }
    _manualStop = false;
    _activeConfig = config;
    _reconnectAttempt = 0;
    _receivedBytes = 0;
    _inspector.reset();
    await _openSession();
  }

  /// NTRIP 通信を停止する
  Future<void> disconnect() async {
    final wasActive = _status == NtripStatus.streaming || _status == NtripStatus.reconnecting;
    _manualStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _ggaTimer?.cancel();
    _ggaTimer = null;
    await _closeSocketOnly();
    if (_status != NtripStatus.disconnected || _errorMessage != null) {
      _status = NtripStatus.disconnected;
      _errorMessage = null;
      if (wasActive && _activeConfig.isConfigured) {
        DeviceConnectionLogService.instance.record(
          category: DeviceConnectionCategory.ntrip,
          type: DeviceConnectionEventType.disconnected,
          deviceName: _activeConfig.normalizedMountpoint,
          deviceAddress: '${_activeConfig.trimmedHost}:${_activeConfig.port}',
          detail: 'manual',
        );
      }
      notifyListeners();
    }
  }

  Future<void> _closeSocketOnly() async {
    _ggaTimer?.cancel();
    _ggaTimer = null;
    final sub = _socketSub;
    _socketSub = null;
    final sock = _socket;
    _socket = null;
    unawaited(sub?.cancel());
    if (sock != null) {
      await sock.close();
    }
  }

  @override
  void dispose() {
    _manualStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _ggaTimer?.cancel();
    _ggaTimer = null;
    unawaited(_closeSocketOnly());
    super.dispose();
  }

  Future<void> _openSession() async {
    if (_manualStop) return;
    _status = NtripStatus.connecting;
    _errorMessage = null;
    notifyListeners();

    try {
      final sock = await connector(
        _activeConfig.trimmedHost,
        _activeConfig.port,
        useTls: _activeConfig.useTls,
        timeout: const Duration(seconds: 10),
      );
      if (_manualStop) {
        await sock.close();
        return;
      }
      _socket = sock;

      var headerParsed = false;
      var isChunked = false;
      final headerBuf = BytesBuilder(copy: false);
      final chunkDecoder = _HttpChunkedDecoder();

      _socketSub = sock.stream.listen(
        (data) {
          if (!headerParsed) {
            headerBuf.add(data);
            final bytes = headerBuf.toBytes();
            final outcome = _tryParseStreamHeader(bytes);
            switch (outcome.kind) {
              case _HeaderKind.needMore:
                if (bytes.length > 8192) {
                  _failPermanent('Invalid NTRIP response header');
                }
                return;
              case _HeaderKind.fatalError:
                _failPermanent(outcome.errorMessage!);
                return;
              case _HeaderKind.ok:
                headerParsed = true;
                isChunked = outcome.chunked;
                headerBuf.clear();
                _reconnectAttempt = 0;
                _status = NtripStatus.streaming;
                _errorMessage = null;
                DeviceConnectionLogService.instance.record(
                  category: DeviceConnectionCategory.ntrip,
                  type: DeviceConnectionEventType.connected,
                  deviceName: _activeConfig.normalizedMountpoint,
                  deviceAddress: '${_activeConfig.trimmedHost}:${_activeConfig.port}',
                );
                _startGgaTimerIfNeeded();
                notifyListeners();
                if (outcome.bodyOffset < bytes.length) {
                  final initialBody = Uint8List.sublistView(bytes, outcome.bodyOffset);
                  _handleBodyBytes(initialBody, isChunked: isChunked, decoder: chunkDecoder);
                }
            }
          } else {
            _handleBodyBytes(data, isChunked: isChunked, decoder: chunkDecoder);
          }
        },
        onError: (Object e) {
          AppLogger.debug('$_logTag socket error: $e');
          _scheduleReconnect('$e');
        },
        onDone: () {
          if (!_manualStop && _status != NtripStatus.error) {
            AppLogger.debug('$_logTag stream closed by caster');
            _scheduleReconnect('Connection closed');
          }
        },
      );

      final req = _buildRequest(_activeConfig, path: '/${_activeConfig.normalizedMountpoint}');
      sock.write(ascii.encode(req));
    } catch (e) {
      AppLogger.debug('$_logTag connect failed: $e');
      _scheduleReconnect('$e');
    }
  }

  void _handleBodyBytes(
    Uint8List raw, {
    required bool isChunked,
    required _HttpChunkedDecoder decoder,
  }) {
    final payload = isChunked ? decoder.add(raw) : raw;
    if (payload.isEmpty) return;

    // 遅延ゼロで Bluetooth 外部GNSS へ転送
    onRtcmData?.call(payload);

    _receivedBytes += payload.length;
    _inspector.addChunk(payload);

    final now = DateTime.now();
    if (_lastStatsNotify == null || now.difference(_lastStatsNotify!).inMilliseconds >= 500) {
      _lastStatsNotify = now;
      notifyListeners();
    }
  }

  void _startGgaTimerIfNeeded() {
    _ggaTimer?.cancel();
    if (!_activeConfig.sendGga) return;
    _sendGgaOnce();
    _ggaTimer = Timer.periodic(
      Duration(seconds: _activeConfig.ggaIntervalSeconds),
      (_) => _sendGgaOnce(),
    );
  }

  void _sendGgaOnce() {
    final sock = _socket;
    if (sock == null || _status != NtripStatus.streaming) return;
    final gga = ggaProvider?.call();
    if (gga == null || gga.isEmpty) return;
    final normalized = gga.endsWith('\r\n') ? gga : '${gga.trimRight()}\r\n';
    try {
      sock.write(ascii.encode(normalized));
    } catch (e) {
      AppLogger.debug('$_logTag GGA send failed: $e');
    }
  }

  /// 401 やマウントポイント名誤りなど、自動再接続してはいけない恒久エラー（RTK2go IP バン防止）
  void _failPermanent(String message) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    unawaited(_closeSocketOnly());
    _status = NtripStatus.error;
    _errorMessage = message;
    DeviceConnectionLogService.instance.record(
      category: DeviceConnectionCategory.ntrip,
      type: DeviceConnectionEventType.reconnectFailed,
      deviceName: _activeConfig.normalizedMountpoint,
      deviceAddress: '${_activeConfig.trimmedHost}:${_activeConfig.port}',
      detail: message,
    );
    notifyListeners();
  }

  void _scheduleReconnect(String reason) {
    if (_manualStop || _status == NtripStatus.error) return;
    unawaited(_closeSocketOnly());
    final idx = _reconnectAttempt.clamp(0, _backoffSeconds.length - 1);
    final delay = _backoffSeconds[idx];
    _reconnectAttempt++;
    _reconnectDelaySec = delay;
    _status = NtripStatus.reconnecting;
    _errorMessage = reason;
    DeviceConnectionLogService.instance.record(
      category: DeviceConnectionCategory.ntrip,
      type: DeviceConnectionEventType.reconnecting,
      deviceName: _activeConfig.normalizedMountpoint,
      deviceAddress: '${_activeConfig.trimmedHost}:${_activeConfig.port}',
      detail: '$reason (retry in ${delay}s)',
    );
    notifyListeners();

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_manualStop) {
        unawaited(_openSession());
      }
    });
  }

  static String _buildRequest(NtripConfig config, {required String path}) {
    final buf = StringBuffer()
      ..write('GET $path HTTP/1.0\r\n')
      ..write('Host: ${config.trimmedHost}:${config.port}\r\n')
      ..write('User-Agent: $userAgent\r\n')
      ..write('Accept: */*\r\n')
      ..write('Connection: close\r\n');
    if (config.username.trim().isNotEmpty || config.password.isNotEmpty) {
      final creds = base64.encode(utf8.encode('${config.username.trim()}:${config.password}'));
      buf.write('Authorization: Basic $creds\r\n');
    }
    buf.write('\r\n');
    return buf.toString();
  }

  static _HeaderOutcome _tryParseStreamHeader(Uint8List bytes) {
    final previewLen = bytes.length < 512 ? bytes.length : 512;
    final headText = latin1.decode(Uint8List.sublistView(bytes, 0, previewLen), allowInvalid: true);

    if (headText.startsWith('SOURCETABLE')) {
      return _HeaderOutcome.fatal(t.ntrip.errMountpointNotFound);
    }
    if (headText.startsWith('ERROR - Bad Password') ||
        headText.startsWith('ICY 401') ||
        headText.startsWith('ICY 403')) {
      return _HeaderOutcome.fatal(t.ntrip.errAuth);
    }

    // NTRIP v1: `ICY 200 OK\r\n` の直後に空行無しで `0xD3` バイナリが始まる実装と、ヘッダ行が続く実装の両対応
    if (headText.startsWith('ICY 200 OK\r\n')) {
      if (bytes.length == 12) return _HeaderOutcome.needMore;
      if (bytes[12] == 0xD3) {
        return const _HeaderOutcome.ok(bodyOffset: 12, chunked: false);
      }
      if (bytes.length >= 14 && bytes[12] == 0x0D && bytes[13] == 0x0A) {
        return const _HeaderOutcome.ok(bodyOffset: 14, chunked: false);
      }
      final crlf2 = _indexOfDoubleCrlf(bytes);
      if (crlf2 >= 0) {
        return _HeaderOutcome.ok(bodyOffset: crlf2 + 4, chunked: false);
      }
      // 追加ヘッダ無しの生ストリームが 0xD3 以外のバイトから始まった場合も改行 1 つで通す
      if (bytes[12] >= 0x80) {
        return const _HeaderOutcome.ok(bodyOffset: 12, chunked: false);
      }
      return _HeaderOutcome.needMore;
    }

    if (headText.startsWith('HTTP/1.')) {
      final crlf2 = _indexOfDoubleCrlf(bytes);
      if (crlf2 < 0) return _HeaderOutcome.needMore;
      final headerBlock = latin1.decode(Uint8List.sublistView(bytes, 0, crlf2), allowInvalid: true);
      final lines = headerBlock.split('\r\n');
      final statusLine = lines.first;
      if (statusLine.contains(' 401') || statusLine.contains(' 403')) {
        return _HeaderOutcome.fatal(t.ntrip.errAuth);
      }
      if (statusLine.contains(' 404')) {
        return _HeaderOutcome.fatal(t.ntrip.errMountpointNotFound);
      }
      if (!statusLine.contains(' 200')) {
        return _HeaderOutcome.fatal(statusLine);
      }
      final lower = headerBlock.toLowerCase();
      if (lower.contains('gnss/sourcetable')) {
        return _HeaderOutcome.fatal(t.ntrip.errMountpointNotFound);
      }
      final chunked = lower.contains('transfer-encoding: chunked');
      return _HeaderOutcome.ok(bodyOffset: crlf2 + 4, chunked: chunked);
    }

    if (bytes.length < 16) return _HeaderOutcome.needMore;
    final firstLineEnd = headText.indexOf('\r\n');
    if (firstLineEnd < 0) return _HeaderOutcome.needMore;
    return _HeaderOutcome.fatal(headText.substring(0, firstLineEnd));
  }

  static int _indexOfDoubleCrlf(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 0x0D &&
          bytes[i + 1] == 0x0A &&
          bytes[i + 2] == 0x0D &&
          bytes[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
  }
}

enum _HeaderKind { needMore, ok, fatalError }

class _HeaderOutcome {
  const _HeaderOutcome._(this.kind, {this.bodyOffset = 0, this.chunked = false, this.errorMessage});
  static const needMore = _HeaderOutcome._(_HeaderKind.needMore);
  const _HeaderOutcome.ok({required int bodyOffset, required bool chunked})
      : this._(_HeaderKind.ok, bodyOffset: bodyOffset, chunked: chunked);
  factory _HeaderOutcome.fatal(String msg) =>
      _HeaderOutcome._(_HeaderKind.fatalError, errorMessage: msg);

  final _HeaderKind kind;
  final int bodyOffset;
  final bool chunked;
  final String? errorMessage;
}

/// NTRIP v2 (`HTTP/1.1` `Transfer-Encoding: chunked`) のチャンクデコーダ
class _HttpChunkedDecoder {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  Uint8List add(Uint8List incoming) {
    if (incoming.isEmpty) return Uint8List(0);
    _buf.add(incoming);
    final bytes = _buf.takeBytes();
    final out = BytesBuilder(copy: false);
    var pos = 0;

    while (pos < bytes.length) {
      var crlf = -1;
      for (var i = pos; i + 1 < bytes.length; i++) {
        if (bytes[i] == 0x0D && bytes[i + 1] == 0x0A) {
          crlf = i;
          break;
        }
      }
      if (crlf < 0) break;

      final sizeLine = ascii.decode(Uint8List.sublistView(bytes, pos, crlf), allowInvalid: true);
      final semi = sizeLine.indexOf(';');
      final hexStr = (semi >= 0 ? sizeLine.substring(0, semi) : sizeLine).trim();
      final chunkSize = int.tryParse(hexStr, radix: 16);
      if (chunkSize == null || chunkSize < 0) {
        // 不正チャンク時は残りを破棄
        return out.takeBytes();
      }
      if (chunkSize == 0) {
        pos = bytes.length;
        break;
      }
      final dataStart = crlf + 2;
      final dataEnd = dataStart + chunkSize;
      if (dataEnd + 2 > bytes.length) {
        // チャンク本体または末尾 CRLF 待ち
        break;
      }
      out.add(Uint8List.sublistView(bytes, dataStart, dataEnd));
      pos = dataEnd + 2;
    }

    if (pos < bytes.length) {
      _buf.add(Uint8List.sublistView(bytes, pos));
    }
    return out.takeBytes();
  }
}
