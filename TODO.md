# TODO

> 2026-10-04 に棚卸しした。開いている項目だけを置く。それまでの帳簿（経緯・完了の記録・当時の見立て）は
> [[docs/history/TODO-2026-10-04]] にそのまま残してある。完了したものはここから消し、記録は git と docs に任せる。

## 次にやる（実装）

- [ ] **GDAL 統合のまとめての実機確認**（2026-10-09〜10 に入れたもの。途中では確かめず最後に 1 回。Pixel 9 で、Fold は使わない）
  - 2026-10-11 Pixel 9 で済んだもの（テスト用アプリ `com.k_root.k_maps.gdaltest` を並べて入れ、`/sdcard/FieldSurvey/GdalCheck` に test/fixtures/gdal を置いた）:
    gdal_smoke_test 全通過（初回 172ms・12 ドライバ往復・Shift_JIS・ラスタ）／shp（.cpg あり・なし）・GeoJSON・KML・CSV が読み取り専用で出て件数が合い、
    端末で作ったキャッシュで Shift_JIS が読めて EPSG:6674 のまま／点と 6674 の GeoTIFF が地図で同じ位置に重なる／外部ラスタ 6 枚がオーバーレイに（PNG 作成 20〜60ms）／
    KML →「gpkgに変換」で points.gpkg ができ元が消える。直した実機だけの不具合: GDAL の初回呼び出しが必ず落ちる・CSV のキャッシュが srs 99999・
    変換の照合が `android_metadata` 表で必ず止まる
  - 2026-10-11 午後に済んだもの: KMZ・GPX・型の混ざった GeoJSON・Z 付きの shp・2 万面の shp（キャッシュ作り約 2.5 秒・UI 止まらず）・タップで選べる・
    編集で「読み取り専用」の通知（変換ボタンは通知センター側）→ 変換 → 頂点を動かして保存・改名で付属ファイルが動く・削除でファイルとキャッシュが消える・
    外部ラスタは位置合わせ不可で通知・外部ラスタの削除で .pgw/.aux.xml まで消える・位置の無い画像は写真のまま・
    書き出し（shp の zip に UTF-8 の .cpg、.prj は JGD2011 VI 系のまま、一時ファイルが残らない）・「ファイルを追加」（SAF）・
    移して空になった gpkg が消える・改名後に .qgs が 6 秒以内に追従・Pixel 9 で書いた .qgs を QGIS 4.2.2 で開いて全レイヤ valid・件数と CRS が合う。
    release APK（3 ABI）183 MB（GDAL 前より約 +57 MB。Play の ABI 別配布では arm64 のダウンロード約 +10 MB）。
    見つけて直した: Z が落ちる・GPX の空レイヤ・.cpg のある shp が QGIS で化ける（.qgs に UTF-8 と書いていた）・変換/改名/追加の後に .qgs とツリーが古い・
    書き出し元にクラス名・改名/削除の題が「GeoPackage」
  - [ ] Drive: 本物のアプリが Google にサインインしていない（Pixel 9）。`/sdcard/FieldSurvey/flat_trial/Kitayama-2026/Kitayama-2026-demo`（Drive 連携）に
        sjis_cpg 一式・points.kml・IMG_TEST.JPG を置いてある。サインインしたら同期して gws で Drive 側を見る。`.kokage` が上がらないことも
  - [ ] 編集しようとしたときの確認ダイアログ（2026-10-11 に通知から変更）: 編集ボタン →「gpkg に変換して編集しますか？」→ 変換 → 同じ地物の編集に入る／
        ペン・GPS 記録 → 変換したレイヤが選ばれてそのまま描ける／属性表 → 表が新しいレイヤに替わる／読み取り専用 Drive フォルダで「自分のフォルダに複製」
  - [ ] 目で見る残り: nodata が透ける・DEM の濃淡・色表付きの色・アプリ製 GeoTIFF の位置合わせ（単体テストは通っている）・大きなオルソの初回 PNG 作成時間
  - [ ] アプリが書く GeoTIFF（オーバーレイ変換）を GDAL が「タグの並びが不正・タイル幅が規格外」と警告する（読めはする）。GDAL で書くように替える
  - web（`tool/web/fetch_gdal_wasm.sh` の後、Chrome で確認）:
    - 2026-10-11 OPFS（Chrome、127.0.0.1 配信）で済んだもの: shp（.cpg あり・なし）・GeoJSON・KML・CSV・GPX・KMZ（doc.kml 形式）が読み取り専用で件数どおり、
      .cpg なしの属性表が日本語・EPSG:6674 → WGS84 の座標が合う／`.kokage/cache/external` ができ、開き直しで作り直さない（初回 約 10 秒・2 回目 約 2 秒、8 ファイル）／
      外部ラスタ 6 枚／KML・GeoJSON →「gpkgに変換」で元が消え .qgs が gpkg に付け替わる／書き出し shp(zip, .cpg=UTF-8)・GeoJSON・CSV が保存の手前（ダウンロード）まで行き
      `.kokage/tmp/` の中身は残らない（空の `tmp/` だけ残る）／「ファイルを追加」（file input を差し替えて 6 ファイル、名前の衝突は `points_1.csv`）。GDAL の初回読み込み 0.2〜0.4 秒。
      直した: KMZ が開けない（2 件）・変換後の .qgs（2 件）・書き出しダイアログの型名
    - [ ] 残り: 選んだフォルダ（File System Access）・ドロップ・本番の `content-encoding`。LIBKML 製の KMZ（doc.kml が NetworkLink だけ）は読めない（未対応のまま）
    - ⚠ Claude の内蔵ブラウザ（Electron）では SharedWorker から fetch できず sqflite が全部落ちる（gpkg が一切開けない）。web の確認は Chrome で
