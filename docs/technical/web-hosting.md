---
title: web版のホスティング
tags: [technical, hosting, web]
---

# web版のホスティング

**本番URL: `https://kokage-map.sleeptree.jp`**（Firebase Hosting、サイトID `kokage-map`）。
「隠しページ」運用: **GitHubのREADMEに載せるURLと、直接共有した相手だけが入口**。
`sleeptree.jp` 本体が公開されても、当分そこからはリンクしない（2026-08-28決定）。
検索除けは `firebase.json` の `X-Robots-Tag: noindex`。

## デプロイ

```bash
bash tool/web/fetch_gdal_wasm.sh   # GDAL の WASM（web/gdal3/<組>/、リポジトリに入れていない）。揃っていれば何もしない
flutter build web --release --dart-define=GOOGLE_WEB_CLIENT_ID=348302294570-7srd6hqqpgpvu8sqilihhvhrd1p720p7.apps.googleusercontent.com
firebase deploy --only hosting:kokage-map --project nemurigi-kobo
```

`https://kokage-map.web.app` にも同じものが出る（Firebaseの既定ドメイン）。

## 構成の在り処

| もの | 場所 |
| --- | --- |
| Hosting設定 | このリポの `firebase.json` / `.firebaserc` |
| DNS（CNAME → kokage-map.web.app） | Call-Agent リポの `infra/gcp/main.tf`（Cloud DNS `sleeptree-jp`、terraform管理） |
| カスタムドメイン登録 | firebasehosting API の customDomains（2026-08-28 作成） |
| OAuth生成元 | GCPコンソール「K-Maps Web」クライアント。`https://kokage-map.sleeptree.jp` と `http://localhost:8099`（開発） |

⚠ Call-Agent の terraform を apply するときは **-target でDNSレコードに絞る**こと。
全体 plan には call_agent VM の must be replaced が出ている（2026-08-28時点、別課題）。

## セキュリティヘッダ（2026-10-09）

`firebase.json` の `headers` で全パスに付けている。JSON にはコメントを書けないので、理由はここに置く。

| ヘッダ | 値の要点 |
| --- | --- |
| `Content-Security-Policy-Report-Only` | 下表。**いまは Report-Only**（違反はコンソールに出るだけで止めない）。`/beta/` `/open/` `/privacy/` `/about/` も同じ 1 本で通る（`/open/` はインラインスクリプトを外して meta refresh だけにした） |
| `X-Frame-Options` | `DENY`。Report-Only の間は CSP の `frame-ancestors` が効かないので、埋め込み除けはこちらで持つ |
| `Cross-Origin-Opener-Policy` | `same-origin-allow-popups`。`same-origin` にすると Google ログイン（GIS）のポップアップが親へ結果を返せない |
| `Permissions-Policy` | 使うものだけ `self`: geolocation（現在地）、camera（QR読み取り）、accelerometer / gyroscope / magnetometer（コンパス・水準器）。他は空 |
| `X-Content-Type-Options` / `Referrer-Policy` | `nosniff` / `strict-origin-when-cross-origin` |

CSP の出所（足すときは、ここにも書く）:

