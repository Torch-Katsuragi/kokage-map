// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [使い方ガイドを新しいホームに合わせた],
  [使い方ガイドの「はじめに」とチュートリアルの「自分のデータで」を、「地図を開く」と QR での受け取りに合わせて書き直しました。],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 8pt, {
    box(width: 100%, fill: rgb("#2e6b4f"), radius: 5pt, inset: (x: 6pt, y: 6pt), text(size: 8pt, fill: white, weight: "bold")[地図を開く])
    v(4pt)
    box(width: 100%, stroke: 0.6pt + line-c, radius: 4pt, inset: (x: 6pt, y: 4pt), text(size: 7pt)[QR で受け取る])
  }),
)

#fixes(
  "ほかにも",
  [一覧を開いたまま現在位置へ移ると、一覧に隠れない位置に着く],
  [使っていない古い地図の部品を外した（起動時の通信が減る）],
)
