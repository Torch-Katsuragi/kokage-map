---
title: Google Drive連携セットアップ
tags: [technical, google-drive, setup]
---


> [!NOTE] 2026-08-27: 同期コードを web でも動く形にした
> `lib/services/google_drive/` から `dart:io` を撤去した。API境界が
> `dart:io` の `File` を持ち回っていたので、そこから変えている:
>
> - `uploadFile(File)` → `uploadFile(String localPath)`
> - `uploadBytes(Uint8List, name, parent)` を追加（一時ファイルを作らないため。
>   web には一時ディレクトリが無い）
> - `LocalSyncFile` は `File` ではなく `path` + `size` を持つ
> - 再帰列挙は `fs.listRecursive()` / `fs.listDirectoriesRecursive()`
> - 更新日時は `fs.lastModified()`（web も `File.lastModified` で取れる）
>
> ⚠ **アップロードは中身を丸ごとメモリに載せる。**
> `openRead()` のストリームは web に無いので揃えた。
> 現場のgpkgは数十MB程度なので許容している。
>
> ⚠ **web で使うには web用のOAuthクライアントIDが要る。**
> GCPコンソールでしか発行できない。`--dart-define=GOOGLE_WEB_CLIENT_ID=...`
> で渡す。未設定の間は `PlatformCapabilities.supportsDriveSync` が
> web で false のままなので、UIも出ない。→ [[#1.5 OAuthクライアントID（Web）]]

> [!IMPORTANT] web のサインインは native と作りが違う
> `google_sign_in_web` は `google_sign_in` の他の実装と同じ顔をしていない。
> 2026-08-27 に踏んだのは次の2点:
>
> 1. **`authenticate()` が無い**（`UnimplementedError` を投げる）。
>    ユーザーの取得は One Tap か、Googleが描画するボタン
>    （`lib/widgets/auth/google_sign_in_button.dart`）でしかできない。
> 2. **スコープ認可のポップアップはクリックの直下でしか開けない**
>    （`authorizationRequiresUserInteraction() == true`）。
>    認証イベントのハンドラは One Tap から非同期に呼ばれるので、
>    そこで `authorizeScopes` を呼ぶとブラウザにポップアップを潰される。
>    console に `[GSI_LOGGER]: Failed to open popup window` だけが残り、
>    アプリ側は「サインインしてください」のまま動かない。
>
> ### 実測: 無音化の決め手は `login_hint`（2026-08-28）
>
> 同一ブラウザ・同意済み・Googleにログイン済みで、
> `google.accounts.oauth2.initTokenClient` を直に叩いて計測した。
>
> | 設定 | 結果 |
> | --- | --- |
> | `prompt:''` のみ（＝`google_sign_in_web` と同じ） | ポップアップが開いたまま**10秒待っても返らない** |
> | `prompt:'' + login_hint` | **858ms でトークン。ポップアップは自動で閉じる** |
> | `prompt:'none' + login_hint` | 755ms でトークン |
>
> 決め手は `prompt` ではなく **`login_hint`**。無いとGoogleが
> 「どのアカウントか」を決められず選択画面で止まる。
> ⚠ そして `google_sign_in_web` は `login_hint` を渡すと
> `prompt` を `select_account` に固定する。**ライブラリが自分で無音化を潰している。**
>
> だから `lib/services/google_drive/web_token_client_web.dart` で GIS を直に叩く。
> 必要なのは**メールアドレスを覚えておくこと**で、これは localStorage（SharedPreferences）に置く。
> トークンは localStorage に置かない（ブラウザを閉じても残り、全タブから読める）。
> リロードをまたぐトークンは sessionStorage にだけ置く（→ 下の「リロードするとサインインが切れる件」）。
>
> ⚠ それでもポップアップ自体は開くので、**ユーザー操作の直後（Chromeで約5秒）**
> にしか呼べない。`main.dart` の `Listener` で、アプリ内の操作に便乗して
> 繋ぎ直している。

> ### リロードするとサインインが切れる件
>
> **2026-10-12 に対処: タブの中だけトークンを持ち越す。**
>
> 何が消えていたか（`google_sign_in_web` 1.1.3 / GIS のソースで確認）:
>
> | もの | リロード後 |
> | --- | --- |
> | Drive のアクセストークン | **消える。** `GisSdkClient._lastClientAuthorizationByUser` はメモリ上の `Map` だけ。ブラウザの OAuth（`response_type=token`）にリフレッシュトークンは無い |
> | Google アカウント（`GoogleSignInAccount`） | **消える。** GIS の id は One Tap / ボタンの credential が来るまで何も持たない。起動時に One Tap は投げていない（`attemptLightweightAuthentication` は Android で選択シートを出すので呼ばない） |
> | Firebase Auth のユーザー | 残る（IndexedDB）。ただし位置共有の**匿名**サインインで、Google とも Drive とも無関係 |
> | 前回のメールアドレス | 残る（SharedPreferences = localStorage の `drive_last_email`）。`login_hint` 用 |
>
> トークンを取り直すには GIS のポップアップが要り、ポップアップは**クリックの直下でしか開けない**
> （起動時に呼ぶと `Failed to open popup window` で潰れる）。だから「リロード直後に無言で Drive が使える」は
> トークンをどこかに持ち越さない限りできない。
>
> そこで:
>
> 1. **取れたトークンを失効時刻つきで `sessionStorage` に置く**（`lib/services/google_drive/web_session_token.dart`）。
>    置くのは `restoreWebAuthorization` で取れたとき（GIS の `expires_in` を使う）と、`signIn` の初回同意
>    （ライブラリ経由で寿命が返らないので仮に 55 分）。
> 2. **起動時**は `restoreSessionSilently(userGesture: false)` がそれだけを見る（ポップアップは開かない）。
>    残りが 2 分を切ったもの・壊れたものは捨てる。採用前に `about.get` を 1 回呼んで、死んでいれば捨てる。
>    通ればクリック無しでサインイン済み（設定画面にアカウントが出る、Drive も使える）。
> 3. 失効していた（最後に取ってから約 1 時間以上たった）ら、これまで通り**次のクリック**で
>    `login_hint` つきの無音の取り直し（`main.dart` の `_restoreDriveOnce`）。ポップアップが一瞬開いて閉じる。
> 4. `_dropApi`（サインアウト・アカウント切替・失効の検出）で `sessionStorage` からも消す。
>
> sessionStorage にした理由（localStorage でない理由）: タブを閉じれば消え、他のタブからは読めない。
> 置くのはアクセストークン（1 時間で死ぬ）だけで、リフレッシュトークンは元から無い。
> 同じオリジンで XSS が走れば、メモリ上のトークンも `fetch` を横取りすれば読めるので、
> sessionStorage に置くことで増える危険は「同じタブ・1 時間以内」に限られる。
> ⚠ `Content-Security-Policy` を強制にする（[[web-hosting#セキュリティヘッダ（2026-10-09）]]）のが本筋の XSS 対策。
>
> 同じクリックから復元を 2 本走らせないこと。`main.dart` の Listener（pointerdown）が先にポップアップを
> 開くとクリックの権利（user activation）を使い切り、続くボタンからの 2 本目はブラウザに潰される。
> `restoreWebAuthorization` は実行中のものがあればその結果を待つ（`_webRestoreInFlight`）。
>
> ⚠ **`prompt=''` でも「無言」とは限らない。** GISは常に別ウィンドウの
> ポップアップを開く。同意済みかつアカウントが一意なら勝手に閉じるが、
> そうでなければ選択画面で止まり、**`await` が返らない**（`requestTokenSilently` は 8 秒で打ち切る）。
> 無言にするには `prompt=''` と `login_hint` を**両方**渡す（`web_token_client_web.dart`）。
> ⚠ `GoogleSignInAccount.authorizationClient` は `login_hint` を渡すため
> ライブラリが `prompt=select_account` を付けてしまう
> （`gis_client.dart`: `prompt: userHint == null ? '' : 'select_account'`）。
>
> もう一段先（クリック無しで 1 時間を超えて持たせる）は、バックエンドを立てて認可コードフローに移り
> リフレッシュトークンをサーバー側で持つこと（サーバー要らずという前提を捨てる）。

> [!TIP] リリースの web でログを見る
> `--dart-define=K_LOG=true` を付けてビルドすると `AppLogger` が
> リリースでも出る。⚠ 付けないと `kDebugMode` が false で**1行も出ない**。
>
> ```bash
> flutter build web --release --dart-define=GOOGLE_WEB_CLIENT_ID=... --dart-define=K_LOG=true
> ```

> そのため `GoogleDriveService` では、イベントハンドラは
> **認可済みのときだけ**初期化し（`promptIfUnauthorized: false`）、
> 未認可なら「サインイン済み・認可待ち」で止める。認可は
> `signIn()`（＝ボタンのクリック直下）が受け持つ。

# Google Drive連携セットアップ

Google Drive連携機能を有効にするためのセットアップ手順。

## 前提条件

- Googleアカウント（GCP利用可能なもの）
- Android端末またはエミュレータ（OAuth認証のテスト用）

---

## 1. Google Cloud Console設定

### 1.1 プロジェクト作成

1. [Google Cloud Console](https://console.cloud.google.com/) にアクセス
2. 「プロジェクトを選択」→「新しいプロジェクト」
3. プロジェクト名: `Root Maps`（任意）
4. 「作成」をクリック

### 1.2 Drive API有効化

1. 左メニュー「APIとサービス」→「ライブラリ」
2. 「Google Drive API」を検索
3. 「有効にする」をクリック

### 1.3 OAuth同意画面設定

1. 左メニュー「APIとサービス」→「OAuth同意画面」
2. ユーザータイプ: 「外部」を選択（テスト段階）
3. 必須項目を入力：
   - アプリ名: `Root Maps`
   - ユーザーサポートメール: 自分のメールアドレス（またはGoogle Group）
   - デベロッパーの連絡先: 自分のメールアドレス
4. スコープ設定で以下を追加：
   - `https://www.googleapis.com/auth/drive` （Driveへのフルアクセス）
   - `https://www.googleapis.com/auth/userinfo.email` （メールアドレス取得）

### 1.3.1 テストユーザーの追加（重要）

**アプリが「テストモード」の間は、テストユーザーに登録されたアカウントのみログイン可能。**

1. OAuth同意画面 → 「**Audience**」または「**対象**」タブ
2. 「テストユーザー」セクションで「**+ ADD USERS**」をクリック
3. ログインに使用するGoogleアカウントのメールアドレスを追加
4. 保存

> **Note**: テストユーザーは最大100人まで追加可能。本番公開前の開発・テスト段階ではこれで十分。

### 1.3.2 本番公開について

本番公開（Google審査）は**ストア公開直前**でOK。開発中はテストユーザー追加で対応。

本番公開に必要なもの（今は不要）：
- プライバシーポリシーURL（GitHub Pagesで簡易ページを作成可）
- 利用規約URL（任意）
- `drive`スコープは機密性が高いため、追加のセキュリティ審査が必要になる場合あり

### 1.4 OAuthクライアントID作成（Android）

> [!WARNING] 今の登録（2026-10-06、プロジェクト `nemurigi-kobo`、パッケージ `com.k_root.k_maps`）は **3 つ要る**
> | 名前 | 鍵 | SHA-1 |
> |---|---|---|
> | K-Maps Android (Debug) | 開発用の debug 鍵 | （debug.keystore） |
> | K-Maps Android (Upload) | アップロード鍵（`k-maps-release.keystore`） | `59:7B:60:7F:…:D4:1F` |
> | **K-Maps Android (Play)** | **Play のアプリ署名鍵**（Play から入れた端末はこれで動く） | `36:7E:1C:6E:4A:B7:E5:FE:41:B0:2A:60:BD:D1:C7:F1:C5:8F:EE:65` |
>
> Play の分が無く、Play から入れた端末だけ `[28444] Developer console is not set up correctly` でサインインできなかった
> （父の端末で発覚。開発者の端末は debug 版なので踏まない）。Play の鍵の SHA-1 は Play Console の「アプリの署名」に出ないので、
> アプリ署名鍵の証明書（`deployment_cert.der`）を落として SHA-1 を計算する（SHA-256 が `71:09:25:12:…:AC:DA` と合うことを確かめる）。
> ⚠ 同じパッケージ名と SHA-1 の組は 1 か所にしか登録できない。旧プロジェクト `k-maps-484306`（RootMap GIS）に残っていた
> Play 用のクライアントが組を押さえていたので消してから作った（旧プロジェクトは 2026-10-07 に削除。30 日は `gcloud projects undelete k-maps-484306` で戻せる）。サインインはアプリの Web クライアントと同じプロジェクトに
> Android クライアントが無いと通らない

**重要**: デバッグビルドとリリースビルドで異なるSHA-1フィンガープリントが使われるため、**両方のクライアントIDを作成**する必要がある。両方登録しておけば、GoogleがSHA-1を見て自動で正しいクライアントIDを選択する。

#### SHA-1フィンガープリントの取得

```powershell
# デバッグ用SHA-1
keytool -list -v -keystore $env:USERPROFILE\.android\debug.keystore -alias androiddebugkey -storepass android -keypass android | Select-String "SHA1"

# リリース用SHA-1（key.propertiesのパスを参照）
keytool -list -v -keystore C:\Users\kitay\Root Maps-release.keystore -alias Root Maps
```

#### デバッグ用クライアントID作成

1. 左メニュー「APIとサービス」→「認証情報」
2. 「認証情報を作成」→「OAuthクライアントID」
3. アプリケーションの種類: 「Android」
4. 名前: `Root Maps Android (Debug)`
5. パッケージ名: `com.k_root.root_maps`
6. SHA-1フィンガープリント: デバッグ用SHA-1を入力
7. 「作成」をクリック

#### リリース用クライアントID作成

1. 「認証情報を作成」→「OAuthクライアントID」
2. アプリケーションの種類: 「Android」
3. 名前: `Root Maps Android (Release)`
4. パッケージ名: `com.k_root.root_maps`
5. SHA-1フィンガープリント: リリース用SHA-1を入力
6. 「作成」をクリック

> **Note**: AndroidクライアントIDはアプリ内で直接使用しない。Google Play Servicesが自動でマッチングする。

### 1.5 OAuthクライアントID（Web）

google_sign_inパッケージはWebクライアントIDも必要。
こかげマップ では既存の `こかげマップ Web` を流用している（新規発行は不要）:

```
348302294570-7srd6hqqpgpvu8sqilihhvhrd1p720p7.apps.googleusercontent.com
```

新しく作る場合は「認証情報を作成」→「OAuthクライアントID」→
種類「ウェブ アプリケーション」。

⚠ **配信元のオリジンを「承認済みの JavaScript 生成元」に登録すること。**
ここが空だと、ポップアップが開いた先で弾かれる。リダイレクトURIは不要
（`google_sign_in_web` はブラウザ内で完結する）。

| オリジン | 用途 |
| --- | --- |
| `http://localhost:8099` | 開発（`build/web` を `python -m http.server 8099` で配信） |
| `https://kokage-map.sleeptree.jp` | 本番（[[web-hosting]]、2026-08-28 登録） |

反映まで5分〜数時間かかることがある。

web版のビルドはこう:

```bash
flutter build web --release --dart-define=GOOGLE_WEB_CLIENT_ID=348302294570-7srd6hqqpgpvu8sqilihhvhrd1p720p7.apps.googleusercontent.com
```

---

## 2. Androidプロジェクト設定

### 2.1 strings.xmlにクライアントIDを追加

`android/app/src/main/res/values/strings.xml` を作成：

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Google Sign-In用のWebクライアントID -->
    <string name="default_web_client_id">YOUR_WEB_CLIENT_ID.apps.googleusercontent.com</string>
</resources>
```

`YOUR_WEB_CLIENT_ID` を実際のWebクライアントIDに置き換え。

---

## 3. 環境変数（オプション）

機密情報を環境変数で管理する場合：

```powershell
# 開発環境用
$env:GOOGLE_WEB_CLIENT_ID = "your-web-client-id.apps.googleusercontent.com"
```

---

## 4. 動作確認

1. アプリをデバッグビルドで実行
2. Google Drive連携画面で「Sign in with Google」をタップ
3. Googleアカウント選択画面が表示されることを確認
4. 権限同意後、Drive APIが使用可能になることを確認

---

## トラブルシューティング

### 「DEVELOPER_ERROR」（ApiException: 10）が表示される

- **最もよくある原因**: デバッグ/リリース両方のAndroidクライアントIDが登録されていない
- SHA-1フィンガープリントが正しいか確認（`keytool`で再取得して比較）
- パッケージ名が`com.k_root.root_maps`と一致しているか確認
- Google Cloud Consoleで両方のクライアントIDが作成されているか確認

### 「access_denied」が表示される

- OAuth同意画面でテストユーザーに追加されているか確認
- スコープが正しく設定されているか確認

### Windows環境での認証

google_sign_inはWindowsネイティブ非対応。代替手段：
- WebViewベースのOAuth（要追加パッケージ）
- ブラウザ経由のOAuth（url_launcher使用）

---

## 関連ドキュメント

- [[google-drive]] - Google Drive連携設計書
