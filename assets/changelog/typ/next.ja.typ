// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [フォルダはアプリの中で選ぶ],
  [ホームの「フォルダを選んで開く」は、端末のファイル選択ではなく、いつもの地図の中のフォルダをレイヤ一覧と同じ見た目でたどります。外の場所は右上のメニューから選べます。],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 0pt, clip: true, {
    box(width: 100%, fill: rgb("#424242"), inset: (x: 6pt, y: 5pt), align(left, text(size: 8pt, fill: white, weight: "bold")[KokageMap]))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#ffc107"), radius: 1pt), text(size: 7pt)[共有])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#7eb0d5"), radius: 1pt), text(size: 7pt)[龍神村])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#b0bec5"), radius: 1pt), text(size: 7pt, fill: gray)[マイ地図.gpkg])))
    box(width: 100%, inset: 6pt, box(width: 100%, fill: rgb("#2e6b4f"), radius: 8pt, inset: 4pt, align(center, text(size: 7pt, fill: white)[「共有」で開く])))
  }),
)

#fixes(
  "直しました",
  [面の多いデータで、塗りの無い面がズーム 14〜15 の間でだけ消えていた],
)
