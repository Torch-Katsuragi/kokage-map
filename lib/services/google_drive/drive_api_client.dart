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
/// Google Drive API v3 のファイル/フォルダ CRUD・ページネーション一覧取得・転送クライアント
library;

import 'dart:async';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../core/shared_link.dart';
import '../../utils/app_logger.dart';
import 'folder_lookup.dart';
import 'network_error.dart';

/// Driveファイルのメタデータ
class DriveFileMetadata {
  final String id;
  final String? name;
  final bool trashed;
  final DateTime? modifiedTime;
  final List<String> parents;

  const DriveFileMetadata({
    required this.id,
    this.name,
    required this.trashed,
    this.modifiedTime,
    this.parents = const [],
  });
}

/// Drive Changes API の差分取得結果
class DriveChangeBatch {
  final List<drive.Change> changes;
  final String newStartPageToken;
  final bool overflowed;

  const DriveChangeBatch({
    required this.changes,
    required this.newStartPageToken,
    this.overflowed = false,
  });
}

/// Drive API v3 の CRUD・ページネーション・一時的ネットワーク失敗リトライを担当するクライアント
class DriveApiClient {
  final drive.DriveApi? Function() _apiProvider;
  final Future<bool> Function()? onUnauthorized;

  const DriveApiClient(
    this._apiProvider, {
    this.onUnauthorized,
  });

  static const String folderMime = 'application/vnd.google-apps.folder';

  /// 1 回の `files.list` にまとめる親フォルダ ID の上限（URL 長と Drive 検索式の複雑度上限に対して十分安全な値）
  static const int maxParentsPerListQuery = 40;

  /// レート制限・5xx 応答に対する最大リトライ回数
  static const int maxRateLimitRetries = 4;

  static final Random _jitterRandom = Random();

  /// 上げたときに返してもらう項目。
  /// 同期の帳簿に Drive 側の時刻を控える（端末の時計と比べない。KMetaSyncFile.remoteModifiedTime）
  static const String _uploadedFields =
      'id, name, modifiedTime, size, md5Checksum, parents';

  /// 通信の一時的な失敗やレート制限時の基準待機時間（テストでは Duration.zero に差し替え可能）
  static Duration transientRetryDelay = const Duration(milliseconds: 800);

