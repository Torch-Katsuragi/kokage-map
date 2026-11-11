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

/// Drive API v3 の CRUD・ページネーション・一時的ネットワーク失敗リトライを担当するクライアント
class DriveApiClient {
  final drive.DriveApi? Function() _apiProvider;

  const DriveApiClient(this._apiProvider);

  static const String folderMime = 'application/vnd.google-apps.folder';

  /// 上げたときに返してもらう項目。
  /// 同期の帳簿に Drive 側の時刻を控える（端末の時計と比べない。KMetaSyncFile.remoteModifiedTime）
  static const String _uploadedFields =
      'id, name, modifiedTime, size, md5Checksum, parents';

  /// 通信の一時的な失敗（名前解決の失敗・接続切れ・時間切れ）を 1 回だけ待って取り直すまでの間
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
    final result = await api.files.list(
      q: q,
      $fields: fields,
      supportsAllDrives: true,
      includeItemsFromAllDrives: true,
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

  /// 読むだけの呼び出し（一覧・情報取得）を、通信の一時的な失敗なら 1 回だけ取り直す。
  ///
  /// Wi-Fi の切り替わりで名前解決が一瞬落ちる（`Failed host lookup: 'www.googleapis.com'`）ことがある
  /// （2026-10-12、Android 実機）。書き込みは二重になりうるので使わない。API のエラー（4xx/5xx）はそのまま投げる
  static Future<T> retryTransient<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on Object catch (e) {
      if (e is drive.ApiRequestError || !isNetworkError(e)) rethrow;
      AppLogger.debug('[GoogleDriveService] 通信の一時的な失敗。1 回だけ取り直す: $e');
      await Future<void>.delayed(transientRetryDelay);
      return call();
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

  /// API を掴んでいれば [body] を呼ぶ。掴んでいなければ、または失敗したら [fallback]（失敗は [what] を添えてログに残す）
  Future<T> _call<T>(
    String what,
    T fallback,
    Future<T> Function(drive.DriveApi api) body,
  ) async {
    final api = _apiProvider();
    if (api == null) return fallback;
    try {
      return await body(api);
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
    final api = _apiProvider();
    if (api == null) {
      return const FolderLookup.failed(
        FolderLookupFailure.other,
        'not signed in',
      );
    }

    try {
      final result = await retryTransient(
        () => api.files.get(
          folderId,
          $fields:
              'id, name, mimeType, md5Checksum, modifiedTime, owners, capabilities',
          supportsAllDrives: true,
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
        final existing = await _findFileByName(fileName, parentId);
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
            oldParentId ?? (await getFileMetadata(fileId))?.parents.firstOrNull;
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

  /// ファイルメタデータを取得。エラー・完全削除（404）なら null
  Future<DriveFileMetadata?> getFileMetadata(String fileId) =>
      _call('ファイルメタデータ取得エラー', null, (api) async {
        final file = await api.files.get(
          fileId,
          $fields: 'id,name,trashed,modifiedTime,parents',
          supportsAllDrives: true,
        ) as drive.File;
        return DriveFileMetadata(
          id: file.id ?? fileId,
          name: file.name,
          trashed: file.trashed ?? false,
          modifiedTime: file.modifiedTime,
          parents: file.parents ?? [],
        );
      });

  /// ファイルの中身をメモリ上にダウンロードする
  Future<Uint8List?> downloadBytes(
    String fileId, {
    void Function(int chunkBytes)? onChunk,
  }) =>
      _call('ダウンロードエラー', null, (api) async {
        final response = await api.files.get(
          fileId,
          downloadOptions: drive.DownloadOptions.fullMedia,
          supportsAllDrives: true,
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
        final response = await api.files.get(
          fileId,
          downloadOptions: drive.DownloadOptions.fullMedia,
          supportsAllDrives: true,
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

  /// フォルダ直下のファイルとフォルダの一覧（共有フォルダにも届くよう共有ドライブも含める）
  ///
  /// ⚠ 取れなければ投げる（空の一覧を返さない）。以前は失敗を空として返しており、
  /// 同期が取れなかったフォルダの中身を「Drive から消えた」と見て手元を消すおそれがあった
  Future<List<drive.File>> listFiles(String parentId) async {
    final api = _apiProvider();
    if (api == null) throw StateError('Drive にサインインしていない');
    return listAllPages(
      api,
      '${inParents(parentId)} and trashed = false',
      // md5Checksum: 中身が同じなら落とさない・変更と見ない（同期の帳簿の remoteMd5 と比べる）
      fields: 'files(id, name, mimeType, modifiedTime, size, md5Checksum, parents)',
    );
  }

  /// ファイル名でファイルを検索
  Future<drive.File?> _findFileByName(String name, String parentId) => _call(
        '同名ファイルの検索エラー',
        null,
        (api) async => (await _list(
          api,
          'name = ${queryLiteral(name)} and ${inParents(parentId)} and trashed = false',
        ))
            .firstOrNull,
      );
}
