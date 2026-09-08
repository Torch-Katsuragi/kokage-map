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
- ラベル: ビルボード。地形に隠れない方針で最後に画面座標で描く

### ヒットテスト（`TerrainPainter.pick`）

ラベル > 線 > 面 の順。線は線分までの距離、面は投影した三角形の内外。
線と面は **地形に隠れていれば当てない**（`isOccluded`: 点から視点側へ視線の地上投影をセル幅ずつなぞり、
`1/tan(pitch)` で上がる視線より地形が高ければ隠れている。視線が DEM の最高点を超えたら打ち切り）。
ラベルは最後に上描きしているので当てる。

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

## データ側

- DEM は Terrarium タイルで持つ（`DemTileSource` プリセット。既定は AWS Terrain Tiles、全球・キー不要）。
  地理院 DEM は `tool/` の CLI で Terrarium に焼く（未実装）。dir 同梱の読み取りも未実装
- 背景は `RasterTileComposer` で表示範囲を 1 枚に合成。いまはネットから直接。本番はアプリのタイルキャッシュから読む
- 出典表示: 地理院タイル・Terrain Tiles とも必要。スパイクでは地図面の左下に出している

## 未着手

1. シーンモデルの切り出し（MapLibre を外すための抽象化）。既存のスタイル解釈を描画系から分離する
2. 真上ロック・カメラ同期・2 モードの交代
3. ラベルの衝突判定（MapLibre と同じく画面内の重なりを間引く）
4. 等高線の描画コスト: 間引いた格子から引いても 1.7 万本で raster 30〜40ms（Impeller の細線）。
   ジェスチャ中はさらに間引くか、等高線だけ間隔を広げる
5. DEM の dir 同梱・焼き込み CLI・タイルキャッシュからのテクスチャ合成
6. web の fps 計測（Chrome を前面にして）

## 参考

- Vault `3D化の詰め_2026-09-07`（設計の正典）、`3D地形と陰影_2026-08-25`（陰影・DEM プリセットの話は生きている）
- MapLibre terrain の手法（Mercator の xy に `1/cos(φ)` を掛けた標高）と同じ座標系
