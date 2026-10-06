# TODO

> 2026-10-04 に棚卸しした。開いている項目だけを置く。それまでの帳簿（経緯・完了の記録・当時の見立て）は
> [[docs/history/TODO-2026-10-04]] にそのまま残してある。完了したものはここから消し、記録は git と docs に任せる。

## 次にやる（実装）

- （空。下の節から選ぶ）

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
- [ ] メモリ削減（profile 実測で 3D の増分 +200〜250MB。画像 LRU・`raw` の畳み込み・親テクスチャ 256²）。
      2026-10-06 に Fold（debug）で測った: `dumpsys meminfo` の GL mtrack が 0.8〜1.2GB で大半。そのうち flutter_gpu 側
      （地形テクスチャ 11 枚 14MB・地形バッファ・線と面のバッファ）は合わせて約 15MB しかない。残りは Impeller が持つ分
      （`ui.Image`・`Picture.toImage`・画面の描画先など）。次は perfetto の GPU メモリか DevTools で `ui.Image` の生存数を見て、
      どれが大きいかを突き止めてから削る（推測で LRU を縮めない）。
      GL の推移: ホーム 70MB → 地図を開いた直後 467MB → パンを重ねると 0.8〜1.2GB → ホームへ戻ると 170MB
      （戻っても残る 100MB は static の `_tileImages`（256 枚）などの候補）。
      `_tileImages` を 64 枚にしても 地図直後 430MB・パン後 746MB で、256 枚（467MB・824MB）と大差なし → 主因ではない。
      タイルが持つ合成画像も測った: 64 タイル中 55 枚・55MB（GPU に上げたのは 9 枚）。画像キャッシュ 64MB と flutter_gpu 15MB を
      足しても 140MB ほどで、GL 830MB のうち 700MB 近くが説明できない。計測は地物の無い引いた眺め（高知のあたり、線・面は 0）
      だったので、地物の描画は関係ない。残る候補は flutter_gpu の描画先（MSAA 4x の色・深度が画面サイズで、
      `gpu.render` が毎フレーム `ui.Image` を返す）と、タイル合成の `Picture.toImage` の一時領域。perfetto で確かめる
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
- [ ] リファクタリングの候補: `cascade_invocations`（好みの問題で保留）、`shapefile_exporter.dart`（914 行）、
      `settings_screen.dart`、`SmartCoordinateSystemManager` の WKT 推定を `WktParser` へ
- [ ] 既存 MapTool（PenTool / SelectTool / GpsTool）の ChangeNotifier 化の統一
- [ ] Flutter の警告「KGP を当てるプラグイン（desktop_drop / firebase_* / location）は将来ビルドできなくなる」→ プラグイン側の更新を待つ。
      `android.builtInKotlin=true` にできたら root の橋渡しは外す
- [ ] 県点群の DTM（1 m 級）を焼いてプロジェクトの dir に入れる（アプリには入れない。配布先は GitHub Releases に決定済み）。
      地理院の DEM1A 配信とタイルキャッシュで足りているので、細かい地形が要る現場が出るまで保留
- [ ] `proj4dart` 3（geobase 1.5.0 が ^2.0.0 を求めるので待ち）
- [ ] 更新履歴の v0.6.0 以前の節が開発ログ調のまま
- [ ] ~~`layer_styles`~~（`.qgs` にレンダラを書くので冗長。gpkg 単体で渡す場合の保険のみ）

## 方針（守ること）

- 上流（josxha/flutter-maplibre など）に issue / PR は出さない（AI が人間のコミュニティに投稿しない）。踏んだバグは手元の回避策で組む
- サーバ権威型の WebGIS は自分では作らない（OSS なので利用者側で構築してもらう）
