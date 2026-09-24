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

## プレイレポート 13 項目（2026-09-12・松本の所感）

検討の全文は Vault `K-Maps/プレイレポート対応_2026-09-12.md`。ここは実装の帳簿。

- [x] 写真の情報カードにも Google Maps リンク（2026-09-12）
- [x] 日本語なのに英語が残る（2026-09-12: 全部 slang に。残っているのは `!kReleaseMode` の開発節と TruPulse のシリアル記法だけ）: ドロワーの開閉 tooltip・通知（Notifications / Mark all read / Clear all / Just now）・`Add`・
      ルート `Home`・ドロワーの移動/改名メッセージ・インポート/エクスポートダイアログ全部・描画の Undo/Cancel/Confirm・
      設定のグローバルフォルダ/自動同期・**スタイル画面**（節名で分岐しているので先にキーを enum に）・TruPulse 画面全部
- [x] 🐛 `.qgs` のラベル: `{a} / {b}` を `fieldName` にそのまま書き `isExpression="0"`（複数列のラベルが QGIS で壊れる）→ 式として書き、読み戻しも（2026-09-12）。
      読み戻しもラベルを見ていない
- [x] GPS 軌跡の区切り（2026-09-12: 10 分以上空いたら `日付 #n` の新しい区間。⚠実機での日跨ぎ・再起動の確認は未）: 暦日だけで区切り、起動時に今日の線へ末尾追記するので別の場所で開くと直線で繋がる。
      10 分以上空いたら／`stop()` で新しいフィーチャ（名前は `2026_09_12 #2`）。点ごとの時刻は details に残っている
- [/] 🐛 ポイントを削除したときだけフィーチャが残る（松本: Pixel の消しゴム、再起動で消える）→ Pixel 9 debug ではタップ消しゴム・ドラッグ消しゴムとも再現せず。消しゴムだけにあった「dispose 前の更新トリガ」で 2 本の `updateFeaturesImpl` が並走し古い結果が後勝ちしうる筋を潰した（トリガ撤去＋世代で古い実行を捨てる、2026-09-12）。再発したら報告を。
      経路は「選択解除 → dispose（DB 削除待ち）→ 更新トリガ → rebuildAll → 静的シーンのキー変更 → GPU バッファ作り直し」で点固有の分岐は見当たらない
- [/] 🐛 断層再発（2026-09-12: 近似の隣の縁は借りない＋`[3D] seam` ログを入れた。再発したら座標とズームを）→ 縁を借りるとき自分の縁との差が閾値超なら `[3D] seam` ログ、隣が近似で自分が本物なら借りない、
      デバッグの段差表示。近似は親 5 段まで（再帰ではないが「近似の近似」は起きうる）
- [x] ラベルを QGIS の式の部分集合に（2026-09-12。`label_expression.dart`、スタイル画面のラベル節、充足率順のチップ、式の直接編集）（`"列"`・`'文字'`・`||`・`concat`）。旧 `{列}` は読み込み時に変換。
      `.qgs` は `isExpression="1"` で書き、読み戻す。ヒントチップ（1 レイヤ: 充足率順／全体: 頻度順）。
      組み立てダイアログをスタイル画面のラベル節へ（レイヤ／View 共通、線・面にも出す）。属性テーブルのボタンはショートカットに
- [x] View のスタイルを項目ごとの合成に（2026-09-12。差分だけ保存・「レイヤに従う」）（今は `view.style ?? layerStyle` の丸ごと差し替えで、一度触った View はレイヤに追従しない）。
      スタイル画面は View モードで差分だけ保存、「レイヤに従う」へ戻せるように。`.qgs` も同じ合成で
- [x] CLI / URL 起動（2026-09-12、Pixel 9 で open / カメラ / reload を確認。[[docs/technical/cli-launch]]）: `/map?project=&lat=&lon=&zoom=&bearing=&pitch=` と `reload`（`onNewIntent` / `hashchange`）、
      地図メニューに「再読み込み」（`initializeProjectTree` 再実行）、`tool/kokage.py open|reload`
- [x] View が既定 1 枚でも行を出す（2026-09-12、実機で確認）
- [x] レイアウトのスロット化とプリセット（2026-09-12。`MapLayout`、設定「画面の配置」。⚠実機での見た目確認は未）（縦持ち／横長／左利き。情報カードと属性テーブルは下パネルで排他）
- [x] 地形の着色をシェーダで（2026-09-12。設定「地形の見た目」。⚠実機での見た目確認は未）（傾斜・標高 → 色ランプ、ユーザー設定）と DEM からの等高線（marching squares → 線シェーダ）
- [x] 引いた段の焼き込み LOD（2026-09-12、z ≤ 13。⚠実機確認は未）（フィーチャをタイルのテクスチャに描き込む。輪郭省略・クラスタの代わり）

## 改善 15 項目（2026-09-07 夜・松本の指摘）

- [x] レイヤ一覧ボタンを右端に／ツール名フラッシュ／Google Maps はリンクコピー（長押しで開く）
- [x] 起動時のアカウント選択: `attemptLightweightAuthentication()` が Android では One Tap を出す。
      `restoreSessionSilently()`（`authorizationForScopes` だけ）に置き換え。詳細はコミット 7fe0f3f
- [x] 削除したフィーチャの残留: DB 削除を待つ＋レイヤ再読込の条件を「未ロード」に
- [x] 背景地図のボケ固定（拡大フォールバックのキャッシュ焼き込み）と県外キャッシュ不表示（透明PNG 200）
  - [x] 圏外検知を到達性ベースに（2026-09-07 夜）: タイル取得が 3 回続けて失敗したら `isNetworkAvailable` を
        false に落とし（Android は mbtiles 直読みへ切替）、20 秒ごとに 1 本だけ短タイムアウトで試して戻す。
        ⚠ 実機での圏外再現は未実施（インターフェイスありで電波なしの状態を作れない）
