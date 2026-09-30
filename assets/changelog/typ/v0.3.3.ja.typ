// 更新履歴（図解）: v0.3.3。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ---- 頭: オフライン地図 ----
#hero(
  "v0.3.3 — 2026/03/11",
  [地図を先に落として、\ オフラインに備える],
  [範囲とズームレベルを指定して、背景地図をまとめてダウンロードできます。電波が無くても背景地図が出ます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 66pt, h: 118pt, label: "範囲とズームを指定", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 8pt, dy: 22pt, rect(width: 44pt, height: 54pt, fill: accent.transparentize(85%),
        stroke: (paint: accent, thickness: 1.2pt, dash: "dashed")))
    })),
    stack(dir: ttb, spacing: 4pt, caption(fill: accent)[一括ダウンロード], arrow-r(w: 30pt)),
    phone(w: 66pt, h: 118pt, label: "電波が無くても", box(width: 60pt, height: 104pt, {
      place(mini-map(60pt, 104pt))
      place(dx: 3pt, dy: 3pt, box(fill: white, radius: 20pt, inset: (x: 4pt, y: 1.5pt), text(size: 5.5pt, weight: "bold", fill: sub)[オフライン]))
    })),
  ),
)

#fixes(
  "ほかにも",
  [Drive の自動同期チェックを追加],
  [記号（SymbolStyleLayer）の描画の不具合を修正],
  [回線切替でレイヤが背景地図の下に隠れていた],
  [GeoPackage のドラッグ移動の不具合を修正],
)
