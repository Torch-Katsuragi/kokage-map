#!/usr/bin/env python3
"""更新履歴の図解（assets/changelog/typ/<版>.<言語>.typ）を SVG に書き出す。

    python tool/changelog/build.py                       # 全部
    python tool/changelog/build.py next.ja               # 1 本だけ
    python tool/changelog/build.py next.ja --preview DIR # PNG も DIR に書く（目で確かめる用）

`<版>.<言語>.typ` → `assets/changelog/svg/<版>.<言語>.svg`。版は `## 次のリリース` なら `next`、
`## v0.7.4` なら `v0.7.4`（ChangelogService.figureSlug）。図解の無い版は md のまま出る。

アプリは SVG を表示するだけで、Flutter に Typst は載せない。文字は形として焼き込まれるので、端末にフォントは
要らない。`.typ` は assets/changelog/typ/ に置くがアプリには同梱しない（pubspec は svg/ だけ載せる）。
typst（typst-py）が要る: `pip install typst`。
"""
import argparse
import pathlib

import typst

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = ROOT / "assets" / "changelog"
SRC = BASE / "typ"
OUT = BASE / "svg"


def build(src: pathlib.Path, preview: pathlib.Path | None) -> None:
    svg = typst.compile(str(src), root=str(BASE), format="svg")
    if isinstance(svg, list):
        raise SystemExit(f"{src.name}: {len(svg)} ページになった（高さ auto の 1 ページで書く）")
    out = OUT / f"{src.stem}.svg"
    out.write_bytes(svg)
    print(f"{out.relative_to(ROOT)}  {len(svg) // 1024} KB")
    if preview:
        preview.mkdir(parents=True, exist_ok=True)
        png = preview / f"{src.stem}.png"
        typst.compile(str(src), output=str(png), root=str(BASE), format="png", ppi=144)
        print(f"  {png}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--preview", type=pathlib.Path)
    args = ap.parse_args()
    sources = [SRC / f"{n}.typ" for n in args.names] if args.names else sorted(p for p in SRC.glob("*.*.typ"))
    for src in sources:
        build(src, args.preview)


if __name__ == "__main__":
    main()
