---
title: レイヤジオメトリタイプ仕様
tags: [features, geometry, ogc, specification]
---

# レイヤジオメトリタイプ仕様（OGC Simple Features準拠）

Root Mapsで新規作成・選択できるレイヤのジオメトリタイプは、OGC（Open Geospatial Consortium）のSimple Features仕様（SFS）に準拠し、以下の3種類のみをサポートします。

## 対応ジオメトリタイプ

| タイプ名           | 説明                                                                                   | WKT例                                 |
|--------------------|----------------------------------------------------------------------------------------|---------------------------------------|
| MultiPoint         | 複数の点（Point）の集合。1つのレイヤ内で複数の点を管理。                               | `MULTIPOINT((10 40), (40 30), (20 20))` |
| MultiLineString    | 複数の線分（LineString）の集合。1つのレイヤ内で複数の線を管理。                        | `MULTILINESTRING((10 10, 20 20), (15 15, 30 15))` |
| MultiPolygon       | 複数のポリゴン（Polygon）の集合。1つのレイヤ内で複数のポリゴンを管理。                 | `MULTIPOLYGON(((30 20, 45 40, 10 40, 30 20)), ((15 5, 40 10, 10 20, 5 10, 15 5)))` |

## 仕様詳細

- 単一のPoint, LineString, Polygonはサポートせず、必ずMulti*型（MultiPoint, MultiLineString, MultiPolygon）として扱う。
- 各レイヤは1種類のジオメトリタイプのみを持つ（混在不可）。
- 属性情報は各ジオメトリ（フィーチャ）ごとに付与可能。
- 仕様はQGISやOGC Simple Features Specification（ISO 19125-1）に準拠。

## 参考リンク

- [QGIS公式ドキュメント: Geometry Handling](https://docs.qgis.org/latest/en/docs/pyqgis_developer_cookbook/geometry.html)
- [OGC Simple Feature Access Standard（外部）](https://www.ogc.org/standards/sfa)

## 関連ドキュメント

- [[drawing-editing]] - 描画・編集機能
- [[../technical/import-export]] - レイヤの書き出し（GDAL）

