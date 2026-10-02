// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [View が 1 つだけなら View の行を出さない],
  [見え方はレイヤの ⋮ の「スタイル」で変えます。「View を追加」すると、レイヤと同じ名前の View（前の「既定」）と足した View が並びます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, ((0, "layer", [エリア], "ok", rgb("#2e7d32")),)), caption[View が 1 つ]),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, ((0, "layer", [エリア], "ok", rgb("#2e7d32")), (1, "layer", [大きい], "hi", rgb("#c0504d")), (1, "layer", [エリア], "ok", rgb("#2e7d32")))), caption[View を足したとき]),
  ),
)

#fixes(
  "チュートリアル",
  [「見え方を変える」に View を足して切り替える手順を加えた],
  [色を変えるたびに一覧を閉じて地図で見る],
)

#fixes(
  "直したこと",
  [面の塗りが尾根などで抜けて、下の地図が白く見えていた],
  [View の「スタイル」で変えた色や濃さが、開き直すと元に戻ることがあった],
  [「View を追加」した View が下に入り、何も描かなかった（今はいちばん上に入る）],
  [練習用の地図のエリアの塗りが黒 10% で、色を変えても分からなかった],
)