- [ ] Z 付きのレイヤを変換した gpkg をアプリで編集すると Z が落ちるはず（`createGpkgWkb` は XY だけ書く。gpkg の z=1 は「必須」）。
      QGIS 製の Z 付き gpkg も同じ。編集した地物の Z をどうするか（元の Z を保つ／0 で埋める）決めて直す

## リリース・Play

- [ ] v0.11.0 の release を実機で確認（Pixel 9。今回は Fold がデバッグ版なので見送った）。
      Play から入れた端末で、スマホのカメラで共有 QR を読んでアプリが開くこと（App Links）
- [ ] テスター 12 人 × 14 日 → 本番環境へのアクセス申請（2026-10-04 時点でオプトイン 3 人。オープンテストもそれまで鍵がかかっている）
- [ ] **オープンベータ（オープンテストか製品版）に移るときに片付ける**
  - [ ] `web/open/index.html` の行き先をテスター募集ページから Play のページへ
  - [ ] `web/.well-known/assetlinks.json` から debug 鍵を外す
  - [ ] `.kokage` への移行の互換（`GlobalFolderLocator._migratePrevious`・`hiddenLegacyDirs`）を消す
- [ ] Play のストアの設定（2026-10-06 に確認）: カテゴリは「仕事効率化」、タグは「地図＆ナビ」「測定」。
      連絡先のウェブサイトが旧リポジトリ名 `github.com/Torch-Katsuragi/k_maps`、メールが `k-root@googlegroups.com` のまま。
      どちらに直すか決める（公開の掲載情報なので本人の判断）
- [ ] テスター募集ページ `/beta/`: テスター一覧のグループ化が審査を通ったら「準備中」の注記を書き換える

### セキュリティの残り（2026-10-09 の点検から）

ルール・関数・hosting ヘッダ・API キーの制限・GitHub の秘密スキャンは 2026-10-09 に反映済み。残りは段階導入の後半と本人操作:

