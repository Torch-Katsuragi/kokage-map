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
/// Google Drive の OAuth 認証状態・サイレント復元・サインイン/サインアウト・トークン寿命管理
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform_capabilities.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import 'drive_auth_state.dart';
import 'sign_in_failure.dart';
import 'web_session_token.dart';
import 'web_token_client.dart';

/// Google Drive の OAuth セッションおよび [drive.DriveApi] インスタンスのライフサイクル管理
class DriveAuthSession {
  /// GoogleSignIn v7 はシングルトン: GoogleSignIn.instance
  bool _isInitialized = false;
  Completer<void>? _initCompleter;

  /// 認証済みユーザー（イベントベースで更新）
  GoogleSignInAccount? _currentUser;

  /// Drive APIクライアント
  drive.DriveApi? _driveApi;

  /// [_driveApi] が使っている http クライアントと、そのアクセストークン。
  ///
  /// 以前は自動同期の周期ごとに DriveApi（と http クライアント）を作り直し、古いものを閉じていなかった。
  /// 同じトークンなら使い回し、変わったときだけ作り直して古いクライアントを閉じる（[useToken]）
  http.Client? _apiClient;
  String? _apiToken;

  /// 差し替えた古いクライアントを閉じるまでの猶予（その上でまだ走っているダウンロードなどを切らない）
  static Duration clientCloseGrace = const Duration(minutes: 2);

  /// 通信できるかの確認。テストで差し替える
  static Future<bool> Function() onlineCheck = _checkOnline;

  /// 認証状態
  final DriveAuthState authState = DriveAuthState();

  /// セッション破棄時（サインアウト・アカウント切替・トークン無効化）のフック
  void Function()? onSessionDropped;

  /// 前回サインインしたメールアドレスを覚えておくキー。
  ///
  /// `login_hint` に渡すためだけに使う。⚠ **トークンを localStorage（SharedPreferences）に置かないこと。**
  /// ブラウザを閉じても残り、全タブから読める。リロードをまたぐトークンは [_webSessionTokens]
  /// （`sessionStorage`・タブ限り・失効時刻まで）だけが持つ
  static const String _kLastEmailKey = 'drive_last_email';

  /// web のリロードをまたいで、いまのアクセストークンをタブの中だけ持ち越す（native は空振り）。
  /// 置き方・消し方の理由は `web_session_token.dart`
  final WebSessionTokenStore _webSessionTokens = WebSessionTokenStore.platform();

  /// [restoreWebAuthorization] の実行中のもの。
  ///
  /// ⚠ 同じクリックから 2 本走らせないこと。`main.dart` の Listener（pointerdown）が先に
  /// ポップアップを開くとクリックの権利（user activation）を使い切り、続くボタンの
  /// `ensureDriveAuthenticated` の 2 本目はブラウザに潰される。2 本目は 1 本目の結果を待つ
  Future<bool>? _webRestoreInFlight;
  bool _loggedNoRememberedEmail = false;

  /// 起動時の無音復元（native）の実行中のもの
  Future<bool>? _silentRestoreInFlight;

  /// [signIn] / [switchAccount] の実行中だけ true。
  /// 認証イベントはユーザー操作と無関係にも届く（自動選択など）ので、
  /// スコープ同意の画面はボタン直下のときにしか出さない
  bool _interactiveSignIn = false;

  /// 必要なOAuthスコープ
  static const List<String> scopes = [
    drive.DriveApi.driveScope, // Driveへのフルアクセス
    'email', // メールアドレス取得
  ];

  /// 現在有効な Drive API インスタンス（未認証なら null）
  drive.DriveApi? get driveApi => _driveApi;

  /// Drive APIが利用可能か確認
  bool get isDriveApiAvailable => _driveApi != null;

  /// Googleアカウントが取れているか（スコープの認可は別）。
  ///
  /// web はこの2段階が分かれる。アカウントが無ければ Googleが描画する
  /// ボタンでしか進めず、あれば認可のポップアップを開ける。
  /// UIはこれを見て、出すボタンを1つに絞ること。
  bool get hasAccount => _currentUser != null;

