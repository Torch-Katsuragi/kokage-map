#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GeoPandas CLI: GPKG/GeoJSON/Shapefile 等の定型操作をサブコマンドで実行する。
入力パスはカレントディレクトリ基準（ワークスペースルートで実行推奨）。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import geopandas as gpd
import pandas as pd
from shapely import make_valid as shapely_make_valid


def _read(path: str, layer: str | None = None, bbox: tuple[float, float, float, float] | None = None) -> gpd.GeoDataFrame:
    kw: dict = {}
    if layer:
        kw["layer"] = layer
    if bbox is not None:
        kw["bbox"] = bbox
    return gpd.read_file(path, **kw)


def _write(gdf: gpd.GeoDataFrame, path: str, driver: str | None, layer: str | None, mode: str = "w") -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    kw: dict = {"mode": mode}
    if driver:
        kw["driver"] = driver
    if layer:
        kw["layer"] = layer
    gdf.to_file(path, **kw)


def _driver_from_ext(p: Path) -> str | None:
    e = p.suffix.lower()
    if e == ".gpkg":
        return "GPKG"
    if e == ".geojson" or e == ".json":
        return "GeoJSON"
    if e == ".shp":
        return "ESRI Shapefile"
    if e == ".fgb":
        return "FlatGeobuf"
    if e == ".parquet":
        return "Parquet"
    return None


def _list_vector_layers(path: Path) -> list[str]:
    try:
        import pyogrio

        meta = pyogrio.list_layers(str(path))
        return [str(row[0]) for row in meta]
    except Exception:
        pass
    try:
        import fiona

        return list(fiona.listlayers(str(path)))
    except Exception:
        pass
    return []


def cmd_info(args: argparse.Namespace) -> int:
    path = Path(args.in_path)
    layers = _list_vector_layers(path)
    if not layers:
        print("レイヤ一覧を取得できませんでした（fiona/pyogrio を確認）。", file=sys.stderr)
        return 1

    if args.layer:
        if args.layer not in layers:
            print(f"レイヤ '{args.layer}' が見つかりません。利用可能: {layers}", file=sys.stderr)
            return 1
        gdf = _read(str(path), layer=args.layer)
        print(f"path: {path}")
        print(f"layer: {args.layer}")
        print(f"rows: {len(gdf)}")
        print(f"crs: {gdf.crs}")
        try:
            b = gdf.total_bounds
            print(f"bounds: {b[0]:.8f}, {b[1]:.8f}, {b[2]:.8f}, {b[3]:.8f}")
        except Exception:
            pass
        print(f"columns: {list(gdf.columns)}")
        print(f"geometry.name: {gdf.geometry.name}")
        return 0

    print(f"path: {path}")
    print(f"layers ({len(layers)}): {layers}")
    for lyr in layers:
        try:
            gdf = _read(str(path), layer=lyr)
        except Exception as ex:
            print(f"  - {lyr}: (読込失敗: {ex})")
            continue
        if not isinstance(gdf, gpd.GeoDataFrame) or gdf.geometry.name not in gdf.columns:
            print(f"  - {lyr}: rows={len(gdf)} (非空間テーブル)")
            continue
        crs_s = str(gdf.crs) if gdf.crs is not None else "None"
        try:
            b = gdf.total_bounds
            bb = f"{b[0]:.6f},{b[1]:.6f},{b[2]:.6f},{b[3]:.6f}"
        except Exception:
            bb = "n/a"
        print(f"  - {lyr}: rows={len(gdf)} crs={crs_s} bounds={bb}")
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    bbox = None
    if args.bbox:
        bbox = tuple(map(float, args.bbox.split(",")))
        if len(bbox) != 4:
            print("--bbox は xmin,ymin,xmax,ymax の4値（カンマ区切り）", file=sys.stderr)
            return 1
    gdf = _read(args.in_path, layer=args.layer, bbox=bbox)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(gdf, str(out), driver, args.out_layer, mode="w")
    print(f"Wrote {len(gdf)} features -> {out} driver={driver} layer={args.out_layer}")
    return 0


def cmd_from_parquet(args: argparse.Namespace) -> int:
    gdf = gpd.read_parquet(args.in_path)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(gdf, str(out), driver, args.out_layer, mode="w")
    print(f"Parquet -> {out} rows={len(gdf)}")
    return 0


