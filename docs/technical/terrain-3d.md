---
title: 3D 地形描画系（純 Dart）
tags: [technical, design, 3d, dem, terrain]
---

# 3D 地形描画系（純 Dart）

> [!NOTE] 位置づけ
> 設計の正典は Vault `事業/ねむりぎ工房/K-Maps/3D化の詰め_2026-09-07`。
> このファイルは `lib/core/terrain/` の実装ノート。[[3d-map-design]] は 2026-09-07 の旧案（別画面・閲覧専用）で、
> 松本の回答（Android にも出す／2D と 3D を行き来／2D でできることは全部 3D に）で上書きされた。

## 方針（要約）

- **最終形は 3D 一本**。真上視点（pitch 0）が 2D 地図。当面は MapLibre との 2 モードだが経過措置
- **正射影**。真上視点の 3D は 2D 地図と幾何が一致するので、切替に継ぎ目が出ない
- 座標は **2D と同じ Web Mercator（m）**。標高には緯度の倍率 `1/cos(φ)` を掛ける（`WebMercator.zScaleAt`）
- **ラスタ（背景地図・写真）はテクスチャ、ベクタ（フィーチャ）は持ち上げ**。フィーチャを画像にして貼らない
- 手描きは真上ロック中だけ。位置ベースのデータ追加（GPS・TruPulse・ルーム）はいつでも
- 地図面以外の UI は共通。地図面の窓口は「カメラの読み書き／投影・逆投影／ヒットテスト／スナップショット」

## 実装（`lib/core/terrain/`）

| ファイル | 役割 |
|---|---|
| `web_mercator.dart` | Mercator の座標・タイル計算・`zScaleAt` |
| `dem_grid.dart` | 規則格子 DEM（Mercator m・南から北）、双一次補間、合成地形 |
| `dem_tiles.dart` | Terrarium / Terrain-RGB タイル → `DemGrid`、背景タイルを 1 枚に合成（`RasterTileComposer`） |
| `terrain_camera.dart` | 正射影カメラ（center / scale / bearing / pitch / zScale）。投影は線形なので pan と zoom は Canvas の変換で済む |
| `terrain_mesh.dart` | `TerrainMeshBuilder`: チャンク（32×32 セル）ごとの共有頂点、象限走査の並び順、LOD（間引き） |
| `terrain_painter.dart` | `TerrainPainter`: 地形（テクスチャ × 陰影色）→ 面 → 線分の束 → 線 → ラベル。`pick` でヒットテスト |
| `contours.dart` | DEM から等高線（marching squares） |
| `terrain_scene.dart` | `TerrainSceneBuilder`: GeoJSON（geobase の Feature + `k-style` / `k-label`）→ 持ち上げ済みの線・面・縁・点・ラベル（seam ②の実体） |

開発用の画面は `lib/screens/terrain_spike/`（設定 > アプリ情報、debug / profile のみ。web は `#/terrain-spike`、
Android は `--route /terrain-spike` か intent extra `route`）。製品機能ではない。

### 隠面処理: 並び替えは要らない

深度バッファが無い `drawVertices` で painter's algorithm を使う。正射影で視点が地表より上なら、
標高場は xy の関数なので **「行を奥から手前へ、行内も奥から手前へ」となぞる順で隠面順が正しい**。
あるセルを隠せるのは視線の地上投影に沿って手前にあるセルだけだから。
順序は方位の象限（4 通り）だけで決まり、pitch・pan・zoom では変わらない。バケットソートは撤去した。
チャンク単位でも同じ（チャンク行を奥から手前、行内も奥から手前）。テストで検証している。

### 毎フレームやること・やらないこと

| いつ | やること |
|---|---|
| pan / zoom | Canvas の translate / scale だけ。頂点は触らない |
| bearing / pitch が変わった | チャンクごとの位置配列を投影し直し、`Vertices.raw` を作り直す。テクスチャ座標・色・インデックスは静的 |
| 象限が変わった | チャンクの描画順と帯番号を引き直す（インデックスは象限ごとに遅延生成・キャッシュ） |
| ジェスチャ中 | LOD: `step = ceil(sqrt(cells / 40000))` で格子を間引く。終わったら全解像度 |

`TerrainPainter` は 1 インスタンスを使い回し、中身を差し替えて `repaint` で通知する。
毎フレーム `setState` で画面全体を組み直すと、地図面以外のウィジェットの再構築が UI スレッドを食う（debug で 10ms 超）。

### ベクタ

- 線（`LiftedPolyline`）: セル幅で細分して各点を DEM で持ち上げる。帯（チャンク）ごとに Path を分けて割り込ませる
- 面（`LiftedPolygon`）: 耳切り → 三角形を DEM セルで矩形クリップ → 扇状分割 → 頂点を持ち上げ。
  チャンクごとに束ねて投影バッファを使い回す。三角形 ∩ 矩形は凸なので扇状分割で正しい
- 線分の束（`LiftedSegments`）: 等高線など本数の多いもの。チャンクごとに `drawRawPoints(PointMode.lines)` 1 回
  （Path 2.5 万本で paint 60ms → 5ms）
- 点（`TerrainPoint`）: ビルボードの丸。地形に隠れていれば描かない
- ラベル: ビルボード。地形に隠れない方針で最後に画面座標で描く。重なりは先勝ちで間引き、間引かれた分は点だけ残す

### ヒットテスト（`TerrainPainter.pick`）

ラベル > 線 > 面 の順。線は線分までの距離、面は投影した三角形の内外。
線と面は **地形に隠れていれば当てない**（`isOccluded`: 点から視点側へ視線の地上投影をセル幅ずつなぞり、
`1/tan(pitch)` で上がる視線より地形が高ければ隠れている。視線が DEM の最高点を超えたら打ち切り）。
ラベルは最後に上描きしているので当てる（間引かれたラベルは当てない）。
画面座標 → 地形上の点は `unproject`（`TerrainCamera.intersectTerrain`: DEM の最高点から視線に沿って高さを下げ、地形に潜った区間で線形補間）。
`TerrainCamera.zoom` は MapLibre と同じ定義（`scale = 256·2^zoom / 2πR`）。

## 計測（2026-09-08・Pixel 9・debug、AOT もほぼ同じ）

| 条件 | 傾けアニメ fps | UI スレッド | mesh build |
|---|---|---|---|
| 合成 401²（16 万セル）全解像度 | 33 | 17 ms | 11 ms |
| 合成 401² LOD（step 2） | 55 | 10 ms | 3 ms |
| 合成 801² 全解像度 | 25 | 29 ms | 26 ms |
| 北山村 z14 2x2（512²・9.6 m）全解像度 | 28 | 22 ms | 14 ms |
| 北山村 z14 2x2 LOD（step 3） | 57 | 9 ms | 2 ms |
| 同上 + 等高線 20 m（2.5 万本、LOD 中 1.7 万本） | 25〜34 | 13〜16 ms | 3 ms（raster 23〜40 ms） |

- raster スレッドは通常 10 ms 以下。GPU は余裕。等高線 2.5 万本を足すと線描画で raster 20〜40 ms
- ⚠ スパイクは Ticker が常に動いていて毎 vsync で再ラスタライズされる（Impeller は複雑な picture をキャッシュしない）。
  製品では静止中にフレームを出さないこと。静止時の raster の数値は「フレームが出たときの重さ」
- 残る CPU コストは `Vertices.raw` のネイティブ側コピー（Flutter の Vertices は不変で毎回コピーする仕様）。
  これ以上は `package:flutter_gpu`（永続バッファ）待ち
- **`FrameTiming`（ui / raster）を見ないと原因を取り違える**。最初の版は UI 時間の半分が `setState` だった
- ⚠ Chrome / 内蔵ブラウザのウィンドウが隠れていると rAF が絞られ、web の fps は測れない（未計測）

## v2: タイルの世界（2026-09-08 夜・松本の指摘で設計し直し）

> [!IMPORTANT] v1（窓 1 枚を読んで差し替える）は捨てる
> 松本: 「見渡す限り 1 面の世界があって、標高は正確に決まっている。フィーチャはその標高メッシュに沿って
> 3 次元的に配置される（手に入る限り細かいメッシュ）。描画用メッシュは別で、視点に近い所は細かく遠くは粗く。
> 3D ゲームの知見を応用せよ」

ゲームの地形描画との対応:

