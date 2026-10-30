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
/// TruPulse固有のRiverpodプロバイダー
library;

import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/survey/traverse_recorder.dart';
import 'trupulse_service.dart';
import 'trupulse_tool.dart';

part 'trupulse_providers.g.dart';

/// TruPulseServiceのシングルトンインスタンス
@Riverpod(keepAlive: true)
TruPulseService trupulseService(Ref ref) {
  final service = TruPulseService();
  // コンテナ破棄時（テスト・ホットリスタート）に接続とストリームを閉じる
  ref.onDispose(service.dispose);
  return service;
}

/// TruPulseToolのシングルトンインスタンス
@Riverpod(keepAlive: true)
TruPulseTool trupulseTool(Ref ref) =>
    TruPulseTool(ref, ref.read(trupulseServiceProvider));

/// 後視時の許容誤差基準（角度差・距離差の上限）。SharedPreferences に JSON で永続化
@Riverpod(keepAlive: true)
class BacksightToleranceSetting extends _$BacksightToleranceSetting {
  static const _key = 'trupulse_backsight_tolerance';

  @override
  BacksightTolerance build() => BacksightTolerance.defaults;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        state = BacksightTolerance.fromJson(jsonDecode(raw) as Map);
      }
    } catch (_) {
      state = BacksightTolerance.defaults;
    }
  }

  Future<void> set(BacksightTolerance value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }
}
