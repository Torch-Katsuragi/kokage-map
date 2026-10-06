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
> 必要なのは**メールアドレスを覚えておくこと**だけで、トークンは保存しない
> （localStorageに置くとXSS一発でDrive全体が漏れる）。
>
> ⚠ それでもポップアップ自体は開くので、**ユーザー操作の直後（Chromeで約5秒）**
> にしか呼べない。`main.dart` の `Listener` で、アプリ内の操作に便乗して
> 繋ぎ直している。

> ### リロードするとサインインが切れる件
>
> ⚠ **ブラウザのOAuthにリフレッシュトークンは無い。**
> `google_sign_in_web` のトークンキャッシュはメモリ上の `Map` だけで、
> 保存も更新もしない。ページを離れれば消える。
> （ポップアップのURLに `response_type=token` が入っているのがその印）
>
> Google側の同意は残っているので `prompt=''` で聞き直せる。それになるのは
> **ユーザーを渡さない** `GoogleSignIn.instance.authorizationClient` だけ。
> `GoogleSignInAccount.authorizationClient` は `login_hint` を渡すため
> ライブラリが `prompt=select_account` を付けてしまう
> （`gis_client.dart`: `prompt: userHint == null ? '' : 'select_account'`）。
>
> ⚠ **`prompt=''` でも「無言」とは限らない。** GISは常に別ウィンドウの
> ポップアップを開く。同意済みかつアカウントが一意なら勝手に閉じるが、
> そうでなければ選択画面で止まり、**`await` が返らない**。
> 2026-08-27 に、これで同期が画面に何も出さないまま固まった。
> 呼ぶときは必ず画面に「別ウィンドウを見てください」を出すこと。
>
> ⚠ 復元は**クリックの直下でしか呼べない**。起動時に呼ぶとポップアップが
> 潰され、console に `Failed to open popup window` だけが残る。
>
> 本当に無言にしたいなら `prompt=''` と `login_hint` を**両方**渡す必要があり、
> それはライブラリを通さず `google.accounts.oauth2.initTokenClient` を
> 直に叩くことになる。やるなら web 専用の interop を足す。
> もう一段先は、バックエンドを立てて認可コードフローに移り
> リフレッシュトークンを持つこと（サーバー要らずという前提を捨てる）。

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
> Play 用のクライアントが組を押さえていたので消してから作った。サインインはアプリの Web クライアントと同じプロジェクトに
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
