// 更新履歴（図解）: v0.6.1。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ---- この版だけの部品 ----

/// ブラウザ（Chrome / Edge）。中身は画面の大きさ（w-6pt × h-20pt）で渡す
#let browser(w: 118pt, h: 84pt, url: "", label: none, screen) = {
  box(width: w, height: h, {
    place(rect(width: w, height: h, radius: 4pt, fill: rgb("#e9e7ee"), stroke: 0.6pt + line-c))
    for (i, c) in ((0, rgb("#f28b82")), (1, rgb("#fdd663")), (2, rgb("#81c995"))) {
      place(dx: 5pt + i * 5pt, dy: 4.5pt, circle(radius: 1.6pt, fill: c))
    }
    place(dx: 22pt, dy: 2.5pt, box(width: w - 27pt, height: 7pt, radius: 3.5pt, fill: white, inset: (x: 4pt, y: 1.2pt),
      text(size: 4.8pt, fill: sub)[#url]))
    place(dx: 3pt, dy: 12pt, box(width: w - 6pt, height: h - 15pt, clip: true, screen))
  })
  if label != none { linebreak(); caption(label) }
}

/// QR コード（見た目だけ）
#let qr(s: 30pt, c: ink) = box(width: s, height: s, {
  place(rect(width: s, height: s, fill: white))
  let u = s / 9
  let finder(x, y) = {
    place(dx: x * u, dy: y * u, rect(width: 3 * u, height: 3 * u, stroke: 0.9 * u + c))
    place(dx: (x + 1) * u, dy: (y + 1) * u, rect(width: u, height: u, fill: c))
  }
  finder(0, 0); finder(6, 0); finder(0, 6)
  for (x, y) in ((4, 0), (4, 2), (3, 3), (5, 3), (4, 4), (6, 4), (8, 4), (3, 5), (7, 5), (4, 6), (6, 6), (8, 6), (3, 7), (5, 8), (7, 8), (8, 8), (0, 4), (2, 4), (1, 3)) {
    place(dx: x * u, dy: y * u, rect(width: u, height: u, fill: c))
  }
})

/// 現在位置の青い点
#let me-dot(r: 3.2pt) = circle(radius: r, fill: accent, stroke: 1.2pt + white)

// ---- 頭: ブラウザでも ----
#hero(
  "v0.6.1 — 2026/09/07",
  [ブラウザでも開けるように],
  [Chrome / Edge でプロジェクトフォルダを開き、GeoPackage の表示・編集、Drive 連携、位置共有パーティが使えます。],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(label: "Android", mini-map(56pt, 98pt)),
    stack(dir: ttb, spacing: 4pt, cloud(w: 34pt, label: "Drive"), arrow-lr(w: 30pt)),
    browser(label: "Chrome / Edge", w: 118pt, h: 84pt, url: "こかげマップ", mini-map(112pt, 69pt)),
  ),
  note: [Windows / macOS / Linux 版は終了し、web 版に一本化しました（PWA としてインストールできます）。Firefox / Safari はフォルダを開けません。位置の精度は粗いので、現場では Android 版を使ってください。],
)

// ---- View ----
#scene(
  [1 つのレイヤを条件で見せ分ける],
  [レイヤのメニューの「View を追加」で、条件（QGIS のフィルタと同じ WHERE 句）の違う見せ方を何枚も作れます。色・太さも View ごとに変えられます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      layer-panel(w: 112pt, (
        (0, "layer", "小班", "ok"),
        (1, "layer", "樹種 = 'スギ'", "hi", map-green),
        (1, "layer", "樹種 = 'ヒノキ'", "ok", map-red),
      )),
      caption[小班に View を 2 枚],
    ),
    arrow-r(w: 14pt),
    phone(w: 50pt, h: 88pt, box(width: 44pt, height: 74pt, {
      place(mini-map(44pt, 74pt, comps: false))
      let cw = 44pt * 0.42
      let ch = 74pt * 0.36
      for (x, y, c) in ((0.05, 0.08, map-green), (0.52, 0.08, map-red), (0.05, 0.53, map-red), (0.52, 0.53, map-green)) {
        place(dx: 44pt * x, dy: 74pt * y, rect(width: cw, height: ch, radius: 1pt, fill: c.lighten(35%), stroke: 0.8pt + c.darken(10%)))
      }
    })),
  ),
  note: [これまでレイヤ単位のスタイルは保存されるだけで地図に出ていませんでしたが、今回から反映されます。重なり順はまだフォルダ構成どおりになりません。],
)

