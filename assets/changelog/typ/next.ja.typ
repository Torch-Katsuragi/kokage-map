// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [ズームの途中で面が消えない],
  [面の多いデータ（森林簿の小班など）で、塗りの無い面がズーム 14〜15 の間でだけ消えていたのを直しました。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    box(width: 60pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[ズーム 14])),
    box(width: 60pt, fill: rgb("#fff4d6"), stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[14.6 でも出る])),
    box(width: 60pt, fill: white, stroke: 0.6pt + line-c, radius: 5pt, inset: 6pt, align(center, text(size: 7pt)[ズーム 15])),
  ),
)
