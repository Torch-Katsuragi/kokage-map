// 更新履歴（図解）: v0.11.1。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.11.1 — 2026/10/05",
  [初めての Google アカウントでもサインインできる],
  [初めてのアカウントでは、選んだあとに Google ドライブの許可の画面が出ます。その途中で「サインインに失敗しました」と出ていたのを、許可が済むまで待つように直しました。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 70pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[アカウントを選ぶ])),
    arrow-r(w: 14pt),
    box(width: 80pt, fill: rgb("#fff4d6"), stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[ドライブの許可（初回だけ）])),
    arrow-r(w: 14pt),
    box(width: 60pt, fill: rgb("#2e6b4f"), radius: 5pt, inset: 6pt, align(center, text(size: 7pt, fill: white, weight: "bold")[地図を開く])),
  ),
)

#fixes(
  "ほかにも",
  [使い方ガイドとチュートリアルを新しいホームに合わせた],
  [一覧を開いたまま現在位置へ移ると、一覧に隠れない位置に着く],
  [使っていない古い地図の部品を外した（起動時の通信が減る）],
)
