// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [既定の View しかないときは View の行を出さない],
  [見え方はレイヤの ⋮ の「スタイル」で変えます。「View を追加」すると、既定と足した View が並びます。既定の View の見え方はレイヤのスタイルと同じです。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, ((0, "layer", [エリア], "ok", rgb("#2e7d32")),)), caption[View が既定だけ]),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, ((0, "layer", [エリア], "ok", rgb("#2e7d32")), (1, "layer", [既定], "ok", rgb("#2e7d32")), (1, "layer", [大きい], "hi", rgb("#c0504d")))), caption[View を足したとき]),
  ),
)

#fixes(
  "直したこと",
  [既定の View の色や濃さを変えても、開き直すと元に戻っていた],
  [練習用の地図のエリアの塗りが黒 10% で、色を変えても分からなかった],
)
