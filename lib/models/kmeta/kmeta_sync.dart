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
// こかげマップ: Google Drive 同期リンク情報・共有フォルダセット・同期帳簿モデル

/// 同期対象ファイルの情報
class KMetaSyncFile {
  /// DriveファイルID
  final String driveFileId;

  /// 最終同期時刻（同期完了時点のDateTime.now()）。ローカルの変更判定（ファイルの mtime と比べる）に使う
  final DateTime? lastSyncedTime;

  /// 最後に同期したときの Drive 側の `modifiedTime`（Drive サーバーの時計）。
  /// リモートの変更判定はこれと比べる。端末の時計（[lastSyncedTime]）と比べると、
  /// 端末の時計が進んでいる分だけ相手の変更を見落とし、上書きして消す（2026-09-24）
  final DateTime? remoteModifiedTime;

  /// この端末で改名・移動したときの元のパス（まだ Drive に反映していない）。
  ///
  /// 改名すると帳簿のパスは新しい場所に付け替わるので「帳簿のパス ≠ Drive のパス」になる。
  /// Drive がまだここにあるなら、それはリモートの移動ではなく**この端末の移動**。
  /// 以前は自動同期がリモートの移動と見て、手元の改名を元に戻していた（2026-09-29）
  final String? movedFrom;

  /// 最後に同期したときの Drive 側の `md5Checksum`（中身の指紋）。
  /// Drive の時刻が進んでいても指紋が同じなら中身は変わっていない（同じ中身の上げ直し）。古い帳簿には無い
  final String? remoteMd5;

  const KMetaSyncFile({
    required this.driveFileId,
    this.lastSyncedTime,
    this.remoteModifiedTime,
    this.movedFrom,
    this.remoteMd5,
  });

  /// [movedFrom] を外したもの（移動が Drive に届いたあと）
  KMetaSyncFile withoutMove() => movedFrom == null
      ? this
      : KMetaSyncFile(
          driveFileId: driveFileId,
          lastSyncedTime: lastSyncedTime,
          remoteModifiedTime: remoteModifiedTime,
          remoteMd5: remoteMd5,
        );

  /// Drive 上のパス [drivePath] が、この端末で動かす前の場所か（＝ローカルの移動がまだ Drive に届いていない）
  bool isPendingLocalMoveFrom(String drivePath) => movedFrom != null && movedFrom == drivePath;

  /// 最後の同期より後に Drive 側が変わったか（Drive の時刻どうしで比べる）。
  /// [remoteModifiedTime] の無い古い帳簿は、以前どおり [lastSyncedTime] と比べる。
  /// Drive の指紋 [md5] と帳簿の [remoteMd5] がそろって同じなら、時刻が進んでいても変わっていない
  bool isRemoteNewer(DateTime driveModified, {String? md5}) {
    if (md5 != null && remoteMd5 != null && md5 == remoteMd5) return false;
    final r = remoteModifiedTime;
    if (r != null) return driveModified.isAfter(r);
    final l = lastSyncedTime;
    return l != null && driveModified.isAfter(l);
  }

