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
import '../models/track_recording_settings.dart';

part 'gps_providers.g.dart';

@Riverpod(keepAlive: true)
class PreferredGpsSourceType extends _$PreferredGpsSourceType {
  @override
  String? build() => null;

  void set(String? value) => state = value;
}

@Riverpod(keepAlive: true)
class SelectedGnssDeviceAddress extends _$SelectedGnssDeviceAddress {
  @override
  String? build() => null;

  void set(String? value) => state = value;
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
