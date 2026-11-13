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
/// Root Maps: Google Drive連携サービス（ファサード）
///
/// - OAuth 認証状態・サイレント復元・サインイン/サインアウト寿命管理: [DriveAuthSession]
/// - Drive API v3 CRUD・ページネーション付き一覧取得・転送: [DriveApiClient]
/// - 共有URL解析・メタデータ種別判定: `drive_url_parser.dart`
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'drive_api_client.dart';
import 'drive_auth_session.dart';
import 'drive_auth_state.dart';
import 'drive_tree_cache.dart';
import 'drive_url_parser.dart';
import 'folder_lookup.dart';

export 'drive_api_client.dart' show DriveChangeBatch, DriveFileMetadata;

/// Google Drive連携サービス
/// シングルトンパターンで実装
class GoogleDriveService {
  static final GoogleDriveService _instance = GoogleDriveService._internal();
  factory GoogleDriveService() => _instance;

  GoogleDriveService._internal() {
    _auth.onSessionDropped = DriveTreeCache.instance.clear;
    _api = DriveApiClient(
      () => _auth.driveApi,
      onUnauthorized: () => _auth.refreshToken(force: true),
    );
  }

  final DriveAuthSession _auth = DriveAuthSession();
  late final DriveApiClient _api;

  // ========== 認証・セッション管理（DriveAuthSession へ委譲） ==========

  /// 認証状態
  DriveAuthState get authState => _auth.authState;

  /// Googleアカウントが取れているか（スコープの認可は別）
  bool get hasAccount => _auth.hasAccount;

  /// Drive APIが利用可能か確認
  bool get isDriveApiAvailable => _auth.isDriveApiAvailable;

  /// 差し替えた古いクライアントを閉じるまでの猶予
  @visibleForTesting
  static Duration get clientCloseGrace => DriveAuthSession.clientCloseGrace;
  @visibleForTesting
  static set clientCloseGrace(Duration value) =>
      DriveAuthSession.clientCloseGrace = value;

  /// 通信できるかの確認。テストで差し替える
  @visibleForTesting
  static Future<bool> Function() get onlineCheck => DriveAuthSession.onlineCheck;
  @visibleForTesting
  static set onlineCheck(Future<bool> Function() value) =>
      DriveAuthSession.onlineCheck = value;

  /// 初期化（二重実行防止）
  Future<void> initialize() => _auth.initialize();

  /// web で、リロード後に認可を無言で取り直す（必ずクリック直下から呼ぶこと）
  Future<bool> restoreWebAuthorization() => _auth.restoreWebAuthorization();

  /// 起動時の無音復元（画面は絶対に出さない）
  Future<bool> restoreSessionSilently({bool userGesture = true}) =>
      _auth.restoreSessionSilently(userGesture: userGesture);

  /// サインイン
  Future<bool> signIn() => _auth.signIn();

  /// サインアウト
  Future<void> signOut() => _auth.signOut();

  /// アカウント切替
  Future<bool> switchAccount() => _auth.switchAccount();

  /// テスト用: [token] の API を使う
  @visibleForTesting
  bool useTokenForTest(String token, http.Client Function() create) =>
      _auth.useToken(token, create);

  /// いまの API が実際に使えるか確かめ、死んでいれば取り直す（クリック直下から呼ぶこと）
  Future<bool> ensureUsableApi() => _auth.ensureUsableApi();

  /// トークンをリフレッシュしてDrive APIを再初期化
  Future<bool> refreshToken({
    bool force = false,
    bool userGesture = false,
  }) =>
      _auth.refreshToken(force: force, userGesture: userGesture);

  // ========== Drive API 操作（DriveApiClient へ委譲） ==========

  /// 通信の一時的な失敗を 1 回だけ待って取り直すまでの間
  @visibleForTesting
  static Duration get transientRetryDelay => DriveApiClient.transientRetryDelay;
  @visibleForTesting
  static set transientRetryDelay(Duration value) =>
      DriveApiClient.transientRetryDelay = value;

  /// Drive の検索式に入れる文字列リテラル（`'` と `\` を逃がす）
  @visibleForTesting
  static String queryLiteral(String value) => DriveApiClient.queryLiteral(value);

  /// 検索式の `'<ID>' in parents`（ID の形でなければ投げる）
  @visibleForTesting
  static String inParents(String parentId) => DriveApiClient.inParents(parentId);

  /// [q] に当たるものを全ページたどって全部返す
  @visibleForTesting
  static Future<List<drive.File>> listAllPages(
    drive.DriveApi api,
    String q, {
    required String fields,
  }) =>
      DriveApiClient.listAllPages(api, q, fields: fields);