  factory KMetaSyncFile.fromJson(Map<String, dynamic> json) {
    // 後方互換性：古いlastSyncedModifiedTimeも読み込む
    final legacyTime = json['lastSyncedModifiedTime'] != null
        ? DateTime.tryParse(json['lastSyncedModifiedTime'] as String)
        : null;
    // expectedParentId は廃止済み（読み捨て）
    return KMetaSyncFile(
      driveFileId: json['driveFileId'] as String,
      lastSyncedTime: json['lastSyncedTime'] != null
          ? DateTime.tryParse(json['lastSyncedTime'] as String)
          : legacyTime, // フォールバック
      remoteModifiedTime: json['remoteModifiedTime'] != null
          ? DateTime.tryParse(json['remoteModifiedTime'] as String)
          : null,
      movedFrom: json['movedFrom'] as String?,
      remoteMd5: json['remoteMd5'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'driveFileId': driveFileId};
    if (lastSyncedTime != null) {
      json['lastSyncedTime'] = lastSyncedTime!.toIso8601String();
    }
    if (remoteModifiedTime != null) {
      // Drive の時刻は UTC のまま持つ（端末のタイムゾーンに引きずられない）
      json['remoteModifiedTime'] = remoteModifiedTime!.toUtc().toIso8601String();
    }
    if (movedFrom != null) json['movedFrom'] = movedFrom;
    if (remoteMd5 != null) json['remoteMd5'] = remoteMd5;
    return json;
  }

  /// コピーを作成（一部フィールドを更新）
  KMetaSyncFile copyWith({
    String? driveFileId,
    DateTime? lastSyncedTime,
    DateTime? remoteModifiedTime,
    String? movedFrom,
    String? remoteMd5,
  }) {
    return KMetaSyncFile(
      driveFileId: driveFileId ?? this.driveFileId,
      lastSyncedTime: lastSyncedTime ?? this.lastSyncedTime,
      remoteModifiedTime: remoteModifiedTime ?? this.remoteModifiedTime,
      movedFrom: movedFrom ?? this.movedFrom,
      remoteMd5: remoteMd5 ?? this.remoteMd5,
    );
  }
}

/// 共有フォルダセット（JSON）が参照マウントするメンバーフォルダ情報
class KMetaFolderSetMember {
  /// DriveフォルダID
  final String driveId;

  /// フォルダセット内でのローカル表示名
  final String name;

  /// 元のDrive共有URL
  final String driveUrl;

  /// 読み取り専用か
  final bool isReadOnly;

  /// 実体ディレクトリのパス（DriveDirStore 上のパス等）
  final String? targetPath;

  const KMetaFolderSetMember({
    required this.driveId,
    required this.name,
    required this.driveUrl,
    this.isReadOnly = false,
    this.targetPath,
  });

