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
// こかげマップ: Drive 同期の帳簿（端末ごと・アプリ私有）
//
// > [!IMPORTANT] 帳簿は共有ファイルに置かない（2026-09-06）
// > 以前は `.kmeta.json` の `sync` に、リンク情報（driveId 等）と一緒に
// > `files`（パス→driveFileId）・`lastSynced`・`driveRevisionId`・`deviceId` を
// > 書いていた。これらは**端末ごとの状態**であり、共有ファイル（いずれ `.qgs`）に
// > 載せると push のたびに共有ファイルが書き換わり、他端末に自分の帳簿を配ってしまう。
// > ここ（SharedPreferences = アプリ私有領域。web では localStorage）に分離する。
//
// キーは driveId（リンク済み）か、フォルダパスのハッシュ（未リンク）。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/fs/k_file_system.dart';
import '../models/kmeta.dart';
import '../utils/app_logger.dart';
import '../utils/stable_hash.dart';

/// 1フォルダぶんの帳簿
class SyncLedgerEntry {
  const SyncLedgerEntry({
    this.lastSynced,
    this.driveRevisionId,
    this.deviceId,
    this.files = const {},
    this.owner,
  });

  final DateTime? lastSynced;
  final String? driveRevisionId;
  final String? deviceId;
  final Map<String, KMetaSyncFile> files;

  /// この帳簿を使っているローカルの dir（[SyncLedger.resolveKey] が、同じ Drive フォルダを
  /// 1 台で 2 か所にクローンしたかを見分けるのに使う）。古い帳簿には無い
  final String? owner;

  SyncLedgerEntry withOwner(String folderPath) => SyncLedgerEntry(
    lastSynced: lastSynced,
    driveRevisionId: driveRevisionId,
    deviceId: deviceId,
    files: files,
    owner: folderPath,
  );

  bool get isEmpty =>
      lastSynced == null && driveRevisionId == null && deviceId == null && files.isEmpty;

  /// [KMetaSync] から帳簿ぶんだけ取り出す
  factory SyncLedgerEntry.fromSync(KMetaSync sync) => SyncLedgerEntry(
    lastSynced: sync.lastSynced,
    driveRevisionId: sync.driveRevisionId,
    deviceId: sync.deviceId,
    files: sync.files,
  );

  /// [sync]（リンク情報）に帳簿を重ねる
  KMetaSync applyTo(KMetaSync sync) => KMetaSync(
    driveId: sync.driveId,
    driveFolderName: sync.driveFolderName,
    driveUrl: sync.driveUrl,
    isReadOnly: sync.isReadOnly,
    lastSynced: lastSynced,
    driveRevisionId: driveRevisionId,
    deviceId: deviceId,
    files: files,
  );

  Map<String, dynamic> toJson() => {
    if (lastSynced != null) 'lastSynced': lastSynced!.toIso8601String(),
    if (driveRevisionId != null) 'driveRevisionId': driveRevisionId,
    if (deviceId != null) 'deviceId': deviceId,
    if (files.isNotEmpty) 'files': files.map((k, v) => MapEntry(k, v.toJson())),
    if (owner != null) 'owner': owner,
  };

  factory SyncLedgerEntry.fromJson(Map<String, dynamic> json) {
    final filesJson = json['files'] as Map<String, dynamic>?;
    return SyncLedgerEntry(
      lastSynced: json['lastSynced'] != null ? DateTime.tryParse(json['lastSynced'] as String) : null,
      driveRevisionId: json['driveRevisionId'] as String?,
      deviceId: json['deviceId'] as String?,
      files: filesJson == null
          ? const {}
          : filesJson.map(
              (k, v) => MapEntry(k, KMetaSyncFile.fromJson(v as Map<String, dynamic>)),
            ),
      owner: json['owner'] as String?,
    );
  }
}

class SyncLedger {
  SyncLedger._();

  static final SyncLedger instance = SyncLedger._();

  static const _prefix = 'sync_ledger:';

  /// メモリ上の控え（SharedPreferences が使えない環境でも動くように）
  final Map<String, SyncLedgerEntry> _cache = {};

  /// 帳簿のキー。リンク済みなら driveId、未リンクならフォルダパスのハッシュ
  static String keyFor({String? driveId, required String folderPath}) =>
      driveId != null && driveId.isNotEmpty
          ? 'drive:$driveId'
          : 'path:${stableHashHex(folderPath, length: 16)}';

  /// [folderPath] の帳簿のキー。
  ///
  /// 普段は [keyFor] の `drive:<driveId>`（ローカルの dir を動かしても帳簿がついてくる）。
  /// ただし同じ Drive フォルダを**この端末の別の dir にもクローンしていて**、そちらがまだ
  /// 同じ Drive を指しているときだけ、dir ごとのキー `drive:<driveId>@<dir のハッシュ>` に分ける。
  /// 以前は 2 つの dir が 1 つの帳簿を取り合い、互いの「最後に同期した時刻」を上書きしていた（2026-09-24）。
  /// 持ち主の dir が消えた・動いた・リンクを外したなら、今までどおり引き継ぐ。
  Future<String> resolveKey({String? driveId, required String folderPath}) async {
    final base = keyFor(driveId: driveId, folderPath: folderPath);
    if (driveId == null || driveId.isEmpty) return base;
    // `/sdcard/...` と `/storage/emulated/0/...` のような同じ場所の別名は、同じ dir として扱う
    // （別名で開くと別のクローンと見て帳簿を分け、全ファイルを落とし直していた。2026-09-25）
    final here = await fs.canonicalPath(folderPath);
    final scoped = '$base@${stableHashHex(here, length: 16)}';
    if (await read(scoped) != null) return scoped;
    final owner = (await read(base))?.owner;
    if (owner == null || owner == folderPath || await fs.canonicalPath(owner) == here) return base;
    try {
      if (!await fs.isDirectory(owner)) return base;
      final ownerMeta = await KMeta.loadFromFile(owner);
      if (ownerMeta?.sync.driveId != driveId) return base;
    } on Object catch (_) {
      return base;
    }
    AppLogger.debug('[SyncLedger] 同じ Drive フォルダが $owner にもある。$folderPath は別の帳簿にする');
    return scoped;
  }

  Future<SyncLedgerEntry?> read(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$key');
      if (raw == null) return null;
      final entry = SyncLedgerEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _cache[key] = entry;
      return entry;
    } on Object catch (e) {
      AppLogger.debug('[SyncLedger] 読めない ($key): $e');
      return _cache[key];
    }
  }

  Future<void> write(String key, SyncLedgerEntry entry) async {
    _cache[key] = entry;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (entry.isEmpty) {
        await prefs.remove('$_prefix$key');
      } else {
        await prefs.setString('$_prefix$key', jsonEncode(entry.toJson()));
      }
    } on Object catch (e) {
      AppLogger.debug('[SyncLedger] 書けない ($key): $e');
    }
  }

  /// リンク解除などでキーが変わるとき、旧キーの帳簿を消す
  Future<void> remove(String key) async {
    _cache.remove(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefix$key');
    } on Object catch (_) {}
  }
}
