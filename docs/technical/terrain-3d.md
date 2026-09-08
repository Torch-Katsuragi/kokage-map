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
  背景: `BaseMapService.getTile` をアクティブなプロバイダの累積補正済み opacity で合成（MapLibre と同じ式）
- 未対応: パーティの他メンバー・頂点マーカー・クラスタ・オーバーレイ画像（GeoTIFF）・描画プレビュー・
  外部機器ツールのオーバーレイ・等高線。DeviceTool（TruPulse）は 3D 中は選べない

## データ側

- DEM は Terrarium タイルで持つ（`DemTileSource` プリセット。既定は AWS Terrain Tiles、全球・キー不要）。
  地理院 DEM は `tool/` の CLI で Terrarium に焼く（未実装）。dir 同梱の読み取りも未実装
- 背景は `RasterTileComposer` で表示範囲を 1 枚に合成。タイル取得は `TileFetcher` 関数で差し替えられる（既定は http。本番は `BaseMapService.getTile` を渡す）
- 出典表示: 地理院タイル・Terrain Tiles とも必要。スパイクでは地図面の左下に出している

## 未着手

1. `SceneSink` / `MapSurfaceController` のインターフェース抽出（[[scene-model]]）。いまは `TerrainMapLayer` が
   `FeatureGeoJsonCache` と `MapStyleGroup` を直接読む形で seam ② を先取りしている
2. 3D 中の機能追い付き（上の「未対応」）。パーティのマーカーと頂点が先
4. 等高線の描画コスト: 間引いた格子から引いても 1.7 万本で raster 30〜40ms（Impeller の細線）。
   ジェスチャ中はさらに間引くか、等高線だけ間隔を広げる
5. DEM の dir 同梱・焼き込み CLI・タイルキャッシュからのテクスチャ合成
6. web の fps 計測（Chrome を前面にして）

## 参考

- Vault `3D化の詰め_2026-09-07`（設計の正典）、`3D地形と陰影_2026-08-25`（陰影・DEM プリセットの話は生きている）
- MapLibre terrain の手法（Mercator の xy に `1/cos(φ)` を掛けた標高）と同じ座標系
