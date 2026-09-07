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
// Root Maps: Google Drive連携サービス
// OAuth認証とDrive API操作を担当

import 'dart:async';
import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import 'drive_auth_state.dart';
import 'web_token_client.dart';

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

/// Google Drive連携サービス
/// シングルトンパターンで実装
class GoogleDriveService {
  // シングルトン
  static final GoogleDriveService _instance = GoogleDriveService._internal();
  factory GoogleDriveService() => _instance;
  GoogleDriveService._internal();

  /// GoogleSignIn v7 はシングルトン: GoogleSignIn.instance
  bool _isInitialized = false;
  Completer<void>? _initCompleter;

  /// 認証済みユーザー（イベントベースで更新）
  GoogleSignInAccount? _currentUser;

  /// Drive APIクライアント
  drive.DriveApi? _driveApi;

  /// 認証状態
  final DriveAuthState authState = DriveAuthState();

  /// 前回サインインしたメールアドレスを覚えておくキー。
  ///
  /// ⚠ **トークンは保存しない。** 保存するのはメールアドレスだけで、これは
  /// `login_hint` に渡すためだけに使う。トークンをlocalStorageに置くと、
  /// XSS一発でDrive全体が漏れる。
  static const String _kLastEmailKey = 'drive_last_email';

  /// Googleアカウントが取れているか（スコープの認可は別）。
  ///
  /// web はこの2段階が分かれる。アカウントが無ければ Googleが描画する
  /// ボタンでしか進めず、あれば認可のポップアップを開ける。
  /// UIはこれを見て、出すボタンを1つに絞ること。
  bool get hasAccount => _currentUser != null;

  /// こかげマップ用のDriveルートフォルダ名
  ///
  /// ⚠ **値を変えないこと。** これは客のDriveに実際に作られたフォルダの名前で、
  /// 変えると連携済みのフォルダを見失う。2026-08-27 の改名でも据え置いた。
  static const String kMapsFolderName = 'RootMap GIS Projects';

  /// 必要なOAuthスコープ
  static const List<String> _scopes = [
    drive.DriveApi.driveScope, // Driveへのフルアクセス
    'email', // メールアドレス取得
  ];