  /// Drive の検索式に入れる文字列リテラル（`'` と `\` を逃がす）。
  ///
  /// ⚠ 以前は名前をそのまま `'...'` で囲んでいた。名前に `'` があると検索式が壊れて例外になり、
  /// 同名のファイルの検索が「見つからない」に化けて Drive にもう 1 つ作ったり、
  /// サブフォルダを解決できずにその中のファイルを上げられなかったりしていた
  static String queryLiteral(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  /// 検索式の `'<ID>' in parents`。ID の形でなければ投げる（検索式に余計な条件を足させない）
  static String inParents(String parentId) {
    if (!isDriveId(parentId)) {
      throw ArgumentError.value(parentId, 'parentId', 'Drive の ID の形ではない');
    }
    return "'$parentId' in parents";
  }

  /// [q] に当たるもの（共有ドライブも含めて探す）。最初の 1 ページだけ（名前で 1 件を探すとき用）
  static Future<List<drive.File>> _list(
    drive.DriveApi api,
    String q, {
    String? fields,
  }) async {
    final result = await retryTransient(
      () => api.files.list(
        q: q,
        $fields: fields,
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
      ),
    );
    return result.files ?? [];
  }

  /// [q] に当たるものを全ページたどって全部返す（[fields] は `files(...)` の形）。
  ///
  /// ⚠ files.list は 1 ページ 100 件で切れる。以前はたどっておらず、101 件目からは
  /// 「Drive に無い」と見て、同期が手元のファイルを消していた（写真の多いフォルダ）
  static Future<List<drive.File>> listAllPages(
    drive.DriveApi api,
    String q, {
    required String fields,
  }) async {
    final out = <drive.File>[];
    String? pageToken;
    do {
      final token = pageToken;
      final page = await retryTransient(
        () => api.files.list(
          q: q,
          $fields: 'nextPageToken, $fields',
          pageSize: 1000,
          pageToken: token,
          supportsAllDrives: true,
          includeItemsFromAllDrives: true,
        ),
      );
      out.addAll(page.files ?? const []);
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return out;
  }

  /// 読むだけの呼び出し（一覧・情報取得）を、通信の一時的な失敗なら 1 回、
  /// Drive API のレート制限（429 / 403 rateLimitExceeded）や 5xx なら指数バックオフ付きで取り直す。
  ///
  /// Wi-Fi の切り替わりで名前解決が一瞬落ちることがある（2026-10-12、Android 実機）。
  /// またサブフォルダが多い共有フォルダの一斉走査で per-user 秒間上限に触れた場合もバックオフで吸収する。
  /// 権限エラー（403 insufficientFilePermissions）や 404 はリトライせずそのまま投げる。
  static Future<T> retryTransient<T>(Future<T> Function() call) async {
    var rateLimitAttempt = 0;
    var retriedNetwork = false;
    while (true) {
      try {
        return await call();
      } on Object catch (e) {
        if (isRateLimitOrServerError(e) &&
            rateLimitAttempt < maxRateLimitRetries) {
          final baseMs = transientRetryDelay.inMilliseconds * (1 << rateLimitAttempt);
          final jitterMs =
              baseMs > 0 ? _jitterRandom.nextInt((baseMs ~/ 4) + 1) : 0;
          final wait = Duration(milliseconds: baseMs + jitterMs);
          rateLimitAttempt++;
          AppLogger.debug(
            '[GoogleDriveService] レート制限/一時サーバーエラーのため待機して再試行 ($rateLimitAttempt/$maxRateLimitRetries): $e',
          );
          if (wait > Duration.zero) {
            await Future<void>.delayed(wait);
          }
          continue;
        }
        if (e is! drive.ApiRequestError &&
            isNetworkError(e) &&
            !retriedNetwork) {
          retriedNetwork = true;
          AppLogger.debug('[GoogleDriveService] 通信の一時的な失敗。1 回だけ取り直す: $e');
          if (transientRetryDelay > Duration.zero) {
            await Future<void>.delayed(transientRetryDelay);
          }
          continue;
        }
        rethrow;
      }
    }
  }

  /// HTTP 401（アクセストークン期限切れ）を受けたときに 1 回だけ [onUnauthorized] でトークンを更新して再実行する
  Future<T> _runWithAuthRetry<T>(
    Future<T> Function(drive.DriveApi api) body,
  ) async {
    final api = _apiProvider();
    if (api == null) throw StateError('Drive にサインインしていない');
    try {
      return await body(api);
    } on Object catch (e) {
      final refresh = onUnauthorized;
      if (isUnauthorizedError(e) && refresh != null) {
        AppLogger.debug('[GoogleDriveService] 401 応答を検出。トークンを再取得して再試行します');
        final refreshed = await refresh();
        final nextApi = refreshed ? _apiProvider() : null;
        if (nextApi != null) {
          return await body(nextApi);
        }
      }
      rethrow;
    }
  }

  /// 中身を上げる。[existingFileId] があればその版を更新し、無ければ [parentId] に作る
  static Future<drive.File> _put(
    drive.DriveApi api,
    Uint8List bytes, {
    required String fileName,
    required String parentId,
    String? existingFileId,
  }) {
    final media = drive.Media(Stream<List<int>>.value(bytes), bytes.length);
    if (existingFileId != null) {
      return api.files.update(
        drive.File(),
        existingFileId,
        uploadMedia: media,
        supportsAllDrives: true,
        $fields: _uploadedFields,
      );
    }
    return api.files.create(
      drive.File(name: fileName, parents: [parentId]),
      uploadMedia: media,
      supportsAllDrives: true,
      $fields: _uploadedFields,
    );
  }

  /// API を掴んでいれば [body] を呼ぶ（401 時は 1 回だけトークン再取得を試す）。
  /// 掴んでいなければ、または失敗したら [fallback]（失敗は [what] を添えてログに残す）
  Future<T> _call<T>(
    String what,
    T fallback,
    Future<T> Function(drive.DriveApi api) body,
  ) async {
    if (_apiProvider() == null) return fallback;
    try {
      return await _runWithAuthRetry(body);
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] $what: $e');
      return fallback;
    }
  }

  // ========== フォルダ操作 ==========

  /// 指定フォルダ内にサブフォルダを取得または作成
  Future<drive.File?> getOrCreateSubFolder(String parentId, String folderName) =>
      _call('サブフォルダ作成エラー', null, (api) async {
        final existing = (await _list(
          api,
          "name = ${queryLiteral(folderName)} and ${inParents(parentId)} and mimeType = '$folderMime' and trashed = false",
          fields: 'files(id, name)',
        ))
            .firstOrNull;
        if (existing != null) return existing;

        final created = await api.files.create(
          drive.File(
            name: folderName,
            mimeType: folderMime,
            parents: [parentId],
          ),
          supportsAllDrives: true,
        );
        AppLogger.debug('[GoogleDriveService] サブフォルダ作成: $folderName');
        return created;
      });

  /// フォルダ情報を取得。取れなければ null（理由が要るなら [lookupFolder]）
  Future<drive.File?> getFolderInfo(String folderId) async =>
      (await lookupFolder(folderId)).folder;

  /// フォルダを確かめる。失敗は「通信できない」「権限が無い」「無い」「その他」に分けて返す（投げない）。
  /// 共有フォルダにもアクセスするため supportsAllDrives=true を設定
  Future<FolderLookup> lookupFolder(String folderId) async {
    if (_apiProvider() == null) {
      return const FolderLookup.failed(
        FolderLookupFailure.other,
        'not signed in',
      );
    }

    try {
      final result = await _runWithAuthRetry(
        (api) => retryTransient(
          () => api.files.get(
            folderId,
            $fields:
                'id, name, mimeType, md5Checksum, modifiedTime, owners, capabilities',
            supportsAllDrives: true,
          ),
        ),
      );
      return FolderLookup.found(result as drive.File);
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] フォルダ情報取得エラー: $e');
      return FolderLookup.fromError(e);
    }
  }

