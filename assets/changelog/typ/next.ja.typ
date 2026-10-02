// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [web 版でもチュートリアル],
  [ホームの「チュートリアル」から始められます。練習用の地図はブラウザの中に作るので、フォルダを選ぶ必要はありません。写真の章は web では出しません。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    box(width: 120pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 8pt, align(center, {
      text(size: 8pt, fill: sub)[プロジェクトを開始]
      v(4pt)
      box(fill: accent, radius: 8pt, inset: (x: 8pt, y: 3pt), text(size: 7pt, fill: white)[フォルダを選択])
      v(3pt)
      box(stroke: 1.4pt + rgb("#c0504d"), radius: 3pt, inset: (x: 4pt, y: 2pt), text(size: 7pt, fill: accent)[チュートリアル])
    })),
    arrow-r(w: 20pt),
    phone(label: "練習用の地図", box(width: 56pt, height: 98pt, mini-map(56pt, 98pt))),
  ),
)

#fixes(
  "チュートリアル",
  [章を始めるたびに地図を 2D・北が上に戻す],
  [「透け具合を変える」の案内が見本を隠していた],
)
