# Google Play 権限申請 動画・宣言 計画

こかげマップ を Google Play に公開するにあたり、審査で説明が必要な権限のための
**デモ動画**と **Play Console 宣言テキスト**を用意するための計画書。

---

## 0. 対象権限（このアプリで審査対象になるもの）

AndroidManifest から確定した、説明が要る権限:

| 権限 | 用途 | 審査難易度 | 必要なもの |
|---|---|---|---|
| `MANAGE_EXTERNAL_STORAGE`（全ファイルアクセス） | ユーザーが選んだ任意フォルダの `.gpkg`（GeoPackage）を直接パスで読み書き・作成 | ★★★ 最難関 | 権限宣言フォーム **＋ デモ動画（実質必須）** |
| `FOREGROUND_SERVICE_LOCATION` / `FOREGROUND_SERVICE_DATA_SYNC` | GPS軌跡の継続記録・位置共有中の前景サービス | ★★ | 前景サービス宣言フォーム＋動作提示 |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | 現在地取得・測量・位置共有 | ★ | アプリ内 Prominent Disclosure（実装済）＋デモ |
| `READ_MEDIA_IMAGES` | 写真の閲覧/添付 | ー | Data safety 記載のみ（動画不要） |
| `BLUETOOTH_SCAN` / `_CONNECT` | 外部GNSS受信機との接続 | ー | 近くのデバイス用途を記載（動画は任意） |
| `POST_NOTIFICATIONS` | 前景サービス通知 | ー | 記載のみ |

> **重要:** `ACCESS_BACKGROUND_LOCATION` は宣言していない（前景サービスで代替）。
> → **背景位置の専用デモ動画は不要**。ただし型付き前景サービスの宣言は必要。

---

## 1. 全体方針

- **動画は1本の「通しデモ」**を推奨（初回起動→開示→許可→機能まで因果が繋がる形）。
  全ファイルアクセスを中心に、位置・前景サービスも同じ流れの中で見せる。
- **必ずリリース（署名）ビルドで撮影**する。デバッグビルドの `DEBUG` リボンが写った
  動画は審査に出さない。ユーザーが実際に見る画面＝リリースビルドで撮る。
- **言語は英語想定**。端末UIを英語ロケールにするか、**英語字幕を必ず入れる**。
- **実機の実動作のみ**（モック・スライドはNG）。「開示 → 許可 → その機能が動く」の
  因果が1カットの流れで見えること。
- 長さの目安 **60–120秒**。

---

## 2. 事前準備（撮影前チェック）

- [ ] **リリースビルドを用意**（`flutter build apk --release` または AAB）。DEBUGバナーが出ないこと。
- [ ] **クリーンな初期状態を作る**（オンボーディングと権限プロンプトを最初から見せるため）:
  ```bash
  adb uninstall com.k_root.k_maps            # データ＋オンボ完了フラグを消す
  adb install app-release.apk
  # （権限は未許可の新規状態になる）
  ```
  再インストールせず権限だけ戻す場合:
  ```bash
  adb shell appops set com.k_root.k_maps MANAGE_EXTERNAL_STORAGE default
  adb shell pm revoke com.k_root.k_maps android.permission.ACCESS_FINE_LOCATION
  adb shell pm clear com.k_root.k_maps       # ← オンボ含め完全初期化したい場合
  ```
- [ ] **デモ用データを配置**：任意フォルダに `.gpkg` を数点入れておく（例: `Pixel/kmaps/rootmap_test/*.gpkg`）。
      「ユーザーが自分で整理した任意の場所のファイルを開ける」ことを示すため、Downloads 直下ではなく
      **自作フォルダ階層**に置くのが望ましい。
- [ ] **端末を英語表示**にする（審査官が読める）／または字幕方針を確定。
- [ ] 通知やSIM等の**個人情報が写らない**ようにする（機内モードで電話系アイコンを隠す等）。

