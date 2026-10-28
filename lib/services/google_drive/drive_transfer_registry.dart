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
/// Google Drive フォルダ転送の状態・排他・未完了マーカー・OS通知を一元管理するレジストリ
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../utils/app_logger.dart';
import 'sync_progress.dart';

/// 転送完了イベント
class DriveTransferCompletionEvent {
  final String localPath;
  final String? driveId;
  final String folderName;
  final bool success;
  final String? errorMessage;

  const DriveTransferCompletionEvent({
    required this.localPath,
    this.driveId,
    required this.folderName,
    required this.success,
    this.errorMessage,
  });
}

/// アプリ全体で1つの転送レジストリ。
///
/// ツリーノード（[DriveFolderNode]）は再読込のたびに作り直されるため、進捗状態はノードではなく
/// このレジストリが正規化パスをキーとして保持する。
class DriveTransferRegistry {
  DriveTransferRegistry._();

  static final DriveTransferRegistry instance = DriveTransferRegistry._();

  static const MethodChannel _osChannel =
      MethodChannel('com.k_root.k_maps/sync_notification');

  /// パス文字列をキー用に正規化する
  static String normalizeKey(String localPath) {
    final norm = p.normalize(localPath).replaceAll('\\', '/');
    if (norm.length > 1 && norm.endsWith('/')) {
      return norm.substring(0, norm.length - 1);
    }
    return norm;
  }

  /// クローン未完了マーカーのパス（`.sync/` 配下なので同期対象外）
  static String clonePendingMarkerPath(String localPath) =>
      p.join(localPath, '.sync', 'clone.pending');

  /// 正規化 localPath → 進捗 ValueNotifier
  final Map<String, ValueNotifier<SyncProgress?>> _progressNotifiers = {};

  /// 正規化 localPath → 実行中タスク名（フォルダ表示名）
  final Map<String, String> _activeNames = {};

  /// driveId → 実行中のクローン Future（共有リンク・ドロワー・AppData同期の重複排除）
  final Map<String, Future<String?>> _inFlightClonesByDriveId = {};

  /// 現在進行中の転送タスク数
  final ValueNotifier<int> activeCount = ValueNotifier<int>(0);

  /// 完了イベントストリーム（マップ画面やドロワーが購読してツリーを再読込する）
  final StreamController<DriveTransferCompletionEvent> _completionController =
      StreamController<DriveTransferCompletionEvent>.broadcast();

  Stream<DriveTransferCompletionEvent> get onTransferCompleted =>
      _completionController.stream;

  /// OS通知の最終送信時刻・最終パーセント（Android のレート制限 5回/秒 を避けるため1秒以上あける）
  final Map<String, DateTime> _lastOsNotifyAt = {};
  final Map<String, int?> _lastOsPercent = {};
  final Map<String, SyncPhase> _lastOsPhase = {};

  static bool get _supportsAndroidOsNotification =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 指定パスのフォルダが現在転送中か
  bool isBusy(String localPath) =>
      _activeNames.containsKey(normalizeKey(localPath));

  /// 指定 driveId のクローンが現在進行中か
  bool isCloningDriveId(String driveId) =>
      _inFlightClonesByDriveId.containsKey(driveId);

  /// 指定パスの進捗 ValueListenable を取得（ノードが再生成されても同じ Notifier を返す）
  ValueListenable<SyncProgress?> progressOf(String localPath) {
    final key = normalizeKey(localPath);
    return _progressNotifiers.putIfAbsent(
      key,
      () => ValueNotifier<SyncProgress?>(null),
    );
  }

  /// 現在の進捗スナップショット（進行中でなければ null）
  SyncProgress? currentProgress(String localPath) =>
      _progressNotifiers[normalizeKey(localPath)]?.value;

  // ========== clone.pending マーカー管理 ==========

  /// クローン開始時に `.sync/clone.pending` マーカーを作成する。
  /// これがある間は AutoSync 対象外かつ Push 禁止（再開時は Pull のみ）。
  Future<void> markClonePending(String localPath) async {
    try {
      final marker = clonePendingMarkerPath(localPath);
      await fs.createDirectory(p.dirname(marker));
      await fs.writeAsString(marker, DateTime.now().toIso8601String());
    } catch (e) {
      AppLogger.debug('[TransferRegistry] clone.pending 作成失敗: $e');
    }
  }

  /// クローン完了（帳簿保存成功）時に `.sync/clone.pending` マーカーを消去する。
  Future<void> clearClonePending(String localPath) async {
    try {
      final marker = clonePendingMarkerPath(localPath);
      if (await fs.exists(marker)) {
        await fs.delete(marker);
      }
    } catch (e) {
      AppLogger.debug('[TransferRegistry] clone.pending 削除失敗: $e');
    }
  }

  /// 指定フォルダに未完了クローンマーカー（`.sync/clone.pending`）があるか
  Future<bool> hasClonePending(String localPath) async {
    try {
      return await fs.exists(clonePendingMarkerPath(localPath));
    } catch (_) {
      return false;
    }
  }

  // ========== 転送ライフサイクル ==========

  /// 転送開始を登録し、初期進捗（走査中）をセットする
  void beginTransfer(
    String localPath, {
    required String folderName,
    SyncProgress initial = const SyncProgress.scanning(),
    bool showOsNotification = true,
  }) {
    final key = normalizeKey(localPath);
    final wasActive = _activeNames.containsKey(key);
    _activeNames[key] = folderName;
    if (!wasActive) {
      activeCount.value = _activeNames.length;
    }
    final notifier = _progressNotifiers.putIfAbsent(
      key,
      () => ValueNotifier<SyncProgress?>(null),
    );
    notifier.value = initial;

    if (showOsNotification) {
      _updateOsProgress(key, folderName, initial, force: true);
    }
  }

