// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [変えた色が残るように],
  [スタイル画面で「既定」の View の色や濃さを変えても、開き直すと元に戻っていました。今はレイヤのスタイルとして残ります。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, box(width: 40pt, height: 36pt, polygon(fill: rgb(46, 125, 50, 150), stroke: 0.8pt + ink, (10pt, 0pt), (30pt, 0pt), (40pt, 18pt), (30pt, 36pt), (10pt, 36pt), (0pt, 18pt))), caption[変えた]),
    arrow-r(w: 24pt),
    stack(dir: ttb, spacing: 4pt, box(width: 40pt, height: 36pt, polygon(fill: rgb(46, 125, 50, 150), stroke: 0.8pt + ink, (10pt, 0pt), (30pt, 0pt), (40pt, 18pt), (30pt, 36pt), (10pt, 36pt), (0pt, 18pt))), caption[開き直しても同じ]),
  ),
)

#fixes(
  "ほかに直したこと",
  [練習用の地図のエリアの塗りが黒 10% で、色を変えても分からなかった],
)