  // ========== ファイル操作 ==========

  /// ファイルをアップロード（同じフォルダに同名のファイルがあればその版を更新）
  /// [localPath] ローカルファイルのパス（web では仮想パス）
  /// [parentId] 親フォルダID
  ///
  /// > [!NOTE] 中身は丸ごとメモリに載せる
  /// > `dart:io` の `openRead()` はストリームで流せるが、web には無い。
  /// > `fs` は「全部読む」しか持たないので、ここで揃えた。
  /// > 現場のgpkgは数十MB程度なので許容できる。
  Future<drive.File?> uploadFile(String localPath, String parentId) async {
    if (_apiProvider() == null) return null;
    final bytes = await fs.readAsBytes(localPath);
    return uploadBytes(bytes, p.basename(localPath), parentId);
  }

  /// メモリ上の内容をそのままアップロードする（同名のファイルがあればその版を更新）。
  ///
  /// 一時ファイルを作らずに済ませたいとき用（フォルダ設定（`.qgs`） の加工など）。
  /// web には一時ディレクトリが無いので、こちらしか使えない。
  Future<drive.File?> uploadBytes(
    Uint8List bytes,
    String fileName,
    String parentId,
  ) =>
      _call('アップロードエラー', null, (api) async {
        final existing = (await _list(
          api,
          'name = ${queryLiteral(fileName)} and ${inParents(parentId)} and trashed = false',
        ))
            .firstOrNull;
        final result = await _put(
          api,
          bytes,
          fileName: fileName,
          parentId: parentId,
          existingFileId: existing?.id,
        );
        AppLogger.debug(
          '[GoogleDriveService] ${existing != null ? 'ファイル更新' : 'ファイルアップロード'}: $fileName',
        );
        return result;
      });

  /// 既知のDriveファイルIDを指定してアップロード（同名の検索をしない）
  /// [existingFileId] が指定されていれば files.update、なければ files.create
  Future<drive.File?> uploadFileById(
    String localPath,
    String parentId, {
    String? existingFileId,
  }) =>
      _call('アップロードエラー(byId)', null, (api) async {
        final fileName = p.basename(localPath);
        final bytes = await fs.readAsBytes(localPath);
        final result = await _put(
          api,
          bytes,
          fileName: fileName,
          parentId: parentId,
          existingFileId: existingFileId,
        );
        AppLogger.debug(
          '[GoogleDriveService] ${existingFileId != null ? 'ファイル更新(byId)' : 'ファイル新規作成(byId)'}: $fileName',
        );
        return result;
      });

