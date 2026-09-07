---
title: 3D 地図の設計メモ
tags: [technical, design, 3d, dem]
---

# 3D 地図の設計メモ（2026-09-07・未着手）

松本の要件（2026-09-07）:

- 最低限 DEM、できれば普通のメッシュに近いもの
- 地図は上から投影することになるが、**画像を貼る方式は反対**。急斜面を横から見たときに
  ベクターとして崩れない描画がほしい
- 視点は**正射影**（透視投影ではない）

## GIS で地形を持つ形式

| 形式 | 中身 | 向き不向き |
|---|---|---|
| DEM（GeoTIFF / 国土地理院 DEM5A・10B の XML → GeoTIFF） | 格子の標高値 | 入手が容易。格子なので急斜面は階段状。5m 格子で村域なら数十 MB |
| Terrain-RGB / Terrarium タイル | 標高を RGB に符号化した PNG タイル | MapLibre がそのまま読める。オンライン前提だが mbtiles 化すればオフライン可 |
| TIN（不規則三角網。GeoPackage には標準が無い、GML / LandXML / OBJ） | 三角形メッシュ | 「普通のメッシュ」に一番近い。尾根・谷に沿った三角形で急斜面が崩れない。作るには DEM から三角化（QGIS の TIN 補間、PDAL、Delaunay）|
| 点群（LAS / LAZ。林野庁・県の航空レーザ） | 点 | 森林の現場では最も価値が高い（樹冠と地盤）。表示は別物（点群ビューア）。DTM/DSM を作る元 |
| 3D Tiles / glTF | 都市モデル向け | PLATEAU 系。山間部の林業にはほぼ無い |

現実的な線は **DEM を持ち、表示時に TIN 化する**。データの流通は DEM（GeoTIFF）、描画はメッシュ。

## 描画方式の比較

### A. MapLibre の terrain（raster-dem）

- `terrain` ソースに Terrain-RGB を渡すだけで、既存のベクターレイヤ（fill / line / circle）が
  地形に沿って**ドレープ描画**される。ラインは地表に沿った折れ線、面は地形に貼り付く
- ⚠ 松本が反対している「画像投影」ではない。ベクターは GPU 側で地形の高さに乗せて描くので、
  横から見ても線は線のまま。ただし**面の塗りは地表テクスチャとして貼られる**ので、崖では引き伸ばされる
- ⚠ 視点は**透視投影のみ**（`pitch` ≤ 85°、正射影は無い）。ここが要件と合わない
- ⚠ maplibre_flutter（`maplibre` 0.3.x）の Android 側で terrain が使えるかは未検証。
  MapLibre Native は 2024 以降 terrain 対応だが、Flutter バインディングの API 露出が要確認
- 工数: 小（数日）。データ準備（DEM → Terrain-RGB タイル → mbtiles）が主

### B. 自前の正射影メッシュビュー（別画面）

- DEM を読み、表示範囲を TIN（または規則格子の三角形）にして、`three_dart` / `flutter_gl` /
  `CustomPainter` で描く。カメラは**正射影**（要件どおり）
- ベクターは**地表に沿って再サンプリング**して 3D 折れ線・3D ポリゴンとして描く
  （ラインは頂点を DEM で持ち上げ、区間を細分。ポリゴンは三角形分割して各頂点を持ち上げる）。
  これなら急斜面を横から見ても崩れない
- 背景地図（ラスタ）は貼らないか、貼るとしても任意。等高線や陰影は DEM から計算して線で描ける
- ⚠ Flutter で GPU 描画をやる土台が弱い。`CustomPainter` だと数万三角形が限界、
  `flutter_gl` は Android のみ安定。web は WebGL が要る
- ⚠ 地図の操作（回転・傾け・選択）を全部自前で持つことになる
- 工数: 大（数週間）。ただし **要件（ベクター描画・正射影）に唯一合致**する

### C. A と B の折衷

- 通常の地図は MapLibre のまま。「3D で見る」ボタンで **B の別画面**を開き、
  いまの表示範囲のフィーチャと DEM を渡す。3D 画面は閲覧専用（選択と情報表示まで）
- 3D 画面は正射影・回転・傾けだけ。編集は 2D に戻ってやる
- 工数: B とほぼ同じだが、「2D の地図に手を入れない」ので事故が少ない。**推奨**

## 決めること

1. DEM の入手経路。国土地理院の基盤地図情報（DEM5A/5B/10B）を GeoTIFF に変換して
   プロジェクトフォルダに置く手順を、アプリ内かツール（`tool/`）で持つか
2. 3D 画面の描画基盤（`flutter_gl` vs `CustomPainter` の三角形描画 vs `three_dart`）。
   Android 実機で 5m 格子 2km 四方（約 16 万三角形）が 30fps で回るかの実測が先
3. web 対応をどこまで求めるか（WebGL 前提なら Chrome / Edge 限定）

## 参考

- MapLibre terrain: `terrain: { source: 'dem', exaggeration: 1.0 }`、ソースは `type: raster-dem`, `encoding: terrarium | mapbox`
- 国土地理院 DEM → GeoTIFF: `fgddem.py`（基盤地図情報 XML 変換）または QGIS の「基盤地図情報 DEM インポート」プラグイン
- TIN 化: QGIS 「TIN 補間」の逆（点→TIN）は `scipy.spatial.Delaunay` か PDAL `filters.delaunay`