| ゲーム | こかげマップ v2 |
|---|---|
| ハイトフィールドをタイルでストリーミング（リング・先読み・LRU・フレームを止めない） | `TerrainWorld`: DEM タイルのキャッシュ、カメラ周りのタイル範囲 + 余白 1 枚を非同期に読む、無いタイルは `getTile` の祖先フォールバック |
| 計算メッシュ（衝突・配置）と描画メッシュ（LOD）を分ける | 計算メッシュ = 手に入る最も細かい DEM タイル（AWS は z15）。標高問い合わせ・フィーチャの貼り付け・当たり判定はこちら。描画メッシュ = 同じタイルを `step` で間引いたもの |
| 三角形予算から LOD を選ぶ | 見えているタイル数 × (256/step)² ≤ 予算（静止 16 万・ジェスチャ中 4 万）になる step を選ぶ。**正射影には遠近が無いので LOD はズームで均一**（2D タイルと同じ理屈）。距離で粗くする・靄・遠方カットは透視投影の「眺め」モードを足すときに効く |
| クラック対策（スカート） | ズームが均一なら LOD 差のクラックは出ない。タイル境界の 1 セル幅の隙間は、東と北の隣タイルの縁の行・列を借りて 257×257 頂点にして塞ぐ（隣が届いたら縁だけ組み直す）。スカートは透視モードのときに検討 |
| 深度順は BSP/四分木の奥→手前走査 | タイルの象限走査（奥の行から手前へ、行内も奥から手前）× タイル内はチャンクの象限走査。ソート不要のまま |
| テクスチャはタイル単位 | DEM タイルごとに 1 段細かいラスタ 4 枚を 512² に合成して持つ（LRU）。表示範囲の合成し直しはしない |
| オブジェクトはセルに登録して描画時にカリング | フィーチャは**タイルごとに**計算メッシュへ貼り付けてキャッシュ。タイル境界で線を切り、面はタイル内のセルだけで切り分ける。パンで貼り直さない。細かいタイルが届いたらそのタイルだけ貼り直す |
| 靄 | 透視モードで頂点色を距離で空色に寄せる（未実装） |

地図面の窓口（カメラ／投影・逆投影／ヒットテスト／スナップショット）は変えない。`TerrainMapLayer` の中身を
「窓 1 枚」から `TerrainWorld` に差し替える。

**実装（2026-09-08 22 時・`70048f7`）**: `terrain_world.dart`（`TileKey` / `TerrainTile` / `TerrainWorld`）、
`terrain_world_painter.dart`（複数タイルの描画・逆投影・遮蔽）、`TerrainMapLayer` v2。
Pixel 9 で 4〜8 枚で画面を覆い、タイル境界に継ぎ目なし。回転・位置を変えての再突入で新しいタイルが足される。
1 タイルの貼り付けは 20〜60ms（初回だけ）。

- 描画順: タイルは `drawOrder`（北が奥なら y 昇順、東が奥なら x 昇順）、タイル内はチャンクの象限走査。
  タイルごとに「カメラ中心をそのタイル座標で投影した点」を引くだけで並ぶ（投影が線形）
- 縁: `TerrainTile.bordered` は東・北・北東の隣の縁を借りた 257×257。隣が届いたら `updateBorder` で組み直し、
  ビルダーとシーンのキャッシュはキーが変わって自然に入れ替わる
- **引いたときに消えない**（22:50）: 理想の段が無いときは `coverSet` が読み込み済みの親（3 段まで）か子（1 段）で埋める。
  親の段は 2 段ぶん先読み（ピラミッド）し LRU でも残す。段が違う隣との裂け目はスカート（縁から幅の 3% 下の壁）。
  読み込みは「画面に掛かる分 → 親 → 1 周り外」の順で、待ち行列は毎回作り直す（読み込み中とは分ける）。
  Pixel 9 で 3 段引いた直後に全面が埋まり、戻すと即座に細かい段。ズームの ＋／− ボタンも置いた
- 未実装: RTIN（三角形の間引き）、透視の眺めモードと靄、計算メッシュを描画より細かい zoom で持つ
  （いまは同じタイル。AWS は z15 が最細なので zoom ≥ 16 では同じこと）、先読みの優先度（見えている分が揃ってから）

## v2.1: 検証と改善（2026-09-09 未明・松本就寝中の 6 時間枠）

成功条件は「ズーム・移動・回転・傾けのどの操作中も地形が隙間なく出ていること」。検証は 2 段で回した。

- **シミュレーション**（`test/terrain_world_sim_test.dart`）: `TerrainWorld` の `tileLoader` を遅延 300ms の擬似タイルに
  差し替え、`fake_async` でカメラを動かしながら毎フレーム計画を立て、`CoverageReport`（理想の段が 親 / 子 で
  埋まっているか）が欠けたフレームを数える。静止・パン 6km・ズーム 16→10→17・乱暴なズーム（1 秒 4 段）・回転と傾け・
  ランダム複合の 6 本。レイヤと同じ規則を使うために計画を `TerrainFramePlanner`（`terrain_frame.dart`）に切り出した
- **実機ドライブ**（debug のみ・ズームボタン列の 🛣 ボタン）: 48 秒の台本（東へ 3km → 4 段引く → 5 段寄る → 一回転 →
  傾け往復 → 西へ 3km）でカメラを動かし、0.5 秒ごとに `[3D] drive …` に被覆率・タイル数・UI/raster 時間・
  穴埋め枚数・欠けフレーム数を出す。100ms タイマーで isolate の停止（`[3D] stall`）も検知する。
  `.temp/` の `stack.dart` / `heap.dart`（VM サービスで main isolate のスタック・GC 後のヒープ）と組で使う

計画の規則（`TerrainFramePlanner`）:

- 理想の段 = 表示ズーム −1。ただし画面に掛かる枚数が 10 を超える間は下げる（傾けるほど画面が広いので粗くなる）。
  境目で往復しないように、粗い段に居たときは理想の段の枚数が上限の 6 割を超える間は留まり、細かい段に居たときは
  枚数が許容内なら留まる
- 読み込み順: 親 4 段を粗い方から（3 段以上上には余白 1 枚。引いている最中に広がる縁を粗い親で先に埋める。
  乱暴なズームアウトの試験はこれで通った）→ 画面に掛かる分 → 1 周り外。一番粗い段でだけ待ち行列を入れ替える
- `trim` は核（1 周り外 + 親 4 段の余白込み）を上限に関わらず残す。核は z16 で 50 枚前後

見つけて直したもの（Pixel 9・debug）:

| 症状 | 原因 | 対処 |
|---|---|---|
| 引いた瞬間に 6〜41 秒止まる | `TerrainWorld.heightRange` が毎回 全タイル 340 万点を走査。タイル到着ごとの `_refresh` が future の連鎖で数珠つなぎになり、イベントループを独占（タイマーもフレームも来ない） | `DemGrid.heightRange` をタイルごとにキャッシュ。非同期のきっかけ（到着・メッシュ完成・シーン更新）は `_scheduleRefresh` で次フレームの頭に 1 回 |
| 引いた直後に上端が白い | 親タイルは届いていても、その段のメッシュが isolate から戻るまで描けない | `placeholderBuilder`（step 16・約 1ms）を同期で作って先に描く。読み込み済みのタイルは必ず描ける |
| メモリ PSS 1.8GB | `compute` がタイルごとに isolate を起動（debug で 1 本 30MB 超・起動 1 秒超）。回転中に毎フレーム捨てる `Vertices` が GC 待ちで native に溜まる。`_meshes` がビルダーをキーに持ち、捨てたタイルのビルダーが残る | 常駐ワーカー 2 本（`TerrainWorker`）。差し替え時と掃除で `TerrainMesh.dispose`。ビルダーはタイルごと 2 段まで。画像 LRU 128 枚。3D の増分は +70〜160MB（土台の 1.4GB は debug + MapLibre） |
| `didUpdateWidget` から同期に通知して setState during build | 現在位置の更新で親が rebuild するたび | 描き直しをフレーム後へ |

結果（ドライブ 48 秒）: 欠けフレーム 0 / 2,650、停止 0、UI 中央値 38ms → 5ms（heightRange の走査が毎フレーム 2 回走っていた）、
DEM の組み立て 1.4 秒 → 21ms（常駐 isolate）。縮小 4 段のスクリーンショット（直後 / 2.5 秒後）でも白抜けなし。

引いた直後の `_refresh` 150〜400ms は常駐ワーカー化のあと再現しない（60ms 超のフレームなし）。内訳ログ（`[3D] refresh`）は残してある。

