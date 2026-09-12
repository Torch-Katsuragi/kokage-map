#!/usr/bin/env python3
"""こかげマップを外から動かす薄い CLI（AI・スクリプト向け）。

データはローカルの .gpkg / .kmeta.json / .qgs なので、編集は QGIS の API や sqlite で直接やり、
アプリには「開いて」「ここを見せて」「読み直して」だけ頼む。その頼み方を包んだもの。

    python tool/kokage.py open --project /sdcard/FieldSurvey/Kitayama-2026 --at 33.8985,135.5718,15
    python tool/kokage.py open --at 33.8985,135.5718,16 --bearing 30 --pitch 45
    python tool/kokage.py reload                      # 起動中のアプリにディスクから読み直させる
    python tool/kokage.py url --at 33.8985,135.5718,15  # web 版の URL を出すだけ

Android は `am start --es route "/map?..."`（MainActivity は singleTop なので、起動中なら
onNewIntent で同じ文字列が届く）。`-s <serial>` で端末を選ぶ。`ADB_SERVER_SOCKET` はそのまま効く。
⚠ Git Bash から呼ぶときは `MSYS_NO_PATHCONV=1` を付ける（`--project /storage/...` の `/` 始まりを
Windows のパスに変換されてしまう）。
"""
import argparse
import shlex
import subprocess
import sys
from urllib.parse import urlencode

PACKAGE = "com.k_root.k_maps"
ACTIVITY = f"{PACKAGE}/.MainActivity"
WEB_BASE = "https://kokage-map.sleeptree.jp/"


def build_route(args) -> str:
    q = {}
    if getattr(args, "project", None):
        q["project"] = args.project
    if getattr(args, "at", None):
        parts = [p.strip() for p in args.at.split(",")]
        if len(parts) < 2:
            sys.exit("--at は lat,lon[,zoom]")
        q["lat"], q["lon"] = parts[0], parts[1]
        if len(parts) > 2:
            q["zoom"] = parts[2]
    if getattr(args, "zoom", None) is not None:
        q["zoom"] = str(args.zoom)
    if getattr(args, "bearing", None) is not None:
        q["bearing"] = str(args.bearing)
    if getattr(args, "pitch", None) is not None:
        q["pitch"] = str(args.pitch)
    if getattr(args, "reload", False):
        q["reload"] = "1"
    return "/map" + ("?" + urlencode(q) if q else "")


def adb_start(route: str, serial: str | None) -> int:
    cmd = ["adb"]
    if serial:
        cmd += ["-s", serial]
    # 端末側の shell が `&` や `?` を解釈しないように、route は 1 つの引用文字列で渡す
    cmd += ["shell", f"am start -n {ACTIVITY} --es route {shlex.quote(route)}"]
    print(" ".join(cmd))
    return subprocess.call(cmd)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", "--serial", help="adb の端末シリアル")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def camera_args(p):
        p.add_argument("--at", help="lat,lon[,zoom]")
        p.add_argument("--zoom", type=float)
        p.add_argument("--bearing", type=float, help="方位（度）")
        p.add_argument("--pitch", type=float, help="傾き（度、0 が真上）")

    p_open = sub.add_parser("open", help="プロジェクトを開く／カメラを合わせる")
    p_open.add_argument("--project", help="プロジェクトフォルダの絶対パス（端末上）")
    p_open.add_argument("--reload", action="store_true", help="開き直すときにディスクから読み直す")
    camera_args(p_open)

    p_reload = sub.add_parser("reload", help="起動中のアプリにディスクから読み直させる")
    camera_args(p_reload)

    p_url = sub.add_parser("url", help="web 版の URL を出す")
    p_url.add_argument("--base", default=WEB_BASE)
    camera_args(p_url)

    args = ap.parse_args()
    if args.cmd == "reload":
        args.reload = True
    route = build_route(args)
    if args.cmd == "url":
        print(args.base.rstrip("/") + "/#" + route)
        return 0
    return adb_start(route, args.serial)


if __name__ == "__main__":
    raise SystemExit(main())
