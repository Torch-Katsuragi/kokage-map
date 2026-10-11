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
| `Content-Security-Policy` | 下表。**2026-10-12 に強制にした**（それまでは Report-Only）。`/beta/` `/open/` `/privacy/` `/about/` も同じ 1 本で通る（`/open/` はインラインスクリプトを外して meta refresh だけにした） |
| `X-Frame-Options` | `DENY`。CSP の `frame-ancestors 'none'` と同じ意味。古いブラウザ向けに残している |
| `Cross-Origin-Opener-Policy` | `same-origin-allow-popups`。`same-origin` にすると Google ログイン（GIS）のポップアップが親へ結果を返せない |
| `Permissions-Policy` | 使うものだけ `self`: geolocation（現在地）、camera（QR読み取り）、accelerometer / gyroscope / magnetometer（コンパス・水準器）。他は空 |
| `X-Content-Type-Options` / `Referrer-Policy` | `nosniff` / `strict-origin-when-cross-origin` |

### CSP の考え方（script-src は絞り、通信と画像は https を丸ごと通す）

利用者が背景地図に任意の XYZ / WMS の URL を足せる（`basemap_service.dart`、設定の「URL から追加」）。
接続先のホストを列挙する CSP だとこれが全部止まるので、**画像と通信（img-src・connect-src）は `https:` なら何処でも通す**。
代わりに **script-src は自前・ハッシュ・名指しの数か所だけ**にして、`'unsafe-inline'` も `'unsafe-eval'` も入れない。

- sessionStorage の Drive トークン（下の注意）を盗むには、まずこのページの上で攻撃者のスクリプトが動く必要がある。
  それを止めるのが script-src。インラインの `<script>`・`onclick=` 属性・`javascript:` URL・`eval` は全部止まる
- connect-src が `https:` だと、**スクリプトが既に動いてしまった後**なら盗んだものを好きな所へ送れる。
  ただ、そこまで来ていればトークンはどの経路でも持ち出せる（画像の URL、`location` の書き換えなど）ので、
  connect-src を絞っても守りはほとんど増えない。背景地図が使えなくなる損の方が大きいと判断した
- `http:` は通さない（https のページからは混在コンテンツでどのみち止まる）。`wss:` は RTDB の `*.firebasedatabase.app` だけ
- style-src の `'unsafe-inline'` は残す。Flutter の engine と GIS のボタンが `<style>` と style 属性を差し込む。
  CSS ではスクリプトは動かない
- `'wasm-unsafe-eval'` は WASM のコンパイル（CanvasKit・GDAL・sqflite・zxing）を許すだけで、JS の `eval` は通さない
- script-src で一番緩いのは `https://*.firebasedatabase.app`（RTDB の long-polling の JSONP。誰でも自分の DB を作れるホスト）。
  WebSocket が通らない網でも位置共有を動かすために残している。CanvasKit（`www.gstatic.com/flutter-canvaskit/`）は
  `flutter build web` の既定どおり CDN から取っている（`build/web/canvaskit/` にも入っているが使われない）
- Trusted Types（`require-trusted-types-for 'script'`）はまだ掛けていない。Flutter の engine と各プラグインが通るか確かめていない

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
| connect-src | `https:`（全部） | 利用者の背景地図（任意の XYZ / WMS）があるので絞らない（上の「考え方」）。実際に繋ぐのは、背景地図・DEM のタイル（`cyberjapandata.gsi.go.jp` `s3.amazonaws.com` `tile.openstreetmap.org`、`basemap_provider.dart` `dem_tiles.dart`）、Flutter の代替フォント（`fonts.gstatic.com`）、Drive API・プロフィール画像（`www.googleapis.com` `*.googleusercontent.com`。CanvasKit の画像は fetch で取るので img-src でなく connect-src）、位置共有の匿名サインインと RTDB（`identitytoolkit` `securetoken` `*.firebasedatabase.app`）、App Check（`firebaseappcheck.googleapis.com` `www.google.com/recaptcha/`）、未知の EPSG の proj4 定義（`epsg.io`、`gpkg_crs_resolver.dart`）、zxing-wasm（`cdn.jsdelivr.net` `fastly.jsdelivr.net`） |
| | `wss://*.firebasedatabase.app` | RTDB の WebSocket（名前空間のホストから `s-…` のシャードへ回されることがあるのでワイルドカード） |
| img-src | `https:` `data:` `blob:` | connect-src と同じ理由。`<img>` で描くのは GIS のボタンのアイコンと静的ページくらい |
| style-src / font-src | `accounts.google.com/gsi/style`、`fonts.googleapis.com` / `fonts.gstatic.com` | GIS のボタン、`/beta/` の Noto Sans JP |