  /// 初期化（二重実行防止）
  Future<void> initialize() async {
    if (_isInitialized) return;

    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    _initCompleter = Completer<void>();
    // 待つ人がいないまま失敗すると、未処理のエラーとして別に飛ぶ（呼んだ本人には rethrow で届く）
    _initCompleter!.future.ignore();
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
  Future<bool> restoreWebAuthorization() =>
      _webRestoreInFlight ??=
          _restoreWebAuthorization().whenComplete(() => _webRestoreInFlight = null);

  Future<bool> _restoreWebAuthorization() async {
    // リロード前のトークンがタブに残っていれば、ポップアップを開かずに済む
    if (await _restoreWebSessionToken()) return true;

    // ⚠ hint はこの2択。**ライブラリの authorizeScopes に落とさないこと。**
    // あちらは `prompt=select_account` を抱き合わせるので、同意済みでも
    // 毎回アカウント選択が出る（2026-08-28、本番で毎回クリックさせていた）。
    final hint = await _rememberedEmail() ?? _currentUser?.email;
    if (hint == null || hint.isEmpty) {
      // ⚠ `login_hint` が無いと、Googleがアカウントを決められず
      // 選択画面で止まる（＝無音にならない）。ここは諦めてUIに渡す。
      if (!_loggedNoRememberedEmail) {
        _loggedNoRememberedEmail = true;
        AppLogger.debug('[GoogleDriveService] 覚えているアドレスが無いので復元しない');
      }
      return false;
    }

    AppLogger.debug('[GoogleDriveService] 認可を無音で復元: ${AppLogger.maskEmail(hint)}');
    WebTokenGrant? grant;
    try {
      grant = await requestTokenSilently(
        clientId: PlatformCapabilities.kWebOAuthClientId,
        scopes: scopes,
        loginHint: hint,
      );
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] トークン要求で例外: $e');
      return false;
    }
    if (grant == null) {
      AppLogger.debug('[GoogleDriveService] 無音の復元は不可');
      return false;
    }

    try {
      final granted = grant.token;
      final email = await _adopt(
        granted,
        () => _BearerClient(granted),
        fallbackEmail: hint,
      );
      _webSessionTokens.save(granted, expiresIn: grant.expiresIn);
      AppLogger.debug('[GoogleDriveService] 復元できた: ${AppLogger.maskEmail(email)}');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] 復元したトークンが使えない: $e');
      return false;
    }
  }

  /// web: リロード前にこのタブで取ったトークンが残っていて、まだ使えるなら採用する。**ポップアップは開かない**
  ///
  /// 起動直後（クリックの無い文脈）でも呼べる。使えなかったトークンは消す
  Future<bool> _restoreWebSessionToken() async {
    if (!PlatformCapabilities.isWeb) return false;
    final token = _webSessionTokens.load();
    if (token == null) return false;
    try {
      final email = await _adopt(token, () => _BearerClient(token));
      AppLogger.debug('[GoogleDriveService] タブに残っていたトークンで復元: ${AppLogger.maskEmail(email)}');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] タブに残っていたトークンは使えない: $e');
      _webSessionTokens.clear();
      return false;
    }
  }

  /// [token] の API を使う API として採用し、サインイン済みにする。Drive が返したメールアドレスを返す。
  ///
  /// 誰のトークンかはトークン自体に入っていないので、Driveに聞く（使えないトークンならここで投げる）。
  /// いま使っているのと同じトークンなら、聞き直さず作り直さない（自動同期が周期ごとに呼ぶ）
  Future<String?> _adopt(
    String token,
    http.Client Function() create, {
    String fallbackEmail = '',
  }) async {
    if (_driveApi != null && _apiToken == token && authState.isAuthenticated) {
      return authState.user?.email;
    }
    final client = create();
    final drive.User? user;
    try {
      user = (await drive.DriveApi(client).about.get($fields: 'user')).user;
    } catch (_) {
      client.close();
      rethrow;
    }
    _useClient(token, client);
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
    _loggedNoRememberedEmail = false;
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
  ///
  /// web で [userGesture] が false（起動時など、クリックの直下でない）なら、タブに残った
  /// トークンだけを見てポップアップは開かない（開いてもブラウザに潰される）。native は見ない
  Future<bool> restoreSessionSilently({bool userGesture = true}) async {
    if (isDriveApiAvailable) return true;
    if (!_isInitialized) await initialize();
    if (PlatformCapabilities.isWeb) {
      return userGesture ? restoreWebAuthorization() : _restoreWebSessionToken();
    }
    return _silentRestoreInFlight ??=
        _restoreNativeSessionSilently().whenComplete(() => _silentRestoreInFlight = null);
  }

  Future<bool> _restoreNativeSessionSilently() async {
    try {
      final authorization = await GoogleSignIn.instance.authorizationClient
          .authorizationForScopes(scopes);
      if (authorization == null) {
        AppLogger.debug('[GoogleDriveService] 無音復元: 認可済みアカウント無し');
        authState.setUnauthenticated();
        return false;
      }
      final email = await _adopt(
        authorization.accessToken,
        () => authorization.authClient(scopes: scopes),
      );
      AppLogger.debug('[GoogleDriveService] 無音復元できた: ${AppLogger.maskEmail(email)}');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] 無音復元に失敗（画面は出さない）: $e');
      authState.setUnauthenticated();
      return false;
    }
  }

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
          final authorized = await _initializeDriveApi(
            event.user,
            promptIfUnauthorized: false,
          );
          if (!authorized) {
            authState.setUnauthenticated();
            AppLogger.debug('[GoogleDriveService] サインイン済み・スコープ認可待ち');
            return;
          }
          authState.setAuthenticated(DriveUser.fromGoogleAccount(event.user));
          await _rememberEmail(event.user.email);
          AppLogger.debug(
            '[GoogleDriveService] サインイン成功: ${AppLogger.maskEmail(event.user.email)}',
          );
        } catch (e) {
          AppLogger.debug('[GoogleDriveService] Drive API初期化エラー: $e');
          await _signInFailed(e, 'Drive API初期化');
        }
      case GoogleSignInAuthenticationEventSignOut():
        _currentUser = null;
        _dropApi();
        authState.setUnauthenticated();
        AppLogger.debug('[GoogleDriveService] サインアウトイベント受信');
    }
  }

  /// 通信できるか。connectivity_plus は**インターフェイスの有無**しか見ないので、
  /// native は短いタイムアウトで実際に 1 本投げて確かめる（圏外でもモバイル回線は「接続中」のまま）。
  /// web はブラウザが繋がっていなければそもそもこの画面まで来にくいので、インターフェイスだけ見る。
  /// 確かめられないとき（プラグイン無しなど）は「通信できる」とする
  static Future<bool> _checkOnline() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
        return false;
      }
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] 接続状態を取れない: $e');
    }
    if (PlatformCapabilities.isWeb) return true;
    try {
      await http
          .head(Uri.parse('https://clients3.google.com/generate_204'))
          .timeout(const Duration(seconds: 3));
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] 到達確認に失敗: $e');
      return false;
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
      // `googleRenderedSignInButton` の担当で、ここは**スコープ認可**を受け持つ。
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
        // ライブラリ経由は寿命が返らないので仮の寿命で置く（採用前に実呼び出しで確かめる）
        final token = _apiToken;
        if (token != null) _webSessionTokens.save(token);
        authState.setAuthenticated(DriveUser.fromGoogleAccount(user));
        await _rememberEmail(user.email);
        return true;
      }

      // ここはボタン直下なので選択画面が出てよい
      return await _authenticateInteractively();
    } catch (e) {
      return await _signInFailed(e, 'サインイン');
    }
  }

  /// サインイン（[what]）の失敗を状態に写して false を返す
  ///
  /// 圏外なら何のエラーでも「通信できない」、本当のキャンセルならエラーにしない、
  /// それ以外は短い文言にサポート用のコード（[DriveAuthState.errorDetail]）を添える
  Future<bool> _signInFailed(Object e, String what) async {
    final failure = classifySignInFailure(e, online: await onlineCheck());
    AppLogger.debug(
      '[GoogleDriveService] $what失敗(${failure.kind.name}): ${failure.detail}',
    );
    switch (failure.kind) {
      case SignInFailureKind.cancelled:
        authState.setUnauthenticated();
      case SignInFailureKind.offline:
        authState.setError(t.drive.signInOffline, detail: failure.detail);
      case SignInFailureKind.other:
        authState.setError(t.drive.signInFailed, detail: failure.detail);
    }
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
        // 圏外で閉じられたものは同意の案内でなく「通信できない」へ回す
        if (!isUserCancellation(e) || !await onlineCheck()) rethrow;
        AppLogger.debug(
          '[GoogleDriveService] スコープ同意キャンセル: code=${e.code.name} description=${e.description}',
        );
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
    } finally {
      // 前のアカウントのトークンを持ったクライアントを残さない（イベントが来なくても）
      _dropApi();
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
      _dropApi();

      // 少し待ってからアカウント選択画面を表示
      await Future.delayed(const Duration(milliseconds: 300));

      // ⚠ web は `authenticate()` を持たない。切断だけして、選び直しは
      // One Tap / `googleRenderedSignInButton` に任せる。
      if (PlatformCapabilities.isWeb) {
        authState.setUnauthenticated();
        return false;
      }

      // authenticate() でアカウント選択UIが表示される
      return await _authenticateInteractively();
    } catch (e) {
      return await _signInFailed(e, 'アカウント切替');
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
        .authorizationForScopes(scopes);

    if (authorization != null) {
      useToken(
        authorization.accessToken,
        () => authorization.authClient(scopes: scopes),
      );
      return true;
    }

    if (!promptIfUnauthorized) return false;

    // スコープがまだ認可されていない場合、認可を要求
    final granted = await account.authorizationClient.authorizeScopes(scopes);
    useToken(granted.accessToken, () => granted.authClient(scopes: scopes));
    return true;
  }

  /// [token] の API を使う。いまと同じトークンならそのまま（作り直さない）。
  /// 違えば [create] で作り直し、前の http クライアントは [clientCloseGrace] のあとに閉じる。作り直したら true
  bool useToken(String token, http.Client Function() create) {
    if (_driveApi != null && _apiToken == token) return false;
    _useClient(token, create());
    return true;
  }

  void _useClient(String token, http.Client client) {
    final old = _apiClient;
    _apiClient = client;
    _apiToken = token;
    _driveApi = drive.DriveApi(client);
    if (old != null && !identical(old, client)) _closeLater(old);
  }

  static void _closeLater(http.Client client) {
    if (clientCloseGrace == Duration.zero) {
      client.close();
    } else {
      Timer(clientCloseGrace, client.close);
    }
  }

  /// API を手放し、http クライアントをすぐ閉じる（サインアウト・アカウント切替・失効）。
  /// タブに残した web のトークンも消す（次のリロードで死んだ／前のアカウントのトークンを拾わない）
  void _dropApi() {
    final old = _apiClient;
    _apiClient = null;
    _apiToken = null;
    _driveApi = null;
    old?.close();
    _webSessionTokens.clear();
    onSessionDropped?.call();
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
      _dropApi();
      if (PlatformCapabilities.isWeb) return restoreWebAuthorization();
      return refreshToken(force: true, userGesture: true);
    }
  }

  /// トークンをリフレッシュしてDrive APIを再初期化
  ///
  /// [force] が true（401 応答を受けた直後など）のときは、同じトークン文字列であっても
  /// クライアントを作り直す。web で [userGesture] が false（自動同期タイマーなど）のときは
  /// ポップアップを開かず、有効な API が既にあればそのまま維持する。
  Future<bool> refreshToken({
    bool force = false,
    bool userGesture = false,
  }) async {
    if (!_isInitialized) return false;

    // ⚠ web の復元セッション（無音復元）には GoogleSignInAccount が無く、
    // 下の native 向けの経路では立て直せない。自動同期などクリックの無い経路では
    // 生きている API を壊さないよう、force でなければそのまま維持する。
    if (PlatformCapabilities.isWeb) {
      if (!force && _driveApi != null) return true;
      _dropApi();
      return userGesture
          ? restoreWebAuthorization()
          : _restoreWebSessionToken();
    }

    try {
      if (force) {
        _apiToken = null;
      }
      // 無音復元で起動したセッションは _currentUser が null のまま _driveApi だけを持つ。
      // restoreSessionSilently() は isDriveApiAvailable で即 return するため、
      // 未接続時のみ無音復元を呼び、接続済みなら authorizationClient から直接トークンを取り直す。
      if (!isDriveApiAvailable && _currentUser == null) {
        return await (_silentRestoreInFlight ??=
            _restoreNativeSessionSilently()
                .whenComplete(() => _silentRestoreInFlight = null));
      }

      final authClient =
          _currentUser?.authorizationClient ??
          GoogleSignIn.instance.authorizationClient;
      final authorization = await authClient.authorizationForScopes(scopes);
      if (authorization == null) {
        if (force) {
          _dropApi();
          authState.setUnauthenticated();
        }
        return false;
      }
      useToken(
        authorization.accessToken,
        () => authorization.authClient(scopes: scopes),
      );
      AppLogger.debug('[GoogleDriveService] トークンリフレッシュ成功');
      return true;
    } catch (e) {
      AppLogger.debug('[GoogleDriveService] トークンリフレッシュエラー: $e');
      return false;
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
