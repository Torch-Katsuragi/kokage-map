---
name: geopandas-gis
description: >
  GeoPandas でベクタ（GPKG/GeoJSON/Shapefile/FlatGeobuf/Parquet 等）を読み書き・変換する。
  「GeoPandas」「GPKGを編集」「ベクタを結合」「クリップ」「バッファ」「CRS変換」「空間結合」
  「属性の一括処理」「レイヤ情報を見たい」等のトリガーで使用。
upstream:
  - https://playbooks.com/skills/k-dense-ai/claude-scientific-skills/geopandas
---

# GeoPandas / ベクタGIS スキル

## venv（必ず Drive 外）

既定: `$env:USERPROFILE\.venvs\geopandas-gis`

初回のみ依存導入:

```powershell
py -3 -m venv "$env:USERPROFILE\.venvs\geopandas-gis"
& "$env:USERPROFILE\.venvs\geopandas-gis\Scripts\pip.exe" install -r ".agent/skills/geopandas-gis/scripts/requirements.txt"
```

Windows on ARM でホイールが不安定なら **x64 版 Python** で同様に作る（AGENTS.md）。

## メインCLI: `gpd_tool.py`

ワークスペースルートで実行。

```powershell
$env:PYTHONUTF8 = "1"
$py = "$env:USERPROFILE\.venvs\geopandas-gis\Scripts\python.exe"
$script = ".agent/skills/geopandas-gis/scripts/gpd_tool.py"
```

### よく使う例

```powershell
& $py $script info --in "data.gpkg"
& $py $script info --in "data.gpkg" --layer "foo"
& $py $script export --in "a.gpkg" --layer "foo" --out "out.gpkg" --out-layer "foo"
& $py $script reproject --in "a.gpkg" --layer "foo" --out "b.gpkg" --to EPSG:6670
& $py $script filter-query --in "a.gpkg" --layer "foo" --out "sub.gpkg" --query "area > 100"
& $py $script clip --in "a.gpkg" --layer "foo" --clip "mask.gpkg" --clip-layer "m" --out "clipped.gpkg"
& $py $script sjoin --left "a.gpkg" --left-layer "x" --right "b.gpkg" --right-layer "y" --out "j.gpkg"
```

サブコマンド一覧: `& $py $script -h`

**破壊的操作**（`append`・上書き `export`）の前は、対象 GPKG のコピーを取る。

## 能力の全体像

詳細・エージェントがコードで足す定番操作は `references/capabilities.md` を読む。

## QGIS との役割分担

- **QGIS**: 画面操作・スタイル・印刷・プラグイン
- **本スキル**: 一括変換、条件付き抽出、結合、検証用サンプル出力、再現性のあるバッチ

## 直接コードを書く場合

スクリプトに収まらない処理は、同じ venv で GeoPandas + Shapely の短い `.py` を `temp/<用途>/` に置き実行してよい（AGENTS.md）。