その後の詰め（01:00 前後）:

- **寄る方向の先読み**: 手が空いているとき（待ち行列が空）、画面の内側半分を 1 段細かい段で読んでおき `trim` でも残す。
  1 段寄った瞬間に理想の段で描ける（exact 0/10 → 4/6 即時）
- **画面の標高幅は直前に描いたタイルから**: 読み込み済み全タイルから取ると遠くの粗い親の高低差で画面範囲が水増しされ、
  枚数が上限を超え続けて z17 でも DEM が z14 に留まっていた。ヒステリシスも「上限の 85% 超のときだけ粗い段に留まる」に絞った
- **入った直後の白い一瞬**: 最初に全面が揃うまで背景を透明にして下の 2D 地図を見せる（0.4 秒後は 2D、1.4 秒後に地形）
- **貼り付けの分割**: 静的（フィーチャ本体・頂点・写真・選択。GeoJSON のリストが同じ限り作り直さない）と
  動的（今日の軌跡・パーティ・現在位置。GPS の更新ごとに作り直すが数本・数点）を別々にキャッシュ。
  以前は現在位置が変わるたびに見えているタイル全部を作り直していた（1 枚 30〜150ms）。静的な貼り付けは
  1 フレーム 2 枚まで（超えたぶんは空のまま描いて次のフレームで足す）
- **メモリ（profile ビルド・Pixel 9）**: 2D 519MB → 3D 静止 763MB / 3 段引き 706MB / 回転 748MB（PSS）。
  3D の増分は **+200〜250MB**（Graphics +110MB = 512² テクスチャ 50〜60 枚 + 画像 LRU 32MB + Vertices、Dart 側 +50〜75MB）。
  減らすなら: 画像 LRU を絞る、`raw` を `bordered` に畳む（15MB）、親のテクスチャを 256² に（見た目が粗くなるので保留）

## 本体への接続（2026-09-08 夜・`feat(3d)`）

- **ツールバーの「3D 地形」ボタン**（`terrain3dModeProvider`）で地図面を `TerrainMapLayer`
  （`lib/screens/map_page/widgets/terrain_map_layer.dart`）に切り替える。MapLibre は下に生きたまま
- 入るとき MapLibre のカメラ（center / zoom / bearing）を引き継いで 45° 傾け、出るときに書き戻す。
  **真上ロック = 3D を抜けること**。ペン / GPS ツールを選ぶと自動で抜ける。3D 中はパン / 選択だけ
- **操作（松本の指定・2026-09-08）: 1 本指 = 回転と傾き（左右で方位、上下で pitch）、2 本指 = 平面移動と拡縮**（焦点を留める）。
  移動と拡縮は Canvas の変換だけで済み、メッシュを組み直すのは回転・傾きのときだけ（LOD）
- 同じシーン: `FeatureGeoJsonCache` の GeoJSON（`k-style` / `k-label`）→ `TerrainSceneBuilder`。
  View 固有スタイル（`MapStyleGroup`）・全体設定の既定・選択色を反映。写真（琥珀の点 + 名前）、
  今日の GPS 軌跡（未 Consolidation 分）、現在位置（青い点）も載せる。
  更新は `terrainSceneRevision`（`_pushFeaturesToSources` と GPS 履歴更新で増える）
- **投影の差し替え**: 3D 中は `IMapState.offsetToLatLng` / `latLngToOffset` が `TerrainProjection`
  （視線と地形の交点 / 地形の高さで持ち上げた投影）を通る。選択ツール・投げ縄はそのまま動く
  （実機で確認: 3D 中のタップで情報カード、2D に戻っても選択が残る）
- DEM: 表示ズーム −1 の 2×2 枚（zoom 16 → z15・4.8m・512²）。中心が範囲の内側 60% から外れるか
  ズームが 2 段変わったら読み直す（古い DEM は届くまで描き続ける）。
  標高タイルは擬似プロバイダ `aws_terrarium`（`BaseMapType.terrain`）として `BaseMapService.getTile` を通す →
  背景地図と同じ MBTiles キャッシュに入り、**一度見た範囲は圏外でも 3D になる**（祖先タイルからの切り出しは粗い標高になる）。
- **読み込みの速さ**（Pixel 9 debug・キャッシュ済み、2026-09-08 夜の計測）: 初版は 1 回 0.85〜1.0 秒が全部 UI スレッドで、さらに
  全フィーチャの持ち上げ直し（150〜190ms）が GPS 更新や同期のたびに走っていた（15 回/数十秒）。対処:
  ①持ち上げは部分キャッシュ（フィーチャ本体は GeoJSON のリストが同じ限り持ち直さない。軌跡・パーティ・選択は別々）
  ②面の切り分け格子を約 20m 角に粗くする（78k → 5.8k 三角形、190ms → 28ms）
  ③DEM の PNG デコードとメッシュの前計算を isolate（`compute`）に
  ④デコード済みタイル画像の LRU（192 枚・3D の出入りで使い回す）→ 2 回目の背景合成 663ms → 47ms。
  結果: 1 回目 1.2 秒（UI を塞ぐのは 85ms）、2 回目以降 0.4 秒（同 55ms）
  背景: `BaseMapService.getTile` を背景地図レイヤ（`activeLayers`）の不透明度・合成モードで合成
- 未対応: パーティの他メンバー・頂点マーカー・クラスタ・オーバーレイ画像（GeoTIFF）・描画プレビュー・
  外部機器ツールのオーバーレイ・等高線。DeviceTool（TruPulse）は 3D 中は選べない

## 3D を正とした操作（2026-09-09 夜）

- 3D 系の UI は**コンパス（右上）だけ**。方位に合わせて回る。傾きスライダーは撤去、
  ズーム ± は web / PC だけ。傾きの上限は 85°（正射影では 90° で地面が線に潰れる）
- **コンパスは 2D / 3D の切替の入り口**（2026-09-13 夕、松本「移動じゃなくてモード変更の入り口に」）: タップで 2D ⇄ 3D、
  ダブルタップで北を上に、長押しで眺めモード（3D のときだけ）。ボタンの下に「2D」「3D」。
  2D = 真上固定（`_flat`）: 1 本指 = 移動、2 本指 = 移動・拡縮・回転（指の下の地面を留めて回す）。3D 導入前のパンと同じで、中身は 3D を真上から見ているだけ。
  3D = 1 本指 = 回転・傾き、2 本指 = 移動・拡縮・回転（回転は 2D と共通の式。透視なら `_groundUnder` で指の下を留める）。起動は 2D。3D に戻すと 2D に入る前の傾き（無ければ 50°）。
  CLI / URL で pitch > 0 を頼まれたら 3D に入る。ペンの真上ロックは両モード共通（2D ではペンを離しても真上のまま）
- **ペン = 真上ロック**: ペンを選ぶと 3D のまま傾きを 0 に寄せ、1 本指を `PenTool` に渡す（2D と同じ経路。
  座標は `TerrainProjection` を通るので傾いていても正しい）。2 本指は移動・拡縮のまま。ペンを離れたら元の傾きに戻す。
  描画中の線・面・点は動的シーンに赤で出す（`GlobalDrawingState`）。GPS ツール・TruPulse・選択は 3D のまま
- 2D のカメラ移動（`jumpTo`: 現在位置へ移動・フィーチャへ移動・属性テーブル）は 3D 中 `TerrainProjection.jumpTo` で地形のカメラを動かす
- 選択中のオーバーレイ画像の枠（青）と変換ツールの回転ハンドル、外部機器ツール（TruPulse）の基準点と計測線も 3D に載る
  （`DeviceTool.overlayLines` / `overlayStation`。MapLibre 向けの層はそれを包む）
- 残っている仮実装: ツールバーの「3D 地形」切替（MapLibre を外すまで）。カメラ状態は保存しない（松本 2026-09-09）
- **3D 中は MapLibre を空のスタイルにする**（2026-09-09 夜）: 下で生かしたままだと 3D の PSS が 1.3GB（Graphics 450MB）。
  最初はウィジェットごと外したが、`maplibre_android` 0.3.5 はプラットフォームビューを捨てるときにネイティブの地図を
  破棄しないので、2D に戻すたびに native heap が 170MB 増えて戻らなかった（5 往復で PSS 2GB）。
  なので `terrain3dModeProvider` を聞いて、入るときは `setStyle(kEmptyMapStyle)`（タイル・ソースを手放す）＋
  `RMapController.detachStyle`・`MapSourceManager.detachStyle`・登録済みソース/オーバーレイの記録を捨てる。
  抜けるときは基図のスタイルを `setStyle` し直し、`onStyleLoaded` から全部やり直す（3D 中に来る空スタイルの onStyleLoaded は無視）。
  カメラは MapLibre が持ったまま（3D を抜けるときに書き戻す）。`RMapController.rememberCamera` / `KMapCamera.fixed` は
  コントローラが無い間（起動直後）の保険として残す