// ---- QGIS 連携 ----
#scene(
  [フォルダを QGIS でも開ける],
  [`<フォルダ名>.qgs` を自動で書き出し、表示やスタイルの変更に追従します。QGIS で保存した View・スタイル・表示状態は、次に開いたとき読み込みます。],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(w: 50pt, h: 88pt, label: "こかげマップ", mini-map(44pt, 74pt, road: map-red, road-w: 2.2pt)),
    stack(dir: ttb, spacing: 3pt, file-icon(accent, w: 14pt), text(size: 7pt, weight: "bold", fill: accent)[林小班.qgs], arrow-lr(w: 30pt)),
    pc(label: "QGIS", w: 110pt, h: 78pt, mini-map(104pt, 63pt, road: map-red, road-w: 2.2pt)),
  ),
  note: [QGIS で作った印刷レイアウトやシンボルの細部は消しません。`.qgz` も読めます。QGIS で実際に開けるかはまだ確かめていません。開かない場合はお知らせください。],
)

// ---- 位置共有パーティ ----
#scene(
  [パーティへは QR コードで],
  [招待リンクか QR コードで参加できます。リンクを開くと、ブラウザ版の参加画面が出ます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    phone(w: 50pt, h: 88pt, label: "ホスト", box(width: 44pt, height: 74pt, fill: white, align(center + horizon,
      stack(dir: ttb, spacing: 4pt, qr(s: 32pt), text(size: 5.5pt, fill: sub)[招待])))),
    arrow-r(w: 18pt),
    phone(w: 50pt, h: 88pt, label: "参加した人", box(width: 44pt, height: 74pt, {
      place(mini-map(44pt, 74pt, comps: false))
      place(dx: 12pt, dy: 22pt, me-dot())
      place(dx: 28pt, dy: 46pt, circle(radius: 3.2pt, fill: warm, stroke: 1.2pt + white))
    })),
  ),
)

// ---- 画面の外の現在位置 ----
#scene(
  [現在地が画面の外でも向きが分かる],
  [現在位置が画面の外にあるとき、その方向を指す矢印が縁に出ます。タップで現在位置へ飛びます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      bubble[縁の矢印をタップ],
      phone(w: 56pt, h: 100pt, box(width: 50pt, height: 86pt, {
        place(mini-map(50pt, 86pt))
        place(dx: 38pt, dy: 66pt, box(width: 10pt, height: 10pt, radius: 5pt, fill: white, stroke: 0.6pt + line-c,
          align(center + horizon, rotate(45deg, polygon(fill: accent, (0pt, -3pt), (2.5pt, 3pt), (-2.5pt, 3pt))))))
      })),
    ),
    arrow-r(w: 18pt),
    phone(w: 56pt, h: 100pt, label: "現在位置へ", box(width: 50pt, height: 86pt, {
      place(mini-map(50pt, 86pt, comps: false))
      place(dx: 25pt - 3.2pt, dy: 43pt - 3.2pt, me-dot())
    })),
  ),
)

// ---- 一覧 ----
#fixes(
  "ほかに変わったこと",
  [呼び名を「こかげマップ」に統一（Drive の `RootMap GIS Projects` はそのまま）],
  [ホストがメンバーを退出させられる],
  [圏外だった仲間の道のりが、電波復帰時に薄い線で届く],
  [Drive 連携フォルダも QR コードで渡せる],
  [サブフォルダも自分の `.qgs` を持ち、単体で開ける],
  [編集した GeoPackage を QGIS でそのまま使えるよう、保存時に整える],
  [GPS 軌跡などを `Documents/KokageMap/Global` に移し、アプリを消しても残る],
  [写真を追加しても、位置情報・撮影方向・元の名前が残る],
  [初期の背景地図を国土地理院（標準地図）に],
  [レイヤ一覧と属性テーブルの背景を不透明に],
)

#fixes(
  "直したこと",
  [OpenStreetMap の「Access blocked」表示],
  [起動時に現在地へ移動しないことがあった],
  [地図が目的地の手前で止まっていた],
  [パーティのダイアログが画面からはみ出していた],
  [Android 13 以降で「GPS 取得中」の通知が出ない],
  [起動のたびに「付近のデバイス」の許可を求めていた],
)