- [x] 複数選択（左下ボタン有効時）・集合の情報パネル・消しゴムの集めてから確定
- [x] GPS 情報は常時バーをやめ、現在位置を擬似フィーチャ `CurrentLocationNode` にして選択パイプラインに載せた
      （選択ツールのタップ候補にだけ入る。投げ縄・複数選択・消しゴムの対象外）。情報カードの枠 `InfoPanelCard` は
      閉じるボタン込みで共通化。消しゴムの対象は選択中レイヤだけに戻した
- [x] ラベル: `{列}` テンプレート（`label_template.dart`）・地図描画（点／線／面のシンボルレイヤ）・
      属性テーブルからの組み立てダイアログ。⚠ View ごとのラベル設定 UI は無い（View のスタイルに
      `labelProperty` があれば効く）。ラベルの衝突回避は MapLibre 任せ
- [x] 🐛 release で `filter:` 付きの `addLayer` が `Expression$Converter` の ClassNotFound で落ち、以後のレイヤが全部消える
      （R8 が maplibre_android の式クラスを削っていた）。`android/app/proguard-rules.pro` の keep で修正。
      View 固有スタイル（グループレイヤ）はこの経路を通るので、リリース版では以前から壊れていたはず
- [x] テスター招待の手順書 [[docs/technical/closed-test-invite]]（アドレス一覧なら「アドレスを聞く＋リンク1つ」、Google グループならリンク2つ）
- [/] ベータ案内の隠しページ `kokage-map.sleeptree.jp/beta/`（2026-09-07 松本了承）: `web/beta/index.html` を書いた（2026-09-11 夜。`/about/` と同じ体裁、14 日条件・2 手順・つまずき・報告先）。
      残: 不具合報告フォーム（作成は本人操作）を貼る、テスター一覧のグループ化が審査を通ったら「準備中」の注記を「準備ができました」に書き換える
