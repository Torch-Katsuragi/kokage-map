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
/// Google Drive 共有フォルダのダウンロード・同期進捗モデルと集計器
library;

import 'dart:math' as math;

/// 同期・ダウンロードの進行フェーズ
enum SyncPhase {
  /// Drive のフォルダ階層・差分を走査中（母数未確定）
  scanning,

  /// ファイルのダウンロード・アップロード・マージ実行中（母数確定）
  transferring,

  /// SQLite WAL 統合（settleAfterDownload）・ベース保存・レイヤ再読込中
  finalizing,
}

/// 同期・ダウンロードの進捗スナップショット
class SyncProgress {
  final SyncPhase phase;
  final int completedFiles;
  final int totalFiles;
  final int transferredBytes;
  final int totalBytes;
  final String? currentFileName;

  const SyncProgress({
    required this.phase,
    this.completedFiles = 0,
    this.totalFiles = 0,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.currentFileName,
  });

  const SyncProgress.scanning({String? currentFileName})
      : this(phase: SyncPhase.scanning, currentFileName: currentFileName);

  const SyncProgress.finalizing({
    int completedFiles = 0,
    int totalFiles = 0,
    int transferredBytes = 0,
    int totalBytes = 0,
    String? currentFileName,
  }) : this(
          phase: SyncPhase.finalizing,
          completedFiles: completedFiles,
          totalFiles: totalFiles,
          transferredBytes: transferredBytes,
          totalBytes: totalBytes,
          currentFileName: currentFileName,
        );

  /// LinearProgressIndicator.value に渡せる進捗率（0.0〜1.0）。
  /// 走査中・反映中または母数未確定の場合は null（Indeterminate バー）を返す。
  double? get fraction {
    if (phase != SyncPhase.transferring) return null;
    if (totalBytes > 0) {
      return (transferredBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalFiles > 0) {
      return (completedFiles / totalFiles).clamp(0.0, 1.0);
    }
    return null;
  }

  /// 0〜100 の整数パーセンテージ（fraction が null の場合は null）
  int? get percent {
    final f = fraction;
    if (f == null) return null;
    return (f * 100).round().clamp(0, 100);
  }

  /// バイト数の人間向け表記（例: "3.2 MB / 12.5 MB"）
  String? get formattedBytes {
    if (totalBytes <= 0) return null;
    final clamped = math.min(transferredBytes, totalBytes);
    return '${formatBytes(clamped)} / ${formatBytes(totalBytes)}';
  }

  /// バイト数を B / KB / MB に整形
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncProgress &&
          phase == other.phase &&
          completedFiles == other.completedFiles &&
          totalFiles == other.totalFiles &&
          transferredBytes == other.transferredBytes &&
          totalBytes == other.totalBytes &&
          currentFileName == other.currentFileName;

  @override
  int get hashCode => Object.hash(
        phase,
        completedFiles,
        totalFiles,
        transferredBytes,
        totalBytes,
        currentFileName,
      );
}

/// 並列ダウンロード時のファイル別バイト集計器（リトライ時の二重計上防止対応）
class SyncByteTracker {
  final Map<String, int> _expectedBytes = {};
  final Map<String, int> _receivedBytes = {};
  final Set<String> _completedKeys = {};
  String? _currentFileName;

  SyncByteTracker([Map<String, int>? initialExpectedBytes]) {
    if (initialExpectedBytes != null) {
      for (final entry in initialExpectedBytes.entries) {
        registerFile(entry.key, entry.value);
      }
    }
  }

  /// 対象ファイルを登録（[expectedSize] が不明・負数の場合は 0 として扱う）
  void registerFile(String key, int expectedSize) {
    _expectedBytes[key] = math.max(0, expectedSize);
    _receivedBytes.putIfAbsent(key, () => 0);
  }

  int get totalFiles => _expectedBytes.length;

  int get completedFiles => _completedKeys.length;

  int get totalBytes =>
      _expectedBytes.values.fold(0, (sum, size) => sum + size);

  int get transferredBytes {
    var sum = 0;
    for (final entry in _receivedBytes.entries) {
      final expected = _expectedBytes[entry.key] ?? 0;
      if (expected > 0) {
        sum += math.min(entry.value, expected);
      } else {
        sum += entry.value;
      }
    }
    final total = totalBytes;
    return total > 0 ? math.min(sum, total) : sum;
  }

  /// チャンク受信時にバイト数を加算
  void addChunk(String key, int chunkBytes, {String? fileName}) {
    if (chunkBytes <= 0) return;
    if (fileName != null && fileName.isNotEmpty) {
      _currentFileName = fileName;
    }
    if (!_expectedBytes.containsKey(key)) {
      _expectedBytes[key] = 0;
    }
    final prev = _receivedBytes[key] ?? 0;
    final expected = _expectedBytes[key] ?? 0;
    _receivedBytes[key] =
        expected > 0 ? math.min(prev + chunkBytes, expected) : prev + chunkBytes;
  }

  /// リトライ発生時に該当ファイルの受信済みバイト数を 0 に戻す（100% 超過防止）
  void resetFile(String key) {
    if (_completedKeys.contains(key)) return;
    _receivedBytes[key] = 0;
  }

  /// ファイル完了時（または未変更スキップ確定時）にそのファイル分を満額計上する
  void markCompleted(String key, {String? fileName}) {
    if (fileName != null && fileName.isNotEmpty) {
      _currentFileName = fileName;
    }
    final expected = _expectedBytes[key] ?? 0;
    if (expected > 0) {
      _receivedBytes[key] = expected;
    }
    _completedKeys.add(key);
  }

  SyncProgress snapshot([SyncPhase phase = SyncPhase.transferring]) {
    return SyncProgress(
      phase: phase,
      completedFiles: completedFiles,
      totalFiles: totalFiles,
      transferredBytes: transferredBytes,
      totalBytes: totalBytes,
      currentFileName: _currentFileName,
    );
  }
}

/// 進捗通知の間引き器（フェーズ変更時・全ファイル完了時は間引きをバイパスして即時通知）
class ProgressThrottler {
  final void Function(SyncProgress progress) onEmit;
  final Duration minInterval;

  DateTime? _lastEmitAt;
  SyncPhase? _lastPhase;
  SyncProgress? _pending;

  ProgressThrottler(
    this.onEmit, {
    this.minInterval = const Duration(milliseconds: 150),
  });

  void add(SyncProgress progress, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final isPhaseChange = _lastPhase != progress.phase;
    final isAllCompleted = progress.totalFiles > 0 &&
        progress.completedFiles >= progress.totalFiles &&
        (progress.totalBytes <= 0 ||
            progress.transferredBytes >= progress.totalBytes);
    final elapsedOk = _lastEmitAt == null ||
        current.difference(_lastEmitAt!) >= minInterval;

    if (isPhaseChange || isAllCompleted || elapsedOk) {
      _lastEmitAt = current;
      _lastPhase = progress.phase;
      _pending = null;
      onEmit(progress);
    } else {
      _pending = progress;
    }
  }

  /// 未送信の最新進捗があれば強制送信する
  void flush({DateTime? now}) {
    final p = _pending;
    if (p == null) return;
    _pending = null;
    _lastEmitAt = now ?? DateTime.now();
    _lastPhase = p.phase;
    onEmit(p);
  }
}