## 1 万面 + 1 万点の負荷（2026-09-09 夜・Pixel 9・profile）

60m 格子 100×100 の面 1 万と点 1 万（`load_polygons_10k.gpkg` / `load_points_10k.gpkg`）を置いてドライブ。当初は格子の上で 10fps・引っかかり 1.9 秒。
Flutter の Canvas には頂点バッファ・頂点シェーダ・深度バッファが無いので、「静止したオブジェクトの配置」でも頂点変換は Dart で毎フレームになる。
それを避けるのが全部:

| 手 | 中身 |
|---|---|
| 描画呼び出しを束ねる | 面はチャンクごとに 1 つの `Vertices`（`PolygonBatch`、色は頂点ごと）、線は帯 × 見た目でまとめ、細い線は `drawRawPoints` |
| 投影を方位・傾きでキャッシュ | 正射影なので移動・拡縮では投影が変わらない。面の束・線・点・ラベルとも `Expando` でキャッシュ、動的なもの（軌跡・向き・現在位置）は別に持つ |
| 標高の参照 | `TerrainWorld.elevationAt` は前回当たったタイルが最細の段ならそれを返す。点・ラベルの z はタイル自身の DEM から。画面中心の標高もキャッシュ |
| 引いた段の間引き | セル × step ≥ 30m では格子の切り分けを粗く（最低 4 セル）、点が 50 を超えるタイルは 60px 相当の格子でまとめて数を出す。面の輪郭とラベルを省くのは**データ全体が 2,000 面を超えるときだけ**（林班は塗りが薄く輪郭が本体。タイルごとに判定すると継ぎ接ぎになる） |
| ラベル | `TextPainter` は描くときまで作らず 1 フレーム 40 個まで（見送ったぶんは次のフレーム）、置けるのは 200 個、重なり判定は 96px の格子、順はタイル順で固定 |
| 貼り付けを育てる | フィーチャの bbox（Mercator）でタイルに掛かるものに絞り、1 回に渡す数を直前の実測で 2ms ぶんに調整、フレーム合計 12ms（ジェスチャ中 4ms）まで。面の束は増えたぶんだけ足し、育ち切ったら 1 本に |
| メッシュ生成 | フレーム合計 20ms まで。超えたぶんは手持ちの段か穴埋めで繋いで次のフレームに。3 秒描いていないメッシュは捨てる（`Vertices` は native 側で 1 枚 1〜2MB） |
| 隠れ判定 | 点は 1 フレーム 300 個まで、ジェスチャ中は判定しない。結果は方位・傾きが変わるまで持つ |

結果: UI 中央値 **5〜6ms**（回転・傾け中 4〜19ms）、最大 71ms（DEM の段が切り替わる瞬間だけ）、raster 中央値 8〜9ms、停止なし、欠けフレーム 0。
内訳ログは `[3D] refresh`（40ms 超）・`[3D] paint`（40ms 超）・`[3D] mesh`（25ms 超）・`貼り付け 一片`（30ms 超）。
Godot 乗り換えは不採用（地図面以外が全部 Flutter、web が重くなる）。次の手があるなら `flutter_gpu`（頂点バッファ・深度バッファ）

## データ側

- **標高ソースは連なり**（`DemTileSource.defaultCascade`、2026-09-09）: 地理院 DEM1A（航空レーザ 1m、z17 まで）→ DEM5A（5m、z15）→
  DEM10B（10m、z14。タイル名は `dem_png`。`dem10b_png` は無い）→ AWS Terrain Tiles（30m 級、全球）。
  404 は `BaseMapService` で再試行しない（以前は 2 回粘って 1 枚 1.5 秒）。無かった (ソース, タイル) はアプリ全体で覚える。**点ごとに重ねる**: 細かいソースの無効な点（整備範囲外・水面。
  地理院 PNG は RGB=(128,0,0)）は次のソースの値で埋め、穴が埋まったらそれ以上は聞かない。ソースごとに MBTiles の擬似プロバイダ
  （`gsi_dem1a_png` など）。無かった (ソース, タイル) はセッション内で覚える（404 を毎回聞くと 1 枚数秒）。
  和歌山県の陸域は DEM1A がほぼ全面ある（Vault `3D化の詰め` 11 節に被覆図）
- ⚠ 取れないタイルは 0m の平面ではなく null → 親（最大 5 段上）から高さの空間で双一次補間した近似で埋め（`sourceZoom` で区別）、
  本物が取れたら差し替える。無効値を「直前の値で埋める」と整備範囲の縁で行ごとの縞と台地になる（やった）
- **残った穴の埋め方（2026-09-13 夕、北山川で台地を観測して直した）**: 主力 3 ソースを重ねても残る穴（川・湖は 3 つとも無効）は
  ①親の近似 → ②最後の砦（AWS。水面にも値がある。z ≤ 15 だけ、細かい段は親の近似が受け継ぐ）を点ごとに重ねる → ③それでも残れば
  `fillInvalidHeights(h, cols:)` で周りから補間（行の中は左右、行ごと無効なら上下の行の間）。
  以前の「直前の値」は、南の縁を川が横切って先頭の行が丸ごと無効だと「タイルの最初の有効値」の板（垂直の壁つき）になった。
  親の近似が板を受け継ぐので子タイルにも出る
- **オーバーレイ画像**（GeoTIFF など）は地形のテクスチャに焼く: 四隅の Mercator 座標 → テクスチャ画素のアフィン変換で
  `drawImage`。見えている集合・位置が変わったら 400ms にまとめて `TerrainWorld.retexture`。web は未対応（ファイルパスで読めない）
- 焼き込み CLI（地理院 DEM を Terrarium に）は DEM1A の配信で**当面不要**。県点群の DTM は必要な所だけ。配布先は GitHub Releases（決定）
- 背景は `RasterTileComposer` で表示範囲を 1 枚に合成。タイル取得は `TileFetcher` 関数で差し替えられる（既定は http。本番は `BaseMapService.getTile` を渡す）
- 出典表示: 地理院タイル・Terrain Tiles とも必要。スパイクでは地図面の左下に出している

## flutter_gpu スパイク（2026-09-10）

Vault `3D化の詰め_2026-09-07` 12 節の「Godot より先に flutter_gpu を試す」の実装。製品機能ではない（`lib/screens/terrain_spike/` の GPU チップ）。

| ファイル | 役割 |
|---|---|
| `lib/core/terrain/gpu/terrain_gpu_renderer.dart` | `TerrainGpuRenderer`: DEM を頂点バッファ（position + uv + shade、24B/頂点、32bit インデックス）に一度だけ上げ、面の束（position + rgba、28B/頂点）も一度だけ。毎フレームは mvp 1 本（正射影 or 透視）をユニフォームに書いて 2 draw。深度バッファ付き（面は深度を書かず、NDC で 0.0005 手前に寄せて z-fight 回避）。`GpuImageSurface` に描いて `ui.Image` を Canvas に `drawImageRect` |
| `terrain_gpu_renderer_stub.dart` / `terrain_gpu.dart` | web 用の空実装と条件 export（`package:flutter_gpu` は dart:ffi 依存） |
| `shaders/*.vert|frag`, `terrain.shaderbundle.json`, `hook/build.dart` | シェーダ束。`flutter_gpu_shaders` の build hook が `build/shaderbundles/terrain.shaderbundle` を作り、pubspec の assets で載せる（web ビルドでも hook は走る） |
| `android/app/src/main/AndroidManifest.xml` | `io.flutter.embedding.android.EnableFlutterGPU=true`（無いと `gpuContext` が例外） |

正射影の mvp は `TerrainCamera.project` と同じ幾何を行列にしたもの（真上 = 2D 地図と一致）。奥行きは `TerrainCamera.depth` を DEM の箱の 8 隅で正規化。
透視は「画面中心で 1m = scale px になる距離」に視点を置く（fov 50°）。NDC は +Y が上、z ∈ [0, 1]（OpenGL の [-1, 1] を半分に畳む）。
ラベルは Dart 側で `toScreen`（最後の mvp）を使って Canvas に描く。ヒットテストは範囲外。

