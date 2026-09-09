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
- [ ] ベータ案内の隠しページ `kokage-map.sleeptree.jp/beta/`（2026-09-07 松本了承・未着手）: `/about/` と同じ体裁で `web/beta/index.html`。内容は 14 日条件・グループ参加→テスターになるの 2 手順・つまずき・不具合報告フォーム（フォーム作成は本人操作）。テスター一覧のグループ化が審査を通ってから「準備ができました」に書き換える
- [/] **3D 地形モード（`feature/3d-map`・2026-09-08）**: 別画面ではなく「いつもの地図が傾く」。純 Dart（`drawVertices` + 象限走査の painter's algorithm）で
      `lib/core/terrain/`、本体接続は `lib/screens/map_page/widgets/terrain_map_layer.dart`（ツールバーの ⛰）。
      設計の正典は Vault `3D化の詰め_2026-09-07`、実装ノートは [[docs/technical/terrain-3d]]、順1 の設計は [[docs/technical/scene-model]]。
      ⚠ [[docs/technical/3d-map-design]] は旧案（別画面・閲覧専用）で上書き済み
  - [x] 描画スパイク（Pixel 9: 北山村 z14 2x2 で LOD 57fps／全解像度 28fps）、実 DEM（AWS Terrain Tiles）＋地理院タイル合成、面・等高線・遮蔽つきヒットテスト、ゴールデン
  - [x] 本体接続: 3D トグル、カメラの引き継ぎと書き戻し、`TerrainProjection` で選択ツールがそのまま動く、写真・GPS 軌跡・現在位置・パーティ・頂点、pitch スライダ、web でも動く
  - [x] 「常に隙間なく」の検証（2026-09-09）: `TerrainFramePlanner` + シミュレーション 6 本 + 実機ドライブモード（debug・🛣）。
        引いた瞬間の停止（`heightRange` 全点走査 × 描き直し連鎖）・白抜け（穴埋めメッシュ）・メモリ（常駐ワーカー isolate）を解消。
        Pixel 9 で欠けフレーム 0 / 2,650・UI 中央値 5ms
  - [ ] 残り: オーバーレイ画像（GeoTIFF）をテクスチャに焼く／クラスタ／DeviceTool のオーバーレイ／描画プレビュー／等高線オプション／
        DEM の dir 同梱と焼き込み CLI（圏外で使えるように）／`SceneSink` / `MapSurfaceController` のインターフェース抽出／web の fps 計測（Chrome を前面に）／
        メモリ削減（profile 実測で 3D の増分 +200〜250MB。画像 LRU・`raw` の畳み込み・親テクスチャ 256²）
  - [x] 3D を正とした UI の前半（2026-09-09）: コンパスタップで北上・真上、ペン／オーバーレイ変換は真上ロックで 3D のまま、
        傾きスライダー撤去、jumpTo を 3D に流す、オーバーレイ画像・TruPulse の線を 3D に載せる。標高は地理院 DEM1A → 5A → 10B → AWS の連なり
  - [x] 1 万面 + 1 万点の負荷（2026-09-09 夜）: profile で UI 中央値 5〜6ms・最大 71ms・停止なし。手法は [[docs/technical/terrain-3d]] の「1 万面 + 1 万点の負荷」
  - [x] 3D 中は MapLibre を組み立てない（2026-09-09 夜。戻すときは覚えたカメラで組み立て直す）
  - [ ] 3D を正とした UI の後半: 切替ボタンを消して MapLibre を外す（インターフェース抽出と同時）、web のマウス操作の実機確認、
        web のオーバーレイ画像、クラスタ（引いた段の格子まとめは済み）。カメラ状態は保存しない（松本 2026-09-09。`.kmeta.json` は `.qgs` へ移す方針でもある）
  - [ ] 焼いた DEM タイル（地理院 DEM5A/10B・県点群 DTM）の配布先は **GitHub Releases**（データ用公開 repo 1 つ。認証なし・無料・
        添付の総量上限なし。2026-09-09 決定。Drive は所有者を隠せない）。焼き込み CLI は `tool/`（Vault 11 節 A）
  - [x] 出典表示: 3D 中の地図面左下と、設定 > アプリ情報「地図データの出典」（2026-09-09）
- [ ] 更新履歴の運用: v0.6.0 以前の節も開発ログ調のまま。読み直すなら v0.6.0 節から

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
- [ ] 残った候補: `avoid_dynamic_calls`（63 件・手作業）、`cascade_invocations`（411 件・好みの問題なので保留）、
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
  - [ ] ⚠ QGIS での実開封は未確認（開発機に QGIS 無し）。確認手順は [[docs/technical/qgis-interop]]。
        特に「QGIS で保存 → アプリで書き出し → QGIS で開き直して設定が残っているか」
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
  - [ ] ラスタ化オーバーレイ（GeoTIFF を `maplayer type="raster"` で）は未着手
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
  - [ ] 🐛 **自己位置マーカーが点・短いラインを隠す**（2026-09-01 実機で確認）
        重なるとフィーチャが見えなくなる。マーカーを半透明にする（不透明度を落とす）方針
  - [ ] 🐛 **レイヤにズームする導線が無い**（2026-09-01）。地図は現在地に開くので、遠方のデータを
        持つ `.gpkg` を開いた人は「何も表示されない」に当たる。レイヤの ⋮ に「ズーム」を足す
  - [ ] 🐛 **ホーム画面から地図へ戻る導線が無い**（2026-09-02）。フォルダ選択済みのカードが出るだけで
        タップしても何も起きない。「フォルダを選択」でピッカーをやり直すしかない
  - [ ] 選択モードで地図をタップすると**フィーチャ情報のポップアップが画面に居座る**（2026-09-02 撮影中に確認）。
        地図を動かしても消えず、複数重なる。閉じる操作か自動消去が要る
- [/] **`.qgs` ライター** — dir/gpkg/layer をレイヤグループ、View をレイヤとして出力
  - [x] 実装（`lib/services/qgis/`）。~~書き出し導線は 地図の ≡ メニュー と
        フォルダのメニュー~~ → 2026-09-06 に手動メニューを撤去。自動追従（`QgsAutoRefresh`）と
        開いたときの読み戻し（`QgsReadBack`）だけ
  - [x] **QGIS 3.44.12 で実開封を確認**（2026-08-26）。相対パス解決・subset適用
        （12→6）・レンダラ読み取り・グループ構造すべて意図どおり。
        手順は [[docs/technical/qgis-interop]]、確認スクリプトは `tool/qgis/`
  - [x] Drive push の直前に自動生成する → `QgsAutoRefresh.flushNow()`（2026-09-06）。
        それ以前にメタデータ保存のたびに追従しているので、push 時は待ちの消化だけ
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
  - [ ] 🐛 **初回起動時、オンボーディングより前に Google の「Sign in with Google / Choose an account」シートが出る**
        （2026-09-03 Fold で確認。Credential Manager の起動時サインイン要求。Google アカウント0件の端末では出ない）。
        審査官の端末では出るので、Drive設定を開くまで出さないようにする
  - [ ] 🌐 `drive_url_input_dialog` の「Driveフォルダを追加」「URL入力」「QRスキャン」が未翻訳（英語UIで日本語のまま）
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