  /// ファイルをゴミ箱に移動（削除）
  /// 完全削除ではなくゴミ箱移動を使用（操作ミス対策 + 共有ドライブ対応）
  Future<bool> deleteFile(String fileId) => _call('ゴミ箱移動エラー', false, (api) async {
        try {
          await api.files.update(
            drive.File(trashed: true),
            fileId,
            supportsAllDrives: true,
          );
          AppLogger.debug('[GoogleDriveService] ファイルをゴミ箱に移動: $fileId');
          return true;
        } on drive.DetailedApiRequestError catch (e) {
          // 404は既にゴミ箱 or 削除済み
          if (e.status == 404) {
            AppLogger.debug('[GoogleDriveService] ファイル既に削除済み（404）: $fileId');
            return true;
          }
          rethrow;
        }
      });

  /// ファイルを移動（親フォルダを変更）。バージョン履歴を維持したまま移動
  /// [oldParentId] 移動元フォルダID（省略時は Drive に聞く）
  /// [newName] を渡すと名前も変える（この端末で改名したとき）
  Future<bool> moveFile(
    String fileId, {
    required String newParentId,
    String? oldParentId,
    String? newName,
  }) =>
      _call('ファイル移動エラー', false, (api) async {
        final removeParent =
            oldParentId ?? (await _fetchMetadataWithApi(api, fileId)).parents.firstOrNull;
        // 同じ dir の中の改名なら親は触らない
        final sameParent = removeParent == newParentId;
        await api.files.update(
          drive.File(name: newName),
          fileId,
          addParents: sameParent ? null : newParentId,
          removeParents: sameParent ? null : removeParent,
          supportsAllDrives: true,
        );
        AppLogger.debug('[GoogleDriveService] ファイル移動: $fileId → $newParentId');
        return true;
      });

  static Future<DriveFileMetadata> _fetchMetadataWithApi(
    drive.DriveApi api,
    String fileId,
  ) async {
    final file = await retryTransient(
      () => api.files.get(
        fileId,
        $fields: 'id,name,trashed,modifiedTime,parents',
        supportsAllDrives: true,
      ),
    ) as drive.File;
    return DriveFileMetadata(
      id: file.id ?? fileId,
      name: file.name,
      trashed: file.trashed ?? false,
      modifiedTime: file.modifiedTime,
      parents: file.parents ?? [],
    );
  }

  /// ファイルメタデータを取得。エラー・完全削除（404）なら null
  Future<DriveFileMetadata?> getFileMetadata(String fileId) =>
      _call(
        'ファイルメタデータ取得エラー',
        null,
        (api) => _fetchMetadataWithApi(api, fileId),
      );