### 計測（2026-09-10・Pixel 9・profile・合成地形・回転アニメ・ラベル 200）

| 経路 | 条件 | fps | UI 中央値/最大 | raster 中央値 | Dart 側の描画コスト |
|---|---|---|---|---|---|
| 純 Dart | 401² LOD（step 2） | 57〜58 | 9 / 48 | 6 | build 2〜4ms |
| 純 Dart | 401² 全解像度 | 39〜43 | 15 / 72 | 7〜8 | build 5〜13ms |
| 純 Dart | 801² 全解像度 | 23〜26 | 30 / 170 | 15〜17 | build 21〜27ms |
| flutter_gpu | 801²（64 万頂点） | 59〜60 | 7 / 17 | 7〜8 | encode 0.5〜0.7ms |
| flutter_gpu | 801² + 1 万面 | 60 | 6〜7 / 14 | 7〜8 | encode 0.5〜0.7ms |
| flutter_gpu | 801² + **10 万面**（面 106 万頂点） | 59〜60 | 7 / 16 | 7〜8 | encode 0.4〜1.0ms |
| flutter_gpu | 同上・透視投影 | 60 | 7 / 13 | 7〜9 | encode 0.4〜0.7ms |
| flutter_gpu | 同上・透視・ラベル 1000 | 60 | 7〜8 / 14 | 10〜11 | encode 0.3〜0.4ms |

debug ビルドの数値もほぼ同じ（純 Dart 801² が 17〜19fps・UI 35ms、GPU 側は同じ）。

- 「UI 中央値 6ms」の中身は地図面以外（ウィジェットの build・ラベル 200 個の描画・計測）。地形と面の描画は 2 draw call で **1ms 未満**、頂点数に依らない
- 静止時は ui 0ms（`_repaint` が無ければ描かない）
- 面 10 万（106 万頂点・28MB）の上げ直しは 116ms、地形 801²（64 万頂点・15MB + インデックス 15MB）は 83ms（テクスチャ 2048² の `toByteData` 込み）
- 見た目: 面は深度バッファで地形に正しく埋まり、painter's algorithm の帯分割・象限走査・pitch 上限（70°）は不要になった。透視投影も同じコードで出る（fov 50°）


## flutter_gpu を TerrainWorld に（2026-09-11）

スパイクの結果（上）を受けて、本体の地図面（`TerrainMapLayer` → `TerrainWorldPainter`）の地形・面・線を flutter_gpu で描くようにした。
点とラベル・ヒットテスト・投影（`TerrainProjection`）は Dart 側のまま。web は従来の純 Dart 経路（`drawVertices` + 象限走査）がそのまま残る。

| ファイル | 役割 |
|---|---|
| `gpu/gpu_geometry.dart` | 純 Dart の頂点パッカー（flutter_gpu 非依存・テスト可）。地形 `GpuTerrainGeometry`（position + uv + shade、32bit インデックス、スカート込み）、面 `GpuPolygonGeometry`（position + rgba、`LiftedPolygon` のリストから `from` 番目以降を増分で）、線 `GpuLineGeometry`（線分 1 本 = 頂点 4 + インデックス 6。両端 a, b・t・side・width・rgba） |
| `gpu/terrain_gpu_world.dart` | `TerrainGpuWorldRenderer`: 複数タイルを 1 パスで描く。web は `terrain_gpu_world_stub.dart` |
| `shaders/line.vert` / `line.frag` | 線の太さを画面空間で付ける頂点シェーダ（両端を mvp で落として直交方向に width/2、端も width/2 伸ばして角の欠けを隠す）。`FrameInfo` は mat4 + viewport(vec2) + pixel_ratio |
| `TerrainMeshBuilder.buildStatic()` / `gpuGeometry()` | 投影しない骨組みだけの `TerrainMesh`（`bands` 空。貼り付けの `chunkOfCell` / `cellIndexAt` に使う）と、GPU に上げる頂点列 |
| `TerrainWorldPainter.gpu` / `TerrainTileDrawable.builder` | `gpu` があれば地形・面・線を `render` の画像で敷き、無ければ従来どおり。ビルダーは GPU 側のバッファのキー |

仕組み:

- **タイルごとの mvp**: 頂点はタイルの DEM 原点基準のまま。カメラ中心基準の正射影（`_orthographicMvp` と同じ幾何）に
  タイル原点の平行移動を畳んだ行列をタイルごとに host buffer へ置く（1 枚 64 バイト）。float32 で世界座標を直接持たないので Mercator 2×10⁷ m でも精度が足りる
- **深度の正規化**: 描くタイルの箱（xy）× 標高の範囲（世界の `heightRange` とタイルの min/max、上下 5% の余白）の 8 隅で `camera.depth` の min/max を取り [0, 1] に
- **バッファの寿命**: 地形はビルダー（縁が変わると別物）、テクスチャは `ui.Image`（`Texture.fromImage` で包む。コピー無し。包めなければ `toByteData` で別経路）、
  面・線はシーンのリスト（`_TileScene.polygons` / `lines` の同一性）をキーに持ち、3 秒描いていないものは手放す（`DeviceBuffer` に dispose は無く GC 任せ）。
  レイヤの `_meshes` は GPU 経路では骨組みメッシュを方位に依らず持ち続ける（`(NaN, NaN, mesh)`）
- **育つ貼り付け**: 静的シーンは 1 フレーム数 ms ずつ育つので、`list.length` が伸びたぶんだけ新しいバッファを足す（1 回の追加 = 1 draw）。
  1 秒育っていなければ 1 本に畳む。動的なもの（軌跡・向き・描画中）は毎フレーム host buffer に流す
- **z-fight**: 面と線は深度を書かず、`2 + セル幅 × step / 2` m ぶん手前に寄せる（面の頂点は細かい DEM で持ち上げ、地形は step で間引くのでその差）。線はさらに 1.5 倍
- **切り替え**: `TerrainGpuWorldRenderer.create()`（シェーダ束の読み込み）は非同期なので、できるまでは純 Dart 経路で描き、できたら投影済みメッシュを捨てて骨組みに差し替える。
  失敗したら純 Dart のまま（ログ `[3D] flutter_gpu 不可`）
- 帯分割・象限走査・スカートを先に描く順・pitch 上限は GPU 経路では要らない（深度バッファ）。コードは web のために残す
- **ミップマップと MSAA（2026-09-11 昼・松本「回転中にテクスチャがギザギザ荒ぶる」）**: 包んだだけの `ui.Image` はミップ段が無く、
  傾けた遠くでテクセルを飛ばして拾うので回転中にちらつく。`toByteData(rawRgba)` → isolate で 2×2 平均のミップ段（`buildMipChain`、純 Dart）→
  `createTexture(mipLevelCount:)` に段ごと `overwrite` で上げ、包んだテクスチャと差し替える（届くまでは包んだ方で描く）。
  サンプラは三線形 + 異方性 4。色バッファは MSAA 4x（`ColorAttachment.resolveTexture` に `frame.colorTexture`、`StoreAction.multisampleResolve`。
  深度も sampleCount 4）。Pixel 9 debug のドライブで欠けフレーム 0・UI 中央値 4〜8ms・raster 3〜5ms のまま（増分なし）。
  ⚠ `Texture.fullMipCount(512, 512)` は 9（1×1 を数えない）で `buildMipChain` は 10 段作る → テクスチャ側の段数に合わせて余りを捨てる。
  flutter_gpu の Dart API に GPU 側でミップを作る口は無い（`doesSupportManuallyMippedTextures` で手上げ）。
  メモリは包んだ画像 + ミップ付きの複製で 1 タイル +1.3MB → **複製ができたら `ui.Image` を手放す**（同日昼）:
  `TerrainTile.textureKey`（画像を差し替えるたび新しくなる世代の識別子）を GPU 側のキャッシュのキーにし、
  `onTextureUploaded(key)` で `tile.releaseImage()`。GPU 側のテクスチャは時間では捨てず、タイルの出入りで `pruneTextures(生きている世代)`
- **線の端を丸く・点を GPU に（同日昼）**: `line.frag` は線分に沿った座標を受けて端からの距離で丸める（折れ線の角は隣の線分の丸い端で埋まる）。
  点は `point.vert/frag` で画面に正対する円 + 白縁（`GpuPointGeometry`、静的な点だけ。動的な点は Canvas のまま）。
  深度テストで丘の裏の点が隠れるので Dart 側の視線なぞり（1 フレーム 300 点上限）が要らなくなった。
  林班・1 万点の範囲のドライブ（debug）: UI 中央値 4〜18ms → **3〜6ms**、raster 4〜5ms、欠けフレーム 0 / 2,452
