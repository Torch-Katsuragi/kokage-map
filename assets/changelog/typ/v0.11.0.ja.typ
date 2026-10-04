// 更新履歴（図解）: v0.11.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.11.0 — 2026/10/04",
  [「地図を開く」で、いつもの地図],
  [フォルダを選ばなくても、ホームの「地図を開く」で Documents/KokageMap がそのまま開きます。書き込み先の「マイ地図」を最初から用意し、QR で受け取った地図は「共有」に入ります。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    box(width: 120pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 8pt, {
      box(width: 100%, fill: rgb("#2e6b4f"), radius: 5pt, inset: (x: 6pt, y: 6pt), text(size: 8pt, fill: white, weight: "bold")[地図を開く])
      v(4pt)
      box(width: 100%, stroke: 0.6pt + line-c, radius: 4pt, inset: (x: 6pt, y: 4pt), text(size: 7pt)[ほかの場所を開く])
    }),
    arrow-r(w: 20pt),
    layer-panel(w: 110pt, (
      (0, "dir", [共有], "ok"),
      (1, "dir", [組合 間伐調査], "ok"),
      (0, "layer", [マイ地図 / 点], "hi", rgb("#2e6b4f")),
    )),
  ),
)

#scene(
  [QR を読むと地図が開く],
  [「QRコードで渡す」の QR をスマホのカメラで読むと、こかげマップが開いて地図を「共有」に取り込み、その場所を開きます。こかげマップが無いスマホやパソコンでは入れ方の案内が開きます。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, box(width: 36pt, height: 36pt, stroke: 2pt + ink, inset: 4pt, grid(columns: 3, gutter: 2pt, ..range(9).map(i => box(width: 8pt, height: 8pt, fill: if calc.rem(i, 2) == 0 { ink } else { white })))), caption[カメラで読む]),
    arrow-r(w: 16pt),
    stack(dir: ttb, spacing: 4pt, box(width: 36pt, height: 36pt, fill: rgb("#2e6b4f"), radius: 8pt), caption[アプリが開く]),
    arrow-r(w: 16pt),
    stack(dir: ttb, spacing: 4pt, box(width: 36pt, height: 36pt, fill: rgb("#e3f0e8"), radius: 4pt, align(center + horizon, folder-icon(warm, w: 16pt))), caption[共有に入る]),
  ),
)

#fixes(
  "チュートリアル",
  [web 版でもチュートリアル（写真の章は除く）],
  [章を始めるたびに地図を 2D・北が上に戻す],
)

#fixes(
  "ほかにも",
  [アプリ用のフォルダ（Global・練習用）は .kokage に移した（初回に自動）],
)
