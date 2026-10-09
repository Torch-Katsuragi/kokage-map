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
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/fs/k_file_system.dart';
import '../../core/platform_capabilities.dart';
import '../../core/shared_link.dart';
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

      // ⚠ ここで `attemptLightweightAuthentication()` を呼んではいけない。
      //   Android の実装は「認可済みアカウントの自動選択」に失敗すると
      //   絞り込み無しの One Tap（アカウント選択シート）を出す。起動のたびに
      //   出ていた選択画面の正体がこれ。無音の復元は [restoreSessionSilently]。
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

    AppLogger.debug('[GoogleDriveService] 認可を無音で復元: ${AppLogger.maskEmail(hint)}');
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
      final email = await _adopt(drive.DriveApi(_BearerClient(token)), fallbackEmail: hint);
      AppLogger.debug('[GoogleDriveService] 復元できた: ${AppLogger.maskEmail(email)}');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] 復元したトークンが使えない: $e');
      return false;
    }
  }

  /// [api] を使う API として採用し、サインイン済みにする。Drive が返したメールアドレスを返す。
  ///
  /// 誰のトークンかはトークン自体に入っていないので、Driveに聞く（使えないトークンならここで投げる）
  Future<String?> _adopt(drive.DriveApi api, {String fallbackEmail = ''}) async {
    final user = (await api.about.get($fields: 'user')).user;
    _driveApi = api;
    final email = user?.emailAddress ?? fallbackEmail;
    authState.setAuthenticated(
      DriveUser(
        id: user?.permissionId ?? '',
        email: email,
        displayName: user?.displayName,
        photoUrl: user?.photoLink,
      ),
    );
    await _rememberEmail(email);
    return user?.emailAddress;
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

  /// 起動時の無音復元。**画面は絶対に出さない**
  ///
  /// 以前に Drive スコープを認可したアカウントがあれば、そのトークンだけを
  /// 取り直して API を組み立てる（アカウントの選択も同意も要求しない）。
  /// 無ければ未サインインのまま。最初の Drive 操作で [signIn] が
  /// ボタン直下から選択画面を出す。FolderSync 等と同じ振る舞い。
  Future<bool> restoreSessionSilently() async {
    if (!_isInitialized) await initialize();
    if (PlatformCapabilities.isWeb) return restoreWebAuthorization();
    try {
      final authorization = await GoogleSignIn.instance.authorizationClient
          .authorizationForScopes(_scopes);
      if (authorization == null) {
        AppLogger.debug('[GoogleDriveService] 無音復元: 認可済みアカウント無し');
        authState.setUnauthenticated();
        return false;
      }
      final email = await _adopt(drive.DriveApi(authorization.authClient(scopes: _scopes)));
      AppLogger.debug('[GoogleDriveService] 無音復元できた: ${AppLogger.maskEmail(email)}');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] 無音復元に失敗（画面は出さない）: $e');
      authState.setUnauthenticated();
      return false;
    }
  }

  /// [signIn] / [switchAccount] の実行中だけ true。
  /// 認証イベントはユーザー操作と無関係にも届く（自動選択など）ので、
  /// スコープ同意の画面はボタン直下のときにしか出さない
  bool _interactiveSignIn = false;

  /// 認証イベントハンドラ
  Future<void> _handleAuthenticationEvent(
    GoogleSignInAuthenticationEvent event,
  ) async {
    switch (event) {
      case GoogleSignInAuthenticationEventSignIn():
        _currentUser = event.user;
        // ボタンからのサインインは [signIn] / [switchAccount] がスコープ同意まで自分で待つ
        if (_interactiveSignIn) return;
        try {
          // ⚠ web の認可ポップアップは**クリックの直下**でしか開けない。
          // このハンドラは One Tap から非同期に呼ばれるので、ここで
          // `authorizeScopes` を呼ぶとブラウザにポップアップを潰される。
          // 認可がまだなら「サインイン済み・認可待ち」で止め、[signIn] に託す。
          final authorized = await _initializeDriveApi(event.user, promptIfUnauthorized: false);
          if (!authorized) {
            authState.setUnauthenticated();
            AppLogger.debug('[GoogleDriveService] サインイン済み・スコープ認可待ち');
            return;
          }
          authState.setAuthenticated(DriveUser.fromGoogleAccount(event.user));
          await _rememberEmail(event.user.email);
          AppLogger.debug('[GoogleDriveService] サインイン成功: ${AppLogger.maskEmail(event.user.email)}');
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

  /// `GoogleSignInException` が「本当のユーザーキャンセル」かどうか
  ///
  /// ⚠ google_sign_in v7（Credential Manager）は**設定系のエラーを
  /// `code=canceled` で返すことがある**（無効な serverClientId、SHA-1 未登録、
  /// OAuth クライアント削除など）。コードだけ見て黙って握り潰すと、
  /// 2026-07 の「Drive 同期サインイン不能」のように原因が何も残らない。
  /// description に設定エラーの兆候があるものはエラーとして扱う。
  static bool isUserCancellation(GoogleSignInException e) {
    if (e.code != GoogleSignInExceptionCode.canceled) return false;

    final desc = e.description?.toLowerCase() ?? '';
    if (desc.isEmpty) return true;

    // 設定エラー・認証情報なしを示す語（黙らせない）
    const configErrorMarkers = [
      'developer console', // 例: [28444] Developer console is not set up correctly
      'deleted_client', // OAuth クライアント削除
      'invalid_client',
      'unregistered',
      'client id',
      'clientid', // serverClientId など
      'sha-1',
      'sha1',
      'certificate',
      'api exception',
      'apiexception',
      'no credential', // 認証情報なし系
      'credential is unavailable',
      'reauth',
    ];
    if (configErrorMarkers.any(desc.contains)) return false;

    // GMS/GIS のステータスコード付きメッセージ
    // （10: DEVELOPER_ERROR、16: 内部エラー/ブロック、28444: コンソール未設定）
    if (RegExp(r'\[?(10|16|28444)[\]:]').hasMatch(desc)) return false;

    return true;
  }

  /// `GoogleSignInException` を表示用に整形する（code と description を必ず残す）
  static String formatSignInError(GoogleSignInException e) {
    final desc = e.description;
    if (desc == null || desc.isEmpty) return e.code.name;
    return '${e.code.name}: $desc';
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

      // ここはボタン直下なので選択画面が出てよい
      return await _authenticateInteractively();
    } catch (e) {
      return _signInFailed(e, 'サインイン');
    }
  }

  /// サインイン（[what]）の失敗を状態に写して false を返す。本当のキャンセルならエラーにしない
  bool _signInFailed(Object e, String what) {
    if (e is GoogleSignInException) {
      if (isUserCancellation(e)) {
        AppLogger.debug('[GoogleDriveService] $whatキャンセル: code=${e.code.name} description=${e.description}');
        authState.setUnauthenticated();
        return false;
      }
      AppLogger.debug('[GoogleDriveService] $whatエラー: code=${e.code.name} description=${e.description}');
      authState.setError(t.services.signInFailed(error: formatSignInError(e)));
      return false;
    }
    AppLogger.debug('[GoogleDriveService] $whatエラー: $e');
    authState.setError(t.services.signInFailed(error: e.toString()));
    return false;
  }

  /// アカウントを選ばせ、Drive のスコープ同意まで済ませる（native）
  ///
  /// ⚠ 同意は認証イベントのハンドラに任せず、ここで待つこと。以前は `authenticate()` が返った直後に
  /// 状態を見ていて、初めてのアカウント（同意画面がまだ出ている途中）を「サインインに失敗しました」に
  /// していた（2026-10-05、同意済みの開発者のアカウントでは起きない）。
  /// 同意画面で戻ったときは、未確認のアプリの画面の進め方を [DriveAuthState.errorMessage] に置いて false
  Future<bool> _authenticateInteractively() async {
    _interactiveSignIn = true;
    try {
      final user = await GoogleSignIn.instance.authenticate();
      _currentUser = user;
      try {
        await _initializeDriveApi(user);
      } on GoogleSignInException catch (e) {
        if (!isUserCancellation(e)) rethrow;
        AppLogger.debug('[GoogleDriveService] スコープ同意キャンセル: code=${e.code.name} description=${e.description}');
        authState.setError(t.drive.consentCanceled);
        return false;
      }
      authState.setAuthenticated(DriveUser.fromGoogleAccount(user));
      await _rememberEmail(user.email);
      AppLogger.debug('[GoogleDriveService] サインイン成功: ${AppLogger.maskEmail(user.email)}');
      return true;
    } finally {
      _interactiveSignIn = false;
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
      return await _authenticateInteractively();
    } catch (e) {
      return _signInFailed(e, 'アカウント切替');
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
      // アカウントを掴んでいなければ無音復元だけ試す（画面は出さない。
      // 自動同期などユーザー操作の無い経路から呼ばれるため）
      if (_currentUser == null) return await restoreSessionSilently();

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

  // ========== Drive API の共通部分 ==========

  static const String _folderMime = 'application/vnd.google-apps.folder';

  /// 上げたときに返してもらう項目。
  /// 同期の帳簿に Drive 側の時刻を控える（端末の時計と比べない。KMetaSyncFile.remoteModifiedTime）
  static const String _uploadedFields = 'id, name, modifiedTime, size, parents';

  /// API を掴んでいれば [body] を呼ぶ。掴んでいなければ、または失敗したら [fallback]（失敗は [what] を添えてログに残す）
  Future<T> _call<T>(String what, T fallback, Future<T> Function(drive.DriveApi api) body) async {
    final api = _driveApi;
    if (api == null) return fallback;
    try {
      return await body(api);
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] $what: $e');
      return fallback;
    }
  }

  /// Drive の検索式に入れる文字列リテラル（`'` と `\` を逃がす）。
  ///
  /// ⚠ 以前は名前をそのまま `'...'` で囲んでいた。名前に `'` があると検索式が壊れて例外になり、
  /// 同名のファイルの検索が「見つからない」に化けて Drive にもう 1 つ作ったり、
  /// サブフォルダを解決できずにその中のファイルを上げられなかったりしていた
  @visibleForTesting
  static String queryLiteral(String value) => "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  /// [q] に当たるもの（共有ドライブも含めて探す）。最初の 1 ページだけ（名前で 1 件を探すとき用）
  static Future<List<drive.File>> _list(drive.DriveApi api, String q, {String? fields}) async {
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
  @visibleForTesting
  static Future<List<drive.File>> listAllPages(drive.DriveApi api, String q, {required String fields}) async {
    final out = <drive.File>[];
    String? pageToken;
    do {
      final page = await api.files.list(
        q: q,
        $fields: 'nextPageToken, $fields',
        pageSize: 1000,
        pageToken: pageToken,
        supportsAllDrives: true,
        includeItemsFromAllDrives: true,
      );
      out.addAll(page.files ?? const []);
      pageToken = page.nextPageToken;
    } while (pageToken != null && pageToken.isNotEmpty);
    return out;
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

  // ========== フォルダ操作 ==========

  /// 指定フォルダ内にサブフォルダを取得または作成
  Future<drive.File?> getOrCreateSubFolder(String parentId, String folderName) =>
      _call('サブフォルダ作成エラー', null, (api) async {
        final existing = (await _list(
          api,
          "name = ${queryLiteral(folderName)} and '$parentId' in parents and mimeType = '$_folderMime' and trashed = false",
          fields: 'files(id, name)',
        ))
            .firstOrNull;
        if (existing != null) return existing;

        final created = await api.files.create(
          drive.File(name: folderName, mimeType: _folderMime, parents: [parentId]),
          supportsAllDrives: true,
        );
        AppLogger.debug('[GoogleDriveService] サブフォルダ作成: $folderName');
        return created;
      });

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
    if (_driveApi == null) return null;
    final bytes = await fs.readAsBytes(localPath);
    return uploadBytes(bytes, p.basename(localPath), parentId);
  }

  /// メモリ上の内容をそのままアップロードする（同名のファイルがあればその版を更新）。
  ///
  /// 一時ファイルを作らずに済ませたいとき用（フォルダ設定（`.qgs`） の加工など）。
  /// web には一時ディレクトリが無いので、こちらしか使えない。
  Future<drive.File?> uploadBytes(Uint8List bytes, String fileName, String parentId) =>
      _call('アップロードエラー', null, (api) async {
        final existing = await _findFileByName(fileName, parentId);
        final result = await _put(api, bytes, fileName: fileName, parentId: parentId, existingFileId: existing?.id);
        AppLogger.debug('[GoogleDriveService] ${existing != null ? 'ファイル更新' : 'ファイルアップロード'}: $fileName');
        return result;
      });

  /// 既知のDriveファイルIDを指定してアップロード（同名の検索をしない）
  /// [existingFileId] が指定されていれば files.update、なければ files.create
  Future<drive.File?> uploadFileById(String localPath, String parentId, {String? existingFileId}) =>
      _call('アップロードエラー(byId)', null, (api) async {
        final fileName = p.basename(localPath);
        final bytes = await fs.readAsBytes(localPath);
        final result =
            await _put(api, bytes, fileName: fileName, parentId: parentId, existingFileId: existingFileId);
        AppLogger.debug(
          '[GoogleDriveService] ${existingFileId != null ? 'ファイル更新(byId)' : 'ファイル新規作成(byId)'}: $fileName',
        );
        return result;
      });

  /// ファイルをゴミ箱に移動（削除）
  /// 完全削除ではなくゴミ箱移動を使用（操作ミス対策 + 共有ドライブ対応）
  Future<bool> deleteFile(String fileId) => _call('ゴミ箱移動エラー', false, (api) async {
        try {
          await api.files.update(drive.File(trashed: true), fileId, supportsAllDrives: true);
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
        final removeParent = oldParentId ?? (await getFileMetadata(fileId))?.parents.firstOrNull;
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

  /// ファイルを [localPath] にダウンロード
  Future<bool> downloadFile(String fileId, String localPath) => _call('ダウンロードエラー', false, (api) async {
        final response = await api.files.get(
          fileId,
          downloadOptions: drive.DownloadOptions.fullMedia,
          supportsAllDrives: true,
        );
        if (response is! drive.Media) {
          AppLogger.debug('[GoogleDriveService] ダウンロード応答が不正');
          return false;
        }
        // ⚠ 追記していく `openWrite()` は web に無いので、全部集めてから一度に書く
        final chunks = BytesBuilder(copy: false);
        await response.stream.forEach(chunks.add);
        await fs.writeAsBytes(localPath, chunks.takeBytes());
        AppLogger.debug('[GoogleDriveService] ダウンロード完了: $localPath');
        return true;
      });

  /// フォルダ直下のファイルとフォルダの一覧（共有フォルダにも届くよう共有ドライブも含める）
  ///
  /// ⚠ 取れなければ投げる（空の一覧を返さない）。以前は失敗を空として返しており、
  /// 同期が取れなかったフォルダの中身を「Drive から消えた」と見て手元を消すおそれがあった
  Future<List<drive.File>> listFiles(String parentId) async {
    final api = _driveApi;
    if (api == null) throw StateError('Drive にサインインしていない');
    return listAllPages(
      api,
      "'$parentId' in parents and trashed = false",
      fields: 'files(id, name, mimeType, modifiedTime, size, parents)',
    );
  }

  /// ファイル名でファイルを検索
  Future<drive.File?> _findFileByName(String name, String parentId) => _call(
        '同名ファイルの検索エラー',
        null,
        (api) async => (await _list(api, "name = ${queryLiteral(name)} and '$parentId' in parents and trashed = false")).firstOrNull,
      );

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

      // こかげマップの共有リンク（`https://kokage-map.sleeptree.jp/open?drive=<ID>`。2026-10-03 からの QR）
      final shared = driveIdFromSharedLink(url);
      if (shared != null) return shared;

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