- **陰影は傾斜依存（同日昼・松本の提案）**: `TerrainShading`（source: slope / hillshade、blend: multiply / overlay）。
  頂点の shade は「オーバーレイ用のグレー」で統一し、`terrain.frag` の `ShadeInfo` uniform で重ね方を選ぶ（純 Dart は 2 × shade の乗算）。
  オーバーレイは白い基図で白が残って傾斜が見えないので、既定は傾斜 × 乗算・濃さ 0.6・50° で頭打ち（0.5 は薄く 0.8 は濃い、松本）。
  ⚠ static の初期値はホットリロードで変わらない（ホットリスタート）。ゴールデンテストは光源に固定
- **陰影を光源から傾斜に（2026-09-11 昼・松本「赤色立体図に近いものをグレースケールで薄く重ねる方がよくない？」）**: `TerrainShading`（`terrain_mesh.dart`）。
  `source`（`slope` = 傾斜角 / `slopeMaxDeg` で濃さ、光の向きに依らない／`hillshade` = 従来）と `blend`（`multiply`／`overlay`）を独立に持つ。
  頂点の `shade` は「オーバーレイ用のグレー（0.5 = 変化なし）」で統一し、GPU 経路は `terrain.frag` の `ShadeInfo` uniform で重ね方を選ぶ、
  純 Dart 経路は 2 × shade の乗算。⚠ **オーバーレイは白い基図（地理院標準）では白を白のまま残すので、傾斜がほぼ見えない**
  （等高線だけ濃くなる）→ 既定は `slope` × `multiply`、`slopeStrength 0.5`・`slopeMaxDeg 50`。
  ⚠ これらは static なのでホットリロードでは初期値が変わらない（ホットリスタートで確認）。
  赤色立体図のもう一方の成分（地上開度・地下開度 = 尾根を明るく谷を暗く）は未実装（近傍探索が要る。曲率で近似する案）

### 計測（2026-09-11・Pixel 9・Kitayama-2026・ドライブ 48 秒）

| ビルド | 場所 | UI 中央値 / 最大 | raster 中央値 / 最大 | 欠けフレーム |
|---|---|---|---|---|
| debug・GPU | 大沼（フィーチャ少） | 3〜7 / 8〜55ms | 3〜5 / 5〜14ms | 0 / 2,673 |
| debug・GPU | 林班・林道・1 万点 1 万面の範囲 | 4〜18 / 12〜69ms | 4〜7 / 5〜14ms | 0 / 2,349 |
| **profile・GPU** | 大沼 | **1〜5 / 7〜28ms** | **3〜5 / 4〜16ms** | 0 / 2,834 |
| **profile・GPU** | 林班・林道・1 万点 1 万面の範囲 | **2〜17 / 7〜58ms** | **4〜15 / 7〜32ms** | 0 / 2,427 |
| （参考）profile・純 Dart（9/9） | 同上 | 5〜6 / 60〜70ms | 8〜9 | 0 |

- 40ms 超の `[3D] paint` は最初の 1 フレーム（パイプラインの温め 62ms）と、ラベル数千・点数千のタイルが入った 1 フレーム（45〜56ms、GPU 側は encode 0ms）だけ。
  残る UI 時間はラベルの layout・点の投影と隠れ判定・貼り付け（GIS 側）。密な範囲で寄った瞬間の raster 15〜32ms も点・ラベルの Canvas 描画
- 3D の出入り 2 往復・3D 中のタップ（情報カード）・GPS 軌跡（動的な線）・オーバーレイ画像（テクスチャ）は従来どおり

## 3D を正に（2026-09-11 昼）

決定（松本、推奨採用）: 長押しの割り当てなし／pitch 上限 75°／起動時は真上。

- `Terrain3dMode` の既定は `!kIsWeb`。Android / desktop は起動から 3D（pitch 0 = 2D と同じ絵）。ツールバーの ⛰ は web だけ
- **3D の間は MapLibre を組まない**（`_buildMapLibreMap` が `SizedBox`）。ネイティブの地図も Graphics メモリも持たない。
  web は 3D を抜けたときにここで組み直す（カメラは `RMapController` が覚えている）
- `RMapController.jumpOverride`: `move` / `moveAndRotate` / `animateTo` を 3D のカメラへ流す。**置いた瞬間に attach 前の保留分も流す**
  （3D 既定では `attachStyle` が来ず、起動時の現在位置ジャンプが永久に保留されていた）
- `_pushFeaturesToSources` は MapLibre のソース初期化に関わらず 3D に先に流す（未初期化で早期 return して 3D にフィーチャが来なかった）
- 3D 側で不足していた 2D 機能は無い（クラスタは格子まとめ、パーティは点とラベル、DeviceTool・描画プレビュー・投げ縄・変形ハンドル・画面外インジケータは済み）
- **web も起動から 3D**（同日昼）。純 Dart 経路の fps（Surface Pro 9・Chrome・profile・terrain-spike・合成地形）:

  | 条件 | fps | UI 中央値/最大 | raster 中央値/最大 |
  |---|---|---|---|
  | 401² LOD 静止 | 59 | 1 / 25ms | 9 / 13ms |
  | 801² 回転（LOD、step 4） | 43 | 10 / 20ms | 10 / 20ms |
  | 801² 回転（全解像度） | 12 | 52 / 67ms | 27 / 29ms |

  本体はジェスチャ中 4 万セルの予算で間引くので、回転中は LOD の行に近い
- **MapLibre は地図ページから撤去した（同日午後）**。`MapSourceManager`、basemap／overlay の mixin、party・overlay の `ml.Layer` ビルダー、
  DeviceTool の `buildOverlayLayers` / `buildOverlayMarkers`、`Terrain3dMode` provider、⛰ ボタンを削除。
  `MapStyleGroup` と `kStyleProp` / `kLabelProp` は `lib/models/map_style_group.dart`、View 固有スタイルの束は `MapPageStateBase.styleGroups`。
  MapLibre が残るのは feature_editor の地図（と、それが使う `RMapWidget` / `RMapController` の attach 部分）だけ。
  `RMapController` は地図ページでは「カメラを覚える箱 + 3D への override」として使う。
  web の逃げ道（2D）は無い。重い端末はジェスチャ中の間引きに頼る（web で GPU を使う道は WebGL2 を JS 相互運用で叩く案、未着手）
- ⚠ **web が起動時に `DeferredNotLoadedError` で真っ白**（同日発覚）: `slang_build_runner` は `slang.yaml` を読まず `build.yaml` の options だけを見る。
  `lazy` の既定 true で日本語が deferred import になり、`LocaleSettings.useDeviceLocaleSync()` が投げていた。`build.yaml` に slang の options を写して `lazy: false`。
  Flutter 3.47 化（9/10）で codegen を build_runner 一本にしたときから壊れていた

## 眺めモード（透視投影、2026-09-11 昼）

コンパスの長押しで切替（透視中はコンパスの縁が空色）。GPU 経路のみ（純 Dart の描画は正射影の線形性に頼っている）。

- `TerrainCamera.perspective`: 同じ方位・傾き・倍率のまま、画面中心（高さ centerHeight）で 1 m = scale px になる距離に視点を置く（fov 50°）。
  画面の「上」は `(sinB·cosP, cosB·cosP, sinP)`（視線と直交。真上のときは方位の向き。up = z 軸だと真上で退化する）
- 投影は線形でないので、ラベル・動的な点・ヒットテストは毎フレーム行列で落とす（`projectPerspective`）。
  逆投影は逆行列で視線を作り、地上距離 stepMeters ずつ地形をなぞる（`intersectRayPerspective`）。隠れ判定は点から視点へなぞる
- GPU の mvp は `toUnit × proj × view × diag(1,1,zScale)`。タイルの平行移動は M × T = 4 列目に M の 1・2 列 × 移動量（**w 行も**）
- 靄: `terrain.frag` がクリップ w（視点からの奥行き）で視点距離 × 1.5〜4 を空色に溶かす。クリアも空色（地平線の上が空）。
  面・線は同じ距離で α を落として消える（`polygon.frag` / `line.frag` に `ShadeInfo`。空色に寄せると地形の靄と二重に掛かる）。点は掛けない。靄より遠いラベルは省く
