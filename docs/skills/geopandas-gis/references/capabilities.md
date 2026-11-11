# GeoPandas スキルでできること（能力一覧）

`gpd_tool.py` のサブコマンドと、エージェントが直接コードを書く場合の対応関係。

## CLI サブコマンド一覧（`gpd_tool.py -h`）

| サブコマンド | 用途 |
|--------------|------|
| `info` | レイヤ一覧、または1レイヤの行数・CRS・bounds・列名 |
| `export` | 任意ドライバへ書き出し（`--bbox` で読込時フィルタ可） |
| `from-parquet` | GeoParquet → GPKG/GeoJSON 等 |
| `copy-layer` | 単一レイヤを別ファイルへ |
| `append` | 既存 GPKG レイヤへ追記（**スキーマ一致必須**・要バックアップ） |
| `filter-bbox` | bbox で読み絞り出力 |
| `filter-query` | `pandas.DataFrame.query` 相当で行抽出 |
| `reproject` | `to_crs` |
| `buffer` | 距離バッファ（cap/join style 指定可） |
| `dissolve` | `--by` 省略で全体統合 |
| `clip` | マスクで `gpd.clip` |
| `overlay` | intersection / union / difference / symmetric_difference / identity |
| `sjoin` | 空間結合（predicate 複数） |
| `sjoin-nearest` | 最近傍結合（`max_distance` 可） |
| `explode` | マルチジオメトリ分割 |
| `simplify` | トポロジ保持オプション付き単純化 |
| `make-valid` | Shapely `make_valid` |
| `calc-metric` | 投影CRSで面積・長さ列（地理座標は拒否、`--force`で無理やり） |
| `merge-csv` | キー列で属性マージ |
| `select-cols` | 列のサブセット |
| `rename-cols` | `--rename-map old:new,...` |
| `head-export` | 先頭N件だけ出力（検証用） |

## 入出力・メタデータ

| 操作 | CLI | GeoPandas / 備考 |
|------|-----|------------------|
| レイヤ一覧・行数・CRS・バウンディングボックス・列名 | `info` | `fiona.listlayers` / `pyogrio.list_layers` 相当は `info` 内で処理 |
| ベクタ読込 | （各コマンドの `--in`） | `gpd.read_file(path, layer=..., bbox=...)` |
| 書き出し GPKG/GeoJSON/SHP/FlatGeobuf 等 | `export` | `gdf.to_file(..., driver=...)` |
| 別GPKGへレイヤコピー | `copy-layer` | 読み込み→書き出し |
| 既存GPKGレイヤへ追記 | `append` | `to_file(..., mode="a")`（ドライバ・レイヤ一致に注意） |
| Parquet（中間・高速） | `export --driver Parquet` / `import` は `export` の入力を `read_file` | `read_parquet` / `to_parquet` は必要ならコードで追加可 |

## 属性・行の操作

| 操作 | CLI | 備考 |
|------|-----|------|
| バウンディングボックスで切り出し | `filter-bbox` | `read_file(..., bbox=)` または読込後 `cx` スライス |
| pandas クエリで絞り込み | `filter-query` | `gdf.query("人口 > 0")` |
| 列の選択 | `select-cols` | `gdf[columns]` + geometry |
| 列のリネーム | `rename-cols --rename-map old:new,...` | `gdf.rename(columns=...)` |
| CSVと属性結合（非空間） | `merge-csv` | `gdf.merge(csv_df, left_on=, right_on=)` |
| 先頭N件だけ出力 | `head-export` | 検証用 |

## 座標系・幾何単体

| 操作 | CLI | 備考 |
|------|-----|------|
| 再投影 | `reproject` | `gdf.to_crs(...)` |
| バッファ | `buffer` | `gdf.buffer(distance, cap_style, join_style)` |
| 単純化 | `simplify` | `gdf.simplify(tolerance)` |
| 不正ポリゴン修復 | `make-valid` | `shapely.make_valid` |
| MultiPart 展開 | `explode` | `gdf.explode(index_parts=...)` |
| 面積・長さ列の付与 | `calc-metric` | 投影座標系で `area` / `length`（地理座標では警告） |

## 空間集約・集合演算

| 操作 | CLI | 備考 |
|------|-----|------|
| ディゾルブ | `dissolve` | `gdf.dissolve(by=..., aggfunc=...)` |
| クリップ | `clip` | `gpd.clip(gdf, mask)` |
| オーバーレイ | `overlay` | `gpd.overlay(..., how=intersection|union|difference|symmetric_difference|identity)` |

## 空間結合

| 操作 | CLI | 備考 |
|------|-----|------|
| 空間結合 | `sjoin` | `gpd.sjoin(..., predicate=intersects|within|contains|covers|...)` |
| 最近傍結合 | `sjoin-nearest` | `gpd.sjoin_nearest(..., max_distance=...)` |

## エージェントがコードで足しやすい定番

- **中心点・代表点**: `gdf.geometry.centroid` / `representative_point()`
- **凸包・エンベロープ**: `gdf.unary_union.convex_hull` 等
- **座標一覧**: `gdf.get_coordinates()`（GeoPandas 0.14+）
- **WKT/WKB**: `gdf.to_wkt()` / `from_wkt` 系
- **GeoSeries 演算**: `contains`, `intersects`, `distance`（投影CRS推奨）

## 制限・注意

- **Shapefile**: 10文字列名制限・単一ジオメトリ型などの制約あり
- **GPKG**: 複数レイヤ可能。`layer` 指定を明示する習慣が安全
- **追記 `append`**: スキーマ一致・ジオメトリ型一致が前提。環境によっては GDAL の追記モードが失敗する場合あり。その場合は `export` で新規レイヤ作成や QGIS 側マージを検討。必ずバックアップ
- **大規模データ**: `bbox` 読み、`Parquet` 中間、または PostGIS 検討
- **Windows on ARM**: ホイールが不安定なら x64 Python venv（AGENTS.md）
