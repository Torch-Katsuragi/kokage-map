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

/// 外部 GNSS の RTK 解状態変化（`RTK FIX` 取得 ／ `FLOAT` 以下・切断への転落）の効果音モニタ
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';

class GnssFixSoundMonitor {
  GnssFixSoundMonitor({
    Future<void> Function(String assetPath)? onPlayAsset,
    this.cooldown = const Duration(milliseconds: 1500),
    DateTime Function()? clock,
  })  : _customPlayer = onPlayAsset,
        _clock = clock ?? DateTime.now;

  static const String rtkFixedAsset = 'sounds/gnss_rtk_fixed.wav';
  static const String rtkLostAsset = 'sounds/gnss_rtk_lost.wav';

  final Future<void> Function(String assetPath)? _customPlayer;
  final Duration cooldown;
  final DateTime Function() _clock;
  AudioPlayer? _audioPlayer;

  bool _wasRtkFixed = false;
  DateTime? _lastPlayedAt;
  String? _lastPlayedAsset;

  @visibleForTesting
  String? get debugLastPlayedAsset => _lastPlayedAsset;

  @visibleForTesting
  void debugClearLastPlayedAsset() => _lastPlayedAsset = null;

  /// 手動で内蔵GPSへ戻したときなど、喪失アラートを鳴らさずに状態を初期化する
  void reset() {
    _wasRtkFixed = false;
  }

  /// 外部 GNSS の接続状態と GGA 品質番号（`4` = RTK Fixed）を渡して遷移を検査する
  Future<void> onExternalFixState({
    required bool enabled,
    required bool connected,
    required int? gpsQuality,
  }) async {
    final isNowRtkFixed = connected && gpsQuality == 4;
    if (isNowRtkFixed == _wasRtkFixed) return;

    _wasRtkFixed = isNowRtkFixed;
    if (!enabled) return;

    final now = _clock();
    if (_lastPlayedAt != null && now.difference(_lastPlayedAt!) < cooldown) {
      return;
    }
    _lastPlayedAt = now;

    final asset = isNowRtkFixed ? rtkFixedAsset : rtkLostAsset;
    await _playAsset(asset);
  }

  /// 外部 GNSS の予期せぬ切断時に警告音を鳴らす（直前に RTK FIX 喪失音が鳴っていればクールダウンで二重鳴動しない）
  Future<void> playDisconnectAlert({required bool enabled}) async {
    _wasRtkFixed = false;
    if (!enabled) return;
    final now = _clock();
    if (_lastPlayedAt != null && now.difference(_lastPlayedAt!) < cooldown) {
      return;
    }
    _lastPlayedAt = now;
    await _playAsset(rtkLostAsset);
  }

  Future<void> _playAsset(String asset) async {
    _lastPlayedAsset = asset;
    if (_customPlayer != null) {
      await _customPlayer(asset);
      return;
    }
    try {
      final player = _audioPlayer ??= AudioPlayer();
      await player.setPlaybackRate(1.0);
      await player.play(AssetSource(asset));
    } catch (e) {
      AppLogger.debug('[GnssFixSound] Playback failed ($asset): $e');
    }
  }

  void dispose() {
    _audioPlayer?.dispose();
    _audioPlayer = null;
  }
}