- タイル計画: `groundBounds` は 4 隅の視線と高さ平面の交点。地平線の上を向く隅と遠すぎる隅は靄の先（× 4）で打ち切る。
  傾けると画面に掛かるタイルが 30 枚まで増える（正射影は 12）。段は `visibleTileCount` の見積もりで下がる
- Pixel 9 debug: 傾けた眺めで山並みが靄に溶ける。タップの情報カード（面・線）も効く。ドライブは欠けフレーム 0・UI 中央値 6〜18ms・最大 141ms（入った瞬間のタイル一斉読み込み）
- 2 本指の移動・拡縮は透視でも指の下の地面（中心の高さの平面）を追う（`_groundUnder`）。純 Dart 経路は透視に対応しない（GPU が無い環境の逃げ道としてだけ残る）

## web の GPU（WebGL2、2026-09-11 午後・`feature/web-gpu`）

flutter_gpu は web に無い（Impeller が無い）ので、`terrain_gpu_world_web.dart` が `package:web` で WebGL2 を直接叩く。
`terrain_gpu.dart` の条件 export で Android と同じクラス名 `TerrainGpuWorldRenderer`・同じ API になり、
`TerrainWorldPainter` と `TerrainMapLayer` は分岐を持たない。

- 頂点データは Android と同じ `gpu_geometry.dart` のパッカー。シェーダだけ GLSL ES 3.00 に書き直し（`terrain_gpu_world_web.dart` 末尾の Dart 文字列）。
  uniform はプレーン（`u_mvp` / `u_viewport` / `u_pixel_ratio` / `u_params`）、Impeller の NDC z ∈ [0,1] を `z' = 2z − w` で [-1,1] に直す
- 描画先は自前の `<canvas>`（`pointer-events: none`）。`platformViewType` を `HtmlElementView` に渡して `CustomPaint` の下に敷き、
  Flutter は点（動的）とラベルをその上に描く。`render` は画像を返さない（`ui.Image` に包む往復が要らない）
- MSAA 4x は multisample renderbuffer（RGBA8 + DEPTH_COMPONENT24）→ 既定の framebuffer へ `blitFramebuffer`。
  ミップは `generateMipmap`（isolate の手作りは要らない）、`EXT_texture_filter_anisotropic` 4。テクスチャは `toByteData(rawRgba)` から `texImage2D`（非同期、できるまで白）
- ⚠ `clear` は `depthMask` に従う。面・線で `depthMask(false)` にしたまま次のフレームの clear をすると深度が残り、回すと地形が欠ける。clear の前に true に戻す
- ⚠ 属性配列はコンテキスト全体の状態。線（6 属性）の後に地形（3 属性）を描くと余りが別バッファを指したまま範囲検査に掛かるので、使わない属性は切る
- 動作確認はスパイク画面の「world GPU」（本体の `TerrainWorldPainter` + このレンダラを 1 タイルで動かす）。切り分けチップ: 深度なし / MSAA なし / getError / flush。
  地図ページの web も同じ経路で地形が出る（DEM は http で取れていた。`kIsWeb` で止めていたのはオーバーレイ画像で、これも `fs` 経由で読むようにした）
- 本体の地図ページでも `HtmlElementView` はプラットフォームビューなので、Flutter の場面が canvas の上下に分かれる（オーバーレイ canvas）。ラベルの Canvas 描画はそのまま動いた

### 計測（2026-09-11・Surface Pro 9 の Chrome・`web-server --profile`・スパイク画面・ラベル 200）

| 場面 | 純 Dart | WebGL2 |
|---|---|---|
| 401² 静止 | 59 fps | 60 fps（UI 1ms / raster 2〜4ms） |
| 801² 全解像度・回転 | 12 fps | 60 fps（正射影）、45〜52 fps（透視。UI 中央値 10ms＝Dart 側のラベル・点） |

## 未着手

1. `SceneSink` / `MapSurfaceController` のインターフェース抽出（[[scene-model]]）。いまは `TerrainMapLayer` が
   `FeatureGeoJsonCache` と `MapStyleGroup` を直接読む形で seam ② を先取りしている
2. 3D 中の機能追い付き（上の「未対応」）。残りはクラスタ・等高線オプション・web のオーバーレイ画像・パーティのマーカー（ウィジェット）
4. 等高線の描画コスト: 間引いた格子から引いても 1.7 万本で raster 30〜40ms（Impeller の細線）。
   ジェスチャ中はさらに間引くか、等高線だけ間隔を広げる
5. DEM の dir 同梱・焼き込み CLI・タイルキャッシュからのテクスチャ合成
6. `--wasm` ビルド: 動くが採らない（2026-09-11 計測: 純 Dart の LOD 回転が 43 → 60 fps になる一方、静止の raster が 6 → 16ms（skwasm）。WebGL2 で描く今は要らず、多スレッドには hosting の COOP/COEP も要る）

## 参考

- Vault `3D化の詰め_2026-09-07`（設計の正典）、`3D地形と陰影_2026-08-25`（陰影・DEM プリセットの話は生きている）
- MapLibre terrain の手法（Mercator の xy に `1/cos(φ)` を掛けた標高）と同じ座標系

## 地形の見た目と焼き込み（2026-09-12、プレイレポート対応）

### 色分け（傾斜・標高）はシェーダで

テクスチャを作って貼るのではなく、頂点が持つ傾斜（`slope`、0〜1 = 度/90。`TerrainMesh` が法線から出す）と
標高（`position.z`）からフラグメントシェーダで色を引く（`shaders/terrain.frag`、web は同じ式の GLSL ES）。
解像度はメッシュに依るので、傾けて横から見ても粗くならない（テクスチャ投影の弱点がそのまま消える）。
色の帯は 256×1 の ramp テクスチャ（`TerrainAppearance.rampBytes()`、3 色の補間。設定が変わると作り直す）。
`ColorInfo`（flutter_gpu）／`u_color_a`・`u_color_b`（WebGL）で種類・強さ・見えている範囲の標高・傾斜の上限を渡す。
強さ 100% で基図を使わない「地形だけ」の絵になる（圏外でも成り立つ）。

- 設定は「地形の見た目」（`TerrainSettingsScreen` → `terrainSettings` → `syncTerrainAppearance()` → `TerrainAppearance`）。
  描画側は毎フレーム `TerrainAppearance` の静的な値を読む（widget 木を通さない）
- 頂点は position(3) + uv(2) + shade(1) + slope(1) = 28 バイト（`GpuTerrainGeometry`）

### 等高線はラスタタイル（2026-09-13 に形からタイルへ）

松本「メッシュから計算した後はタイルとしてキャッシュして、地図・タイル側で背景地図として扱う。等高線の細かい設定は大胆に切り捨て」。
以前は タイル・段ごとに marching squares で線を作って形（`LiftedSegments`）として持ち上げていた（メモリのキャッシュだけ、web は同じスレッド、
設定は間隔・主曲線・色・太さ）。今は:

- `contour_tiles.dart`: 標高タイル（DEM）から marching squares で線を引き、256×256 の透明 PNG にする（`renderContourTilePng`、
  純 Dart で isolate）。テクスチャの段 z の 1 段下の DEM タイル（読み込み済みなら縁を借りた格子 `bordered`、無ければ `TerrainWorld.demFor`）の
  該当する 1/4 を描く。間隔はズームで固定（`ContourTiles.intervalForZoom`）。**地理院地図「標準地図」の出典に合わせる**（地理院タイル一覧: ZL18 = 電子国土基本図 2500 図式、ZL15〜17 = 同 25000 図式、ZL12〜14 = 20 万分 1、ZL9〜11 = 100 万分 1）:
  ZL18 以上 = 2 m（計曲線 10 m）、ZL15〜17 = 10 m（50 m）、ZL12〜14 = 100 m（500 m）、ZL9〜11 = 200 m。5 本ごとに主曲線。
  凡例 PDF（`cyberjapandata.gsi.go.jp/legend/std_*_legend.pdf`）には数値が無く、各図式（2 万 5 千分 1 地形図・20 万分 1 地勢図）の等高線間隔から
- 生成プロバイダ `BaseMapProvider.contourOverlay`（`BaseMapType.generated`、id `contours`、タイルキャッシュは `cacheId` = `contours_v{ContourTiles.version}`。絵を変えたら `ContourTiles.version` を上げる（id は設定の鍵なので変えない。古い版のキャッシュは `BaseMapService._dropStaleGeneratedCaches` が起動時に消す）。`availableProviders` の 1 つで、一覧では普通の背景地図として振る舞う）: `BaseMapService.registerTileGenerator` で
  生成器を登録し、`getTile` は キャッシュ → 生成 → キャッシュ（MBTiles）。背景地図と同じ経路なので一度作れば圏外でも出る。