  /// ファイルの中身をメモリ上にダウンロードする
  Future<Uint8List?> downloadBytes(
    String fileId, {
    void Function(int chunkBytes)? onChunk,
  }) =>
      _call('ダウンロードエラー', null, (api) async {
        final response = await retryTransient(
          () => api.files.get(
            fileId,
            downloadOptions: drive.DownloadOptions.fullMedia,
            supportsAllDrives: true,
          ),
        );
        if (response is! drive.Media) {
          AppLogger.debug('[GoogleDriveService] ダウンロード応答が不正');
          return null;
        }
        final chunks = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          chunks.add(chunk);
          onChunk?.call(chunk.length);
        }
        return chunks.takeBytes();
      });

  /// ファイルを [localPath] にストリーミング＆アトミック書き込みでダウンロード
  Future<bool> downloadFile(
    String fileId,
    String localPath, {
    void Function(int chunkBytes)? onChunk,
    void Function()? onRetryReset,
  }) =>
      _call('ダウンロードエラー', false, (api) async {
        onRetryReset?.call();
        final response = await retryTransient(
          () => api.files.get(
            fileId,
            downloadOptions: drive.DownloadOptions.fullMedia,
            supportsAllDrives: true,
          ),
        );
        if (response is! drive.Media) {
          AppLogger.debug('[GoogleDriveService] ダウンロード応答が不正');
          return false;
        }
        try {
          await fs.writeStream(
            localPath,
            response.stream,
            onChunk: onChunk,
          );
          AppLogger.debug('[GoogleDriveService] ダウンロード完了: $localPath');
          return true;
        } catch (e) {
          AppLogger.debug('[GoogleDriveService] ファイル書き込みエラー: $e');
          return false;
        }
      });

  static const String _listItemFields =
      'files(id, name, mimeType, modifiedTime, size, md5Checksum, parents)';

  /// フォルダ直下のファイルとフォルダの一覧（共有フォルダにも届くよう共有ドライブも含める）
  ///
  /// ⚠ 取れなければ投げる（空の一覧を返さない）。以前は失敗を空として返しており、
  /// 同期が取れなかったフォルダの中身を「Drive から消えた」と見て手元を消すおそれがあった
  Future<List<drive.File>> listFiles(String parentId) => _runWithAuthRetry(
        (api) => listAllPages(
          api,
          '${inParents(parentId)} and trashed = false',
          // md5Checksum: 中身が同じなら落とさない・変更と見ない（同期の帳簿の remoteMd5 と比べる）
          fields: _listItemFields,
        ),
      );

  /// 複数の親フォルダ直下のファイル・サブフォルダを一括取得し、親フォルダIDごとに振り分けて返す。
  ///
  /// サブフォルダが数百〜数千ある共有フォルダで、フォルダごとに `files.list` を投げると
  /// Drive API の秒間レート制限に引っかかるため、最大 [maxParentsPerListQuery] 件ずつ `or` で束ねる。
  Future<Map<String, List<drive.File>>> listFilesForParents(
    List<String> parentIds,
  ) async {
    if (parentIds.isEmpty) return const {};
    final uniqueIds = parentIds.toSet().toList(growable: false);
    if (uniqueIds.length == 1) {
      final single = uniqueIds.single;
      return {single: await listFiles(single)};
    }

    final result = <String, List<drive.File>>{
      for (final id in uniqueIds) id: <drive.File>[],
    };
    for (var i = 0; i < uniqueIds.length; i += maxParentsPerListQuery) {
      final end = (i + maxParentsPerListQuery < uniqueIds.length)
          ? i + maxParentsPerListQuery
          : uniqueIds.length;
      final chunk = uniqueIds.sublist(i, end);
      if (chunk.length == 1) {
        result[chunk.single]!.addAll(await listFiles(chunk.single));
        continue;
      }
      final clause = chunk.map(inParents).join(' or ');
      final files = await _runWithAuthRetry(
        (api) => listAllPages(
          api,
          '($clause) and trashed = false',
          fields: _listItemFields,
        ),
      );
      for (final file in files) {
        for (final pId in file.parents ?? const <String>[]) {
          result[pId]?.add(file);
        }
      }
    }
    return result;
  }

  // ========== Changes API（差分検知） ==========

  /// Drive Changes API の開始ページトークンを取得する（失敗時は null）
  Future<String?> getChangesStartPageToken() =>
      _call('変更開始トークン取得エラー', null, (api) async {
        final res = await retryTransient(
          () => api.changes.getStartPageToken(supportsAllDrives: true),
        );
        return res.startPageToken;
      });

  /// [pageToken] 以降の Drive 変更履歴を取得する。
  /// [maxChanges] 件を超えた場合は `overflowed: true` で打ち切り、呼び出し側で全キャッシュ破棄にフォールバックさせる。
  Future<DriveChangeBatch?> listChanges(
    String pageToken, {
    int maxChanges = 5000,
  }) =>
      _call('変更一覧取得エラー', null, (api) async {
        final out = <drive.Change>[];
        String? nextToken = pageToken;
        String? newStartToken;
        while (nextToken != null && nextToken.isNotEmpty) {
          final currentToken = nextToken;
          final page = await retryTransient(
            () => api.changes.list(
              currentToken,
              pageSize: 1000,
              includeItemsFromAllDrives: true,
              supportsAllDrives: true,
              includeRemoved: true,
              $fields:
                  'nextPageToken, newStartPageToken, changes(fileId, removed, file(id, name, mimeType, trashed, parents))',
            ),
          );
          out.addAll(page.changes ?? const []);
          if (out.length > maxChanges) {
            return const DriveChangeBatch(
              changes: [],
              newStartPageToken: '',
              overflowed: true,
            );
          }
          newStartToken = page.newStartPageToken ?? newStartToken;
          nextToken = page.nextPageToken;
        }
        if (newStartToken == null || newStartToken.isEmpty) return null;
        return DriveChangeBatch(
          changes: out,
          newStartPageToken: newStartToken,
        );
      });
}