- [/] **3D 地形モード（`feature/3d-map`・2026-09-08）**: 別画面ではなく「いつもの地図が傾く」。純 Dart（`drawVertices` + 象限走査の painter's algorithm）で
      `lib/core/terrain/`、本体接続は `lib/screens/map_page/widgets/terrain_map_layer.dart`（ツールバーの ⛰）。
      設計の正典は Vault `3D化の詰め_2026-09-07`、実装ノートは [[docs/technical/terrain-3d]]、順1 の設計は [[docs/technical/scene-model]]。
      ⚠ [[docs/technical/3d-map-design]] は旧案（別画面・閲覧専用）で上書き済み
  - [x] 描画スパイク（Pixel 9: 北山村 z14 2x2 で LOD 57fps／全解像度 28fps）、実 DEM（AWS Terrain Tiles）＋地理院タイル合成、面・等高線・遮蔽つきヒットテスト、ゴールデン
  - [x] 本体接続: 3D トグル、カメラの引き継ぎと書き戻し、`TerrainProjection` で選択ツールがそのまま動く、写真・GPS 軌跡・現在位置・パーティ・頂点、pitch スライダ、web でも動く
  - [x] 「常に隙間なく」の検証（2026-09-09）: `TerrainFramePlanner` + シミュレーション 6 本 + 実機ドライブモード（debug・🛣）。
        引いた瞬間の停止（`heightRange` 全点走査 × 描き直し連鎖）・白抜け（穴埋めメッシュ）・メモリ（常駐ワーカー isolate）を解消。
        Pixel 9 で欠けフレーム 0 / 2,650・UI 中央値 5ms
  - [ ] 残り: オーバーレイ画像（GeoTIFF）をテクスチャに焼く／クラスタ／DeviceTool のオーバーレイ／描画プレビュー／
        DEM の dir 同梱と焼き込み CLI（圏外で使えるように）／`SceneSink` / `MapSurfaceController` のインターフェース抽出／web の fps 計測（Chrome を前面に）／
        メモリ削減（profile 実測で 3D の増分 +200〜250MB。画像 LRU・`raw` の畳み込み・親テクスチャ 256²）
  - [x] 3D を正とした UI の前半（2026-09-09）: コンパスタップで北上・真上、ペン／オーバーレイ変換は真上ロックで 3D のまま、
        傾きスライダー撤去、jumpTo を 3D に流す、オーバーレイ画像・TruPulse の線を 3D に載せる。標高は地理院 DEM1A → 5A → 10B → AWS の連なり
  - [x] 1 万面 + 1 万点の負荷（2026-09-09 夜）: profile で UI 中央値 5〜6ms・最大 60〜70ms・停止なし。手法は [[docs/technical/terrain-3d]] の「1 万面 + 1 万点の負荷」。
        ドライブ 4 本連続のソークも停止なし（PSS は 1.4GB で頭打ち。Graphics 600MB は 3D の世界を捨てても残るのでエンジン側のプール。4 分の連続描画で熱で絞られる）
  - [x] 3D 中は MapLibre を空のスタイルにしてタイルとソースを手放す（2026-09-09 夜。ウィジェットごと外すと maplibre_android がネイティブの地図を捨てず往復ごとに 170MB 漏れる）
  - [x] ⚠ maplibre 0.3.5 の Android は地図を create/dispose するたびにネイティブの地図が漏れる（feature_editor の地図も）
        → 2026-09-10 に Flutter 3.47.3 / maplibre 0.3.6 へ更新して解消（地図ページからは MapLibre 自体を撤去済み。残るのは feature_editor だけ）
  - [ ] 3D を正とした UI の後半: 切替ボタンを消して MapLibre を外す（インターフェース抽出と同時）、web のマウス操作の実機確認（右ドラッグ回転でブラウザのコンテキストメニューが出るのは `BrowserContextMenu` で止めた 2026-09-12）、
        web のオーバーレイ画像、クラスタ（引いた段の格子まとめは済み）。カメラ状態は保存しない（松本 2026-09-09。`.kmeta.json` は `.qgs` へ移す方針でもある）
  - [ ] 焼いた DEM タイル（地理院 DEM5A/10B・県点群 DTM）の配布先は **GitHub Releases**（データ用公開 repo 1 つ。認証なし・無料・
        添付の総量上限なし。2026-09-09 決定。Drive は所有者を隠せない）。焼き込み CLI は `tool/`（Vault 11 節 A）
  - [x] 出典表示: 3D 中の地図面左下と、設定 > アプリ情報「地図データの出典」（2026-09-09）
  - [x] flutter_gpu を本体に（2026-09-11）: タイルごとの頂点バッファ・面と線の増分バッファ・深度バッファ。点とラベル・ヒットテストは Dart のまま。
        web は純 Dart 経路が残る。Pixel 9 debug のドライブで欠けフレーム 0・UI 中央値 3〜7ms・raster 3〜5ms。手法と数値は [[docs/technical/terrain-3d]]「flutter_gpu を TerrainWorld に」。
        ミップマップ（isolate で段を作って手上げ）＋ MSAA 4x ＋異方性 4 で回転中のちらつきを止めた（同日昼）。
        線の端を丸く・点を GPU に・複製ができたら `ui.Image` を手放す・陰影は傾斜依存（`TerrainShading`、濃さ 0.6）も同日。
        残: 透視の眺めモード、純 Dart 経路の整理（web にだけ要る）
  - [x] web も GPU（`feature/web-gpu`、2026-09-11 午後）: `package:web` で WebGL2 を直接叩く同 API のレンダラ。スパイク画面の「world GPU」で 801² 回転が 12 → 45〜60 fps。
        地図ページの web も 3D（同日夕）、オーバーレイ画像も web で読む、面・線にも靄。`--wasm` は測って見送り。手法は [[docs/technical/terrain-3d]]「web の GPU」
  - [x] v0.7.0+20 を master へ ff・web を本番へデプロイ（2026-09-11 夕）。release の新規インストールで位置情報の許可直後に落ちるバグ（`getBondedDevices`）も同時に修正
  - [x] v0.7.0+20 を Play のクローズドテスト（alpha）へ送信（2026-09-11 20:40、審査中）。署名済み AAB（106MB、`259e406`）を Surface で組み
        `play.py upload --track alpha --name 0.7.0+20 --apply`。⚠ 106MB の AAB は API のソケットが 98% で時間切れになることがある →
        `socket.setdefaulttimeout(1800)` を掛けたラッパから呼ぶ（Surface の `C:/Users/mtmtk/play_upload.py`）
  - [x] ストアのスクショを 3D の新 UI で撮り直した（2026-09-11 21:40、ja-JP 5 枚差し替え・審査中）。Pixel 9 の 1080×2424 は上下を切って 1080×2160（Play の 2:1 上限）。
        原本は Vault `google play console/store_shots_2026-09-11/`
  - [x] DEM の取得を速くした `d6e3a5a`（主力ソースを同時に取る・AWS は最後の砦・1 段上の親を先に・http.Client 使い回し）:
        Pixel 9 debug のドライブ 48 秒で欠けフレーム 0・寄せる最中も理想の段が 1.5 秒以内 → master へ ff・web デプロイ（2026-09-11 夜）
  - [x] 3D を正とした UI の後半 ①（2026-09-11。決定: 長押し割り当てなし／pitch 上限 75°／起動時は真上）: Android / desktop は起動から 3D（真上）、
        切替ボタンは web だけ、MapLibre は空のスタイルで組む、`RMapController.jumpOverride` で移動系を 3D に流す（起動時の現在位置ジャンプ含む）
  - [x] 3D の間は MapLibre を組まない（2026-09-11 昼。Android / desktop はネイティブの地図を持たない。web は 3D を抜けたときに組み直す）
  - [x] 眺めモード（透視投影、2026-09-11 昼）: コンパス長押しで切替、靄と空、視線なぞりのヒットテスト。手法は [[docs/technical/terrain-3d]]「眺めモード」
  - [x] web も起動から 3D（2026-09-11 昼。Surface の Chrome で 401² LOD 静止 59fps・801² 回転 LOD 43fps）
  - [x] web が起動時に真っ白（DeferredNotLoadedError）: slang_build_runner は build.yaml の options しか読まない → `build.yaml` に `lazy: false`（2026-09-11）
  - [x] **MapLibre を地図ページから撤去**（2026-09-11 午後、松本「もちろん外すけど」）: `MapSourceManager` / basemap・overlay mixin /
        party・overlay の `ml.Layer` ビルダー / DeviceTool の `buildOverlayLayers` `buildOverlayMarkers` / `Terrain3dMode` provider / ⛰ を削除。
        `MapStyleGroup` と `kStyleProp` は `lib/models/map_style_group.dart` へ。View 固有スタイルは `MapPageStateBase.styleGroups`。
        MapLibre が残るのは feature_editor の地図と `RMapWidget` / `RMapController` の attach 部分だけ（feature_editor 用）
  - ⚠ release の APK は `--no-pub` を付けずに組む（2026-09-11）。debug の `flutter run` の後に `--no-pub` で release を組むと
    `GeneratedPluginRegistrant.java` が dev 依存（integration_test）入りのまま残り、`compileReleaseJavaWithJavac` で落ちる
  - ⚠ release の署名: `android/key.properties`（master 側の checkout に在る。gitignore）の `storeFile=../k-maps-release.keystore` は
    **`android/app` 基準**なので鍵は `android/k-maps-release.keystore` に置く（repo 直下だと `validateSigningRelease` で落ちる）。
    鍵の正本は Vault `事業/ねむりぎ工房/K-Maps/google play console/`。worktree を増やしたら両方コピーする
  - [x] release で 3D（GPU・眺めモード・ヒットテスト）と web release の起動を確認（2026-09-11 13:05、Pixel 9 / Surface Chrome）
  - [/] 眺めモードの残り: 面・線の靄は入れた（2026-09-11 夕）。残るのは純 Dart 経路（web の GPU 無し環境）の透視。2 本指の移動・拡縮・ホイールは透視の式にした（指の下の地面を留める。実機のピンチは未確認）
  - [x] v0.7.2+22 を release（2026-09-13）: master ff・web デプロイ・Play alpha へ送信。Pixel 9 はネット無しだったので実機は新規インストール → 権限 → SAF → 地図ページ → 眺めモードの生存確認まで（地形の描画は 9/12 の debug で確認済み）
  - [x] web の `#/map?...` hashchange で「Null check operator used on a null value」（v0.7.2 の release で発覚、v0.7.1 には無い）: `/map` を routes から外した副作用。
        `_RootMapsAppState.didPushRouteInformation` で `/map` を飲み込む（MaterialApp のオブザーバより先に登録される）。要求は `LaunchRequest` の hashchange 側が拾う（2026-09-13）
  - [x] web の「地図を開く」（picker 無し）で地図が真っ白だった件: master の web-server ビルドを 127.0.0.1 で `showDirectoryPicker` を消して再現を試みたが、地形も基図も出た（2026-09-13）。index.html を差し替えた静的配信の副作用とみて閉じる