  factory KMetaFolderSetMember.fromJson(Map<String, dynamic> json) {
    return KMetaFolderSetMember(
      driveId: (json['driveId'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      driveUrl: (json['driveUrl'] as String?) ?? '',
      isReadOnly: (json['isReadOnly'] as bool?) ?? false,
      targetPath: json['targetPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'driveId': driveId,
        'name': name,
        'driveUrl': driveUrl,
        'isReadOnly': isReadOnly,
        if (targetPath != null) 'targetPath': targetPath,
      };

  KMetaFolderSetMember copyWith({
    String? driveId,
    String? name,
    String? driveUrl,
    bool? isReadOnly,
    String? targetPath,
  }) {
    return KMetaFolderSetMember(
      driveId: driveId ?? this.driveId,
      name: name ?? this.name,
      driveUrl: driveUrl ?? this.driveUrl,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      targetPath: targetPath ?? this.targetPath,
    );
  }
}

/// 同期設定（Google Drive連携用）
class KMetaSync {
  /// Google DriveのフォルダID
  final String? driveId;

  /// Driveフォルダ名（表示用）
  final String? driveFolderName;

  /// Drive共有URL（元のURL）
  final String? driveUrl;

  /// 読み取り専用か
  final bool? isReadOnly;

  /// JSONマニフェストによる共有フォルダセットか
  final bool? isFolderSet;

  /// 共有フォルダセットが参照するメンバー一覧（`.qgs` に保存されるリンク情報）
  final List<KMetaFolderSetMember> setMembers;

  /// 最終同期日時
  final DateTime? lastSynced;

  /// 最後に同期したDriveリビジョンID
  final String? driveRevisionId;

  /// このデバイスの識別子（ローカル専用、同期対象外）
  final String? deviceId;

  /// 同期対象ファイル（ファイル名 → ファイル情報）
  final Map<String, KMetaSyncFile> files;

  const KMetaSync({
    this.driveId,
    this.driveFolderName,
    this.driveUrl,
    this.isReadOnly,
    this.isFolderSet,
    this.setMembers = const [],
    this.lastSynced,
    this.driveRevisionId,
    this.deviceId,
    this.files = const {},
  });

  /// JSONからパース
  factory KMetaSync.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const KMetaSync();

    // filesフィールドをパース
    final filesJson = json['files'] as Map<String, dynamic>?;
    final files = <String, KMetaSyncFile>{};
    if (filesJson != null) {
      for (final entry in filesJson.entries) {
        files[entry.key] = KMetaSyncFile.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }

    final membersJson = json['setMembers'] as List<dynamic>?;
    final setMembers = <KMetaFolderSetMember>[
      if (membersJson != null)
        for (final item in membersJson)
          if (item is Map<String, dynamic>) KMetaFolderSetMember.fromJson(item),
    ];

    return KMetaSync(
      driveId: json['driveId'] as String?,
      driveFolderName: json['driveFolderName'] as String?,
      driveUrl: json['driveUrl'] as String?,
      isReadOnly: json['isReadOnly'] as bool?,
      isFolderSet: json['isFolderSet'] as bool?,
      setMembers: setMembers,
      lastSynced: json['lastSynced'] != null
          ? DateTime.tryParse(json['lastSynced'] as String)
          : null,
      driveRevisionId: json['driveRevisionId'] as String?,
      deviceId: json['deviceId'] as String?,
      files: files,
    );
  }

  /// JSONへシリアライズ（全フィールド含む）
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (driveId != null) json['driveId'] = driveId;
    if (driveFolderName != null) json['driveFolderName'] = driveFolderName;
    if (driveUrl != null) json['driveUrl'] = driveUrl;
    if (isReadOnly != null) json['isReadOnly'] = isReadOnly;
    if (isFolderSet != null) json['isFolderSet'] = isFolderSet;
    if (setMembers.isNotEmpty) {
      json['setMembers'] = [for (final m in setMembers) m.toJson()];
    }
    if (lastSynced != null) json['lastSynced'] = lastSynced!.toIso8601String();
    if (driveRevisionId != null) json['driveRevisionId'] = driveRevisionId;
    if (deviceId != null) json['deviceId'] = deviceId;
    if (files.isNotEmpty) {
      json['files'] = files.map((k, v) => MapEntry(k, v.toJson()));
    }
    return json;
  }

  /// 共有ファイルに書くぶん（リンク情報だけ）。帳簿は `SyncLedger` へ
  KMetaSync linkOnly() => KMetaSync(
    driveId: driveId,
    driveFolderName: driveFolderName,
    driveUrl: driveUrl,
    isReadOnly: isReadOnly,
    isFolderSet: isFolderSet,
    setMembers: setMembers,
  );

  /// 帳簿（端末ごとの状態）を含んでいるか
  bool get hasBookkeeping =>
      lastSynced != null || driveRevisionId != null || deviceId != null || files.isNotEmpty;

  /// 空かどうか
  bool get isEmpty =>
      driveId == null &&
      driveFolderName == null &&
      setMembers.isEmpty &&
      lastSynced == null &&
      driveRevisionId == null &&
      deviceId == null &&
      files.isEmpty;

  /// Drive連携済みかどうか
  bool get isLinked => driveId != null;

  /// コピーを作成（一部設定を変更）
  KMetaSync copyWith({
    String? driveId,
    String? driveFolderName,
    String? driveUrl,
    bool? isReadOnly,
    bool? isFolderSet,
    List<KMetaFolderSetMember>? setMembers,
    DateTime? lastSynced,
    String? driveRevisionId,
    String? deviceId,
    Map<String, KMetaSyncFile>? files,
  }) {
    return KMetaSync(
      driveId: driveId ?? this.driveId,
      driveFolderName: driveFolderName ?? this.driveFolderName,
      driveUrl: driveUrl ?? this.driveUrl,
      isReadOnly: isReadOnly ?? this.isReadOnly,
      isFolderSet: isFolderSet ?? this.isFolderSet,
      setMembers: setMembers ?? this.setMembers,
      lastSynced: lastSynced ?? this.lastSynced,
      driveRevisionId: driveRevisionId ?? this.driveRevisionId,
      deviceId: deviceId ?? this.deviceId,
      files: files ?? this.files,
    );
  }
}