  /// 初期化（二重実行防止）
  Future<void> initialize() async {
    if (_isInitialized) return;

    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    try {
      // v7: シングルトンを初期化
      //
      // ⚠ web はブラウザ用のOAuthクライアントIDが要る。native は
      //   `google-services.json` / `Info.plist` から拾うので渡さない
      //   （渡すと逆に取り違える）。
      await GoogleSignIn.instance.initialize(
        clientId:
            PlatformCapabilities.isWeb &&
                    PlatformCapabilities.kWebOAuthClientId.isNotEmpty
                ? PlatformCapabilities.kWebOAuthClientId
                : null,
      );

      // 認証イベントをリッスン
      GoogleSignIn.instance.authenticationEvents.listen(
        _handleAuthenticationEvent,
      ).onError((Object error) {
        AppLogger.debug('[GoogleDriveService] 認証イベントエラー: $error');
      });

      // v7: 軽量認証を試行（以前の signInSilently 相当）
      try {
        await GoogleSignIn.instance.attemptLightweightAuthentication();
      } catch (e) {
        AppLogger.debug('[GoogleDriveService] 軽量認証失敗: $e');
      }

      _isInitialized = true;
      _initCompleter!.complete();
    } catch (e) {
      _initCompleter!.completeError(e);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  /// web で、リロード後に認可を無言で取り直す
  ///
  /// ⚠ **必ずクリックの直下から呼ぶこと。** `prompt=''` でもGISはポップアップを
  /// 使うので、起動時など操作から切り離された文脈ではブラウザに潰される
  /// （console に `Failed to open popup window` だけが残る）。
  ///
  /// ⚠ **web はページを離れるとトークンが消える。** `google_sign_in_web` の
  /// トークンキャッシュはただのメモリ上の Map で、保存も更新もしない
  /// （ブラウザのOAuthにリフレッシュトークンは無い）。
  /// 放っておくとリロードのたびにサインインし直しになる。
  ///
  /// ただしGoogle側の同意は残っているので、`prompt=''` で聞けば画面を出さずに
  /// トークンが降りてくる。⚠ その `prompt=''` になるのは
  /// **ユーザーを渡さない** `GoogleSignIn.instance.authorizationClient` だけで、
  /// `GoogleSignInAccount.authorizationClient` は `prompt=select_account` に
  /// なり必ず選択画面が出る（[_initializeDriveApi] も同じ理由でこちらを使う）。
  ///
  /// 同意がまだ／ブラウザにGoogleのセッションが無ければ失敗する。そのときは
  /// 通常のサインインUIに任せる。
  Future<bool> restoreWebAuthorization() async {
    // ⚠ hint はこの2択。**ライブラリの authorizeScopes に落とさないこと。**
    // あちらは `prompt=select_account` を抱き合わせるので、同意済みでも
    // 毎回アカウント選択が出る（2026-08-28、本番で毎回クリックさせていた）。
    final hint = await _rememberedEmail() ?? _currentUser?.email;
    if (hint == null || hint.isEmpty) {
      // ⚠ `login_hint` が無いと、Googleがアカウントを決められず
      // 選択画面で止まる（＝無音にならない）。ここは諦めてUIに渡す。
      AppLogger.debug('[GoogleDriveService] 覚えているアドレスが無いので復元しない');
      return false;
    }

    AppLogger.debug('[GoogleDriveService] 認可を無音で復元: $hint');
    String? token;
    try {
      token = await requestTokenSilently(
        clientId: PlatformCapabilities.kWebOAuthClientId,
        scopes: _scopes,
        loginHint: hint,
      );
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] トークン要求で例外: $e');
      return false;
    }
    if (token == null) {
      AppLogger.debug('[GoogleDriveService] 無音の復元は不可');
      return false;
    }

    try {
      final api = drive.DriveApi(_BearerClient(token));
      // 誰のトークンかはトークン自体に入っていないので、Driveに聞く
      final about = await api.about.get($fields: 'user');
      final user = about.user;
      _driveApi = api;
      authState.setAuthenticated(
        DriveUser(
          id: user?.permissionId ?? '',
          email: user?.emailAddress ?? hint,
          displayName: user?.displayName,
          photoUrl: user?.photoLink,
        ),
      );
      await _rememberEmail(user?.emailAddress ?? hint);
      AppLogger.debug('[GoogleDriveService] 復元できた: ${user?.emailAddress}');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] 復元したトークンが使えない: $e');
      return false;
    }
  }

  Future<void> _rememberEmail(String email) async {
    if (email.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastEmailKey, email);
  }