### 録画コマンド（adb）
```bash
# 3分制限に注意。音声は録れない（字幕で補う）。
adb shell screenrecord --time-limit 180 --bit-rate 8000000 /sdcard/perm_demo.mp4
# 停止（Ctrl+C）後に取り出し
adb pull /sdcard/perm_demo.mp4 ./perm_demo.mp4
```
> 端末内蔵のスクリーンレコーダーでも可（タップ位置表示をONにすると分かりやすい：
> 設定→システム→開発者向けオプション→「タップを表示」）。

---

## 3. 撮影シナリオ（操作の順番）

**1本の通しで以下を順に撮る。** カッコ内は「何の権限の根拠になるか」。

1. **アプリ初回起動** → オンボーディング Welcome ページ（アプリ名が分かる画面）
2. **ストレージ開示ページ**（Prominent Disclosure）を **2–3秒静止**して全文を見せる（全ファイルアクセスの事前開示）
3. 「許可」→ システムの **「すべてのファイルへのアクセス」設定画面** → トグルON → 戻る（権限プロンプト本体＋許可操作）
4. **位置情報開示ページ**を全文静止 → 「許可」→ システムの位置プロンプト → **「アプリの使用中のみ許可」**（位置の事前開示＋許可）
5. Bluetoothページは「スキップ」でも可（外部GNSS用途。任意）
6. ホーム画面 → **「フォルダを選択」** → **ユーザーが任意の場所の自作フォルダを選ぶ** → `.gpkg` レイヤが地図に表示
   （★核心：任意フォルダの GeoPackage を直接読む＝全ファイルアクセスの必要性）
7. レイヤを1つ編集 or **新規レイヤ/フィーチャを作成して保存**（書き込みも見せる）
8. GPS測量ボタン → **現在地取得** → 地図に自分の位置（位置情報の用途）
9. **≡メニュー → 位置共有パーティ → 新規作成** → 自分の位置が共有される様子（位置＋前景サービスの用途）
10. **通知シェードを一瞬開き**、前景サービス通知（記録/共有中）を見せる（FGS location/dataSync の用途）

### 「核心カット」（審査官がこれだけ見れば必要性が分かる部分）
- **全ファイルアクセス**：手順6–7。「ユーザーが選んだ任意フォルダ配下の複数の `.gpkg` を
  直接読み書き・作成し、QGIS等の外部GISツールと同じファイルを共有する」ことが要点。
- **位置**：手順4＋8–9。開示文 → 現在地 → 共有。
- **前景サービス**：手順9–10。共有/記録中の通知。

---

## 4. 必ず含める要素（チェックリスト）

- [ ] アプリ名／アイコンが分かる画面が冒頭にある
- [ ] 各 **Prominent Disclosure の全文**が読める（静止 or 字幕で再掲）
- [ ] **システム権限プロンプト本体**と、ユーザーが「許可」する操作が写っている
- [ ] 許可直後に**その機能が実際に動く**因果が繋がって見える
- [ ] 全ファイルアクセス：**任意フォルダ**のファイルを開く／保存する場面
- [ ] 位置：現在地取得／位置共有の場面
- [ ] 前景サービス：記録/共有中の**通知**
- [ ] DEBUGバナーが写っていない（＝リリースビルド）
- [ ] 個人情報（電話番号・他アプリ通知・氏名等）が写っていない

---

## 5. 編集

- 不要な待ち時間（ロード・タイル読み込み等）はカット。ただし**開示文と権限プロンプトは十分な尺**で残す。
- **英語字幕**を各ステップに1文ずつ＋権限名を明示（例: "Granting All files access to read GeoPackage data"）。
  可能なら各権限の直前に **"Why we need this:"** のテロップを1枚挟む。
- 冒頭に **アプリ名 ＋ "Permission usage demo"** のタイトルテロップ。
- 解像度は撮影のまま、**縦向き**。BGM不要（審査は内容重視）。
- 出力：MP4、限定公開（Unlisted）YouTube にアップ → **URL を Play Console の宣言に貼る**。
  （直接アップロードを求められる項目もあるので両方用意しておく）

---

## 6. Play Console 側に書く宣言テキスト（動画と対で提出）