- 3D のテクスチャ合成は `TerrainWorld.textureLayers`（設定の背景地図レイヤそのまま。等高線もその 1 層）を `composeLayers` で重ねる。
  以前は先頭 1 枚しか使っていなかった
- 設定は背景地図のレイヤに「等高線」が並ぶだけ（松本「カード分けなくてよくね？重ね合わせ機能ももともとある」）。標準地図の上に等高線（乗算）のように重ねる。地形の見た目 から等高線の節は消した。
  web の MapLibre（feature_editor）には URL が無いので出ない（`buildBasemapStyleJson` が飛ばす）
- 絵なので傾けると粗い（引いた段では気にならない）。線として持ち上げたい場面（真横から見る等）が出たら、そのときに考える

### 引いた段の焼き込み（真上からの投影）

z ≤ 13（`kBakeMaxZoom`）のタイルは、面・線・点を形として持ち上げず、**テクスチャに描き込む**
（`_bakeFeatures`。`TerrainWorld.textureDecorator` の中、オーバーレイ画像の次）。
描画コストは基図と同じ 1 枚で済み、1 万面でも回る。寄せた段は今までどおり形で描く。
選択・頂点・写真は形のまま（少ないし光らせたい）。ヒットテストはデータから引くので影響しない。
フィーチャが変わったら（`sceneRevision` で一覧の同一性が変わったとき）焼き込む段のタイルだけ
`retexture(where: _bakesFeatures)` で作り直す（400ms にまとめる）。

⚠ 焼き込みは真上からの投影なので傾けると粗い。引いた段なので目立たない、という割り切り。

⚠ **焼き直しは世代で管理する（2026-09-13）**: 以前は「一覧が変わった瞬間に読み込み済みのタイル」だけ焼き直していたので、
その瞬間に読み込み中だった親タイル（合成が終わってから `_tiles` に入る）はフィーチャ無しのテクスチャのまま残った。
寄せる最中は親と子が入れ替わるので、フィーチャが出たり消えたりして見える（松本の報告。web で目立つ）。
今は `_bakeGen`（一覧が変わるたびに進む）と、`_decorateTexture` がテクスチャの範囲から引いたタイルのキーごとに
「どの世代で焼いたか」（`_bakedGen`）を記録し、`_checkBakes`（世界の変化・一覧の変化から 400ms）が
古い世代のタイルだけ `retexture(where:)` する。打ち切られた分は要求を取り下げて見直す。
web は新しい世代の GPU 転送が非同期で、終わるまで白だったので、`TerrainTile.previousTextureKey` で前の世代を描き続ける
（`pruneTextures` は転送が終わるまで前の世代も生かす）。

⚠ **「一覧が変わった」の判定は中身で、焼き直す範囲は変わったフィーチャの範囲だけ**（同日）: GPS 軌跡の統合が 30 秒ごとに
全件を組み直す（`updateFeaturesImpl` → `rebuildAll`）ので、リストの同一性で見ると毎回「変わった」になり、焼き込み済み 46 枚を
毎回焼き直していた（1 枚 40〜90ms・UI スレッド）。`FeatureGeoJsonCache` はフィーチャごとに署名（座標の数と総和、スタイル・ラベル・名前）と
範囲を持ち、`contentRevision` と `lastChangeLonLat`（変わった・足した・消したフィーチャの範囲）を出す。
記録中の GPS 軌跡は中身として本当に伸びているので、その範囲に掛かるタイルだけ（Pixel 9 で 5 枚）焼き直す。
`_bakeEvents`（世代, 範囲）を 64 件持ち、タイルは「自分が焼かれた後の出来事のうち範囲に掛かるもの」があるときだけ古いとみなす。

### web のマウス操作とコンテキストメニュー

右ドラッグ = 回転・傾き（MapLibre の慣例）。ブラウザは右ボタンを離すと `contextmenu` を出すので、
`TerrainMapLayer` が載っている間だけ `BrowserContextMenu.disableContextMenu()`（`flutter/services`）で止め、
`dispose` で戻す。アプリ全体で止めないのは、テキスト欄などでブラウザのメニューを使えるようにするため
（止めている間、Flutter のテキスト欄は自前の選択ツールバーを出す）。

### 断層（縁の段差）

隣が自分より粗い近似（親から補間したタイル）なら、その縁は借りない（`TerrainTile._canBorrow`）。
借りた縁と自分の縁の差が 20m を超えたら debug で `[3D] seam` ログ（`lastSeamM`）。

### 背景地図はレイヤ（2026-09-13 午後）

松本「お絵描きソフトのレイヤ。順番と可視状態と透明度と合成モード」。重みの比で混ぜる旧式（`basemap_weights`、累積補正 α_i = w_i / Σw）はやめた。

- モデル `BaseMapLayer`（`lib/models/basemap_layer.dart`）: `providerId` / `visible` / `opacity` 0〜100 / `blend`（`BaseMapBlend` → `ui.BlendMode`）。
  `BaseMapService.layers` は**下から上**、設定画面は上から並べる。同じプロバイダは 1 枚まで。保存は prefs `basemap_layers`（JSON 配列）。
  旧 `basemap_weights` は `BaseMapLayer.fromLegacyWeights` で読み替え（α をそのまま不透明度にすると同じ絵）
- 合成 `RasterTileComposer.composeLayers(range, List<TextureLayer>)`: 灰色の下地 → `saveLayer` の透明な板に下から `drawImage(paint..color.alpha = opacity ..blendMode = blend)` → `restore`。
  一番下の層の合成モードは透明な板に対して効かない（お絵描きソフトと同じ）。設定画面でも一番下は選べない
- web 2D（feature_editor の MapLibre）は `raster-opacity` だけ（ラスタに合成モードは無い）。生成プロバイダは TileServer 経由でしか出せない
- 出典は地図面から消し、設定「地図・タイル」の「出典」節（いま見えているレイヤ + 標高）に。**OSM が見えているときだけ地図面にも出す**
  （OSM の attribution guideline は対話型地図で地図上のクレジットを求める。地理院タイル・Terrain Tiles は「出典の明示」で置き場所は問わない）
- 設定画面のプレビュー `BaseMapPreview`（`lib/widgets/basemap_preview.dart`）: 地図の中心のタイル 1 枚を同じ `composeLayers` で合成して見せる（設定変更から 300 ms 待って作り直し）
- 一括ダウンロードは一番下の見えているレイヤ（`currentProvider`）だけ。

### 高密度画面ではテクスチャを 2 段上で（2026-09-13 夕）

松本「ズーム最大にしても背景地図が粗い」。Pixel 9（密度 2.6）でタイル 256 px を論理 256 px に貼ると 2.6 倍に伸びる（地理院地図をスマホで見るのと同じ甘さ）。
地理院タイルは z18 までなので、それより寄った分（z20 で 10 倍、z22 で 42 倍）はどうにもならない（切り出しの線形補間と GPU のバイリニアで二重にぼける）。

- `TerrainWorld.textureZoomOffsetFor(demZoom)`: 密度 2 以上の端末では **DEM z15 以上だけ 2 段上**（テクスチャ 1024²、`TerrainMapLayer.didChangeDependencies` で設定）。z17 までの引き伸ばしが 2.6 倍 → 1.3 倍。
  引いた段は 512² のまま（眺めモードで 50 枚になっても膨らまない）
- `textureDecorator` は DEM の段を受け取る（テクスチャの段から逆算しない。z16 のテクスチャが存在しない等、段の対応が飛ぶ）
- 実測（Pixel 9 debug、z17、写真 + 等高線）: dumpsys の Graphics 1.94〜1.97 GB → 2.01〜2.02 GB（+50〜80 MB。見積もり 12〜16 枚 × 4 MB どおり）。
  初回の読み込みは 1 タイルあたり地図 16 枚 × 層を取るので 2〜5 秒（等高線 z18 の生成込み）、2 回目からは 0.8 秒未満（ログに出ない）。画像 LRU は 128 → 256 枚
- 等高線タイルは z19 まで作れる（DEM z17 から k = 2）。地理院タイルの z19 は z18 の切り出し重ねた層ぶんもまとめて落とすのは未
