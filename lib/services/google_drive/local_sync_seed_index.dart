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
/// 既存同期済みファイルからのローカルシード索引（Tier 2: [LocalSyncSeedIndex]）。
///
/// 親フォルダ（例: `全体プロジェクト`）の一部として既にローカルへ同期済みのファイルを
/// [SyncLedger] から索引化する。別 `driveId` の子フォルダをクローンする際、`driveFileId` または
/// `md5Checksum` が一致するローカルファイルが存在すれば、MD5 を検証した上でローカルコピーし、
/// 冗長なネットワークダウンロードを回避する。
library;

import 'dart:isolate';

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../utils/app_logger.dart';
import '../sync_ledger.dart';
import 'drive_transfer_registry.dart';

/// ローカルの既存同期済みファイル候補
class LocalSeedCandidate {
  final String driveFileId;
  final String? remoteMd5;
  final String localFilePath;

  const LocalSeedCandidate({
    required this.driveFileId,
    required this.remoteMd5,
    required this.localFilePath,
  });
}

/// 既存の [SyncLedger] から構築するローカルファイルシード索引。
///
/// 巨大な親共有フォルダ（例: `全体プロジェクト`）の中にあるサブフォルダと同一のファイルが
/// 別の `driveId` でクローン要求された際、ネットワーク通信を行わずにローカルから検証付きコピーする。
class LocalSyncSeedIndex {
  LocalSyncSeedIndex._();

  static final LocalSyncSeedIndex instance = LocalSyncSeedIndex._();

  final Map<String, List<LocalSeedCandidate>> _byDriveFileId = {};
  final Map<String, List<LocalSeedCandidate>> _byMd5 = {};
  bool _initialized = false;

  /// [SyncLedger] の全エントリから索引を再構築する
  Future<void> refreshFromLedgers() async {
    _byDriveFileId.clear();
    _byMd5.clear();
    _initialized = true;

    final entries = await SyncLedger.instance.readAllEntries();
    for (final entry in entries) {
      final owner = entry.owner;
      if (owner == null || owner.isEmpty) continue;
      for (final fileEntry in entry.files.entries) {
        final relPath = fileEntry.key;
        final syncFile = fileEntry.value;
        if (syncFile.driveFileId.isEmpty) continue;
        final absPath = p.normalize(p.joinAll([owner, ...relPath.split('/')]));
        _addCandidate(
          LocalSeedCandidate(
            driveFileId: syncFile.driveFileId,
            remoteMd5: syncFile.remoteMd5,
            localFilePath: absPath,
          ),
        );
      }
    }
  }

  void _addCandidate(LocalSeedCandidate candidate) {
    final byId = _byDriveFileId.putIfAbsent(
      candidate.driveFileId,
      () => <LocalSeedCandidate>[],
    );
    if (!byId.any((c) => c.localFilePath == candidate.localFilePath)) {
      byId.add(candidate);
    }
    final md5Hex = candidate.remoteMd5?.toLowerCase();
    if (md5Hex != null && md5Hex.isNotEmpty) {
      final byHash = _byMd5.putIfAbsent(md5Hex, () => <LocalSeedCandidate>[]);
      if (!byHash.any((c) => c.localFilePath == candidate.localFilePath)) {
        byHash.add(candidate);
      }
    }
  }

  /// ダウンロードまたはシード完了したファイルを即座にメモリ索引へ追加する
  void registerSeededFile({
    required String driveFileId,
    required String? remoteMd5,
    required String localFilePath,
  }) {
    if (driveFileId.isEmpty || localFilePath.isEmpty) return;
    _addCandidate(
      LocalSeedCandidate(
        driveFileId: driveFileId,
        remoteMd5: remoteMd5,
        localFilePath: p.normalize(localFilePath),
      ),
    );
  }

  /// ローカルに同一内容（MD5一致）のファイルが存在すれば [targetFilePath] へアトミックにコピーし true を返す。
  /// ローカルで編集されたファイル（MD5不一致）はコピーせず false を返すため、不整合や破損が伝播しない。
  Future<bool> trySeedToFile({
    required String driveFileId,
    required String? remoteMd5,
    int? remoteSize,
    required String targetFilePath,
    void Function(int chunkBytes)? onChunkBytes,
  }) async {
    if (remoteMd5 == null || remoteMd5.isEmpty) return false;
    if (!_initialized) {
      await refreshFromLedgers();
    }

    final expectedMd5 = remoteMd5.toLowerCase();
    final targetNorm = DriveTransferRegistry.normalizeKey(targetFilePath);

    final candidates = <LocalSeedCandidate>[
      ...?_byDriveFileId[driveFileId],
      ...?_byMd5[expectedMd5],
    ];
    if (candidates.isEmpty) return false;

    final seenPaths = <String>{};
    for (final candidate in candidates) {
      final srcPath = candidate.localFilePath;
      final srcNorm = DriveTransferRegistry.normalizeKey(srcPath);
      if (srcNorm == targetNorm || !seenPaths.add(srcNorm)) continue;

      try {
        if (!await fs.exists(srcPath)) continue;
        if (remoteSize != null) {
          final srcLen = await fs.length(srcPath);
          if (srcLen == null || srcLen != remoteSize) continue;
        }

        final bytes = await fs.readAsBytes(srcPath);
        if (remoteSize != null && bytes.length != remoteSize) continue;

        final actualMd5 = kIsWeb
            ? md5.convert(bytes).toString().toLowerCase()
            : await Isolate.run(
                () => md5.convert(bytes).toString().toLowerCase(),
              );
        if (actualMd5 != expectedMd5) {
          AppLogger.debug(
            '[LocalSyncSeedIndex] ローカル変更あり（MD5不一致）のためシード除外: $srcPath',
          );
          continue;
        }

        await fs.writeStream(
          targetFilePath,
          Stream<List<int>>.value(bytes),
          onChunk: onChunkBytes,
        );
        registerSeededFile(
          driveFileId: driveFileId,
          remoteMd5: expectedMd5,
          localFilePath: targetFilePath,
        );
        AppLogger.debug(
          '[LocalSyncSeedIndex] ローカルシード成功 (${bytes.length} bytes): $srcPath -> $targetFilePath',
        );
        return true;
      } on Object catch (e) {
        AppLogger.debug('[LocalSyncSeedIndex] シード試行失敗 ($srcPath): $e');
      }
    }
    return false;
  }

  @visibleForTesting
  void resetForTest() {
    _byDriveFileId.clear();
    _byMd5.clear();
    _initialized = false;
  }
}