- [ ] debug ビルドの App Check デバッグトークン（logcat に出る）を Firebase コンソールに登録（Pixel 9 は 2026-10-09 登録済み。Fold・メインPC側の端末が残り）
- [ ] App Check の指標で web・Android とも検証済みの要求が来ているのを確かめてから、RTDB を「強制」に
- [ ] GDAL（web）を載せて最初のデプロイの後: `/gdal3/3.13.3-1/gdal.{wasm,data}` が圧縮（`content-encoding`）されて返るか、
      `Cache-Control: immutable` が付くかを見る。`.data` が素の 11.6 MB なら対策を考える（[[docs/technical/gdal#未決・見張り]]）
- [ ] 本番でログインして Drive 一覧・同期・App Check に CSP 違反が出ないのを確かめてから、`Content-Security-Policy-Report-Only` を強制に（ハッシュの作り直しは [[docs/technical/web-hosting]]）
- [ ] release で外部インテントの `route` が効かないこと・共有リンクの確認ダイアログを実機で確認
- [ ] プライバシーポリシーの「App Check で保護」は強制に切り替えるまで実態と食い違う。強制と同時に見直す

### OAuth 検証（一般公開・資金調達後）

- [ ] デモ動画（OAuth `R22vltqCmt4`）のリンクを GCP のデータアクセスページに登録
- [ ] 同意画面のアプリ名が「ねむりぎ工房」。Kokage Map に変えるか説明するか決める
- [ ] CASA（`drive` は制限付きスコープ。Google から求められたら）
- [ ] 検証センターから申請

## web

- [ ] PWA + Service Worker + タイルキャッシュ（オフライン対応）
- [ ] 公開ビューア（PMTiles / GeoJSON を静的ホスティング、URL で共有）。⚠ 自分のデータを自分のホストから配る初めての機能。着手時に転送量を見積もる
- [ ] 「普通に公開」に切り替えるとき noindex を外し、リンクを張る（今は隠しページ）
- [ ] 予算アラート（同時接続数とダウンロード量）・寄付導線（露骨にしない）・セルフホスト手順（大口向けの選択肢）
- [ ] App Check に web のプロバイダを渡していない（reCAPTCHA のサイトキーはコンソール発行）。強制に切り替えるときに要対応
- [ ] ⚠ web はリロードでサインインが切れる。起動時の One Tap は FedCM のクールダウン等で出ないことがある。ボタン側の経路を消さないこと

## 3D・描画

- [ ] `SceneSink` / `MapSurfaceController` のインターフェース抽出（[[docs/technical/scene-model]]）
- [ ] メモリ削減の残り（2026-10-06 に大きいものは片づけた。経緯は [[docs/technical/performance]]）
  - [ ] Dart のヒープ（profile で約 340MB）: 地物の形を turf（点ごとに数値を箱に入れて持つ）・geobase（描画用）の 2 通りで
        持っている。turf をやめて 1 通りにできれば大きく減るが、turf はアプリ中で使っているので作り直しが大きい
  - [ ] GL の残り（profile で地図を開いて 520〜590MB）: flutter_gpu の分は 15MB ほどで、残りは Impeller が抱えている分。
        perfetto の GPU メモリで内訳を取ってから削る
- [ ] web の fps 計測（Chrome を前面に）・GPU の無い web の純 Dart 経路の透視（眺めモード）
- [ ] 選択・頂点の見た目を View（スタイルグループ）別にできない（View の順に描くのは 2026-10-06 に済み）

## 見張り（再発したら直す）

- [ ] ポイントを削除したときだけフィーチャが残る（2026-09-12 に並走の筋を潰した。再発したら報告を）
- [ ] 地形の断層（`[3D] seam` ログ。再発したら座標とズームを）
- [ ] 写真の取り込みで座標が消える（再現条件が未確定。logcat の `MediaCopy` と `[GalleryImport]` を控える）
- [ ] GPS 軌跡の区切り（10 分空いたら新しい区間）の、日跨ぎ・再起動の実機確認

## 要判断・保留

- [ ] 「この端末」（sys）の実機確認の残り: global 配下の Drive 連携 dir（表示は Pixel / Fold、可視性の保存は 2026-10-06 に Fold で確認済み）
- [ ] `sys/view`（端末の写真など読み取り専用の仮想レイヤ）。写真の権限（Play の申告）と大量写真の性能の設計が先
- [ ] リファクタリングの候補: `cascade_invocations`（好みの問題で保留）
- [ ] Flutter の警告「KGP を当てるプラグイン（desktop_drop / firebase_* / location）は将来ビルドできなくなる」→ プラグイン側の更新を待つ。
      `android.builtInKotlin=true` にできたら root の橋渡しは外す
- [ ] 県点群の DTM（1 m 級）を焼いてプロジェクトの dir に入れる（アプリには入れない。配布先は GitHub Releases に決定済み）。
      地理院の DEM1A 配信とタイルキャッシュで足りているので、細かい地形が要る現場が出るまで保留
- [ ] `proj4dart` 3（geobase 1.5.0 が ^2.0.0 を求めるので待ち）
- [ ] 更新履歴の v0.6.0 以前の節が開発ログ調のまま
- [ ] ~~`layer_styles`~~（`.qgs` にレンダラを書くので冗長。gpkg 単体で渡す場合の保険のみ）
- [x] QGIS で普通に作った GeoTIFF はオーバーレイとして開けない → GDAL で開くようにした（2026-10-10、`GdalRasterOverlay`、
      [[docs/technical/external-formats#ラスタのオーバーレイ（GDAL、2026-10-10）]]）。純 Dart で読む試み（`feat/ext-geotiff`）は捨てた
- [ ] 外のラスタの残り: 大きな `.tif` の判定で中身を丸ごと読む（アプリの GeoTIFF のタグを見るため。先頭だけ読めば足りる）
- [ ] オーバーレイ画像の不透明度（2026-04 に廃止、GeoTIFF のアルファで持つ）。復活させるなら `.qgs` の `<rasterrenderer opacity>` と往復させる
- [ ] 背景地図の一覧に無い XYZ タイル（独自 URL）を背景地図に足す。利用規約で配布アプリから使えないタイル（Google など）を
      持ち込まない仕組みと、出典表示が先。いまは `.qgs` の読み戻しで「背景地図の一覧に無い XYZ タイル」と報告して `.qgs` には残す
- [ ] 端末の背景地図を `.qgs` に XYZ レイヤとして書く（しない方向。背景地図は端末の設定で、端末ごとに `.qgs` が揺れて同期が無駄に動く）

## 2026-10-07 の大掃除で見つけて直していないもの

直すと挙動・保存内容が変わる、または実機で確かめられなかったもの。直したものは git log（fix:）に。

- Drive 同期
  - [ ] pull が変わっていないファイルも毎回全部落とし直す
  - [ ] マージで「端末を採用」して上げるとき、Drive のフォルダを解決できないとルート直下に上げる
  - [ ] 自動同期が毎周期 DriveApi を作り直し、古い http クライアントを閉じていない
- 属性表
  - [ ] 「表をコピー」は最初に読んだ 1 ページ目だけ。ページの大きさの選択も効かない（常に 100 行）
  - [ ] 再読込でフィルタが効いたままでも、ツールバーの表示は「未適用」に戻る
  - [ ] 編集パネルの属性欄では全角数字が半角にならない（フォームではなる）
- そのほか
  - [ ] メタデータ列（`metadataColumn` = kmaps_metadata）はアプリが作らないので、線・面の GPS 測量の記録（drawing_points）は捨てられている
  - [ ] TruPulse の計測のたびに地図ページ全体を組み直す購読が残っている
  - [ ] `LiftedSegments`（等高線をラスタにした後の名残）がどこからも作られていない。gpu/ が参照しているので残した
  - [ ] web 版を `python -m http.server` で配ると練習用の gpkg が作れない（sqflite の WASM が初期化に失敗。今日の変更の前のビルドでも同じ。本番の配信では起きない）

## 方針（守ること）

- 上流（josxha/flutter-maplibre など）に issue / PR は出さない（AI が人間のコミュニティに投稿しない）。踏んだバグは手元の回避策で組む
- サーバ権威型の WebGIS は自分では作らない（OSS なので利用者側で構築してもらう）
