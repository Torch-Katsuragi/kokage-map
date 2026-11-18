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

/// 外部計測機器（外部GNSS・測距器・NTRIP）の接続・切断イベントを永続記録するサービス
///
/// リリースビルドでも常時稼働し、アプリを終了・再起動しても「いつどの機器が切れ、
/// いつ復帰・フォールバックしたか」をアプリ内から確認・コピーできるようにする。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_connection_log_sink.dart';

enum DeviceConnectionCategory {
  gnss,
  rangefinder,
  ntrip;

  static DeviceConnectionCategory fromName(String? raw) =>
      DeviceConnectionCategory.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => DeviceConnectionCategory.gnss,
      );
}

enum DeviceConnectionEventType {
  connected,
  disconnected,
  reconnecting,
  reconnectFailed,
  fallbackInternal,
  resumedExternal;

  static DeviceConnectionEventType fromName(String? raw) =>
      DeviceConnectionEventType.values.firstWhere(
        (e) => e.name == raw,
        orElse: () => DeviceConnectionEventType.disconnected,
      );
}

@immutable
class DeviceConnectionEvent {
  final DateTime timestamp;
  final DeviceConnectionCategory category;
  final DeviceConnectionEventType type;
  final String deviceName;
  final String? deviceAddress;
  final String? detail;

  const DeviceConnectionEvent({
    required this.timestamp,
    required this.category,
    required this.type,
    required this.deviceName,
    this.deviceAddress,
    this.detail,
  });

  Map<String, dynamic> toJson() => {
        'ts': timestamp.toIso8601String(),
        'cat': category.name,
        'type': type.name,
        'name': deviceName,
        if (deviceAddress != null) 'addr': deviceAddress,
        if (detail != null && detail!.isNotEmpty) 'detail': detail,
      };

  factory DeviceConnectionEvent.fromJson(Map<dynamic, dynamic> json) =>
      DeviceConnectionEvent(
        timestamp:
            DateTime.tryParse(json['ts']?.toString() ?? '') ?? DateTime.now(),
        category: DeviceConnectionCategory.fromName(json['cat']?.toString()),
        type: DeviceConnectionEventType.fromName(json['type']?.toString()),
        deviceName: json['name']?.toString() ?? '',
        deviceAddress: json['addr']?.toString(),
        detail: json['detail']?.toString(),
      );

  String formatTimestampLocal() {
    final l = timestamp.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  String formatLine() {
    final addrPart =
        (deviceAddress != null && deviceAddress!.isNotEmpty) ? ' ($deviceAddress)' : '';
    final detailPart =
        (detail != null && detail!.isNotEmpty) ? ' — $detail' : '';
    return '[${formatTimestampLocal()}] [${category.name.toUpperCase()}] '
        '${type.name}: $deviceName$addrPart$detailPart';
  }
}

class DeviceConnectionLogService extends ChangeNotifier {
  static final DeviceConnectionLogService instance =
      DeviceConnectionLogService._internal();
  DeviceConnectionLogService._internal();

  @visibleForTesting
  DeviceConnectionLogService.forTesting();

  static const String _prefsKey = 'device_connection_events_v1';
  static const int maxEntries = 300;

  final List<DeviceConnectionEvent> _events = <DeviceConnectionEvent>[];
  final Set<void Function(DeviceConnectionEvent event)> _eventSinks =
      <void Function(DeviceConnectionEvent event)>{};
  bool _loaded = false;

  /// GeoPackage (`gps_history.gpkg` の `device_connection_events` テーブル等) へリアルタイム転送するシンクを登録
  void addEventSink(void Function(DeviceConnectionEvent event) sink) {
    _eventSinks.add(sink);
  }

  void removeEventSink(void Function(DeviceConnectionEvent event) sink) {
    _eventSinks.remove(sink);
  }

  /// 新しい順（先頭が最新）で返す
  List<DeviceConnectionEvent> get events =>
      List.unmodifiable(_events.reversed.toList());

  bool get isEmpty => _events.isEmpty;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lines = prefs.getStringList(_prefsKey);
      if (lines != null && lines.isNotEmpty) {
        final parsed = <DeviceConnectionEvent>[];
        for (final raw in lines) {
          try {
            parsed.add(
              DeviceConnectionEvent.fromJson(jsonDecode(raw) as Map),
            );
          } catch (_) {}
        }
        // load() 完了前に record() されたイベントがあれば後ろに残す
        final inMemory = List<DeviceConnectionEvent>.of(_events);
        _events
          ..clear()
          ..addAll(parsed)
          ..addAll(inMemory);
        if (_events.length > maxEntries) {
          _events.removeRange(0, _events.length - maxEntries);
        }
      }
      _loaded = true;
      notifyListeners();
    } catch (_) {
      _loaded = true;
    }
  }

  void record({
    required DeviceConnectionCategory category,
    required DeviceConnectionEventType type,
    required String deviceName,
    String? deviceAddress,
    String? detail,
    DateTime? timestamp,
  }) {
    final ev = DeviceConnectionEvent(
      timestamp: timestamp ?? DateTime.now(),
      category: category,
      type: type,
      deviceName: deviceName,
      deviceAddress: deviceAddress,
      detail: detail,
    );
    _events.add(ev);
    if (_events.length > maxEntries) {
      _events.removeRange(0, _events.length - maxEntries);
    }
    for (final sink in List.of(_eventSinks)) {
      try {
        sink(ev);
      } catch (_) {}
    }
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> clear() async {
    _events.clear();
    notifyListeners();
    await _persist();
  }

  String exportAsText() =>
      _events.map((e) => e.formatLine()).join('\n');

  Future<void> _persist() async {
    final lines = [for (final e in _events) jsonEncode(e.toJson())];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, lines);
    } catch (_) {}
    await writeDeviceConnectionLogFile(lines);
  }

  @visibleForTesting
  void resetForTesting() {
    _events.clear();
    _loaded = false;
  }
}