def cmd_copy_layer(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out) or "GPKG"
    _write(gdf, str(out), driver, args.out_layer or args.layer, mode="w")
    print(f"Copied layer '{args.layer}' -> {out} as '{args.out_layer or args.layer}'")
    return 0


def cmd_append(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    driver = args.driver or "GPKG"
    _write(gdf, args.target, driver, args.target_layer, mode="a")
    print(f"Appended {len(gdf)} rows to {args.target} layer={args.target_layer}")
    return 0


def cmd_filter_bbox(args: argparse.Namespace) -> int:
    parts = args.bbox.split(",")
    if len(parts) != 4:
        print("--bbox は xmin,ymin,xmax,ymax", file=sys.stderr)
        return 1
    bbox = tuple(map(float, parts))
    gdf = _read(args.in_path, layer=args.layer, bbox=bbox)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(gdf, str(out), driver, args.out_layer, mode="w")
    print(f"filter-bbox: {len(gdf)} features -> {out}")
    return 0


def cmd_filter_query(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    try:
        gdf = gdf.query(args.query, engine="python")
    except Exception as ex:
        print(f"query 失敗: {ex}", file=sys.stderr)
        return 1
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(gdf, str(out), driver, args.out_layer, mode="w")
    print(f"filter-query: {len(gdf)} features -> {out}")
    return 0


def cmd_reproject(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    gdf = gdf.to_crs(args.to_crs)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(gdf, str(out), driver, args.out_layer, mode="w")
    print(f"reproject -> {out} crs={gdf.crs}")
    return 0


def cmd_buffer(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    cap = int(args.cap_style)
    join = int(args.join_style)
    ser = gdf.geometry.buffer(args.distance, cap_style=cap, join_style=join)
    out_gdf = gdf.set_geometry(ser)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(out_gdf, str(out), driver, args.out_layer, mode="w")
    print(f"buffer distance={args.distance} -> {out}")
    return 0


def cmd_dissolve(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    by = [c.strip() for c in args.by.split(",") if c.strip()]
    if not by:
        dissolved = gdf.dissolve()
    else:
        dissolved = gdf.dissolve(by=by)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(dissolved.reset_index(drop=False), str(out), driver, args.out_layer, mode="w")
    print(f"dissolve by={by or 'all'} -> {len(dissolved)} rows {out}")
    return 0


def cmd_clip(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    clip_gdf = _read(args.clip_path, layer=args.clip_layer)
    if clip_gdf.crs != gdf.crs and clip_gdf.crs is not None and gdf.crs is not None:
        clip_gdf = clip_gdf.to_crs(gdf.crs)
    clipped = gpd.clip(gdf, clip_gdf)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(clipped, str(out), driver, args.out_layer, mode="w")
    print(f"clip: {len(clipped)} features -> {out}")
    return 0


def cmd_overlay(args: argparse.Namespace) -> int:
    left = _read(args.left, layer=args.left_layer)
    right = _read(args.right, layer=args.right_layer)
    if right.crs != left.crs and right.crs is not None and left.crs is not None:
        right = right.to_crs(left.crs)
    out_gdf = gpd.overlay(left, right, how=args.how, keep_geom_type=args.keep_geom_type)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(out_gdf, str(out), driver, args.out_layer, mode="w")
    print(f"overlay {args.how}: {len(out_gdf)} -> {out}")
    return 0


def cmd_sjoin(args: argparse.Namespace) -> int:
    left = _read(args.left, layer=args.left_layer)
    right = _read(args.right, layer=args.right_layer)
    if right.crs != left.crs and right.crs is not None and left.crs is not None:
        right = right.to_crs(left.crs)
    joined = gpd.sjoin(left, right, how=args.how, predicate=args.predicate)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(joined, str(out), driver, args.out_layer, mode="w")
    print(f"sjoin {args.how}/{args.predicate}: {len(joined)} -> {out}")
    return 0


def cmd_sjoin_nearest(args: argparse.Namespace) -> int:
    left = _read(args.left, layer=args.left_layer)
    right = _read(args.right, layer=args.right_layer)
    if right.crs != left.crs and right.crs is not None and left.crs is not None:
        right = right.to_crs(left.crs)
    kw: dict = {"how": args.how, "distance_col": args.distance_col}
    if args.max_distance is not None:
        kw["max_distance"] = args.max_distance
    joined = gpd.sjoin_nearest(left, right, **kw)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(joined, str(out), driver, args.out_layer, mode="w")
    print(f"sjoin-nearest: {len(joined)} -> {out}")
    return 0


def cmd_explode(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    ex = gdf.explode(index_parts=args.index_parts).reset_index(drop=True)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(ex, str(out), driver, args.out_layer, mode="w")
    print(f"explode: {len(ex)} rows -> {out}")
    return 0


def cmd_simplify(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    simp = gdf.copy()
    simp.geometry = gdf.simplify(args.tolerance, preserve_topology=not args.no_preserve_topology)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(simp, str(out), driver, args.out_layer, mode="w")
    print(f"simplify tol={args.tolerance} -> {out}")
    return 0


def cmd_make_valid(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    fixed = gdf.copy()
    fixed.geometry = gdf.geometry.apply(lambda g: shapely_make_valid(g) if g is not None else g)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(fixed, str(out), driver, args.out_layer, mode="w")
    print(f"make-valid: {out}")
    return 0


def cmd_calc_metric(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    if gdf.crs is None:
        print("CRS が無いため面積・長さは意味がありません。", file=sys.stderr)
        return 1
    is_geo = False
    try:
        is_geo = bool(gdf.crs.is_geographic)
    except Exception:
        try:
            from pyproj import CRS as ProjCRS

            is_geo = ProjCRS.from_user_input(gdf.crs).is_geographic
        except Exception:
            is_geo = False
    if is_geo and not args.force:
        print(
            "地理座標系のままです。投影座標系へ reproject するか --force を付けてください。",
            file=sys.stderr,
        )
        return 1
    out_gdf = gdf.copy()
    if args.area_col:
        out_gdf[args.area_col] = out_gdf.geometry.area
    if args.length_col:
        out_gdf[args.length_col] = out_gdf.geometry.length
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(out_gdf, str(out), driver, args.out_layer, mode="w")
    print(f"calc-metric -> {out}")
    return 0


def cmd_merge_csv(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    csv_df = pd.read_csv(args.csv_path, encoding=args.encoding)
    merged = gdf.merge(csv_df, left_on=args.left_on, right_on=args.right_on, how=args.how)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(merged, str(out), driver, args.out_layer, mode="w")
    print(f"merge-csv: {len(merged)} rows -> {out}")
    return 0


def cmd_select_cols(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    cols = [c.strip() for c in args.columns.split(",") if c.strip()]
    geom_name = gdf.geometry.name
    if geom_name not in cols:
        cols = cols + [geom_name]
    missing = [c for c in cols if c not in gdf.columns]
    if missing:
        print(f"存在しない列: {missing}", file=sys.stderr)
        return 1
    sub = gdf[cols]
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(sub, str(out), driver, args.out_layer, mode="w")
    print(f"select-cols: {list(sub.columns)} -> {out}")
    return 0


def cmd_rename_cols(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    mapping: dict[str, str] = {}
    for part in args.rename_map.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" not in part:
            print(f"rename は old:new 形式: '{part}'", file=sys.stderr)
            return 1
        old, new = part.split(":", 1)
        mapping[old.strip()] = new.strip()
    ren = gdf.rename(columns=mapping)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(ren, str(out), driver, args.out_layer, mode="w")
    print(f"rename-cols {mapping} -> {out}")
    return 0


def cmd_head_export(args: argparse.Namespace) -> int:
    gdf = _read(args.in_path, layer=args.layer)
    head = gdf.head(args.n)
    out = Path(args.out_path)
    driver = args.driver or _driver_from_ext(out)
    _write(head, str(out), driver, args.out_layer, mode="w")
    print(f"head {args.n} -> {out}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="GeoPandas vector CLI (GPKG/GeoJSON/...)")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_in_out(sp: argparse.ArgumentParser) -> None:
        sp.add_argument("--in", dest="in_path", required=True, help="入力ベクタパス")
        sp.add_argument("--out", dest="out_path", required=True, help="出力パス")
        sp.add_argument("--layer", default=None, help="入力レイヤ名（GPKG等）")
        sp.add_argument("--out-layer", dest="out_layer", default=None, help="出力レイヤ名")
        sp.add_argument("--driver", default=None, help="OGRドライバ（省略時は拡張子から推測）")

    sp = sub.add_parser("info", help="レイヤ一覧または1レイヤの詳細")
    sp.add_argument("--in", dest="in_path", required=True)
    sp.add_argument("--layer", default=None)
    sp.set_defaults(func=cmd_info)

    sp = sub.add_parser("export", help="ベクタを別形式へ書き出し")
    add_in_out(sp)
    sp.add_argument("--bbox", default=None, help="読込時に xmin,ymin,xmax,ymax で絞り込み")
    sp.set_defaults(func=cmd_export)

    sp = sub.add_parser("from-parquet", help="GeoParquet をベクタに変換")
    sp.add_argument("--in", dest="in_path", required=True)
    sp.add_argument("--out", dest="out_path", required=True)
    sp.add_argument("--out-layer", dest="out_layer", default=None)
    sp.add_argument("--driver", default=None)
    sp.set_defaults(func=cmd_from_parquet)

    sp = sub.add_parser("copy-layer", help="1レイヤを別ファイルへコピー")
    sp.add_argument("--in", dest="in_path", required=True)
    sp.add_argument("--layer", required=True)
    sp.add_argument("--out", dest="out_path", required=True)
    sp.add_argument("--out-layer", dest="out_layer", default=None)
    sp.add_argument("--driver", default=None)
    sp.set_defaults(func=cmd_copy_layer)

    sp = sub.add_parser("append", help="既存GPKGレイヤへ行を追記（スキーマ要一致）")
    sp.add_argument("--in", dest="in_path", required=True)
    sp.add_argument("--layer", required=True, help="追記するデータのレイヤ")
    sp.add_argument("--target", dest="target", required=True, help="追記先GPKG")
    sp.add_argument("--target-layer", dest="target_layer", required=True)
    sp.add_argument("--driver", default="GPKG")
    sp.set_defaults(func=cmd_append)

    sp = sub.add_parser("filter-bbox", help="バウンディングボックスで読み絞り or 書き出し")
    add_in_out(sp)
    sp.add_argument("--bbox", required=True, help="xmin,ymin,xmax,ymax")
    sp.set_defaults(func=cmd_filter_bbox)

    sp = sub.add_parser("filter-query", help="pandas query で行を絞り込み")
    add_in_out(sp)
    sp.add_argument("--query", required=True, help='例: `人口 > 0`')
    sp.set_defaults(func=cmd_filter_query)

    sp = sub.add_parser("reproject", help="CRS 変換")
    add_in_out(sp)
    sp.add_argument("--to", dest="to_crs", required=True, help="EPSG:6670 等")
    sp.set_defaults(func=cmd_reproject)

    sp = sub.add_parser("buffer", help="ジオメトリをバッファ")
    add_in_out(sp)
    sp.add_argument("--distance", type=float, required=True)
    sp.add_argument("--cap-style", dest="cap_style", default="1", help="1=round 2=flat 3=square")
    sp.add_argument("--join-style", dest="join_style", default="1", help="1=round 2=mitre 3=bevel")
    sp.set_defaults(func=cmd_buffer)

    sp = sub.add_parser("dissolve", help="属性でディゾルブ（by 省略で全体統合）")
    add_in_out(sp)
    sp.add_argument("--by", default="", help="カンマ区切り列名")
    sp.set_defaults(func=cmd_dissolve)

    sp = sub.add_parser("clip", help="マスクでクリップ")
    sp.add_argument("--in", dest="in_path", required=True)
    sp.add_argument("--layer", default=None)
    sp.add_argument("--clip", dest="clip_path", required=True)
    sp.add_argument("--clip-layer", dest="clip_layer", default=None)
    sp.add_argument("--out", dest="out_path", required=True)
    sp.add_argument("--out-layer", dest="out_layer", default=None)
    sp.add_argument("--driver", default=None)
    sp.set_defaults(func=cmd_clip)

    sp = sub.add_parser("overlay", help="2レイヤの集合演算")
    sp.add_argument("--left", required=True)
    sp.add_argument("--left-layer", dest="left_layer", default=None)
    sp.add_argument("--right", required=True)
    sp.add_argument("--right-layer", dest="right_layer", default=None)
    sp.add_argument("--how", required=True, choices=[
        "intersection", "union", "identity", "symmetric_difference", "difference",
    ])
    sp.add_argument("--out", dest="out_path", required=True)
    sp.add_argument("--out-layer", dest="out_layer", default=None)
    sp.add_argument("--driver", default=None)
    sp.add_argument("--keep-geom-type", dest="keep_geom_type", action="store_true")
    sp.set_defaults(func=cmd_overlay)

    sp = sub.add_parser("sjoin", help="空間結合")
    sp.add_argument("--left", required=True)
    sp.add_argument("--left-layer", dest="left_layer", default=None)
    sp.add_argument("--right", required=True)
    sp.add_argument("--right-layer", dest="right_layer", default=None)
    sp.add_argument("--how", default="left", choices=["left", "right", "inner"])
    sp.add_argument(
        "--predicate",
        default="intersects",
        choices=[
            "intersects", "within", "contains", "covers", "covered_by", "touches", "crosses", "overlaps",
        ],
    )
    sp.add_argument("--out", dest="out_path", required=True)
    sp.add_argument("--out-layer", dest="out_layer", default=None)
    sp.add_argument("--driver", default=None)
    sp.set_defaults(func=cmd_sjoin)

    sp = sub.add_parser("sjoin-nearest", help="最近傍空間結合")
    sp.add_argument("--left", required=True)
    sp.add_argument("--left-layer", dest="left_layer", default=None)
    sp.add_argument("--right", required=True)
    sp.add_argument("--right-layer", dest="right_layer", default=None)
    sp.add_argument("--how", default="left", choices=["left", "right", "inner"])
    sp.add_argument("--max-distance", dest="max_distance", type=float, default=None)
    sp.add_argument("--distance-col", dest="distance_col", default="distance")
    sp.add_argument("--out", dest="out_path", required=True)
    sp.add_argument("--out-layer", dest="out_layer", default=None)
    sp.add_argument("--driver", default=None)
    sp.set_defaults(func=cmd_sjoin_nearest)

    sp = sub.add_parser("explode", help="マルチジオメトリを分割")
    add_in_out(sp)
    sp.add_argument("--index-parts", dest="index_parts", action="store_true")
    sp.set_defaults(func=cmd_explode)

    sp = sub.add_parser("simplify", help="ジオメトリ単純化")
    add_in_out(sp)
    sp.add_argument("--tolerance", type=float, required=True)
    sp.add_argument("--no-preserve-topology", dest="no_preserve_topology", action="store_true")
    sp.set_defaults(func=cmd_simplify)

    sp = sub.add_parser("make-valid", help="不正ジオメトリを修復（Shapely make_valid）")
    add_in_out(sp)
    sp.set_defaults(func=cmd_make_valid)

    sp = sub.add_parser("calc-metric", help="投影座標系で面積・長さ列を付与")
    add_in_out(sp)
    sp.add_argument("--area-col", dest="area_col", default=None)
    sp.add_argument("--length-col", dest="length_col", default=None)
    sp.add_argument("--force", action="store_true", help="地理座標系でも計算（非推奨）")
    sp.set_defaults(func=cmd_calc_metric)

    sp = sub.add_parser("merge-csv", help="属性をCSVと非空間結合")
    sp.add_argument("--in", dest="in_path", required=True)
    sp.add_argument("--layer", default=None)
    sp.add_argument("--csv", dest="csv_path", required=True)
    sp.add_argument("--left-on", dest="left_on", required=True)
    sp.add_argument("--right-on", dest="right_on", required=True)
    sp.add_argument("--how", default="left", choices=["left", "right", "inner", "outer"])
    sp.add_argument("--encoding", default="utf-8")
    sp.add_argument("--out", dest="out_path", required=True)
    sp.add_argument("--out-layer", dest="out_layer", default=None)
    sp.add_argument("--driver", default=None)
    sp.set_defaults(func=cmd_merge_csv)

    sp = sub.add_parser("select-cols", help="列のサブセット（geometryは自動保持）")
    add_in_out(sp)
    sp.add_argument("--columns", required=True, help="カンマ区切り")
    sp.set_defaults(func=cmd_select_cols)

    sp = sub.add_parser("rename-cols", help="列リネーム old:new,old2:new2")
    add_in_out(sp)
    sp.add_argument("--rename-map", required=True, dest="rename_map", help="例: old_name:new_name,code:id")
    sp.set_defaults(func=cmd_rename_cols)

    sp = sub.add_parser("head-export", help="先頭N件だけ書き出し（検証用）")
    add_in_out(sp)
    sp.add_argument("--n", type=int, default=10)
    sp.set_defaults(func=cmd_head_export)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
