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
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/gnss_quality.dart';
import '../models/ntrip_config.dart';
import '../models/track_recording_settings.dart';

part 'gps_providers.g.dart';

@Riverpod(keepAlive: true)
class PreferredGpsSourceType extends _$PreferredGpsSourceType {
  static const _key = 'preferred_gps_source_type';

  @override
  String? build() => null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getString(_key);
    } catch (_) {
      state = null;
    }
  }

  Future<void> set(String? value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, value);
      }
    } catch (_) {}
  }
}

@Riverpod(keepAlive: true)
class SelectedGnssDeviceAddress extends _$SelectedGnssDeviceAddress {
  static const _key = 'selected_gnss_device_address';

  @override
  String? build() => null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getString(_key);
    } catch (_) {
      state = null;
    }
  }

  Future<void> set(String? value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, value);
      }
    } catch (_) {}
  }
}

@Riverpod(keepAlive: true)
class SelectedGnssDeviceName extends _$SelectedGnssDeviceName {
  static const _key = 'selected_gnss_device_name';

  @override
  String? build() => null;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getString(_key);
    } catch (_) {
      state = null;
    }
  }

  Future<void> set(String? value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, value);
      }
    } catch (_) {}
  }
}

/// GPS 測量の足切りの条件（設定 → GPS・測位）。既定は何もしない。SharedPreferences に JSON で永続化
@Riverpod(keepAlive: true)
class GnssQualityGateSetting extends _$GnssQualityGateSetting {
  static const _key = 'gnss_quality_gate';

  @override
  GnssQualityGate build() => GnssQualityGate.off;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) state = GnssQualityGate.fromJson(jsonDecode(raw) as Map);
    } catch (_) {
      state = GnssQualityGate.off;
    }
  }

  Future<void> set(GnssQualityGate value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }
}

/// GPS 軌跡の記録の設定（設定 → GPS・測位 →「軌跡の記録」）。SharedPreferences に JSON で永続化
@Riverpod(keepAlive: true)
class TrackRecordingSetting extends _$TrackRecordingSetting {
  static const _key = 'track_recording_settings';

  @override
  TrackRecordingSettings build() => TrackRecordingSettings.defaults;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) state = TrackRecordingSettings.fromJson(jsonDecode(raw) as Map);
    } catch (_) {
      state = TrackRecordingSettings.defaults;
    }
  }

  Future<void> set(TrackRecordingSettings value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }
}

/// 外部GNSS使用時に RTK FIX 取得／喪失の効果音を鳴らすか（既定 ON）
@Riverpod(keepAlive: true)
class GnssFixSoundSetting extends _$GnssFixSoundSetting {
  static const _key = 'gnss_fix_sound_enabled';

  @override
  bool build() => true;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = prefs.getBool(_key) ?? true;
    } catch (_) {
      state = true;
    }
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

/// 内蔵 NTRIP クライアントの接続設定（端末ローカル SharedPreferences に永続化）
@Riverpod(keepAlive: true)
class NtripConfigSetting extends _$NtripConfigSetting {
  static const _key = 'ntrip_config';

  @override
  NtripConfig build() => NtripConfig.defaults;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        state = NtripConfig.fromJson(jsonDecode(raw) as Map);
      }
    } catch (_) {
      state = NtripConfig.defaults;
    }
  }

  Future<void> set(NtripConfig value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }
}
