---
title: 公式オープンデータ連携と微地形表現（System レイヤ・MVT・PMTiles・CS立体図）
tags: [technical, official-data, mvt, pmtiles, terrain, basemap]
---

# 公式オープンデータ連携と微地形表現

2026-11-14 実装。林班・国有林・地質図などの公的空間オープンデータを `System`（`SysNode`）の読み取り専用ストリーミングレイヤとして追加できるようにし、背景地図にも高精細航空写真カスケード・端末内自動生成 CS立体図・産総研シームレス地質図 V2 を組み込んだ。

## 設計原則

- **QGIS 相互運用（`.qgs`・Google Drive 同期）を汚さない**:
  `OfficialLayerNode` と `OfficialFeatureNode` は `getAbsoluteFilePath() => null` を返し、プロジェクトフォルダの実体ファイルにも `.qgs` にも書かない。端末ごとの表示設定として `SharedPreferences`（`official_enabled_layers` / `official_layer_visibility`）に保持し、Android・web の双方でルート直下の `SysNode` に同期する。
- **地域差を `bbox` カスケードで吸収する**:
  3D 地形の `DemTileSource` と同じく、テーマ単位（森林区画・地質・高精細オルソ）で公開元のリストを持ち、`bbox` とズーム範囲（`minZoom`〜`maxZoom`）が重なる上位ソースから順に試す。利用者は省庁や都道府県ごとの配信 URL を意識せずに使える。
- **純粋 Dart 実装（GDAL 再ビルド不要・Android / web 共通）**:
  同梱 GDAL には MVT / PMTiles ドライバを入れていないため、Protobuf ベースの MVT v2.1 デコーダと PMTiles v3 HTTP `Range` リーダーを純粋 Dart で実装した。Web（JS 数値表現）でも上位ビットが欠けないよう、64bit varint や Little-Endian uint64 はビットシフトではなく算術演算（53bit 安全範囲）で扱う。
- **外部 CSV 属性結合は行わない**:
  QGIS のベクトルタイルレイヤ（`QgsVectorTileLayer`）は `<vectorjoins>` を持たず、結合するには `.gpkg` への複製が必要になるため、公式レイヤは純粋な読み取り専用ストリーミングに徹する。個人情報を伴う筆界・所有者の管理が必要な場合は、従来どおり利用者の `.gpkg` レイヤ＋CSV 結合（[[qgis-interop]]）を使う。

## 構成

| ファイル | 役割 |
|---|---|
| `lib/core/official/mvt_decoder.dart` | Mapbox Vector Tile（MVT v2.1 / `.pbf`、gzip 圧縮・非圧縮両対応）を WGS84 の `geobase` `Feature<Geometry>` へ復号。Y 下向き画面座標の符号付き面積で外環・内環（穴）を分類 |
| `lib/core/official/pmtiles_reader.dart` | PMTiles v3 の 127B ヘッダ・Hilbert 曲線 `tileId`・列指向 varint ディレクトリ（leaf キャッシュ付き）を HTTP `Range` で読むリーダー |
| `lib/core/official/official_data_catalog.dart` | `OfficialLayerSpec`（`rinya_forest_plan`・`gsj_seamless_geology`）、`OfficialVectorSource`、`RegionalRasterSource.highResOrthoCascade` |
| `lib/core/terrain/cs_relief_tiles.dart` | `DemTiles` の標高格子から Horn 法傾斜＋多重スケールラプラシアン曲率を計算し、尾根（暖色朱茶）と谷（寒色青藍）を描き分ける 256×256 CS立体図 PNG 生成器（`TerrainWorker` 実行） |
| `lib/models/nodes/official_layer_node.dart` | `SysNode` 配下の `OfficialLayerNode` と、タップ選択用の擬似ノード `OfficialFeatureNode`（`FeatureNode` 非継承のため編集・削除・消しゴム対象外） |
| `lib/services/official/official_layer_service.dart` | 有効レイヤ永続化、`SysNode` 同期、MVT / PMTiles 非同期取得＋LRU キャッシュ、林班ポリゴン等のタップ当たり判定、産総研シームレス地質図 V2 `legend.json` 地点照会 |
| `lib/widgets/layer_drawer/tiles/official_layer_tile.dart` | `System` 内のレイヤ行（出典・推奨ズーム表示・目のアイコン・削除メニュー）と「公式データを追加」ボトムシート |

## 組み込みカタログと背景プロバイダ

### `System`（`sys`）から追加できる公式データ

1. **森林計画対象森林（林班・国有林）**（`rinya_forest_plan`）
   - 配信元: 林野庁 G空間情報センター `https://rinya-tiles.geospatial.jp/fr_layer_pbf_2025/{z}/{x}/{y}.pbf`（`z12`〜`z16`、`z17` 以上は `z16` タイルから自動オーバーズーム）
   - 3D 地形メッシュの動的シーン（`_buildDynamic`）に国有林（濃緑線＋`国` 接頭辞ラベル）と民有林（黄緑線＋林班番号ラベル）を描き分け、静的 GeoPackage シーンの再構築を起こさない。
   - タップ選択（`SelectTool` 優先度 3: 通常ポリゴンの次）で林班・民国別・森林計画区・森林管理署・概算面積・シルエットを表示。
2. **産総研 シームレス地質図 V2（20万分の1）**（`gsj_seamless_geology`）
   - 地形テクスチャ上に `gsj_geology_v2` ラスタタイルを乗算（65%）で合成しつつ、地図タップ時に `legend.json?point={lat},{lon}` を遅延照会して地質記号・形成時代・地層群・岩相を詳細カードに表示する。

### 背景地図・重ね合わせレイヤ

- **航空写真（高精細優先）**（`ortho_cascade`）: 国交省 Project PLATEAU オルソ（2024 → 2023、`tile.plateauview.mlit.go.jp`、`z14`〜`z19`）を優先取得し、整備範囲外（404）は即座に国土地理院 `seamlessphoto`（林野庁国有林写真・都道府県民有林写真・災害正射画像を統合済み）へフォールバックする。
- **CS立体図（微地形・自動生成）**（`cs_relief`）: 公開タイルが存在しない地域やオフライン環境でも、端末内の高精細 DEM カスケード（0.25m〜10m）から直接生成し `cs_relief_v1` として MBTiles キャッシュする。
- **シームレス地質図 V2**（`gsj_geology_v2`）: `z/y/x` 順 URL（最大 `z13`）を `_getTileWithFallback`（最大 6 段拡大）で `z19` までシームレスに拡大表示する。

## 将来の拡張（PMTiles カスケード）

地籍調査の筆界（法務省地図 XML 由来）や都道府県別の森林小班・樹種ポリゴンは全国単一の公式 XYZ サーバーが無いため、県別オープンデータを `.pmtiles` に変換して静的オブジェクトストレージ（Cloudflare R2 等）に配置すれば、`OfficialVectorSource` に `urlTemplate: 'https://.../wakayama_cadastral.pmtiles'` と `bbox` を 1 行足すだけで既存の `PmTilesReader`＋`MvtDecoder` パイプラインがそのまま動く。
