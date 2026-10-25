// 更新履歴（図解）: v0.13.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.13.0 — 2026/10/23",
  [複数の端末で軌跡と設定をそろえる],
  [設定 → Drive同期 の「端末間でデータを統合する」を ON にすると、同じ Google アカウントの端末どうしで、昨日までの GPS 軌跡・「共有」のフォルダ・一部の設定がそろいます。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(phone(w: 58pt, h: 96pt, label: [端末 A], mini-map(52pt, 82pt, road: map-red))),
    arrow-lr(w: 22pt),
    box(cloud(w: 68pt, label: [AppData/kmap])),
    arrow-lr(w: 22pt),
    box(phone(w: 58pt, h: 96pt, label: [端末 B], mini-map(52pt, 82pt, road: map-red))),
  ),
)

#scene(
  [昨日までの軌跡をお互いに取り込む],
  [今日の軌跡は上げないので、記録を続けたまま同期できます。],
  stack(dir: ttb, spacing: 5pt,
    grid(
      columns: (112pt, 112pt), column-gutter: 8pt, align: center,
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[端末 A（スマホ）]
        v(4pt)
        badge[10/21 (A)]
        v(3pt)
        badge(ok: false)[今日 記録中]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[端末 B（タブレット）]
        v(4pt)
        badge[10/21 (B)]
        v(3pt)
        badge[10/22 (B)]
      })),
    ),
    arrows-in(232pt, h: 22pt),
    cloud(w: 72pt, label: [AppData/kmap]),
    arrow-d(h: 14pt),
    block(fill: white, stroke: 1.2pt + accent, radius: 6pt, inset: 7pt, width: 210pt, align(left, {
      text(size: 7.5pt, weight: "bold", fill: accent)[同期のあと、どちらの端末にも]
      v(4pt)
      badge[10/21 (A)]; h(3pt); badge[10/21 (B)]; h(3pt); badge[10/22 (B)]
    })),
  ),
  note: [同じ日に 2 台で歩いた軌跡は、端末ごとに別の線で残ります。],
)

#scene(
  [「共有」のフォルダもそろう],
  [端末 A の「共有」に入れたフォルダは、次の同期で端末 B の「共有」にも入ります。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[端末 A で受け取る],
      layer-panel(w: 104pt, (
        (0, "dir", [共有], "ok"),
        (1, "dir", [北山村 施業班], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[端末 B にも入る],
      layer-panel(w: 104pt, (
        (0, "dir", [共有], "ok"),
        (1, "dir", [北山村 施業班], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
  ),
  note: [「共有」から消したフォルダは、ほかの端末からは消えません。消した端末に戻ってくることもありません。],
)

#fixes(
  "そろう設定",
  [背景地図（重ね方・URL で足したもの）・軌跡の記録・測位の品質（足切り）・表示の言語],
  [画面の配置と文字の大きさは端末ごとのまま],
  [同じ設定を 2 台で変えたときは、あとから同期した端末の値になる],
  [2 台目の端末で ON にすると、これらの設定はドライブにある値に置き換わる],
)

#fixes(
  "気をつけること",
  [そろえるのは「今すぐ統合を実行」を押したときと、WiFi での自動同期のとき（web 版では設定だけそろいます）],
  [マイドライブに AppData/kmap フォルダができる。消したり名前を変えたりしない],
)