  /// 進捗を更新する（UIの ValueNotifier を更新し、OS通知は1秒間隔で間引いて送る）
  void updateProgress(
    String localPath,
    SyncProgress progress, {
    String? folderName,
    bool showOsNotification = true,
  }) {
    final key = normalizeKey(localPath);
    if (!_activeNames.containsKey(key)) {
      _activeNames[key] = folderName ?? p.basename(localPath);
      activeCount.value = _activeNames.length;
    }
    final name = folderName ?? _activeNames[key] ?? p.basename(localPath);
    final notifier = _progressNotifiers.putIfAbsent(
      key,
      () => ValueNotifier<SyncProgress?>(null),
    );
    notifier.value = progress;

    if (showOsNotification) {
      _updateOsProgress(key, name, progress);
    }
  }

  /// 転送終了を登録し、進捗表示をクリアして完了イベント・OS完了通知を発火する
  void endTransfer(
    String localPath, {
    String? driveId,
    String? folderName,
    required bool success,
    String? completionTitle,
    String? completionBody,
    String? errorMessage,
    bool showOsNotification = true,
  }) {
    final key = normalizeKey(localPath);
    final name = folderName ?? _activeNames.remove(key) ?? p.basename(localPath);
    _activeNames.remove(key);
    activeCount.value = _activeNames.length;

    final notifier = _progressNotifiers[key];
    if (notifier != null) {
      notifier.value = null;
    }
    _lastOsNotifyAt.remove(key);
    _lastOsPercent.remove(key);
    _lastOsPhase.remove(key);

    if (showOsNotification && completionTitle != null) {
      _showOsComplete(
        key,
        title: completionTitle,
        body: completionBody ?? '',
        isError: !success,
        stopService: _activeNames.isEmpty,
      );
    } else if (_supportsAndroidOsNotification && _activeNames.isEmpty) {
      unawaited(_invokeOs('stopIfIdle', const {}));
    }

    _completionController.add(
      DriveTransferCompletionEvent(
        localPath: localPath,
        driveId: driveId,
        folderName: name,
        success: success,
        errorMessage: errorMessage,
      ),
    );
  }

  /// driveId 単位で重複排除しながらクローン処理を実行する
  Future<String?> runDeduplicatedClone(
    String driveId,
    Future<String?> Function() action,
  ) {
    final existing = _inFlightClonesByDriveId[driveId];
    if (existing != null) return existing;
    final fut = action();
    _inFlightClonesByDriveId[driveId] = fut;
    return fut.whenComplete(() => _inFlightClonesByDriveId.remove(driveId));
  }

  // ========== Android OS システム通知連携 ==========

  void _updateOsProgress(
    String key,
    String folderName,
    SyncProgress progress, {
    bool force = false,
  }) {
    if (!_supportsAndroidOsNotification) return;
    final now = DateTime.now();
    final lastAt = _lastOsNotifyAt[key];
    final lastPct = _lastOsPercent[key];
    final lastPhase = _lastOsPhase[key];
    final pct = progress.percent;

    final phaseChanged = lastPhase != progress.phase;
    final elapsedOk =
        lastAt == null || now.difference(lastAt).inMilliseconds >= 1000;
    final pctChanged = pct != lastPct;

    if (!force && !phaseChanged && (!elapsedOk || !pctChanged)) {
      return;
    }

    _lastOsNotifyAt[key] = now;
    _lastOsPercent[key] = pct;
    _lastOsPhase[key] = progress.phase;

    final String detail;
    switch (progress.phase) {
      case SyncPhase.scanning:
        detail = 'フォルダ構成を確認しています...';
      case SyncPhase.transferring:
        final bytesStr = progress.formattedBytes;
        final pctStr = pct != null ? '$pct%' : '';
        final fileStr = progress.currentFileName ?? '';
        detail = [
          if (pctStr.isNotEmpty) pctStr,
          if (bytesStr != null) '($bytesStr)',
          if (fileStr.isNotEmpty) '· $fileStr',
        ].join(' ');
      case SyncPhase.finalizing:
        detail = '地図データを整えています...';
    }

    unawaited(
      _invokeOs('showProgress', {
        'id': _notificationIdFor(key),
        'title': '「$folderName」をダウンロード中',
        'body': detail,
        'progress': pct ?? 0,
        'max': 100,
        'indeterminate': progress.fraction == null,
      }),
    );
  }

  void _showOsComplete(
    String key, {
    required String title,
    required String body,
    required bool isError,
    required bool stopService,
  }) {
    if (!_supportsAndroidOsNotification) return;
    unawaited(
      _invokeOs('showComplete', {
        'id': _notificationIdFor(key),
        'title': title,
        'body': body,
        'isError': isError,
        'stopService': stopService,
      }),
    );
  }

  static int _notificationIdFor(String key) =>
      2000 + (key.hashCode.abs() % 100000);

  Future<void> _invokeOs(String method, Map<String, Object?> args) async {
    try {
      await _osChannel.invokeMethod<void>(method, args);
    } catch (e) {
      AppLogger.debug('[TransferRegistry] OS通知呼び出し失敗 ($method): $e');
    }
  }

  @visibleForTesting
  void resetForTest() {
    _activeNames.clear();
    _inFlightClonesByDriveId.clear();
    for (final n in _progressNotifiers.values) {
      n.value = null;
    }
    _progressNotifiers.clear();
    _lastOsNotifyAt.clear();
    _lastOsPercent.clear();
    _lastOsPhase.clear();
    activeCount.value = 0;
  }
}