> [!WARNING] Firebase のハッシュは firebase_core_web の版に縛られる
> 差し込むスクリプトの本文に JS SDK の URL（`firebasejs/12.19.0/...`）が入るので、
> `flutter pub upgrade` で firebase_core_web が上がるとハッシュが変わる。CSP は強制なので、これを忘れると
> **web の位置共有が黙って動かなくなる**。上げたら `python tool/web/firebase_csp_hashes.py` で出し直し、
> `firebase.json` の 8 個と見比べる（入っている firebase_core_web のテンプレートから計算する。
> テンプレート自体が変わっていたら止まる）。
> 中身は `firebase_core_web/lib/src/firebase_core_web.dart` の `injectSrcScript` の 2 つのテンプレートに、
> `$windowVar`（`firebase_core` など）と `$stringUrl` を埋めた文字列の SHA-256（base64）。
> `'''` 直後の改行は Dart が落とすので含めない。

> [!NOTE] Drive のアクセストークンを sessionStorage に置いている（2026-10-12）
> リロードでサインインが切れないよう、失効時刻つきでタブの中だけ持ち越す（約 1 時間で死ぬ・リフレッシュトークンは無い）。
> 同じオリジンの XSS から読めるので、CSP を強制にする意味がここでも増える。
> 設計は [[google-drive-setup#リロードするとサインインが切れる件]]。

確かめたこと:

- 2026-10-09（Report-Only の値を手元で強制にして）: 地図・DEM・3D・背景地図の全種・チュートリアル・等高線・位置共有（匿名サインインと RTDB）・EPSG・
  GIS ボタンの表示とポップアップが開くところ・zxing-wasm の読み込み・静的ページ・GDAL（worker と WASM。gdal3.js のとき）で違反 0
- 2026-10-12（強制に切り替えたとき）: `tool/web/serve_csp.py --report` で配り、Chrome で起動・Firebase の SDK 4 つの読み込み（ハッシュ）・
  既存プロジェクトを開いて地図・利用者の背景地図（`server.arcgisonline.com` の XYZ を URL から追加 →「確かめる」→ 地図に出る）・
  GDAL 3.13.3-1 の worker 起動（init と version）・`/beta/` `/privacy/` `/about/` で違反 0。
  インラインの `<script>` を差し込むと止まって報告が届くことも確かめた（コレクタが生きている確認）

本番でしか確かめられないもの（[[TODO]]「次の実機確認」6 に置いた）: GIS のサインインから戻った後の Drive 一覧・同期、
WMS の背景地図、OPFS / 選んだフォルダからの GDAL 形式、ルームの位置共有と App Check（reCAPTCHA Enterprise）、QR の実カメラ。

> [!WARNING] Windows の `firebase serve` / hosting エミュレータでは headers が効かない
> firebase-tools 14.1.0 の superstatic がヘッダの `source` を `\**` に変えてしまい、どのパスにも当たらない（2026-10-09）。
> 手元では `python tool/web/serve_csp.py`（`firebase.json` の `source: "**"` のヘッダを付けて `build/web` を配る。既定 `http://localhost:8099/`、OAuth の開発用生成元と同じ）。
> `--report` で CSP に `report-uri` を足し、違反を標準出力と `.temp/csp_reports.jsonl` に集める（worker の中の違反も拾える）。
> 内蔵ブラウザ（Claude のブラウザペイン）は sqflite が動かずプロジェクトが開けないので、確認は Chrome で。

## キャッシュ

| パス | Cache-Control | |
|---|---|---|
| `**/*.@(js\|wasm)` | 1 時間 | Flutter の成果物（名前に版が入らない） |
| `/gdal3/*/**` | 1 年・`immutable` | GDAL の WASM（24 MB）。組ごとのフォルダ（`/gdal3/3.13.3-1/`）なので、焼き直せばパスが変わる。`/gdal3/worker.js`（自前）はここに当たらず 1 時間 |

Flutter の `flutter_service_worker.js` は 3.47 では自分を外すだけの空の SW で、何も事前キャッシュしない（gdal3 を全員に配ってしまうことは無い）。

COOP/COEP（`SharedArrayBuffer`）は要らない。GDAL の WASM は単一スレッドのビルド。COOP は `same-origin-allow-popups` のまま。

⚠ Service Worker が古いビルドを配り続けることがある。デプロイ後に挙動が変わらないときは
devtools → Application → Service Workers で unregister して再読込（2026-08-28に踏んだ）。
