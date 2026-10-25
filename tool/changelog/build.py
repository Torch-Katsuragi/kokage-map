#!/usr/bin/env python3
"""更新履歴の図解（assets/changelog/typ/<版>.<言語>.typ）を、切れごとの SVG に書き出す。

    python tool/changelog/build.py                       # 全部
    python tool/changelog/build.py next.ja               # 1 本だけ
    python tool/changelog/build.py next.ja --preview DIR # 切れをつないだ PNG も DIR に書く（目で確かめる用）
    python tool/changelog/build.py --pdf DIR             # 図解版の更新履歴を PDF で DIR に書き出す（単体＋全版まとめ）

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


_ID_DEF = re.compile(rb'id="([A-Za-z_][\w-]*)"')
_ID_USE = re.compile(rb'(id="|#)([A-Za-z_][\w-]*)(?=["\)])')


def _short_ids(svg: bytes) -> bytes:
    """Typst の id（字形ごとの `g` + 32 桁の 16 進など）を短い名前に付け替える。字形は 1 枚に数百あって
    `<use xlink:href="#…">` で何度も引くので、圧縮後でも図解全体で約 16% 減る。中身（形・座標）は変えない。
    付け替えるのはファイル内で `id="…"` と定義された名前だけ（`#ffffff` などの色はそのまま）"""
    names = {}
    for m in _ID_DEF.finditer(svg):
        k = m.group(1)
        if k not in names:
            n, t = len(names), ""
            while True:
                t = "abcdefghijklmnopqrstuvwxyz"[n % 26] + t
                n //= 26
                if n == 0:
                    break
            names[k] = ("_" + t).encode()  # Typst の名前（g・r・16 進）と重ならない
    if not names:
        return svg
    return _ID_USE.sub(lambda m: m.group(1) + names.get(m.group(2), m.group(2)), svg)


def hero_title(src: pathlib.Path) -> str:
    """`#hero(版, [大きな一言], ...)` の一言を文字だけにして返す。アプリは畳んだ版の見出しに使う"""
    text = src.read_text(encoding="utf-8")
    m = re.search(r"#hero\(\s*\"[^\"]*\"\s*,\s*\[", text)
    if not m:
        raise SystemExit(f"{src.name}: #hero(\"版\", [一言], ...) が見つからない")
    depth, i = 1, m.end()
    while depth:
        depth += {"[": 1, "]": -1}.get(text[i], 0)
        i += 1
    title = text[m.end():i - 1]
    title = re.sub(r"\\\s*", "", title)          # 改行の `\`
    title = re.sub(r"`([^`]*)`", r"\1", title)   # raw
    title = re.sub(r"\\(\S)", r"\1", title)      # エスケープ（`k\_maps`）
    return re.sub(r"\s+", " ", title).strip()


def _version_sort_key(src: pathlib.Path) -> tuple:
    """`v0.13.0.ja.typ` -> (0, 13, 0) で降順ソートできるようにする（`next` は最上位）"""
    ver = src.stem.rsplit(".", 1)[0]
    if ver == "next":
        return (9999, 9999, 9999)
    nums = [int(x) for x in re.findall(r"\d+", ver)]
    return tuple(nums)


def _strip_preamble(typ_text: str) -> str:
    """単体 `.typ` の先頭にある `#import "lib.typ": *` と `#show: page-setup...` を取り除く"""
    lines = []
    for line in typ_text.splitlines():
        s = line.strip()
        if s.startswith('#import "lib.typ"') or s.startswith("#show: page-setup"):
            continue
        lines.append(line)
    return "\n".join(lines)


def build_combined_pdf(lang: str, pdf_dir: pathlib.Path) -> pathlib.Path:
    """指定言語（`ja` / `en`）の全バージョンを新しい順に1冊のPDF（しおり付き）にまとめて書き出す"""
    files = sorted(SRC.glob(f"*.{lang}.typ"), key=_version_sort_key, reverse=True)
    if not files:
        raise SystemExit(f"No .{lang}.typ files found in {SRC}")
    show_line = '#show: page-setup.with(lang: "en")' if lang == "en" else "#show: page-setup"
    parts = [
        '#import "lib.typ": *',
        show_line,
    ]
    for idx, f in enumerate(files):
        if idx > 0:
            parts.append("#pagebreak(weak: true)")
        parts.append("#[")
        parts.append(_strip_preamble(f.read_text(encoding="utf-8")))
        parts.append("]")
    tmp_src = SRC / f"_combined_{lang}.typ"
    try:
        tmp_src.write_text("\n".join(parts) + "\n", encoding="utf-8")
        pdf_bytes = typst.compile(str(tmp_src), root=str(BASE), format="pdf", sys_inputs={"mode": "pdf"})
    finally:
        tmp_src.unlink(missing_ok=True)
    pdf_dir.mkdir(parents=True, exist_ok=True)
    out_path = pdf_dir / f"changelog.{lang}.pdf"
    out_path.write_bytes(pdf_bytes)
    print(f"  PDF (all {len(files)} versions): {out_path} ({len(pdf_bytes) // 1024} KB)")
    return out_path


def build(src: pathlib.Path, preview: pathlib.Path | None, pdf_dir: pathlib.Path | None = None) -> None:
    pages = typst.compile(str(src), root=str(BASE), format="svg")
    if not isinstance(pages, list):
        pages = [pages]
    pages = [_short_ids(_shrink(p)) for p in pages]
    for old in OUT.glob(f"{src.stem}.*.svg"):
        old.unlink()
    chunks = []
    for i, svg in enumerate(pages):
        name = f"{src.stem}.{i:02d}.svg"
        (OUT / name).write_bytes(svg)
        w, h = map(float, re.search(rb'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg).groups())
        chunks.append({"file": name, "width": round(w, 2), "height": round(h, 2)})
    index = {"title": hero_title(src), "chunks": chunks}
    (OUT / f"{src.stem}.json").write_text(json.dumps(index, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
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

    if pdf_dir:
        pdf_dir.mkdir(parents=True, exist_ok=True)
        pdf_bytes = typst.compile(str(src), root=str(BASE), format="pdf", sys_inputs={"mode": "pdf"})
        out = pdf_dir / f"{src.stem}.pdf"
        out.write_bytes(pdf_bytes)
        print(f"  {out} ({len(pdf_bytes) // 1024} KB)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--preview", type=pathlib.Path)
    ap.add_argument("--pdf", type=pathlib.Path, help="図解版更新履歴の PDF 出力先ディレクトリ")
    ap.add_argument("--short-ids", action="store_true", help="書き出し済みの SVG の id だけ付け替える（Typst を回さない）")
    args = ap.parse_args()
    if args.short_ids:
        for svg in sorted(OUT.glob("*.svg")):
            svg.write_bytes(_short_ids(svg.read_bytes()))
        return
    sources = [SRC / f"{n}.typ" for n in args.names] if args.names else sorted(p for p in SRC.glob("*.*.typ"))
    OUT.mkdir(parents=True, exist_ok=True)
    for src in sources:
        build(src, args.preview, args.pdf if args.names else None)
    if args.pdf:
        langs = sorted({src.stem.rsplit(".", 1)[1] for src in sources if "." in src.stem})
        for lang in langs:
            build_combined_pdf(lang, args.pdf)


if __name__ == "__main__":
    main()