- [ ] 更新履歴の運用: v0.6.0 以前の節も開発ログ調のまま。読み直すなら v0.6.0 節から

## Android のビルド環境（2026-09-11 夜）

- [x] **AGP 9.1.0 / Gradle 9.3.1 / Java 17 / Kotlin 2.4.0**（Flutter 3.47 のテンプレ構成。`android.newDsl=false` `android.builtInKotlin=false` はテンプレと同じ opt-out）。
      debug / release を Pixel 9 に新規インストールして起動・SAF のフォルダ選択・3D（GPU）まで確認
  - `flutter_bluetooth_serial` 0.4.0 は build.gradle が `jcenter()` と AGP 4.1 の buildscript を持ち Gradle 9 で評価に失敗
    → `third_party/flutter_bluetooth_serial/` に写しを置き build.gradle だけ現代化、`dependency_overrides` で差し替え。
    ⚠ 写しの pubspec の sdk は `>=2.12.0 <3.0.0` のまま（3.0 に上げると `StreamSink` の継承がクラス修飾子で落ちる）。上流には出さない
  - file_picker 11 / device_info_plus 13 は「AGP 9 なら Kotlin は組み込み」と決め打ちして KGP を当てないので、
    opt-out 中は Kotlin が一切コンパイルされず `GeneratedPluginRegistrant` がクラスを見つけられない
    → file_picker は 12.3（federated。`android_file_picker` は property を見る）へ、それでも残る分は root の `build.gradle.kts` で
    「builtInKotlin=false のとき、Kotlin ソースを持つのに KGP が無いライブラリにこちらから KGP を当てる」橋渡し（`kotlin.jvm.target.validation.mode=warning`）
  - file_picker 12 の API 移行: pickFiles は List、`identifier` → `uri`、`path` は file:// のときだけ、`saveFile` は bytes 先渡し
    （エクスポートは一時フォルダに書いてから保存ダイアログ。Shapefile の組は zip）。エクスポート（release、SAF の保存 → zip に shp/shx/dbf/cpg/prj）とギャラリー取り込み（Photo Picker → content:// → プロジェクトフォルダに複製）を Pixel 9 で確認済み（2026-09-11 23:10）
- [ ] Flutter の警告「KGP を当てるプラグイン（desktop_drop / firebase_* / location）は将来ビルドできなくなる」→ プラグイン側の更新を待って上げる。
      `android.builtInKotlin=true` にできたら root の橋渡しは外す

## リファクタリング（2026-09-07）

> ここ1か月で内部を大きく変えたあとの棚卸し。各段で analyze 0 件・unit テスト green を確認してコミット。

- [x] 到達不能コードの削除 32 ファイル（約 1.3 万行。旧エクスポータ `lib/converters/`・`DialogManager`・
      旧 Drive ダイアログ・`metadata_parser`・`layer_migration_service`・`tile_cache_geopackage` 等）。
      判定は import 追跡＋クラス名検索の両方。`@Deprecated` 5 件、未使用依存 3 件、追跡していたツール出力も除去
- [x] `KMetaService.getMergedMeta` → `getMeta`（継承チェーン廃止後の名残。マージ用キャッシュも撤去）
- [x] `map_page.dart` 1931 → 1104 行。GeoJSON 組み立て `FeatureGeoJsonCache`（通常／選択の二重実装を一本化）、
      `turf_geo_convert.dart`（純粋関数＋テスト）、`MapBasemapMixin` / `MapOverlayMixin` / `MapStyleMixin`、
      `widgets/party_map_layers.dart` / `widgets/overlay_image_layers.dart`
- [x] 座標系モジュールの三重化を解消。EPSG 表は `EpsgRegistry` だけ、`CoordinateConverter`（843 行）削除
- [x] lint 強化（`analysis_options.yaml`）＋ `dart fix` 422 箇所。`unawaited_futures` 30 箇所は個別判断
- [x] discontinued の `flutter_markdown` → `flutter_markdown_plus`
- [x] 実機確認（2026-09-07・Pixel 11 Pro Fold）: `map_contract_test` 9 件 green。選択ハイライト（点・面）・
      画面外矢印のジャンプ・ベースマップ切替・更新履歴画面・パーティのダイアログを一巡、Dart 例外なし。
      ⚠パーティの実ルームとオーバーレイ画像の変形は実データが無く未確認