  /// 読むだけの呼び出しを、通信の一時的な失敗なら 1 回だけ取り直す
  @visibleForTesting
  static Future<T> retryTransient<T>(Future<T> Function() call) =>
      DriveApiClient.retryTransient(call);

  /// 指定フォルダ内にサブフォルダを取得または作成
  Future<drive.File?> getOrCreateSubFolder(String parentId, String folderName) =>
      _api.getOrCreateSubFolder(parentId, folderName);

  /// ファイルをアップロード（同名のファイルがあればその版を更新）
  Future<drive.File?> uploadFile(String localPath, String parentId) =>
      _api.uploadFile(localPath, parentId);

  /// メモリ上の内容をそのままアップロードする
  Future<drive.File?> uploadBytes(
    Uint8List bytes,
    String fileName,
    String parentId,
  ) =>
      _api.uploadBytes(bytes, fileName, parentId);

  /// 既知のDriveファイルIDを指定してアップロード（同名の検索をしない）
  Future<drive.File?> uploadFileById(
    String localPath,
    String parentId, {
    String? existingFileId,
  }) =>
      _api.uploadFileById(localPath, parentId, existingFileId: existingFileId);

  /// ファイルをゴミ箱に移動（削除）
  Future<bool> deleteFile(String fileId) => _api.deleteFile(fileId);

  /// ファイルを移動（親フォルダを変更・改名）
  Future<bool> moveFile(
    String fileId, {
    required String newParentId,
    String? oldParentId,
    String? newName,
  }) =>
      _api.moveFile(
        fileId,
        newParentId: newParentId,
        oldParentId: oldParentId,
        newName: newName,
      );

  /// ファイルメタデータを取得。エラー・完全削除（404）なら null
  Future<DriveFileMetadata?> getFileMetadata(String fileId) =>
      _api.getFileMetadata(fileId);

  /// ファイルの中身をメモリ上にダウンロードする
  Future<Uint8List?> downloadBytes(
    String fileId, {
    void Function(int chunkBytes)? onChunk,
  }) =>
      _api.downloadBytes(fileId, onChunk: onChunk);

  /// ファイルを [localPath] にストリーミング＆アトミック書き込みでダウンロード
  Future<bool> downloadFile(
    String fileId,
    String localPath, {
    void Function(int chunkBytes)? onChunk,
    void Function()? onRetryReset,
  }) =>
      _api.downloadFile(
        fileId,
        localPath,
        onChunk: onChunk,
        onRetryReset: onRetryReset,
      );

  /// フォルダ直下のファイルとフォルダの一覧（失敗時は例外を投げる）
  Future<List<drive.File>> listFiles(String parentId) =>
      _api.listFiles(parentId);

  /// 複数の親フォルダ直下のファイルとフォルダを一括取得し、親フォルダIDごとに返す
  Future<Map<String, List<drive.File>>> listFilesForParents(
    List<String> parentIds,
  ) =>
      _api.listFilesForParents(parentIds);

  /// Drive Changes API の開始ページトークンを取得する
  Future<String?> getChangesStartPageToken() =>
      _api.getChangesStartPageToken();

  /// Drive Changes API で [pageToken] 以降の変更一覧を取得する
  Future<DriveChangeBatch?> listChanges(
    String pageToken, {
    int maxChanges = 5000,
  }) =>
      _api.listChanges(pageToken, maxChanges: maxChanges);

  /// フォルダ情報を取得。取れなければ null（理由が要るなら [lookupFolder]）
  Future<drive.File?> getFolderInfo(String folderId) =>
      _api.getFolderInfo(folderId);

  /// フォルダを確かめる（失敗理由を分類して返す）
  Future<FolderLookup> lookupFolder(String folderId) =>
      _api.lookupFolder(folderId);

  // ========== 共有URL・メタデータ判定（drive_url_parser.dart へ委譲） ==========

  /// 共有URLからフォルダID（またはマニフェスト等のファイルID）を抽出
  static String? extractFolderIdFromUrl(String url) =>
      extractDriveIdFromUrl(url);

  /// Driveのメタデータがフォルダかどうか判定
  static bool isFolderMetadata(drive.File file) =>
      isDriveFolderMetadata(file);

  /// Driveのメタデータが共有フォルダセット用のJSONファイルかどうか判定
  static bool isJsonFileMetadata(drive.File file) =>
      isDriveJsonFileMetadata(file);
}