  Future<String?> _rememberedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastEmailKey);
  }

  /// 認証イベントハンドラ
  Future<void> _handleAuthenticationEvent(
    GoogleSignInAuthenticationEvent event,
  ) async {
    switch (event) {
      case GoogleSignInAuthenticationEventSignIn():
        _currentUser = event.user;
        try {
          // ⚠ web の認可ポップアップは**クリックの直下**でしか開けない。
          // このハンドラは One Tap から非同期に呼ばれるので、ここで
          // `authorizeScopes` を呼ぶとブラウザにポップアップを潰される。
          // 認可がまだなら「サインイン済み・認可待ち」で止め、[signIn] に託す。
          final authorized = await _initializeDriveApi(
            event.user,
            promptIfUnauthorized: !PlatformCapabilities.isWeb,
          );
          if (!authorized) {
            authState.setUnauthenticated();
            AppLogger.debug('[GoogleDriveService] サインイン済み・スコープ認可待ち');
            return;
          }
          authState.setAuthenticated(DriveUser.fromGoogleAccount(event.user));
          await _rememberEmail(event.user.email);
          AppLogger.debug('[GoogleDriveService] サインイン成功: ${event.user.email}');
        } catch (e) {
          AppLogger.debug('[GoogleDriveService] Drive API初期化エラー: $e');
          authState.setError(t.services.signInFailed(error: e.toString()));
        }
      case GoogleSignInAuthenticationEventSignOut():
        _currentUser = null;
        _driveApi = null;
        authState.setUnauthenticated();
        AppLogger.debug('[GoogleDriveService] サインアウトイベント受信');
    }
  }

  /// サインイン
  Future<bool> signIn() async {
    if (!_isInitialized) {
      await initialize();
    }

    authState.setAuthenticating();

    try {
      // ⚠ web に `authenticate()` は無い（`google_sign_in_web` が
      // `UnimplementedError` を投げる）。ユーザーの取得は One Tap か
      // [webSignInButton] の担当で、ここは**スコープ認可**を受け持つ。
      // この経路はボタンのクリック直下なので、ポップアップが開ける。
      if (PlatformCapabilities.isWeb) {
        // ⚠ アカウントの有無に関わらず、まず無音復元（login_hint 直叩き）。
        // 以前はアカウントがあるとライブラリの `authorizeScopes` に落ちており、
        // `select_account` 抱き合わせで**毎回アカウント選択が出ていた**。
        if (await restoreWebAuthorization()) return true;

        final user = _currentUser;
        if (user == null) {
          // hint が本当に無い＝このブラウザで初めて。ここは画面が出て正しい
          authState.setUnauthenticated();
          return false;
        }
        // hint があったのに無音で通らなかった＝同意がまだ（本当の初回）。
        // ここで出る同意画面は正当。ただしライブラリ経由なので選択画面も付く
        await _initializeDriveApi(user);
        authState.setAuthenticated(DriveUser.fromGoogleAccount(user));
        await _rememberEmail(user.email);
        return true;
      }

      // v7: authenticate() を呼ぶ
      await GoogleSignIn.instance.authenticate();
      // 認証イベントハンドラが呼ばれて状態が更新される
      return authState.status == DriveAuthStatus.authenticated;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        authState.setUnauthenticated();
        return false;
      }
      AppLogger.debug('[GoogleDriveService] サインインエラー: ${e.code} ${e.description}');
      authState.setError(t.services.signInFailed(error: e.description ?? e.code.toString()));
      return false;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] サインインエラー: $e');
      authState.setError(t.services.signInFailed(error: e.toString()));
      return false;
    }
  }

  /// サインアウト
  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.disconnect();
      // 認証イベントハンドラで状態がクリアされる
      AppLogger.debug('[GoogleDriveService] サインアウト完了');
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] サインアウトエラー: $e');
    }
  }

  /// アカウント切替（disconnect → authenticate でアカウント選択画面を表示）
  Future<bool> switchAccount() async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      // Credential Manager との紐付けを解除
      await GoogleSignIn.instance.disconnect();
      _currentUser = null;
      _driveApi = null;

      // 少し待ってからアカウント選択画面を表示
      await Future.delayed(const Duration(milliseconds: 300));

      // ⚠ web は `authenticate()` を持たない。切断だけして、選び直しは
      // One Tap / [webSignInButton] に任せる。
      if (PlatformCapabilities.isWeb) {
        authState.setUnauthenticated();
        return false;
      }

      // authenticate() でアカウント選択UIが表示される
      await GoogleSignIn.instance.authenticate();
      // 認証イベントハンドラが呼ばれて状態が更新される
      return authState.status == DriveAuthStatus.authenticated;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        authState.setUnauthenticated();
        return false;
      }
      AppLogger.debug('[GoogleDriveService] アカウント切替エラー: ${e.code} ${e.description}');
      authState.setError(t.services.signInFailed(error: e.description ?? e.code.toString()));
      return false;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] アカウント切替エラー: $e');
      authState.setError(t.services.signInFailed(error: e.toString()));
      return false;
    }
  }

  /// Drive APIを初期化
  /// v7: authorizationClient 経由で authClient を取得
  ///
  /// [promptIfUnauthorized] が false なら、認可済みのときだけ初期化して
  /// 未認可なら false を返す（認可ダイアログを出さない）。
  Future<bool> _initializeDriveApi(
    GoogleSignInAccount account, {
    bool promptIfUnauthorized = true,
  }) async {
    // スコープの認可を確認・要求
    final authorization = await account.authorizationClient
        .authorizationForScopes(_scopes);

    if (authorization != null) {
      _driveApi = drive.DriveApi(authorization.authClient(scopes: _scopes));
      return true;
    }

    if (!promptIfUnauthorized) return false;

    // スコープがまだ認可されていない場合、認可を要求
    final granted = await account.authorizationClient.authorizeScopes(_scopes);
    _driveApi = drive.DriveApi(granted.authClient(scopes: _scopes));
    return true;
  }

  /// いまの API が実際に使えるか確かめ、死んでいれば取り直す
  ///
  /// ⚠ **web のトークンは約1時間で失効し、失効しても `_driveApi` は
  /// 残ったまま**になる（リフレッシュトークンが無いので自動更新できない）。
  /// タブを開きっぱなしにした翌操作で 401 を踏み、同期エラーに化けていた。
  /// 同期の入口では [isDriveApiAvailable] ではなくこれを使うこと。
  /// 軽い実呼び出し（about.get）で生存確認する。
  ///
  /// ⚠ 取り直しはポップアップを使うので、**クリックの直下から呼ぶこと**。
  Future<bool> ensureUsableApi() async {
    final api = _driveApi;
    if (api == null) return false;
    try {
      await api.about.get($fields: 'user');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] APIが失効している: $e');
      _driveApi = null;
      if (PlatformCapabilities.isWeb) return restoreWebAuthorization();
      return refreshToken();
    }
  }

  /// トークンをリフレッシュしてDrive APIを再初期化
  /// トークン期限切れエラー時に呼び出す
  Future<bool> refreshToken() async {
    if (!_isInitialized) return false;

    // ⚠ web の復元セッション（無音復元）には GoogleSignInAccount が無く、
    // 下の native 向けの経路では立て直せない。復元をやり直す。
    if (PlatformCapabilities.isWeb) {
      _driveApi = null;
      return restoreWebAuthorization();
    }

    try {
      if (_currentUser == null) {
        // 軽量認証を再試行
        await GoogleSignIn.instance.attemptLightweightAuthentication();
        // 認証イベントハンドラで _currentUser が更新される
        if (_currentUser == null) return false;
      }

      // Drive APIを再初期化（新しいトークンを取得）
      await _initializeDriveApi(_currentUser!);
      AppLogger.debug('[GoogleDriveService] トークンリフレッシュ成功');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] トークンリフレッシュエラー: $e');
      return false;
    }
  }

  /// Drive APIが利用可能か確認
  bool get isDriveApiAvailable => _driveApi != null;

  /// Drive APIを取得（認証済みの場合のみ）
  drive.DriveApi? get driveApi => _driveApi;

  // ========== フォルダ操作 ==========

  /// こかげマップのルートフォルダを取得または作成
  Future<drive.File?> getOrCreateRootMapsFolder() async {
    if (_driveApi == null) return null;

    try {
      // 既存のフォルダを検索
      const query =
          "name = '$kMapsFolderName' and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
      final result = await _driveApi!.files.list(q: query);

      if (result.files != null && result.files!.isNotEmpty) {
        return result.files!.first;
      }

      // フォルダを新規作成
      final folder = drive.File()
        ..name = kMapsFolderName
        ..mimeType = 'application/vnd.google-apps.folder';

      final created = await _driveApi!.files.create(folder);
      AppLogger.debug('[GoogleDriveService] ルートフォルダ作成: ${created.id}');
      return created;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] フォルダ取得/作成エラー: $e');
      return null;
    }
  }

  /// 指定フォルダ内のサブフォルダを取得
  Future<List<drive.File>> listFolders(String parentId) async {
    if (_driveApi == null) return [];

    try {
      final query =
          "'$parentId' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
      final result = await _driveApi!.files.list(
        q: query,
        $fields: 'files(id, name, modifiedTime)',
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
      );
      return result.files ?? [];
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] フォルダ一覧取得エラー: $e');
      return [];
    }
  }

  /// 指定フォルダ内にサブフォルダを取得または作成
  Future<drive.File?> getOrCreateSubFolder(
    String parentId,
    String folderName,
  ) async {
    if (_driveApi == null) return null;

    try {
      final query =
          "name = '$folderName' and '$parentId' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false";
      final result = await _driveApi!.files.list(
        q: query,
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
        $fields: 'files(id, name)',
      );
      final existing = result.files?.isNotEmpty == true ? result.files!.first : null;
      if (existing != null) return existing;

      final folder = drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [parentId];

      final created = await _driveApi!.files.create(
        folder,
        supportsAllDrives: true,
      );
      AppLogger.debug('[GoogleDriveService] サブフォルダ作成: $folderName');
      return created;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] サブフォルダ作成エラー: $e');
      return null;
    }
  }

  /// 新しいプロジェクトフォルダを作成
  Future<drive.File?> createProjectFolder(
    String name, {
    String? parentId,
  }) async {
    if (_driveApi == null) return null;

    try {
      // 親フォルダが指定されていない場合はルートフォルダに作成
      final parent = parentId ?? (await getOrCreateRootMapsFolder())?.id;
      if (parent == null) return null;

      final folder = drive.File()
        ..name = name
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [parent];

      final created = await _driveApi!.files.create(folder);
      AppLogger.debug('[GoogleDriveService] プロジェクトフォルダ作成: ${created.id}');
      return created;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] フォルダ作成エラー: $e');
      return null;
    }
  }

  // ========== ファイル操作 ==========

  /// ファイルをアップロード
  /// [localPath] ローカルファイルのパス（web では仮想パス）
  /// [parentId] 親フォルダID
  /// [onProgress] 進捗コールバック（0.0〜1.0）
  ///
  /// > [!NOTE] 中身は丸ごとメモリに載せる
  /// > `dart:io` の `openRead()` はストリームで流せるが、web には無い。
  /// > `fs` は「全部読む」しか持たないので、ここで揃えた。
  /// > 現場のgpkgは数十MB程度なので許容できる。
  Future<drive.File?> uploadFile(
    String localPath,
    String parentId, {
    void Function(double progress)? onProgress,
  }) async {
    if (_driveApi == null) return null;
    final bytes = await fs.readAsBytes(localPath);
    return uploadBytes(bytes, p.basename(localPath), parentId);
  }

  /// メモリ上の内容をそのままアップロードする。
  ///
  /// 一時ファイルを作らずに済ませたいとき用（`.kmeta.json` の加工など）。
  /// web には一時ディレクトリが無いので、こちらしか使えない。
  Future<drive.File?> uploadBytes(
    Uint8List bytes,
    String fileName,
    String parentId,
  ) async {
    if (_driveApi == null) return null;

    try {
      // 既存ファイルを検索（同名ファイルがあれば更新）
      final existingFile = await _findFileByName(fileName, parentId);

      final media = drive.Media(
        Stream<List<int>>.value(bytes),
        bytes.length,
      );

      drive.File result;

      if (existingFile != null) {
        // 既存ファイルを更新
        result = await _driveApi!.files.update(
          drive.File(),
          existingFile.id!,
          uploadMedia: media,
          supportsAllDrives: true,
        );
        AppLogger.debug('[GoogleDriveService] ファイル更新: $fileName');
      } else {
        // 新規アップロード
        final driveFile = drive.File()
          ..name = fileName
          ..parents = [parentId];

        result = await _driveApi!.files.create(
          driveFile,
          uploadMedia: media,
          supportsAllDrives: true,
        );
        AppLogger.debug('[GoogleDriveService] ファイルアップロード: $fileName');
      }

      return result;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] アップロードエラー: $e');
      return null;
    }
  }

  /// 既知のDriveファイルIDを指定してアップロード（_findFileByName不要）
  /// [existingFileId] が指定されていれば files.update、なければ files.create
  Future<drive.File?> uploadFileById(
    String localPath,
    String parentId, {
    String? existingFileId,
  }) async {
    if (_driveApi == null) return null;

    try {
      final fileName = p.basename(localPath);
      final bytes = await fs.readAsBytes(localPath);
      final media = drive.Media(
        Stream<List<int>>.value(bytes),
        bytes.length,
      );

      if (existingFileId != null) {
        final result = await _driveApi!.files.update(
          drive.File(),
          existingFileId,
          uploadMedia: media,
          supportsAllDrives: true,
        );
        AppLogger.debug('[GoogleDriveService] ファイル更新(byId): $fileName');
        return result;
      } else {
        final driveFile = drive.File()
          ..name = fileName
          ..parents = [parentId];
        final result = await _driveApi!.files.create(
          driveFile,
          uploadMedia: media,
          supportsAllDrives: true,
        );
        AppLogger.debug('[GoogleDriveService] ファイル新規作成(byId): $fileName');
        return result;
      }
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] アップロードエラー(byId): $e');
      return null;
    }
  }

  /// ファイルを削除
  /// [fileId] DriveファイルID
  /// ファイルをゴミ箱に移動（削除）
  /// 完全削除ではなくゴミ箱移動を使用（操作ミス対策 + 共有ドライブ対応）
  Future<bool> deleteFile(String fileId) async {
    if (_driveApi == null) return false;

    try {
      await _driveApi!.files.update(
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
      AppLogger.debug('[GoogleDriveService] ゴミ箱移動エラー: status=${e.status}, message=${e.message}');
      return false;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] ゴミ箱移動エラー: $e');
      return false;
    }
  }

  /// ファイルを移動（親フォルダを変更）
  /// バージョン履歴を維持したまま移動
  /// [fileId] DriveファイルID
  /// [newParentId] 移動先フォルダID
  /// [oldParentId] 移動元フォルダID（省略可、省略時は現在の親から推測）
  Future<bool> moveFile(
    String fileId, {
    required String newParentId,
    String? oldParentId,
  }) async {
    if (_driveApi == null) return false;

    try {
      // 移動元が指定されていない場合は現在の親を取得
      String? removeParent = oldParentId;
      if (removeParent == null) {
        final metadata = await getFileMetadata(fileId);
        if (metadata != null && metadata.parents.isNotEmpty) {
          removeParent = metadata.parents.first;
        }
      }

      await _driveApi!.files.update(
        drive.File(),
        fileId,
        addParents: newParentId,
        removeParents: removeParent,
        supportsAllDrives: true,
      );
      
      AppLogger.debug(
        '[GoogleDriveService] ファイル移動: $fileId → $newParentId',
      );
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] ファイル移動エラー: $e');
      return false;
    }
  }

  /// ファイルメタデータを取得
  /// [fileId] DriveファイルID
  /// 戻り値: {trashed, modifiedTime, name, parents} または null（エラー/完全削除時）
  Future<DriveFileMetadata?> getFileMetadata(String fileId) async {
    if (_driveApi == null) return null;

    try {
      final file = await _driveApi!.files.get(
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
    } catch (e) {
      // 404 = 完全削除済み
      AppLogger.debug('[GoogleDriveService] ファイルメタデータ取得エラー: $e');
      return null;
    }
  }

  /// ファイルをダウンロード
  /// [fileId] DriveファイルID
  /// [localPath] 保存先パス
  /// [onProgress] 進捗コールバック（0.0〜1.0）
  Future<bool> downloadFile(
    String fileId,
    String localPath, {
    void Function(double progress)? onProgress,
  }) async {
    if (_driveApi == null) return false;

    try {
      final response = await _driveApi!.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
        supportsAllDrives: true,
      );

      if (response is! drive.Media) {
        AppLogger.debug('[GoogleDriveService] ダウンロード応答が不正');
        return false;
      }

      // ⚠ 追記していく `openWrite()` は web に無いので、全部集めてから一度に書く
      final chunks = <int>[];
      await for (final chunk in response.stream) {
        chunks.addAll(chunk);
      }
      await fs.writeAsBytes(localPath, Uint8List.fromList(chunks));
      AppLogger.debug('[GoogleDriveService] ダウンロード完了: $localPath');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] ダウンロードエラー: $e');
      return false;
    }
  }

  /// フォルダ内のファイル一覧を取得
  /// 共有フォルダにもアクセスするため supportsAllDrives=true を設定
  Future<List<drive.File>> listFiles(String parentId) async {
    if (_driveApi == null) return [];

    try {
      final query = "'$parentId' in parents and trashed = false";
      final result = await _driveApi!.files.list(
        q: query,
        $fields: 'files(id, name, mimeType, modifiedTime, size, parents)',
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
      );
      return result.files ?? [];
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] ファイル一覧取得エラー: $e');
      return [];
    }
  }

  /// ファイル名でファイルを検索
  Future<drive.File?> _findFileByName(String name, String parentId) async {
    if (_driveApi == null) return null;

    try {
      final query =
          "name = '$name' and '$parentId' in parents and trashed = false";
      final result = await _driveApi!.files.list(
        q: query,
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
      );
      return result.files?.firstOrNull;
    } catch (e) {
      return null;
    }
  }

  // ========== 共有URL操作 ==========

  /// 共有URLからフォルダIDを抽出
  /// 対応形式:
  /// - https://drive.google.com/drive/folders/{folderId}
  /// - https://drive.google.com/drive/folders/{folderId}?usp=sharing
  /// - https://drive.google.com/drive/u/0/folders/{folderId}
  /// - https://drive.google.com/open?id={folderId}
  /// - https://drive.google.com/folderview?id={folderId}
  static String? extractFolderIdFromUrl(String url) {
    try {
      // 空白をトリム
      url = url.trim();
      
      AppLogger.debug('[GoogleDriveService] URL解析: $url');
      
      final uri = Uri.parse(url);
      
      // drive.google.comドメインか確認
      if (!uri.host.contains('google.com')) {
        AppLogger.debug('[GoogleDriveService] Google Driveドメインではない: ${uri.host}');
        return null;
      }
      
      final pathSegments = uri.pathSegments;
      AppLogger.debug('[GoogleDriveService] pathSegments: $pathSegments');
      
      // パターン1: /drive/folders/{folderId} または /drive/u/0/folders/{folderId}
      final foldersIndex = pathSegments.indexOf('folders');
      if (foldersIndex != -1 && foldersIndex + 1 < pathSegments.length) {
        final folderId = pathSegments[foldersIndex + 1];
        AppLogger.debug('[GoogleDriveService] フォルダID検出 (folders): $folderId');
        return folderId;
      }
      
      // パターン2: /open?id={folderId} または /folderview?id={folderId}
      final idParam = uri.queryParameters['id'];
      if (idParam != null && idParam.isNotEmpty) {
        AppLogger.debug('[GoogleDriveService] フォルダID検出 (id param): $idParam');
        return idParam;
      }
      
      AppLogger.debug('[GoogleDriveService] フォルダIDが見つからない');
      return null;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] URL解析エラー: $e');
      return null;
    }
  }

  /// フォルダ情報を取得
  /// 共有フォルダにもアクセスするため supportsAllDrives=true を設定
  Future<drive.File?> getFolderInfo(String folderId) async {
    if (_driveApi == null) return null;

    try {
      final result = await _driveApi!.files.get(
        folderId,
        $fields: 'id, name, modifiedTime, owners, capabilities',
        supportsAllDrives: true,
      );
      return result as drive.File;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] フォルダ情報取得エラー: $e');
      return null;
    }
  }

}

/// アクセストークンを `Authorization` に付けるだけのHTTPクライアント
///
/// web の無音復元では生のトークンしか手に入らないので、
/// `googleapis` に食わせるためにこれで包む。
class _BearerClient extends http.BaseClient {
  final String _token;
  final http.Client _inner = http.Client();

  _BearerClient(this._token);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_token';
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
