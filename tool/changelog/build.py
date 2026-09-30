#!/usr/bin/env python3
"""更新履歴の図解（assets/changelog/typ/<版>.<言語>.typ）を、切れごとの SVG に書き出す。

    python tool/changelog/build.py                       # 全部
    python tool/changelog/build.py next.ja               # 1 本だけ
    python tool/changelog/build.py next.ja --preview DIR # 切れをつないだ PNG も DIR に書く（目で確かめる用）

`<版>.<言語>.typ` の 1 ページが 1 切れ（lib.typ の fig・section がページを切る）。
→ `assets/changelog/svg/<版>.<言語>.NN.svg` と、切れの一覧 `<版>.<言語>.json`（ファイル名と幅・高さ）。
アプリは一覧を読んで高さを先に確保し、スクロールに合わせて切れを読み込む（継ぎ目を見せない）。
版は `## 次のリリース` なら `next`、`## v0.7.4` なら `v0.7.4`（ChangelogService.figureSlug）。図解の無い版は md のまま出る。

アプリは SVG を表示するだけで、Flutter に Typst は載せない。文字は形として焼き込まれるので、端末にフォントは
要らない。`.typ` は assets/changelog/typ/ に置くがアプリには同梱しない（pubspec は svg/ だけ載せる）。
typst（typst-py）が要る: `pip install typst`。
"""
import argparse
import io
import json
import pathlib
import re

import typst

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = ROOT / "assets" / "changelog"
SRC = BASE / "typ"
OUT = BASE / "svg"

# プレビューの地（アプリの画面の色）
APP_BG = (248, 249, 255)


_LONG_FLOAT = re.compile(rb"-?\d+\.\d{3,}")


def _shrink(svg: bytes) -> bytes:
    """座標を小数 2 桁に丸める。Typst は字形の輪郭を 7〜8 桁で書くので、それだけで大きさの半分近くになる。
    単位は pt で、0.01pt は 3 倍密度の画面でも 0.04 px。見た目は変わらない"""
    def r(m: re.Match) -> bytes:
        s = f"{float(m.group(0)):.2f}".rstrip("0").rstrip(".")
        return (s if s not in ("-0", "") else "0").encode()
    return _LONG_FLOAT.sub(r, svg)


def build(src: pathlib.Path, preview: pathlib.Path | None) -> None:
    pages = typst.compile(str(src), root=str(BASE), format="svg")
    if not isinstance(pages, list):
        pages = [pages]
    pages = [_shrink(p) for p in pages]
    for old in OUT.glob(f"{src.stem}.*.svg"):
        old.unlink()
    chunks = []
    for i, svg in enumerate(pages):
        name = f"{src.stem}.{i:02d}.svg"
        (OUT / name).write_bytes(svg)
        w, h = map(float, re.search(rb'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg).groups())
        chunks.append({"file": name, "width": round(w, 2), "height": round(h, 2)})
    (OUT / f"{src.stem}.json").write_text(json.dumps({"chunks": chunks}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    total = sum(len(p) for p in pages)
    print(f"{src.stem}: {len(pages)} 切れ・{total // 1024} KB")

    if preview:
        from PIL import Image

        preview.mkdir(parents=True, exist_ok=True)
        pngs = typst.compile(str(src), root=str(BASE), format="png", ppi=144)
        imgs = [Image.open(io.BytesIO(b)).convert("RGBA") for b in (pngs if isinstance(pngs, list) else [pngs])]
        pad = 32  # アプリの左右の余白（16dp）相当
        sheet = Image.new("RGBA", (imgs[0].width + pad * 2, sum(i.height for i in imgs) + pad * 2), APP_BG + (255,))
        y = pad
        for im in imgs:
            sheet.alpha_composite(im, (pad, y))
            y += im.height
        out = preview / f"{src.stem}.png"
        sheet.convert("RGB").save(out)
        print(f"  {out}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--preview", type=pathlib.Path)
    args = ap.parse_args()
    sources = [SRC / f"{n}.typ" for n in args.names] if args.names else sorted(p for p in SRC.glob("*.*.typ"))
    OUT.mkdir(parents=True, exist_ok=True)
    for src in sources:
        build(src, args.preview)


if __name__ == "__main__":
    main()