### 6-1. All files access（MANAGE_EXTERNAL_STORAGE）宣言 ＝ 英語ドラフト
> こかげマップ is a field GIS application. Its core function is to let users open,
> edit, create, and save **GeoPackage (`.gpkg`) spatial databases** located in
> **any user-chosen folder** on the device, and interoperate with external desktop
> GIS tools (e.g., QGIS) that read/write the same files by absolute path.
> A single project consists of many `.gpkg` files plus SQLite sidecar files
> (`-journal`, `-wal`) that must be read and written **in place** by exact path.
> The Storage Access Framework / scoped storage cannot provide reliable random
> read/write access to these SQLite databases and sidecars across arbitrary
> user-organized directories, so broad file access is required for the core
> feature. Access is requested with a prominent in-app disclosure before the
> system prompt.

> ⚠️ この権限は却下リスクが高い。「なぜ SAF/MediaStore/scoped storage では
> 実用にならないか」を具体的に書くことが重要（SQLiteの直接パス読み書き・sidecar・
> 外部ツール互換）。却下された場合の次善策は §8 参照。

### 6-2. 前景サービス（Foreground service）宣言 ＝ 英語ドラフト
> The app uses a foreground service (`location` + `dataSync`) to (1) continuously
> record the user's GPS track during field surveys and (2) share the user's live
> location with party members, while an ongoing notification is shown. The service
> only runs while the user has explicitly started tracking/sharing and is
> dismissible by leaving the session. No background location permission is used;
> location access occurs within the foreground service with a persistent notification.

### 6-3. 位置情報 Prominent Disclosure（アプリ内文言の確認）
- オンボーディングの `t.onboarding.locationDisclosure`（`lib/i18n/*.json` の `onboarding.locationDisclosure`）が
  「何のために・どう使うか」を明示しているか審査基準で見直す。
- 文言に **アプリ名 ＋ 位置の用途（測量・軌跡・共有）＋ 前景での利用**が含まれること。

### 6-4. Data safety フォーム（別途）
- 位置情報：収集/共有の有無（位置共有＝他メンバーへ共有する点を正直に記載）。
- 写真（READ_MEDIA_IMAGES）、デバイスID等も該当箇所を記入。

---

## 7. 提出前 最終チェックリスト

- [ ] 動画はリリースビルドで撮影（DEBUGバナーなし）
- [ ] 各権限の「開示→プロンプト→許可→機能」が1本で繋がっている
- [ ] 英語字幕あり／端末UIが英語
- [ ] 全ファイルアクセスの必要性（任意フォルダの `.gpkg` 直接read/write）が明確
- [ ] 前景サービス通知が写っている
- [ ] Play Console：All files access 宣言テキスト記入＋動画URL
- [ ] Play Console：前景サービス宣言記入
- [ ] Data safety フォーム記入（位置共有を含む）
- [ ] 個人情報が動画に写っていない

---

## 8. リスクと次善策（All files access 却下時）

`MANAGE_EXTERNAL_STORAGE` は Google が「ファイルマネージャ等のコア用途」に限定しがちで、
**却下される可能性が現実的にある**。却下・保留になった場合の備え:

- **SAF（Storage Access Framework）ベースへ移行**の検討：ユーザーがフォルダをツリー選択
  （`ACTION_OPEN_DOCUMENT_TREE`）→ そのツリー配下だけを読み書き。既に「フォルダを選択」の
  UXがあるので相性は悪くない。ただし SQLite を SAF 上で直接開くのは制約が大きく、
  **一旦アプリ専用領域へコピー→編集→書き戻し**などの実装変更が要る（設計インパクト大）。
- **段階戦略**：まず内部テスト/クローズドテストで申請 → 審査フィードバックを見てから
  本番判断。全ファイルアクセスが通らなければ SAF 移行を別タスク化。

> この §8 は「動画がダメだった時」ではなく「権限自体が却下された時」の話。
> 動画・宣言を丁寧に作れば承認確率は上がるが、100%ではない点は認識しておく。