| ディレクティブ | オリジン | 何のため |
| --- | --- | --- |
| script-src | `www.gstatic.com/flutter-canvaskit/` | Flutter の CanvasKit（既定で CDN から取る）。`'wasm-unsafe-eval'` もこのため |
| | `'self'`（足したものは無い） | GDAL（WASM、[[gdal#web（WASM）]]）は自前ホストの `/gdal3/`。worker（`worker-src 'self'`）が `importScripts` で読み、WASM は `'wasm-unsafe-eval'`、`.wasm` `.data` の取得は `connect-src 'self'` で通る。eval・`new Function` は使っていない。2026-10-09 に CSP を**強制**にした手元の配信で違反 0 を確認（gdal3.js 2.8.1 のとき。3.13.3-1 も `-sDYNAMIC_EXECUTION=0` で eval を出さない） |
| | `www.gstatic.com/firebasejs/` | firebase_core が JS SDK を差し込む |
| | `'sha256-...'` 8 個 | firebase_core_web が SDK ごとに差し込む**インラインスクリプト**（core / auth / database / app_check × Trusted Types の有無で 2 通り）。下の注意を参照 |
| | `accounts.google.com/gsi/client` | Google ログイン（google_sign_in_web） |
| | `*.firebasedatabase.app` | RTDB の long-polling（JSONP）に落ちたとき |
| | `cdn.jsdelivr.net/npm/zxing-wasm@3.1.3/` | mobile_scanner の web 版（BarcodeDetector の無いブラウザ）。⚠ mobile_scanner を上げたら版を合わせる |
| | `www.google.com/recaptcha/` `www.gstatic.com/recaptcha/` | App Check（reCAPTCHA Enterprise）。frame-src・connect-src にも対応分あり |
| connect-src | `cyberjapandata.gsi.go.jp` `s3.amazonaws.com` `tile.openstreetmap.org` | 背景地図・DEM のタイル（`basemap_provider.dart` `dem_tiles.dart`） |
| | `fonts.gstatic.com` | Flutter が日本語などの代替フォントを取る |
| | `www.googleapis.com` `*.googleusercontent.com` | Drive API・プロフィール画像（CanvasKit の画像は fetch で取るので img-src でなく connect-src） |
| | `identitytoolkit` `securetoken` `*.firebasedatabase.app`（https/wss） | 位置共有の匿名サインインと RTDB |
| | `epsg.io` | 未知の EPSG の proj4 定義（`gpkg_crs_resolver.dart`） |
| style-src / font-src | `accounts.google.com/gsi/style`、`fonts.googleapis.com` / `fonts.gstatic.com` | GIS のボタン、`/beta/` の Noto Sans JP |

> [!WARNING] Firebase のハッシュは firebase_core_web の版に縛られる
> 差し込むスクリプトの本文に JS SDK の URL（`firebasejs/12.19.0/...`）が入るので、
> `flutter pub upgrade` で firebase_core_web が上がるとハッシュが変わる。強制（`Content-Security-Policy`）に
> 切り替えた後にこれを忘れると、**web の位置共有が黙って動かなくなる**。上げたら必ず違反が出ないか見ること。
> 値は `firebase_core_web/lib/src/firebase_core_web.dart` の `injectSrcScript` の 2 つのテンプレートに、
> `$windowVar`（`firebase_core` など）と `$stringUrl` を埋めた文字列の SHA-256（base64）。
> `'''` 直後の改行は Dart が落とすので含めない。

強制に切り替えるとき（`-Report-Only` を外す）の前に確かめていないもの（2026-10-09 時点）:
Google ログインのポップアップから戻った後の Drive 一覧・同期、QR 読み取りでの実カメラ、App Check（reCAPTCHA Enterprise）。
地図・DEM・3D・背景地図の全種・チュートリアル・等高線・位置共有（匿名サインインと RTDB）・EPSG・GIS ボタンの表示と
ポップアップが開くところ・zxing-wasm の読み込み・静的ページ・GDAL（worker と WASM。確認は gdal3.js のとき）は、違反 0 を確認済み。

> [!WARNING] Windows の `firebase serve` / hosting エミュレータでは headers が効かない
> firebase-tools 14.1.0 の superstatic がヘッダの `source` を `\**` に変えてしまい、どのパスにも当たらない（2026-10-09）。
> 手元で確かめるときは、`firebase.json` の headers を読んで付ける小さな静的サーバを使うか、WSL / CI の Linux で回す。
> CSP に `report-uri` を一時的に足して違反を手元のサーバに集めると、コンソールを読むより取りこぼしが無い。

## キャッシュ

| パス | Cache-Control | |
|---|---|---|
| `**/*.@(js\|wasm)` | 1 時間 | Flutter の成果物（名前に版が入らない） |
| `/gdal3/*/**` | 1 年・`immutable` | GDAL の WASM（24 MB）。組ごとのフォルダ（`/gdal3/3.13.3-1/`）なので、焼き直せばパスが変わる。`/gdal3/worker.js`（自前）はここに当たらず 1 時間 |

Flutter の `flutter_service_worker.js` は 3.47 では自分を外すだけの空の SW で、何も事前キャッシュしない（gdal3 を全員に配ってしまうことは無い）。

COOP/COEP（`SharedArrayBuffer`）は要らない。GDAL の WASM は単一スレッドのビルド。COOP は `same-origin-allow-popups` のまま。

⚠ Service Worker が古いビルドを配り続けることがある。デプロイ後に挙動が変わらないときは
devtools → Application → Service Workers で unregister して再読込（2026-08-28に踏んだ）。