- [x] `avoid_dynamic_calls`（54 件）を型付けして lint を有効化（2026-09-11 夜）。残す 1 件は `terrain_worker_io.dart` の isolate 境界（型を消して運ぶ設計）で ignore
- [ ] 残った候補: `cascade_invocations`（411 件・好みの問題なので保留）、
      `map_page.dart` の `build`（161 行）と `_buildMapLibreMap`（109 行）、`shapefile_exporter.dart`（914 行）、
      `settings_screen.dart`（1168 行）、`import_export/` の `SmartCoordinateSystemManager` の WKT 推定を `WktParser` へ寄せる

## 正典を `.qgs` に移す（2026-09-06・設計済み・未着手）

> 設計は [[docs/technical/project-format-design#正典を `.qgs` に移す（2026-09-06 決定・設計）]]。
> `.kmeta.json` をやめ、dir ごとの `<dir名>.qgs` を正典にする。子 dir は QGIS の
> 埋め込み（`embedded_project`）で親に載せ、統合版は派生物としてだけ書き出す。

- [x] 🐛 **段0: `.qgs` のレイヤ id が web と native で一致しない**（2026-09-06 修正）。
      `stableHashHex()`（`lib/utils/stable_hash.dart`・MD5）に替えた。⚠ 既に書き出した `.qgs` の id は変わる
      （次の書き出しで旧 id のレイヤは「無くなったレイヤ」として外され、新 id で足し直される）
- [x] 🐛 **段0: 同名 gpkg が root とサブ dir にあるとレイヤ id が衝突**（2026-09-06 実機のデモデータで発見）。
      `viewKey` に dir が無いのが原因。id のハッシュに gpkg の相対 dir を混ぜた（`layerIdForViewKey(dirPath:)`）。
      衝突版が書いた `.qgs`（同じ id の maplayer が2つ）は、次の更新で `QgsDocument` が2つ目以降を畳む
- [x] 段0-b（2026-09-06）: 同期の帳簿（`files` / `lastSynced` / `driveRevisionId` / `deviceId`）を
      `SyncLedger`（SharedPreferences・キーは driveId かパスのハッシュ）へ。共有ファイルにはリンク情報4項目だけ。
      旧版が書いた帳簿は初回ロードで引き取って共有ファイルから剥がす。継承チェーンは廃止
      （`getMeta` は自フォルダのメタデータを返す。2026-09-07 に `getMergedMeta` から改名し、マージ用キャッシュも撤去）
      - [ ] ⚠ Drive 同期の通し確認は未実施（本セッションは Drive にサインインしていない）
- [x] 段1: DOM 保持型 `QgsDocument`（2026-09-06）。`lib/services/qgis/qgs_document.dart`。
      QGIS 3.44 のフィクスチャで往復テスト 13 件（`test/qgs_document_test.dart`）:
      未知の最上位要素・maplayer 内要素・ツリーの customproperties が残る／参照とフィルタは直る／
      単一シンボルは色だけ差し替え／単一シンボル以外は触らず報告／無いレイヤは外して報告／
      埋め込み（`embedded="1"`）は残す／印の往復と「最後に書いたのは自分か」
  - [x] **書き出しを DOM 保持型の更新に切り替え**、ファイル名を `<dir名>.qgs` に
        （`project.qgs` が残っていれば改名して引き継ぐ）。印を書く。
        手動の書き出し／取り込みメニューはその後撤去（`qgs_export_action.dart` 削除）
  - [x] **自動更新**（2026-09-06）: `.kmeta.json` が保存されるたびに root の `<dir名>.qgs` を
        3秒デバウンスで DOM 保持型更新する（`QgsAutoRefresh`）。Drive push と手動書き出しの前に flush。
        `.kmeta.json` が正典のまま、QGIS から見える状態を常に最新にする途中経過
  - [x] ⚠ QGIS での実開封（2026-09-12、開発機に QGIS 4.2.0 を入れて headless で確認）。
        「QGIS で保存 → アプリで DOM 更新 → QGIS の pipe / projectCrs が残る」「アプリで読み戻し → subset と消灯が入る」まで。
        副産物: gpkg の `user_version` を sqflite が 1 に潰していたのを修正。詳細は [[docs/technical/qgis-interop]]
- [ ] 段2: `KMetaService` の裏を `QgsDocument` に差し替え（`KMeta` モデルは残す。35ファイルの呼び出し側を動かさない）
- [/] 段2（実用形・2026-09-06）: **QGIS 側で保存された `.qgs` をプロジェクトを開いたときに読み戻す**
      （`QgsReadBack`。印と `saveDateTime` の不一致で判定 → 寛容インポータで View・スタイル・可視性を取り込み →
      自動更新で正規化＋印つきに書き戻す）。`.kmeta.json` は残しているが、書きは自動更新・読みは読み戻しで
      両方向が繋がったので、利用者から見れば `.qgs` が正典。`KMetaService` の裏を差し替える完全形は未着手
  - [x] 実機（Fold）で確認: QGIS 保存を模した `.qgs`（`saveDateTime` を進め、レイヤを Unchecked）を置いて
        開き直す → `[QgsReadBack] ... 取り込む` → View 3 件取り込み → 印つきで再生成。
        可視性の読み戻しは2点直した: ①既定 View 1枚のレイヤは可視性をレイヤ側に持つのに
        インポータが View 側にしか書いていなかった ②QGIS でグループごと消灯した場合に備え、
        祖先グループの checked を AND で畳む
- [/] 段3（2026-09-06）: 展開状態（`layer-tree-group@expanded`）と簡易ラベル（`labeling type="simple"`・
      `labelsEnabled`）を出力。DOM 更新では `text-style` の管轄属性だけ差し替え、ルールベースは触らない
  - [x] ラスタ化オーバーレイ（GeoTIFF を `maplayer type="raster"` で）→ 2026-09-11 夜に実装（上の「オーバーレイ画像をラスタレイヤとして書く」）
- [x] 段4（2026-09-06）: 自分の `.kmeta.json` を持つ子 dir は独立した `<dir名>.qgs` を持ち、親には
      `embedded="1" embedded_project` のグループと `<maplayer embedded="1">` スタブで載せる。
      読み戻しは子 dir も辿る。インポータは埋め込みスタブを飛ばす
  - [ ] 平坦化版（1枚に展開した派生物）の書き出しは未着手
- [/] 段5（2026-09-06）: `*.qgs` を Drive 同期の対象に追加（既存の「新しい方が勝つ／衝突コピー」で扱う）
  - [ ] レイヤ単位の 3-way マージは未着手
- [/] 段6（2026-09-06）: `.qgz` 読み（`archive`）・壊れた `.qgs` の `.bak` 退避・外したレイヤの報告
  - [ ] `.kmeta.json` → `.migrated` の移行は、段2 の完全形と一緒に
- [ ] 段7: 「QGIS で設定されたスタイル」の読み取り専用 UI（未着手。いまは分類レンダラを触らないだけ）
- [ ] 未決: dir 改名が Drive 越しに届いたときの追従／埋め込み3階層以上の実測／web の `.qgs~` リネーム

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
  - [x] 🐛 **View を hide してもフィーチャが地図から消えない**（2026-09-01 実機で確認）→ **修正（2026-09-11 夜）**: 下の見立てどおり
        `updateChildren()` の二重実行ガードが進行中（古い WHERE）の Future をそのまま返していた。進行中なら終わってからもう一度読む形に
        （`_rerunRequested`。待ち手が何本いても読み直しは 1 回）。`test/view_hide_reload_test.dart` 3 本で固定。実機確認は未
        - 当時の見立て（残しておく）:
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
  - [/] **グローバルフォルダを共有ストレージへ（2026-09-06）**。アンインストールで GPS 軌跡が消える
        （debug/release の行き来のたびに失う）のを止めるため、Android の既定を
        `Documents/KokageMap/Global` に変更。`GlobalFolderLocator.resolve()` が
        場所決め・書込プローブ・旧 `k_maps_global` からの移行（コピー→旧を `.migrated` に改名）を担う。
        共有ストレージが使えなければ内部領域へ退避して警告。カスタムパス設定はそのまま優先
        - 不採用: `applicationIdSuffix` での debug/release 共存（Firebase・OAuth・ディープリンクが割れる）、Auto Backup
        - [x] 実機で移行を確認（2026-09-06、Pixel 11 Pro Fold・release 0.6.0+16 → 0.6.1+18 上書き）。
              `gps_history.gpkg` ほか2ファイルが `Documents/KokageMap/Global` へ移り、GPS記録もそこで再開。
              2回目起動では移行が走らない（旧側は `.migrated` に改名済み）ことも確認
  - [x] **画面外の現在位置を指す矢印**（2026-09-05）。現在位置が見えないとき、地図の縁に
        方向を示す三角矢印を出す。タップで現在位置へジャンプ。ドロワーに隠れた範囲は
        「見えていない」扱い（`OffscreenLocationIndicator` / 幾何は `edge_indicator_geometry.dart`、
        ユニットテストあり）。ジャンプ処理は `MapJumpMixin.jumpTo()` に集約し、起動時の
        現在位置ジャンプ・ドロワー/属性テーブルからの移動も同じ経路に載せた
        - [x] 実機確認（2026-09-06、Pixel 11 Pro Fold）。見つけて直した2件:
              ①ドロワーを開いたまま矢印をタップすると**ドロワーの真下に着地して矢印が消えない**
              → `jumpTo()` が `jumpObscuredInsets`（ドロワー幅）を除いた見える範囲の中心に寄せるようにした
              （投影で画面座標をずらす。ズーム変更時は 2^(from-to) で画素換算）。起動時の現在位置ジャンプにも効く
              ②矢印が下端に出ると**左下の LeftBottomFab に潜ってタップが取られる**
              → 縁インジケータの見える範囲から下 96px を除外（`_bottomButtonsInset`）
  - [x] 🐛 **自己位置マーカーが点・短いラインを隠す**（2026-09-01 実機で確認）→ 3D の現在位置の点を半透明（alpha 0.55）に（2026-09-11 夜）
  - [x] 🐛 **レイヤにズームする導線が無い**（2026-09-01）→ レイヤの ⋮ に「レイヤへ寄せる」を足した（行のダブルタップと同じ `_zoomToLayer`。2026-09-11 夜）
  - [x] 🐛 **ホーム画面から地図へ戻る導線が無い**（2026-09-02）→ 「選択されたフォルダ」のカードをタップで `_openProjectDir` を通して開き直す（2026-09-11 夜）
  - [x] 選択モードで地図をタップすると**フィーチャ情報のポップアップが画面に居座る**（2026-09-02）→ 2026-09-07 の `InfoPanelCard`（閉じるボタン込みで共通化・1 枚だけ）で解消。2026-09-11 の実機でも 1 枚で × で閉じられることを確認
- [/] **`.qgs` ライター** — dir/gpkg/layer をレイヤグループ、View をレイヤとして出力
  - [x] 実装（`lib/services/qgis/`）。~~書き出し導線は 地図の ≡ メニュー と
        フォルダのメニュー~~ → 2026-09-06 に手動メニューを撤去。自動追従（`QgsAutoRefresh`）と
        開いたときの読み戻し（`QgsReadBack`）だけ
  - [x] **QGIS 3.44.12 で実開封を確認**（2026-08-26）。相対パス解決・subset適用
        （12→6）・レンダラ読み取り・グループ構造すべて意図どおり。
        手順は [[docs/technical/qgis-interop]]、確認スクリプトは `tool/qgis/`
  - [x] Drive push の直前に自動生成する → `QgsAutoRefresh.flushNow()`（2026-09-06）。
        それ以前にメタデータ保存のたびに追従しているので、push 時は待ちの消化だけ
  - [x] オーバーレイ画像（GeoTIFF）をラスタレイヤとして書く（2026-09-11 夜）: `QgsRasterLayer`（gdal・参照だけ、レンダラは QGIS 任せ）。DOM 更新でも足す・直す・外す。
        写真と GeoTIFF でないオーバーレイは従来どおり報告して外す。QGIS 4.2.0 で実開封を確認（2026-09-12、ラスタ valid・EPSG:4326・範囲一致）
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
    - [x] 本番ドメイン `https://kokage-map.sleeptree.jp` を承認済み JavaScript 生成元に追加済み（[[docs/technical/web-hosting]] の OAuth 生成元。2026-08-28）
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
    - [x] 🐛 その入口（`#/map` 直開きも同じ）でレイヤ一覧から GeoPackage を作れてしまい、IndexedDB にだけ残る幽霊になった
          → `/map` はホームから始める・パスを解決できないフォルダでは追加ボタンを出さない（2026-09-12）
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
  - [/] **追加修正（2026-09-05）: 「座標が消える」が再発した報告を受けて**
    - 上の修正は **全ファイルアクセスが許可されている前提**だった。無いと実パスは
      「読める」がFUSEでリダクションされ、それを成功扱いして黙って位置情報が消える。
      再インストール直後（debug/release の行き来）で権限が未許可のときに当たりやすい
    - `copyOriginal` の戻りを `"original"` / `"maybe_redacted"` / null に変え、
      第2経路として `ACCESS_MEDIA_LOCATION` + `MediaStore.setRequireOriginal()` を追加。
      取り込み前に全ファイルアクセスが無ければ `photos` + `accessMediaLocation` を要求
    - `maybe_redacted` かつ位置情報が取れなかった写真があれば通知で枚数と対処を出す
      （ログは `[GalleryImport] <file>: copy=... location=...` と logcat `MediaCopy`）
    - [x] 実機確認（2026-09-06、Pixel 11 Pro Fold・Android 17）: 全ファイルアクセスONで
          Photo Picker 経由の取り込み → `copy=original location=true`、コピー先の EXIF に GPS が残っている
          （`PXL_20260811_082358800.jpg`）
    - ℹ **「全ファイルアクセスOFF」の経路は Android 11+ では実質到達できない**。appops で権限を
          落とすとアプリが即 kill され、再起動後はホーム画面の権限ゲートでプロジェクトを開けない。
          第2経路（ACCESS_MEDIA_LOCATION）と警告通知は、クラウド専用写真など「原本が読めない」
          ケースの保険として残す
    - [ ] 🔴 **再現条件が未確定**。今回の端末では消えなかったので、報告された「座標が消える」は
          ①別の操作（写真→オーバーレイ変換は地図中心に置く仕様）②クラウド専用写真
          ③Android のバージョン差 のどれか。次に再現したら logcat の `MediaCopy` と
          `[GalleryImport] <file>: copy=... location=...` を控える
    - [ ] 「地図に追加」がギャラリー取り込み以外の操作（写真→オーバーレイ変換など）なら別件。
          オーバーレイ変換は仕様として地図中心に置いている（`photo_tile.dart`）

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
  - [x] **OAuthデモ（Google Sign-In → Drive スコープ同意 → Driveクローン/同期）を撮影・編集済み**（2026-09-03）
        成果物 `.temp/play-demo/kokage-map_oauth-demo.mp4`（167秒・1080x2342・英語字幕）。
        Pixel 11 Pro Fold の実機・端末言語 English・未同意アカウントで撮った（未同意なら Play開発者サービスでも
        スコープ同意画面は出る。9/1の「出ない」は既同意アカウントで見た誤り）。
        ⚠ 同意画面のアプリ名が **「ねむりぎ工房」**（GCP nemurigi-kobo の OAuth 同意画面設定）。検証申請前に
        Kokage Map へ変えるか説明するか決める
  - [x] 🐛 **初回起動時、オンボーディングより前に Google の「Sign in with Google / Choose an account」シートが出る**
        （2026-09-03 Fold で確認）→ 2026-09-07 の `restoreSessionSilently()` 化（`attemptLightweightAuthentication` をやめた）で解消。
        2026-09-11 夜に Pixel 9 へ release / debug を新規インストールして確認: オンボーディングの前後とも Google のシートは出ない
  - [x] 🌐 `drive_url_input_dialog` の「Driveフォルダを追加」「URL入力」「QRスキャン」が未翻訳 → `t.driveUrlDialog.*` に（2026-09-11 夜）
  - [ ] ~~カメラ: 写真マーカー撮影、QRコードスキャン~~ → 宣言フォーム対象外なので撮らない
  - [ ] ~~Bluetooth: TruPulse測量機器との接続・データ取得~~ → **撮らない**（2026-09-01）
        「近くのデバイス」（`BLUETOOTH_SCAN`/`_CONNECT`/`_ADVERTISE`）は制限付き権限ではなく、
        Play Console に宣言フォーム自体が無い（用途記載のみ）。OAuth検証もDriveスコープの話で
        BTは無関係。⚠ エミュでの代替は不可（AVDにホストのBTは通らない・rootcanalは
        emulator↔emulator専用）。そもそも提出動画は実機の実動作のみでモック不可
- [x] YouTubeに限定公開でアップロード（2026-09-04。権限 `2F6B51H4DYs`／OAuth `R22vltqCmt4`）
- [/] Play Console各権限セクションにリンク登録（2026-09-04 済み）。GCP データアクセスページは OAuth 検証（資金調達後）のとき

**ストア掲載情報**

- [x] アプリ名・短い説明・詳しい説明（2026-09-04。`play.py listing` で更新できる）
- [x] スクリーンショット（2026-09-11 に 3D の新 UI で 5 枚に差し替え。`play.py images`）
- [x] アプリアイコン・フィーチャーグラフィック（掲載済み。ja-JP の featureGraphic 1 枚を API で確認）
- [ ] カテゴリ設定（ツール or 地図＆ナビ）— Play Console で要確認
- [x] 連絡先情報（`k-root@googlegroups.com`）

**クローズドテストトラック**

- [x] トラック作成・テスターリスト登録（クローズドテスト alpha。テスターは Google グループ方式、[[docs/technical/closed-test-invite]]）
- [x] AABアップロード・リリースノート入力（0.6.0+17 → 0.7.0+20 まで `play.py upload`）
- [x] ロールアウト・参加リンク共有（招待手順は [[docs/technical/closed-test-invite]]。残: テスター 12 人 × 14 日 → 本番アクセス申請）

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

- [/] 行単位マージを geodiff で（設計は [[docs/technical/drive-geodiff-sync]]。ops.log 案は取り下げ）
  - [x] 段1: `libgeodiff.so`（arm64-v8a）と `geodiff.dll` を焼く（2026-09-18。vcpkg 無し、`third_party/geodiff/`）。Pixel 9 で version 2.3.1
  - [x] 段2: `lib/services/geodiff/`（ffi + web stub）とテスト（ホスト VM 4 本・実機 2 本、2026-09-18 通過。web ビルドも通る）
  - [x] 段3: base の保持（`.sync/base/`）と `executeMerge()` の `MergeChoice.merge`（2026-09-18）。
        push/pull/merge で gpkg を上げ下ろしした直後に `SyncBaseStore.saveBase()`。`.sync/` は scan・push・pull の削除・空フォルダ掃除・レイヤツリーから除外。
        自動同期は両方 modified の gpkg で base があれば merge を選ぶ。手動の同期ダイアログは merge を既定にして端末／クラウドも選べる。
        衝突（同じ行・同じ列）はローカル優先で `conflict.json` → 通知（テーブル・fid・クラウド値→端末値）。
        ⚠ `executeMerge` の merge 枝は単体テスト無し（`GoogleDriveService` が private ctor のシングルトンで fake を差せない）。`GpkgMerger` / `SyncBaseStore` は `test/gpkg_merger_test.dart` で 6 本
  - [x] 段4: 接続を閉じてから geodiff に触らせる（`GeoPackageConnection.closeAllFor`）、rebase 後の rtree・範囲の焼き直し（`GpkgIndexRepair`）、
        同期後に読み込み済みレイヤのフィーチャを読み直す（`GeoPackageNode.reloadLoadedLayers`。既存の上書きダウンロードでも古いまま残っていた）（2026-09-24）
  - [x] 🐛 リモートの変更判定が Drive の時刻と端末の時計の比較で、端末の時計が進んでいると相手の変更を見落として上書きしていた
        → 帳簿に `remoteModifiedTime` を持ち Drive の時刻どうしで比べる（2026-09-24、偽 Drive で再現→修正）
  - [x] 段5（偽 Drive）: Pixel 9 + Fold の 2 台で往復（`tool/sync_relay/run_two_device.sh`、2026-09-24 通過）。ホスト VM と実機 1 台で同じ 6 本
  - [ ] 段5（本物の Drive）: 2 台とも Drive にサインインして手で往復（人の手が要る）
  - [ ] ⚠ `SyncLedger` のキーが `drive:<driveId>` なので、1 台で同じ Drive フォルダを 2 つの dir にクローンすると帳簿が衝突する
  - [x] Android の SQLite に rtree が無いので、`GpkgIndexRepair` は rtree を geodiff の SQLite で書く（`Geodiff.execSql`、2026-09-24 実機で確認）
  - [x] 🐛 同じ理由で、既存の `SpatialIndexManager.updateRTreeIndex` と `QgisInterop.updateContentsBounds` が Android では効いていなかった
        （QGIS 製の gpkg を Android で編集すると、足した地物が QGIS の空間索引に載らない。実機で再現）
        → `GeoPackageFile.dispose()` の最後に `GpkgIndexRepair.rebuildFile()`（2026-09-24、実機で緑）

#### MapLibre

- [x] ~~3D terrain有効化（RasterDemSource + setTerrain + pitch/tiltコントロール）~~ → MapLibre の terrain ではなく自前の 3D 描画系で実現（v0.7.0、`feature/3d-map`）
- [x] ~~国土地理院DEMタイル → Terrain-RGB変換の実装・検証~~ → 変換せず地理院の標高 PNG を直接読む（DEM1A → 5A → 10B → AWS の連なり）
- [x] ~~Flutter SDKアップグレード（3.10+）→ maplibre_webview導入（Windows対応）~~ → Flutter は 3.47.3。maplibre_webview と Windows 版は 2026-08-25 に撤去
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
- [x] ポイント詳細情報からGoogle Mapリンクをコピーする機能（2026-09-07 の改善 15 項目「Google Maps はリンクコピー（長押しで開く）」）
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
