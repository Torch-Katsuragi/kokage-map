# TODO List

## ~~Windows版の復活~~ → 撤去（2026-08-25）

> [!IMPORTANT] デスクトップ版（Windows / macOS / Linux）は撤去した
> 2026-08-21〜 に Windows版を復活させたが、その後 web版が
> **起動 → フォルダを開く → GeoPackage読み書き**まで到達し、役割を引き継いだ。
> `windows/` `linux/` `macos/` と `maplibre_webview` を削除。
> 経緯と代償（オフラインで配れる実行ファイルが無くなる）は
> [[docs/features/concept#プラットフォームの役割分担]]。
>
> 復活させるなら `flutter create --platforms=windows .` からやり直す。
> 当時の作業内容は git 履歴（`a9da582` まで）に残っている。

- [x] Windows版のビルド復旧・地図バックエンド選定・契約テスト整備（→ 撤去により役目終了）
- [x] 撤去にあわせて `flutter_inappwebview` が Android APK から落ちた（`maplibre_webview` の推移的依存だった）
- [x] 死んだ依存 `flutter_map` を pubspec から外す（2026-08-26）
- [ ] 上流に issue/PR（josxha/flutter-maplibre）は**出さない**（AIが人間のコミュニティに投稿しない方針）。
      踏んだバグは手元の回避策とコメントに残してある

## プロジェクト形式の設計（2026-08-21・設計のみ）

> 設計は [[docs/technical/project-format-design|プロジェクト形式の設計]] に集約。
> **web版が全ての前提**なので、下の web 版が終わるまで着手しない。

- [/] **View の導入** — Layer の下に「フィルタ＋スタイルの集合体」を置く。QGISのレイヤと1:1対応
  - [x] モデル（`ViewNode` / `KMetaView`）・`.kmeta.json` への永続化・ツリーUI
        （追加／名前変更／フィルタ編集／複製／削除／同一レイヤ内の並べ替え）
  - [x] フィルタが効く（表示中Viewのフィルタを OR で束ねて WHERE に渡す）
  - [x] **段4b: View ごとのスタイルが描画に出るようにした**（2026-08-26）
        フィーチャに `k-style` を載せ、グループごとにフィルタ付きスタイルレイヤを積む。
        ソースは共有のままなのでデータ転送は増えない。
        View のメニューに「スタイル」を追加。**副産物としてレイヤ単位のスタイル設定が
        初めて描画に効くようになった**（UIは前からあったが描画側が見ていなかった）
  - [ ] View の z順（同一レイヤ内の並び）は描画に未反映。並びの保存だけしてある。
        共有ソース1本という作りの制約で、レイヤ間の前後も表現できない
  - [ ] 選択・頂点・クラスタの見た目はグループ別にできない（全体で1組のまま）
  - [ ] 🐛 **View を hide してもフィーチャが地図から消えない**（2026-09-01 実機で確認）
        show は効く／再起動すると正しく消えている＝**永続化は正しく、セッション中の
        「減らす」経路だけ壊れている**。読んだ範囲では下が怪しい。次回はログで裏を取る:
        - `updateChildren()` の二重実行ガード（[[lib/models/nodes/layer_node.dart]] 付近）は
          実行中だと**進行中のFutureをそのまま返す**。その進行中の読み込みは
          **古い `activeViewFilter`** で走っているので、hide 直後の呼び出しが
          「古いWHEREの結果」を掴んだまま完了しうる
        - `updateFeaturesImpl()`（[[lib/screens/map_page/mixins/map_feature_cache_mixin.dart]]）の
          `layersNeedingLoad` は **features が空のレイヤしか読み直さない**。
          上で children が減らなければ、ここも素通りする
        - ソース側（`_pushFeaturesToSources` → `updateFeatures`）は毎回**全入れ替え**なので
          描画側の取りこぼしではない。犯人は children が減っていないこと
        - 見るべきログ: hide をタップした瞬間の `[Features] P:.. L:.. Pg:..` の件数と、
          `updateChildren already in progress` が出ているかどうか
  - [ ] 🐛 **自己位置マーカーが点・短いラインを隠す**（2026-09-01 実機で確認）
        重なるとフィーチャが見えなくなる。マーカーを半透明にする（不透明度を落とす）方針
  - [ ] 🐛 **レイヤにズームする導線が無い**（2026-09-01）。地図は現在地に開くので、遠方のデータを
        持つ `.gpkg` を開いた人は「何も表示されない」に当たる。レイヤの ⋮ に「ズーム」を足す
  - [ ] 🐛 **ホーム画面から地図へ戻る導線が無い**（2026-09-02）。フォルダ選択済みのカードが出るだけで
        タップしても何も起きない。「フォルダを選択」でピッカーをやり直すしかない
  - [ ] 選択モードで地図をタップすると**フィーチャ情報のポップアップが画面に居座る**（2026-09-02 撮影中に確認）。
        地図を動かしても消えず、複数重なる。閉じる操作か自動消去が要る
- [/] **`.qgs` ライター** — dir/gpkg/layer をレイヤグループ、View をレイヤとして出力
  - [x] 実装（`lib/services/qgis/`）。書き出し導線は 地図の ≡ メニュー と
        フォルダのメニュー（共有の単位が dir なので両方から）
  - [x] **QGIS 3.44.12 で実開封を確認**（2026-08-26）。相対パス解決・subset適用
        （12→6）・レンダラ読み取り・グループ構造すべて意図どおり。
        手順は [[docs/technical/qgis-interop]]、確認スクリプトは `tool/qgis/`
  - [ ] Drive push の直前に自動生成する（いまは手動のみ）
  - [ ] 画像・オーバーレイをラスタレイヤとして書く（いまは除外して報告するだけ）
- [x] `.qgs` インポータ（root外参照を破棄・グループはdir構造に置換・捨てたものを必ず報告）
  - 2026-08-26 実装。こかげマップ → `.qgs` → こかげマップ の往復を web で確認済み
  - QGIS 3.44.12 に書かせた `.qgs` を `test/fixtures/` に置き、それでテストしている。
    これを入れて2件バグが見つかった（色の浮動小数表記・`<data_defined_properties>`）
- [/] web側のQR発行（受け側の `cloneFromDrive` と QRスキャンは実装済み）
  - [x] QRを出す口を作った（`qr_flutter`）。Drive連携フォルダの行に出る。
        **webでも出る**ので「事務所で整えたdirを現場に渡す」の出口はできた
  - [/] **web版のDrive連携**
    - [x] 同期コードの `dart:io` を撤去（2026-08-27）
    - [x] ⚠ **web用のOAuthクライアントIDが要る。** GCPコンソールでしか発行できない
          （gcloud にも Firebase CLI にも口が無い）。
          `--dart-define=GOOGLE_WEB_CLIENT_ID=...` で渡す作り。
          既存の `こかげマップ Web` を流用した（新規発行は不要だった）:
          `348302294570-7srd6hqqpgpvu8sqilihhvhrd1p720p7.apps.googleusercontent.com`
    - [x] 承認済みJavaScript生成元に `http://localhost:8099` を登録（2026-08-27）
    - [x] web のサインイン経路を直した。⚠ ここは native と作りが違う:
          - `google_sign_in_web` に `authenticate()` は**無い**（`UnimplementedError`）。
            ユーザーの取得は One Tap か `renderButton`（`lib/widgets/auth/`）
          - スコープ認可のポップアップは**クリックの直下でしか開けない**。
            認証イベントのハンドラから呼ぶとブラウザに潰される
    - [x] 実アカウントでログイン→認可→Driveのメタ取得まで確認（2026-08-27）
    - [x] クローン本体の通し確認（2026-08-27）。ここで `dart:io` の残りを
          3ファイル潰した（`layer_drawer_service` / `layer_drawer` / `folder_tile`）
    - [/] アップロード（push）の通し確認。**同期そのものより手前で止まっていた**
          - `ensureDriveAuthenticated` が認可の復元を待ったまま返らない。
            `prompt=''` でもGISはポップアップを開き、アカウント選択で止まると
            `await` が返らない（2026-08-27 にログで確認）
          - 画面に「別ウィンドウを見てください」を出す形にした。
            ⚠ 残: ポップアップを本当に無言にするなら `prompt=''` と
            `login_hint` を両方渡す必要があり、`google_sign_in_web` を
            通さず `initTokenClient` を直に叩くことになる
          - [x] **無音化の決め手を実測で特定（2026-08-28）**: `login_hint`。
                `prompt:''` だけだと返らないが、`login_hint` を足すと858msで返る。
                `google_sign_in_web` が `login_hint` に `select_account` を
                抱き合わせているのが原因だったので、GISを直に叩く実装に変えた
                （`web_token_client_web.dart`）
          - [x] **通し確認済み（2026-08-28）。** リロード後、サインインUIを
                一切出さずに復元→アップロードまで通った（Drive上の実体も確認）
          - [x] 詰まりの正体は2つだった:
                1. builder の `if (scaleFactor == 1.0) return child!` が
                   復元Listenerごとスキップしていた（等倍だと一度も走らない）
                2. ログ観測の失敗。コンソール・`window`・DOMは全滅で、
                   **Flutter内のオーバーレイ**（左下のLOGチップ）で解決した
    - [ ] ⚠ **web はリロードでサインインが切れる。** 起動時に One Tap を投げる
          ようにしたが、FedCMのクールダウンやChromeの「サイト間のログイン」
          オフで**出ないことがある**。ボタン側の経路を消さないこと
    - [ ] 本番ドメインを決めたら、承認済みJavaScript生成元に追加する
- [ ] ~~`layer_styles`~~ → **優先度を下げた**。`.qgs` にレンダラを書けば冗長。gpkg単体を渡す場合の保険のみ

## web版（調査済み・2026-08-21）

> `flutter build web` は**エラー0件で通る**。落ちるのは実行時の `UnsupportedError`。
> Dart は `dart:io` を「コンパイルは通るが呼ぶと落ちるスタブ」として web に出しているため、
> 「webで到達する呼び出しを1つずつ塞ぐ」作業になる。詳細は [[docs/technical/testing|テスト構成]] ではなく
> Vault の案件md（Windows版復活_2026-08-21）を参照。
>
> **段1は 2026-08-24 に完了。** ブラウザで起動して背景地図（OSM）まで出る。
> プラットフォーム判定は `lib/core/platform_capabilities.dart` に集約したので、
> 以降 `Platform.is` を直に書かないこと。

- [x] **クリティカルパス: WASM SQLite の性能PoC** → **通過**。全件読み538ms / UPDATE 1件1ms /
      書き戻し14ms / deserialize 5ms。8.5MBなら全部メモリに載せる選択肢も取れる
- [x] **段1: 起動して地図が出るまで**（2026-08-24 完了）
  - [x] `Platform.isXxx` 30箇所を `lib/core/platform_capabilities.dart` の capability 経由に
  - [x] webではTileServerを起動しない（`HttpServer` が無く、かつ不要）
  - [x] `web/index.html` に maplibre-gl-js を追加（maplibre_web は script を注入しない）
  - [x] プロジェクトを開かずに地図だけ見る入口（web限定・段2までの暫定）
  - [x] `integration_test/support/harness.dart` の `hasMapBackend` に web を追加
- [x] **web版の `map_contract_test`**（2026-08-26 全件PASS）
  - `tool/test_matrix.ps1` に `build:web` / `e2e:web` 段を追加（chromedriverの
    起動・停止まで面倒を見る）。CI にも `e2e (web)` ジョブを足した
  - 通すために2箇所直した:
    - `RMapController.animateTo` が、maplibre_web の「キャンセル」例外で
      着地を待たずに返っていた（web はリサイズ由来の `moveend` でもここに来る）
    - 契約テストの `pumpMap` が、地図がコンテナのサイズを取り込む前に走っていた
- [/] **`File(` / `Directory(` をファイルシステム抽象経由に**（本丸）
  - [x] **段2前半: 抽象を作ってツリー経路を載せ替え**（2026-08-25 完了・挙動不変）
        `lib/core/fs/` に `KFileSystem`（**同期メソッドは意図的に無し**）と io / web 実装。
        `path_resolver` / `kmeta` / `kmeta_service` / `folder_node` / `geopackage_node` /
        `image_node` / `global_folder_node` / `geopackage_connection` を移行。173 → 156箇所
  - [x] **段2後半: web実装（File System Access API）＋フォルダ選択**（2026-08-25 完了）
        Chrome/Edge でフォルダを選ぶとツリー（サブフォルダ・.gpkg・画像）が出るところまで到達。
        ⚠ Firefox/Safari は `showDirectoryPicker` が無いので「地図プレビュー」のまま
  - [/] 残り（shapefile・GeoTIFF・TileServer 等）。
        web で通らない経路なので、必要になった段で個別に移す
    - [x] **Drive同期を移した**（2026-08-27）。`lib/services/google_drive/` から
          `dart:io` が完全に消えた。API境界が `File` を持ち回っていたので、
          `uploadFile(String path)` / `LocalSyncFile(path, size)` に変えた
- [x] **段3: GeoPackage を sqlite3 WASM へ**（2026-08-25 完了）
  - `sqflite_common_ffi_web` を採用。既存の `rawQuery` / `transaction` はそのまま動く
  - チェックアウト（元ファイル→WASM）／チェックイン（WASM→元ファイル）を
    `GeoPackageConnection` に実装。書き戻しは `total_changes()` の監視で自動
  - ⚠ OPFSは使っていない（sqflite_common_ffi_web が IndexedDB を使う）。
    ユーザーのフォルダとの受け渡しは File System Access API 側で行う
- [ ] PWA + Service Worker + タイルキャッシュ（オフライン対応）
- [ ] 公開ビューア（PMTiles/GeoJSONを静的ホスティング、URLで共有）
      ⚠ **自分のデータを自分のホストから配る初めての機能**。着手時に転送量を見積もる

### 公開・運用（2026-08-25 方針決定 → [[docs/features/concept#配布と運用コスト]]）

- [/] Firebase Hosting へデプロイして**普通に公開**（ルーム機能が形になってから）
  - [x] 隠しページとしてデプロイ済み（2026-08-28）: `https://kokage-map.sleeptree.jp`
        （noindex・リンク非公開）。手順は docs/technical/web-hosting.md
  - [ ] 「普通に公開」に切り替えるとき: noindex を外し、リンクを張る
- [ ] 予算アラートを設定（同時接続数とダウンロード量）
- [ ] 寄付導線を置く（露骨にしない）
- [ ] セルフホスト手順を書く（既定にはしない。大口向けの選択肢）
- [x] web版でルーム機能を使えるように（2026-08-27）
  - `firebase apps:create WEB` で web アプリを登録し、`firebase_options.dart` に追加。
    `flutterfire configure` は対話式なので使わず、CLIで非対話に済ませた
  - ルーム機能は RTDB しか触らず `dart:io` に依存しないので、設定だけで動いた
  - ⚠ **App Check に web のプロバイダを渡していない**。web は reCAPTCHA の
    サイトキーが要り、それはコンソール発行。App Check API はプロジェクトで
    有効化すらされていないので現状は素通り。強制に切り替えるときに要対応
- [x] **ルーム機能の仕上げ（2026-08-28）** — 設計・詳細は [[docs/technical/location-sharing]]
  - [x] 招待リンク（`?room=CODE`）: web は起動URLから参加ダイアログへ直行。
        シートに「招待リンク」コピー＋「QRコード」表示。参加欄はコード/URL両対応、
        スマホはQRスキャンも可（`lib/services/party/party_invite.dart`）
  - [x] 圏外区間軌跡（gap backfill）の**受信側**: `/tracks` を購読して
        地図に薄いオレンジの線で描画（送信は実装済みだった）
  - [x] キック（host）: メンバー行から退出させる。蹴られた側は members 購読の
        消失/エラーで自動退出＋通知センター表示
  - [x] Android実機（Pixel 9）× web で通し確認: 招待URL参加・メンバー/バッテリー同期・
        キック・tracks描画
  - [x] 旧名称（Root Maps）の残骸をi18nから一掃。位置情報の開示文を
        位置共有機能と整合（パーティ参加中のみ共有と明記。Play審査の 6-3 にも効く）
  - [ ] ⚠ **web でマウスホイール/キーボードの地図ズームが効かない疑い**
        （CDP合成イベントでは再現。実マウスでの確認とホイールズーム対応の調査が要る。
        パン/ドラッグは効く）
  - [x] **OSMタイル403 "Access blocked" を解消（2026-08-28）**
    - 原因: タイル取得の User-Agent が雛形の `com.example.k_maps` のままで、
      OSMのタイル利用ポリシー（固有UA＋連絡先必須・汎用/偽装UAは予告なくブロック）に抵触
    - 対応（3点セット）:
      1. 全タイル取得に正規UA `KokageMap/1.0 (+URL; メール)` を送る
         （`kTileUserAgent`。webはブラウザUAが付くので送らない）
      2. **既定の背景地図を 国土地理院（標準）に変更**（OSMを配布アプリの既定にして
         community運営サーバに全ユーザーを向けない。OSMは選択肢として残す）
      3. **OSM選択中の一括ダウンロードをブロック**（ポリシーで prefetch 禁止。
         通知でGSIへの切替を案内）
    - ⚠ ブロック期間中にキャッシュされた「Access blocked」タイルは残る。
      設定→背景地図→キャッシュクリアで消える（changelogに記載済み）
    - [x] 実機での表示確認（2026-08-28 夜）: フレッシュ起動で地理院標準が
      既定選択＆表示、OSMへ切り替えてもタイルが正常に出る。サーバ側も
      旧UA=blockedタイル/新UA=実タイルを直接確認済み
- [x] **写真インポートでGPS位置情報が欠落するのを修正（2026-08-28）**
  - 原因: `GET_CONTENT` が**システム Photo Picker**（`com.google.android.photopicker`）に
    ルーティングされ、picker URI は ①`openInputStream` が GPS ゼロ埋めの複製を返す
    ②`_data` クエリも「成功」するが返るのは `/sdcard/.transforms/synthetic/...`
    という**リダクション済み合成パス**（ここに既存対策が騙されていた）
  - 修正: picker URI からメディアIDを取り出し `MediaStore.Images` の実体で `_data` を
    引き直す＋synthetic パスは実パス扱いしない（`MainActivity.resolveRealPath`）。
    実パス直読みは FUSE リダクション対象外なので EXIF が丸ごと残る（Pixel 9 実測）
  - ついでに Photo Picker が表示名をメディアID（`20.jpg`）にする問題も
    `resolveDisplayName` で元名に戻した
  - ⚠ クラウド専用アイテム（ローカル実体なし）は実パスが無く、従来どおり
    リダクション済みで取り込まれる（「位置情報なし」表示で見分けられる）
  - ℹ 端末の Photo Picker ⋮ メニューに「位置情報を含める」は未搭載だった
    （2026年8月の mainline 更新で入る見込みの機能。入ればユーザー側でも回避可能になる）

### 段1 の積み残し（2026-08-26 に全て解消）

- [x] **webで背景地図を切り替えても即時反映されない**（→ 解消）
  - 原因は上流。maplibre_web 0.3.5 の `StyleController.addSource()` が `RasterSource` の
    `tiles` と `url` を**両方**JSに書くため、片方が必ず null になり
    maplibre-gl のバリデータが `url: string expected, null found` で弾く。
    例外もリクエストも出ないので**無言で背景地図が消える**
  - **壊れているのは `addSource` だけで `addLayer` は動く**と分かったので、
    初期スタイルJSONには**全プロバイダのソースだけ**を焼き込み、
    レイヤは native と同じ実行時経路（`_addBasemapSources`）で積むようにした。
    切り替えはレイヤの付け外しだけで済むので再読み込みが要らない
  - ⚠ web では basemap の**ソースを消してはいけない**（消すと `addSource` が
    壊れているせいで二度と足せない）。`replaceBasemapSource()` に分岐がある
- [x] **webで地図が右のレイヤドロワーに透けて見える**（→ 解消）
  - **web固有の合成バグではなかった。** `map_page.dart` のサイドパネル／
    ボトムパネルの背景が `Colors.white.withValues(alpha: 0.9)` だったため。
    航空写真だと文字が読めなくなるので不透明にした
- [x] **web: 同じフォルダを3回列挙している**（→ 解消）
  - `LayerTreeNode.listOnce()` で1回だけ列挙し、`FolderNode` / `GeoPackageNode` /
    `ImageNode` の `loadNodes(entries:)` に配る形にした。
    `DriveFolderNode` / `GlobalFolderNode` も同じ形に揃えてある
- [x] **web: 選んだフォルダがリロードで失われる**（→ 解消）
  - ハンドルを IndexedDB に保存し、ホーム画面に「前回のフォルダを開く」を出す。
    ⚠ **自動復元はしない**。`requestPermission()` はユーザー操作の中でしか通らない

> [!NOTE] 方針
> - web版はWindows版を**置き換えた**（2026-08-25 に撤去済み）
> - サーバ権威型のWebGISは**自分ではやらない**。OSS なので利用者側で構築してもらう

---

## 🔥 直近のアクション

- [/] アプリ名を「こかげマップ」に改名
  - [ ] J-PlatPat（日本特許庁）で「rootmap」の商標検索（Class 9/42）— メンテ明け後に実施
  - [ ] USPTO TESSで「rootmap」の商標検索
  - [x] 改名作業を実施（UI、Android/Windows/Web、changelog、Drive連携フォルダ名）
- [x] 内部テスト版でGoogle Sign-Inログイン動作確認
- [x] 連絡先メールアドレスを `k-root@googlegroups.com` に統一
  - [x] GCP ブランディング: サポートメール・デベロッパー連絡先 → 設定済み
  - [x] Play Console: アカウントの詳細・デベロッパープロフィール → 設定完了（2026/04/12）

---

## 未完了タスク

### Google Play リリース

#### 内部テスト（残り）

- [ ] ストア掲載情報（アプリ名、説明文、スクリーンショット等）
- [ ] 内部テスターリスト設定
- [ ] 内部テストとしてリリース

#### クローズドテスト

> 内部テスト完了後、より広い範囲のテスターに配布するためのステップ。

**Play Console「アプリのセットアップ」**

- [ ] アプリのアクセス権（Google Drive連携にはGoogleログインが必要である旨を記載）
- [ ] 広告の有無申告（「いいえ」）
- [ ] コンテンツのレーティング（IAQCレーティング質問票）
- [ ] ターゲットユーザー設定（18歳以上）
- [ ] ニュースアプリ申告（「いいえ」）
- [ ] データの安全性（開発者サーバーへの送信なし、端末内利用の説明）
- [ ] 行政機関のアプリ申告（「いいえ」）
- [ ] 財務機能申告（「提供していない」）

**デモ動画の作成**

> Play Console権限説明 + OAuth検証申請で兼用可能。1本にまとめてYouTubeタイムスタンプで各セクションに飛ばす。

- [ ] 撮影内容（シナリオの詳細は [[docs/technical/play-permission-video-plan|権限申請 動画・宣言 計画]]）:
  - [x] **権限デモ（全ファイルアクセス・位置情報・前景サービス）を1本で撮影・編集済み**（2026-09-02）
        成果物 `.temp/play-demo/kokage-map_permission-demo.mp4`（92秒・1080x2424・英語字幕・座標バーぼかし済み）。
        撮影は `adb` 自動操作（`.temp/play-demo/take.sh` + `ui.py`）、編集は `edit.py`（ffmpeg）。
        ⚠ 地図画面のタップは座標決め打ちでは通らない（ドロワの自動オープン・ツリー展開が不定）→
        `uiautomator dump` で Flutter の semantics からテキスト検索してタップする
  - [ ] Google Sign-In → Drive同期の操作フロー（OAuth検証用）。**web版で別撮り・同意画面を English に**
        （ネイティブは Play開発者サービスのダイアログでスコープ一覧が出ない）
  - [ ] ~~カメラ: 写真マーカー撮影、QRコードスキャン~~ → 宣言フォーム対象外なので撮らない
  - [ ] ~~Bluetooth: TruPulse測量機器との接続・データ取得~~ → **撮らない**（2026-09-01）
        「近くのデバイス」（`BLUETOOTH_SCAN`/`_CONNECT`/`_ADVERTISE`）は制限付き権限ではなく、
        Play Console に宣言フォーム自体が無い（用途記載のみ）。OAuth検証もDriveスコープの話で
        BTは無関係。⚠ エミュでの代替は不可（AVDにホストのBTは通らない・rootcanalは
        emulator↔emulator専用）。そもそも提出動画は実機の実動作のみでモック不可
- [ ] YouTubeに限定公開でアップロード
- [ ] Play Console各権限セクション + GCPデータアクセスページにリンク登録

**ストア掲載情報**

- [ ] アプリ名・短い説明・詳しい説明
- [ ] スクリーンショット（スマートフォン用: 最低2枚）
- [ ] アプリアイコン（512x512 PNG）
- [ ] フィーチャーグラフィック（1024x500 PNG）
- [ ] カテゴリ設定（ツール or 地図＆ナビ）
- [ ] 連絡先情報（`k-root@googlegroups.com`）

**クローズドテストトラック**

- [ ] トラック作成・テスターリスト登録
- [ ] AABアップロード・リリースノート入力
- [ ] ロールアウト・参加リンク共有

---

### OAuth検証申請（一般公開向け）

> 内部テスト（100人以下）には不要。一般公開時に必要。

- [x] GCP ブランディング設定（HP・プライバシーポリシー・承認ドメイン）
- [x] GCP データアクセス（`drive` スコープ、用途チェック3種全選択）
- [ ] デモ動画のYouTubeリンクをGCPデータアクセスページに登録
- [ ] CASA対応（`drive`は制限付きスコープ。Googleから要求された場合のみ）
- [ ] 検証センターから申請

---

### 機能開発

#### Google Drive連携

- [ ] レイヤ単位での競合解決（GeoPackage内のレイヤレベルマージ、ops.logによる競合検出）

#### MapLibre

- [ ] 3D terrain有効化（RasterDemSource + setTerrain + pitch/tiltコントロール）
- [ ] 国土地理院DEMタイル → Terrain-RGB変換の実装・検証
- [ ] Flutter SDKアップグレード（3.10+）→ maplibre_webview導入（Windows対応）
  - **Windows対応一時中断**（2026/04/07）: maplibre_webviewのWebView2実装に起因する問題のため、当面Android特化。
- [ ] MapLibre GL JS/CSS/pmtiles.jsのローカルバンドル化（CDN依存排除、オフライン起動対応）
  - 注: バンドル版pmtiles.jsがNode.js用ビルドでブラウザ非互換のため保留

#### OverlayImageNode

- [x] OverlayTransformTool: ハンドルベースの移動・拡縮・回転UI
- [x] オーバーレイ設定ダイアログ: 不透明度・位置パラメータの調整UI
- [x] オーバーレイ変換ダイアログ: 紙地図スキャン画像の透明化処理（4モード）
- [x] オーバーレイ変形パフォーマンス改善（100msデバウンス）

#### その他機能

- [x] チェンジログ表示機能（CHANGELOG.md + アプリ内Markdown表示 + 未読通知バッジ）
- [x] UIサイズ7段階調整機能（0.75x〜1.30x、設定 → 一般、MediaQuery.textScaler + Riverpod）
- [x] フィードバックフォームにバージョン情報・端末モデルを事前入力（Google Forms URLパラメータ + PackageInfo + DeviceInfo）
- [ ] ポイント詳細情報からGoogle Mapリンクをコピーする機能
- [ ] 既存MapTool (PenTool/SelectTool/GpsTool) のChangeNotifier化統一
- [x] 水準器（Spirit Level）機能（v0.6.0 — 加速度計/コンパス/GPS統合、直角三角形計算付き）

### コード品質

`flutter analyze` 残存警告: **0件** ✅

- [x] `overridden_fields`: `FeatureNode` のフィールドオーバーライド警告 → ignoreコメント位置修正
- [x] `annotate_overrides`: `@override` アノテーション不足 → 2箇所追加（map_page_state_base.dart）
- [x] `unintended_html_in_doc_comment`: docコメント内のHTML解釈問題 → バッククォートエスケープ（tile_server.dart）
- [x] `avoid_print`: テストコード内の `print()` → `// ignore: avoid_print` 追加（15箇所）

---

## 完了済み

<details>
<summary>内部テスト・Google Play（2026/04）</summary>

- [x] リリース準備
  - [x] keystore統一、バージョン番号設定（0.5.1+6）、署名付きAABビルド
  - [x] ACCESS_MOCK_LOCATION をdebugマニフェストに移動
  - [x] keystoreをandroid/配下にコピー、key.propertiesのパス修正
- [x] Play Consoleアップロード・公開
  - [x] アップロード鍵リセット申請、内部テストトラックにAABアップロード（v0.5.1+6）
  - [x] プライバシーポリシー作成・GitHub公開・Play Console登録
  - [x] リリースノート作成（`docs/release_notes_v0.5.1.md`）
- [x] Google Sign-In修正（2026/04/10）
  - [x] Play App Signing の SHA-1 取得（deployment_cert.der）
  - [x] Google Cloud Console に Play App Signing 用 Android OAuthクライアントID 作成
  - [x] SHA-1 一覧をGoogle Drive保存（`開発用キー/SHA-1フィンガープリント.txt`）
  - [x] 不要な `email` スコープを削除
- [x] GPSゾンビプロセス対策（2026/04/11）
  - [x] AndroidManifest `stopWithTask="true"` 設定（OS レベルでのサービス自動停止）
  - [x] ハートビートベース自殺機構（foreground_service.dart: 5秒間隔ping/pong、30秒無応答で自動停止）
  - [x] メインisolate側の応答ハンドラ（internal_gps_location_store.dart）
- [x] アプリ名を「こかげマップ」に改名（2026/04/12）
  - [x] UI、Android/Windows/Web、changelog、Drive連携フォルダ名を一括更新

</details>

<details>
<summary>Google Drive連携MVP（2026/01）</summary>

- [x] 認証基盤（google_sign_in, googleapis）、GoogleDriveService/DriveAuthState
- [x] フォルダ追加: 通常/Drive連携の選択、URL入力（ペースト＋QRスキャン）
- [x] クローン: 共有フォルダからの初回ダウンロード
- [x] 永続化: .kmeta.jsonにDrive情報保存、再読み込み時にDriveFolderNodeとして復元
- [x] 手動同期（Push/Pull/状態確認/連携解除）、自動チェック
- [x] 視覚的区別（青いクラウドアイコン、同期状態オーバーレイ）
- 注: モバイル専用機能（PCでは無効化）

</details>

<details>
<summary>MapLibre移行（2026/03）</summary>

- [x] FlutterMap → MapLibreMap ウィジェット置換（KMapController/KMapCameraラッパー）
- [x] レイヤ移植（Polygon/Polyline/Marker → maplibre StyleLayer）
- [x] タイルキャッシュ基盤の移行（TileServer、localhost経由配信）
- [x] フィーチャ描画パフォーマンス修正（MapSourceManager、GeoJsonSource+StyleLayer）
- [x] ポイントクラスタリング実装（supercluster）
- [x] ImageNode描画をSymbolStyleLayerに移行（GPU描画化）
- [x] Windows版パフォーマンス最適化（頂点マーカーGPU化、batchSetPaintProperties）
- [x] Windows版マップ表示不具合修正（WebSocketレースコンディション）

</details>

<details>
<summary>外部計測機器・測量機能（2026/03）</summary>

- [x] TruPulseService: BT SPP接続、プロトコルパーサー
- [x] ExternalDeviceService / DeviceTool 抽象レイヤ（プラグインパターン）
- [x] MapToolbar / map_page へのDeviceTool汎用統合
- [x] Point → Line/Polygon 変換（閉合補正: コンパス法則/トランシット法則）
- [x] 磁気偏角補正、器械高・目標高補正
- [x] 測量精度リアルタイム表示（閉合比警告）

</details>

<details>
<summary>アーキテクチャ改善・Riverpod移行（2025/12〜2026/03）</summary>

- [x] 型安全性改善（IMapState、MapTool型安全化）
- [x] 重複コード削減、定数集約、ファイル構造整備
- [x] map_page.dart mixin統合（6 mixin + 3 widget）
- [x] 内蔵GPSリファクタリング（InternalGpsLocationStore、ForegroundService）
- [x] GPS軌跡の常時記録と切り取りUI（GpsHistoryRecorder、TrackExtractionDialog）
- [x] Riverpod導入 → 正規化 → 完全正規化（GlobalConfig完全削除、38ファイル190箇所解消）
- [x] LayerDrawerリファクタリング（ConsumerWidget化、LayerDrawerService抽出）
- [x] 非同期競合状態防止（Completer使用、6箇所）
- [x] 巨大ファイル分割（feature_converter, layer_drawer_tiles, sync_engine, metadata_parser）

</details>

<details>
<summary>コード品質・パフォーマンス改善</summary>

- [x] BuildContextの非同期使用問題の修正（10ファイル）
- [x] 非推奨APIの更新（withOpacity→withValues、onPopInvoked→onPopInvokedWithResult等）
- [x] print()をAppLoggerに統一
- [x] GeoPackageロード高速化（N+1解消、並列化、Isolate化）
- [x] 地図操作パフォーマンス改善（レンダリングキャッシュ、selectedFeaturesのSet化）
- [x] 宣言的設定フレームワーク（SettingDef + SettingsStore）

</details>

<details>
<summary>その他完了済み機能</summary>

- [x] フォルダメタデータシステム（.kmeta.json）
- [x] グローバルフォルダ機能（PC版カスタムパス対応含む）
- [x] LayerTreeNode大規模リファクタリング（NodeType enum、PathResolver等）
- [x] 属性テーブルQGISフィルタ・複製機能
- [x] OverlayImageNode変換後の即時マップ反映
- [x] ドキュメント構造整理（docs/features + docs/technical分割）
- [x] 背景地図改善（一括DL、並列処理、オフラインフォールバック、航空写真対応）
- [x] 設定画面UI統一

</details>
