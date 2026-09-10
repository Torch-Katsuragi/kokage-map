---
title: テスト構成（Android / web）
tags: [technical, testing, android, web]
---

# テスト構成

> [!NOTE] 2026-08-25 にデスクトップ版を撤去した
> 対象は **Android と web**。Windows/macOS/Linux の段は無くなった。
> 経緯は [[../features/concept#プラットフォームの役割分担]]。

## コード生成

`*.g.dart` は **`.gitignore` 済み**（リポジトリに入っていない）。
`flutter pub get` のあとに回すこと。

```powershell
dart run build_runner build --delete-conflicting-outputs # riverpod + i18n（slang_build_runner）
```

> [!WARNING] `dart run slang` を先に回さない（2026-09-10 逆転）
> build_runner 2.16 以降は、自分が作っていない `strings*.g.dart` があると
> `InvalidOutputException: Asset already exists` で落ちる（`--delete-conflicting-outputs` でも消さない）。
> 2.13 時代は逆に `slang` を先に回す必要があった。手元に古い `strings*.g.dart` が残っていたら
> `lib/i18n/strings*.g.dart` を消してから build_runner を回す。

> [!IMPORTANT] CI でも回すこと
> 2026-08-26 まで、CIは**4ジョブ全部が生成コード不足で落ちていた**。
> `Undefined name 'Translations'` のような、原因の分かりにくい形で出る。
> ジョブを足すときは codegen ステップを忘れないこと。

## 一発で回す

```powershell
pwsh tool/test_matrix.ps1
```

段ごとの結果が表で出る。ログは `.temp/test_matrix/` に残る。

| 段 | 内容 | 端末 |
|---|---|---|
| `analyze` | `flutter analyze` | 不要 |
| `unit` | `test/` 配下（ホストVM） | 不要 |
| `build:android` | debug APK のコンパイルゲート | 不要 |
| `e2e:android` | `integration_test/` を実機/エミュで実行 | Android |
| `build:web` | release web のコンパイルゲート | 不要 |
| `e2e:web` | `integration_test/` を Chrome で実行 | chromedriver |

よく使うオプション:

```powershell
pwsh tool/test_matrix.ps1 -Only analyze,unit   # 端末不要の段だけ
pwsh tool/test_matrix.ps1 -Only e2e:web        # webのe2eだけ
pwsh tool/test_matrix.ps1 -SkipWeb             # Androidだけ
pwsh tool/test_matrix.ps1 -Emulator Medium_Phone_API_36
```

`e2e:android` は **実機を優先**する。実機が繋がっていなければエミュレータを自動起動する。

> [!IMPORTANT] Androidの検証は実機で行う（2026-08-21 方針）
> エミュはCPU/GPUが実機と別物で、性能の数字も描画の挙動もあてにならない。
> `tool/test_matrix.ps1` は `adb devices` の結果から実機を先に選ぶ。
> エミュはあくまで実機が無いときのフォールバック。
> ⚠ベンチ（`integration_test/benchmark/`）の数字を比較するときは、
> **どちらで取ったかを必ず併記する**こと。

## 地図バックエンド契約テスト

[[map_contract_test|integration_test/map_contract_test.dart]] が本命。
地図バックエンドを差し替えたとき、振る舞いが変わっていないかを機械的に検証する。
もともとは Windows(maplibre_webview) と Android(maplibre-native) の挙動差を数値に
固定するために書かれた。デスクトップ撤去後も、**Android と web で同じ契約が成り立つか**
を見る網として有効。

検証している契約:

- `onStyleLoaded` が発火する
- `MapOptions` の初期カメラ（center / zoom / bearing / pitch）が反映される
- `move()` / `moveAndRotate()` が即時にカメラへ反映される
- カメラ中心のスクリーン座標がウィジェット中央になる（DPRの二重適用検出）
- スクリーン座標 ⇄ 地理座標の往復が2px以内で一致する
- `KMapCamera` のヘルパが `RMapController` と同じ値を返す
- `animateTo()` の Future が完了し、目標カメラに着地する
- `fitCoordinates()` が全座標を画面内に収める
- GeoJSONソース／レイヤの追加・更新・削除が `getLayerIds()` に反映される


## プラットフォーム前提の宣言

`integration_test/support/harness.dart` に、プラットフォームごとの前提を集約している。
暗黙にテストを落とすのではなく、ここで明示的にスキップ理由を宣言する。

| フラグ | 意味 | 現状 |
|---|---|---|
| `hasMapBackend` | maplibre のプラットフォーム実装があるか | android / ios / web |
| `hasFirebaseConfig` | `firebase_options.dart` に設定があるか | android / ios のみ |

前提が変わったら、このファイルの1行を直せば対象テストが走り出す。

> [!IMPORTANT] web では `Platform` を**先に**踏まないこと
> `dart:io` は web でも**コンパイルは通る**が、`Platform.isAndroid` などを
> 呼んだ瞬間に `UnsupportedError` を投げる。harness も `kIsWeb` を先に見る形にしてある。
> アプリ側の同じ規約は `lib/core/platform_capabilities.dart` に集約している。

`pumpUntil()` も同ファイル。地図はプラットフォームビューで常時アニメーションが走るため
`pumpAndSettle()` は永久に settle しない。地図まわりでは必ず `pumpUntil()` を使う。

## web版のテスト

`flutter test <file> -d chrome` は
**`Web devices are not supported for integration tests yet.` で断られる。**
web だけは `flutter drive` 経由になり、chromedriver（Chrome と同じメジャーバージョン）が要る。

```powershell
chromedriver --port=4444
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/map_contract_test.dart -d web-server --browser-name=chrome
```

`tool/test_matrix.ps1` の `e2e:web` 段が chromedriver の起動・停止まで面倒を見るので、
普段は手で叩かなくてよい（2026-08-26 に全件PASSを確認）。

### chromedriver の入れ方

**Chrome と同じビルド番号のものが要る。** バージョンがずれると
`session not created: This version of ChromeDriver only supports Chrome version NN` で落ちる。
Chrome は勝手に更新されるので、落ちたら入れ直す前提でいる。

```powershell
# 1. いま入っている Chrome のバージョンを見る
(Get-ItemProperty 'HKCU:\Software\Google\Chrome\BLBeacon').version

# 2. Chrome for Testing の一覧から、同じビルドの win64 版URLを引く
#    https://googlechromelabs.github.io/chrome-for-testing/latest-patch-versions-per-build-with-downloads.json

# 3. .temp/ に展開する（PATH は汚さない。test_matrix.ps1 がここを見る）
```

置き場は `.temp/chromedriver-win64/chromedriver.exe`。`.gitignore` 済みなので
コミットされない。別の場所に置くなら `-ChromeDriver <path>` で渡す。

### 画面を目で見るとき

```powershell
flutter build web --release
python -m http.server 8110 --directory build\web --bind 127.0.0.1
```

### web の GeoPackage に必要なファイル

`web/sqlite3.wasm` と `web/sqflite_sw.js` はリポジトリに入れてある
（`sqflite_common_ffi_web` が要求する）。**消すと web で GeoPackage が一切開けない。**
再生成はこれ:

```powershell
dart run sqflite_common_ffi_web:setup
```

### フォルダを開く経路を、OSのダイアログ無しで試す

`showDirectoryPicker()` はOSのフォルダ選択ダイアログを出すので、自動操作から
完了させられない。**OPFS のディレクトリハンドルを返すスタブに差し替える**と、
アプリ側のコード（`WebFileSystem` → ツリー構築）をそのまま通して確認できる。
ブラウザのコンソールで、アプリを読み込んだ直後に:

```js
const opfs = await navigator.storage.getDirectory();
const root = await opfs.getDirectoryHandle('テストプロジェクト', {create: true});
await root.getDirectoryHandle('林小班', {create: true});
const fh = await root.getFileHandle('路網.gpkg', {create: true});
const w = await fh.createWritable(); await w.write('dummy'); await w.close();
window.showDirectoryPicker = async () => root;   // ← これでピッカーを乗っ取る
```

`.gpkg` を用意したいが geopandas が無いときは、標準ライブラリだけで最小の
GeoPackage を作れる（GeoPackageは規約に沿ったSQLiteでしかない）。
`gpkg_spatial_ref_sys` / `gpkg_contents` / `gpkg_geometry_columns` の3表と、
`fid`+`geom` を持つ実テーブルがあれば読める。ジオメトリは
`'GP' + version + flags + srs_id(LE int32)` のヘッダ + WKB。

> [!WARNING] `debugPrint` はスロットリングされる
> web の release ビルドでログを見ていると、**数十秒遅れてまとめて出てくる**。
> 「ログが出ない＝処理が止まった」と即断しないこと（実際に一度誤診した）。
> 待てば出る。`console.log` を配列に溜めておいて後から読むのが確実。

> [!WARNING] `flutter run -d chrome` のデバッグサーバは別ブラウザから開くと不安定
> DWDS はクライアントを1つしか面倒を見ないので、`flutter run` が起動した Chrome とは
> 別のタブから同じポートを開くとモジュールの読み込みが止まることがある。
> 画面を機械的に確認したいときは `flutter build web --release` して
> `build/web` を静的配信するほうが速くて確実。

## 既知の落とし穴

- **integration_test はファイル単位で起動する。**
  `flutter test integration_test -d <device>` とディレクトリ指定すると2本目以降が
  `The log reader stopped unexpectedly, or never started.` で起動に失敗する。
  `tool/test_matrix.ps1` はファイルごとに `flutter test <file> -d <device>` を呼び直している。
- **`testWidgets` の `skip` は `bool` しか取れない。**
  理由つきスキップ（文字列）を使いたいときは `group` 側に置く。`test` は `Object?` を取るので問題ない。
- **ホストVMのテストで sqflite を使うなら FFI 初期化が要る。**
  `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;` を `setUpAll` で呼ぶ
  （`main.dart` のデスクトップ分岐と同じ）。
- **`addLayer()` は `fid` と `geom` しか作らない**（QGIS互換の最小スキーマ）。
  属性を扱うテストは `addAttributeColumns()` で明示的にカラムを足す。
- ⚠ **ワイヤレスデバッグ: `_adb-tls-connect._tcp` が広告されないことがある。**
  2026-08-27 に踏んだ（adb 35.0.2 / Windows / Openscreen mDNS）。
  ペア設定用の `_adb-tls-pairing._tcp` は**ダイアログを開いている間だけ**出るが、
  ペアリング後に出るはずの接続用サービスが最後まで出てこない。
  `adb kill-server; adb start-server` でも変わらなかった。

  一番早いのは、端末の「ワイヤレスデバッグ」画面に出ている
  **`IPアドレスとポート` をそのまま使う**こと。

  ```powershell
  adb connect 192.168.11.21:35221
  ```

  画面を見られないときはポートスキャンで探せる（1分弱）。
  ワイヤレスデバッグのポートは 30000〜49999 に入る。

  ```powershell
  $ip='192.168.11.21'
  30000..49999 | ForEach-Object -Parallel {
    $c = [System.Net.Sockets.TcpClient]::new()
    try { if ($c.ConnectAsync($using:ip, $_).Wait(300)) { $_ } } catch {} finally { $c.Dispose() }
  } -ThrottleLimit 300
  ```

  ペアリング自体は一度やれば残る（`adb pair <ip>:<pairPort> <6桁>`）。
  **ポートは端末を再起動すると変わる**ので、毎回そこだけ拾い直す。
- **`e2e:android` が無反応で固まったら、まず adb サーバを立て直す。**
  端末側ではなくPC側が詰まっていることがある（APKのインストールまでログが出て、
  そこから先が永久に進まない）。2026-08-24 に20分ハングした実例あり。
  ```powershell
  adb kill-server; adb start-server; adb devices
  ```
  残った `dart.exe` / `dartvm.exe` が掴んでいることもあるので、先に落としておく。
- ⚠ **Git Bash から `adb shell df -h /data` を打つと嘘をつく。**
  `/data` が `C:/Program Files/Git/data` に変換されて `No such file or directory` になり、
  端末のストレージが壊れているように見える。`MSYS_NO_PATHCONV=1` を付けるか
  PowerShell から叩くこと。
- **エミュレータの空き容量に注意**（実機を使えば回避できる）。
  debug APK は230MB超あり、テストはファイルごとに入れ直すので使い回したエミュはすぐ埋まる。
  `INSTALL_FAILED_INSUFFICIENT_STORAGE` だけでなく
  `adb: device 'emulator-XXXX' not found` や `VmServiceDisappearedException` という
  紛らわしい形でも出る。`tool/test_matrix.ps1` は実行前に空きを見て、
  1500MB を切っていたらその場で止める。
  詰まったら `adb shell pm list packages -3` で残骸を探して消す。

## 起動時にプロジェクトを自動で開く

```bash
flutter run -d chrome --dart-define=PROJECT_DIR=/プロジェクト名
```

フォルダピッカーを手で操作しないと地図画面に入れないと、起動〜描画の検証が回せないので用意した
（`lib/core/launch_options.dart`）。指定が無い／パスが存在しない場合は通常どおり選択画面が出る。

> [!WARNING] パスはスラッシュ区切りで渡す
> バックスラッシュはシェルと `--dart-define` の間で食われて
> `C:UsersyouProject` のような別物になる。存在しないパスは黙って無視されるので気づきにくい。

## CI

`.github/workflows/ci.yml` で以下を回す。端末が要る段はCIでは扱わない。

- `analyze + unit`（ubuntu）
- `build (web)` — web版が「コンパイルすら通らない」状態に戻るのを防ぐゲート
  ⚠ ビルドが通っても実行時に落ちうる（`dart:io` はwebでスタブとして出るため）
- `build (android)`

## 関連

- [[tech-stack|技術スタック]]
- [[../../TODO|TODO]]
