// 更新履歴（図解）: v0.7.2。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ---- この版だけの部品 ----

// 地形の色分けの 3 色（地図の中の色）
#let slope-c = (rgb("#9ccc65"), rgb("#fdd835"), rgb("#e57373"))

/// 傾けた地形（3D）。cells は色の番号（0〜2、none で塗らない）を奥から手前へ 4 行 × 5 列
#let terrain(w, h, cells: none, contours: false, road: none, road-w: 1.6pt) = box(width: w, height: h, clip: true, {
  let top = h * 0.3
  place(rect(width: w, height: h, fill: rgb("#dbe9f7")))
  let p(u, v) = {
    let ww = w * 0.9 + w * 1.3 * v
    (w / 2 + (u - 0.5) * ww, top + v * (h - top))
  }
  place(polygon(fill: map-bg, p(0, 0), p(1, 0), p(1, 1), p(0, 1)))
  if cells != none {
    for (r, row) in cells.enumerate() {
      for (c, k) in row.enumerate() {
        if k != none {
          let (u0, u1, v0, v1) = (c / 5, (c + 1) / 5, r / 4, (r + 1) / 4)
          place(polygon(fill: slope-c.at(k), p(u0, v0), p(u1, v0), p(u1, v1), p(u0, v1)))
        }
      }
    }
  }
  if contours {
    for v in (0.2, 0.45, 0.72) {
      place(curve(stroke: 0.7pt + map-road.darken(10%),
        curve.move(p(0, v)), curve.line(p(0.25, v - 0.08)), curve.line(p(0.5, v + 0.06)), curve.line(p(0.75, v - 0.05)), curve.line(p(1, v + 0.04))))
    }
  }
  if road != none {
    place(curve(stroke: (paint: road, thickness: road-w, cap: "round"),
      curve.move(p(0, 0.78)), curve.line(p(0.3, 0.45)), curve.line(p(0.6, 0.8)), curve.line(p(1, 0.3))))
  }
})

// 尾根を斜めに横切る傾斜の並び
#let slope-cells = (
  (0, 1, 2, 1, 0),
  (1, 2, 2, 1, 0),
  (1, 2, 1, 0, 0),
  (2, 1, 0, 0, 1),
)

/// 設定の画面（見出しと行）。rows は (名前, 中身)
#let settings-panel(w: 120pt, title, rows) = box(width: w, fill: white, stroke: 0.6pt + line-c, radius: 3pt, clip: true, align(left, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: (x: 5pt, y: 3pt), below: 0pt, text(size: 6.5pt, weight: "bold", fill: sub)[#title])
  for (name, body) in rows {
    block(width: 100%, inset: (x: 5pt, y: 3.5pt), above: 0pt, below: 0pt, stroke: (top: 0.4pt + line-c),
      grid(columns: (auto, 1fr), column-gutter: 4pt, align: (left + horizon, right + horizon),
        text(size: 7pt)[#name], body))
  }
}))

#let seg(..items, on: 0) = {
  for (i, it) in items.pos().enumerate() {
    box(fill: if i == on { accent } else { white }, stroke: 0.5pt + if i == on { accent } else { line-c },
      inset: (x: 3pt, y: 1.5pt), radius: 2pt,
      text(size: 6pt, weight: "bold", fill: if i == on { white } else { sub })[#it])
  }
}
#let swatch(c) = box(width: 8pt, height: 8pt, radius: 1.5pt, fill: c, stroke: 0.4pt + c.darken(25%), baseline: 15%)
#let slider(op) = box(width: 36pt, height: 3pt, baseline: -30%, {
  place(rect(width: 100%, height: 3pt, radius: 1.5pt, fill: line-c))
  place(rect(width: op * 100%, height: 3pt, radius: 1.5pt, fill: accent))
})

/// 画面の中の配置。card: "bottom"/"right"、bar: "left"/"right"
#let layout-screen(w, h, card: "bottom", bar: "left") = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  let bx = if bar == "left" { 3pt } else { w - 11pt }
  place(dx: bx, dy: 5pt, rect(width: 8pt, height: 30pt, radius: 3pt, fill: white, stroke: 0.4pt + line-c))
  for i in range(3) { place(dx: bx + 2pt, dy: 8pt + i * 9pt, circle(radius: 2pt, fill: accent)) }
  if card == "bottom" {
    place(dy: h * 0.62, rect(width: w, height: h * 0.38, radius: (top-left: 4pt, top-right: 4pt), fill: white, stroke: 0.5pt + line-c))
    for (i, k) in (0.55, 0.8, 0.4).enumerate() { place(dx: 5pt, dy: h * 0.62 + 5pt + i * 5pt, rect(width: (w - 10pt) * k, height: 2pt, fill: line-c)) }
  } else {
    place(dx: w * 0.58, rect(width: w * 0.42, height: h, fill: white, stroke: 0.5pt + line-c))
    for (i, k) in (0.55, 0.8, 0.4).enumerate() { place(dx: w * 0.58 + 4pt, dy: 5pt + i * 5pt, rect(width: (w * 0.42 - 8pt) * k, height: 2pt, fill: line-c)) }
  }
})

/// ラベルの付いた地図（小班 4 つに ラベル）
#let label-map(w, h, labels) = box(width: w, height: h, clip: true, {
  place(mini-map(w, h))
  for ((x, y), l) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)).zip(labels) {
    place(dx: w * x, dy: h * y, box(width: w * 0.42, height: h * 0.36, align(center + horizon,
      text(size: 6pt, weight: "bold", fill: ink)[#l])))
  }
})

/// スタイルの 1 行（名前と値）。inherit: レイヤから届いた値
#let style-card(title, rows, stroke: 0.6pt + line-c) = box(width: 84pt, fill: white, stroke: stroke, radius: 3pt, clip: true, align(left, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: (x: 5pt, y: 3pt), below: 0pt, text(size: 6.5pt, weight: "bold", fill: sub)[#title])
  for (name, body, own) in rows {
    block(width: 100%, inset: (x: 5pt, y: 3pt), above: 0pt, below: 0pt, stroke: (top: 0.4pt + line-c),
      grid(columns: (1fr, auto), align: (left + horizon, right + horizon),
        text(size: 7pt, fill: if own { ink } else { sub })[#name],
        text(size: 7pt, weight: if own { "bold" } else { "regular" }, fill: if own { ink } else { sub })[#body]))
  }
}))


// ---- 頭: 地形の見た目 ----
#hero(
  "v0.7.2 — 2026/09/13",
  [地形を傾斜や標高で色分け],
  [設定に「地形の見た目」を足しました。傾斜や標高で地形を色分けでき、標高タイルから等高線も描けます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    settings-panel(w: 116pt, "地形の見た目", (
      ([色分け], seg([傾斜], [標高])),
      ([色], { swatch(slope-c.at(0)); h(2pt); swatch(slope-c.at(1)); h(2pt); swatch(slope-c.at(2)) }),
      ([強さ], { slider(0.6); h(3pt); text(size: 6pt, fill: sub)[60%] }),
      ([等高線], check-box()),
    )),
    arrow-r(w: 16pt),
    phone(w: 62pt, h: 104pt, terrain(56pt, 90pt, cells: slope-cells, contours: true)),
  ),
  note: [3 色は自分で選べます。強さを 100% にすると、基図なしの地形だけになります。色も線も地形の網目から作るので、傾けて横から見ても粗くなりません。],
)

// ---- 画面の配置 ----
#scene(
  [画面の配置を持ち方で選ぶ],
  [設定で自動／縦持ち／横長／左利きを選べます。情報カードは属性テーブルと同じく下から出て、両方は同時に出ません。],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: bottom,
    phone(w: 50pt, h: 88pt, label: "縦持ち", layout-screen(44pt, 74pt)),
    phone(w: 92pt, h: 56pt, label: "横長", layout-screen(86pt, 42pt, card: "right")),
    phone(w: 50pt, h: 88pt, label: "左利き", layout-screen(44pt, 74pt, bar: "right")),
  ),
  note: [横長はカードが右、左利きはツールバーとボタンが右に寄ります。],
)

// ---- ラベル ----
#scene(
  [ラベルは QGIS と同じ式で],
  [ラベルはスタイル画面（レイヤ／View）で組み立て、線と面のレイヤにも付けられます。],
  stack(dir: ttb, spacing: 8pt,
    box(fill: white, stroke: 0.6pt + line-c, radius: 3pt, inset: (x: 6pt, y: 4pt),
      text(size: 7.5pt)[`concat("林班", '-', "小班")`]),
    arrow-d(),
    grid(
      columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
      phone(w: 50pt, h: 88pt, label: "こかげマップ", label-map(44pt, 74pt, ([12-1], [12-2], [12-3], [12-4]))),
      arrow-lr(w: 26pt),
      pc(w: 96pt, h: 66pt, label: "QGIS", label-map(90pt, 51pt, ([12-1], [12-2], [12-3], [12-4]))),
    ),
  ),
  note: [`.qgs` には式のまま書き、QGIS で決めたラベルも読み戻します。これまでの設定はそのまま読み替えます。列は値が入っている順に並び、式を直接書くこともできます。],
)

// ---- View のスタイル ----
#scene(
  [View はレイヤと違うところだけ],
  [View のスタイルは、レイヤと違う項目だけを持ちます。レイヤ側を変えると、触っていない項目は View にも届きます。],
  stack(dir: ttb, spacing: 8pt,
    grid(
      columns: (auto, auto, auto), column-gutter: 6pt, align: bottom,
      stack(dir: ttb, spacing: 4pt,
        bubble[レイヤの色を緑に],
        style-card("レイヤ", (([色], swatch(map-green), true), ([太さ], [2], true)), stroke: 1.2pt + accent),
      ),
      arrow-r(w: 16pt),
      style-card("View", (([色], swatch(map-green), false), ([太さ], [4], true))),
    ),
    grid(
      columns: (auto, auto), column-gutter: 16pt,
      phone(w: 50pt, h: 88pt, label: "レイヤ", mini-map(44pt, 74pt, road: map-green.darken(20%), road-w: 1.6pt)),
      phone(w: 50pt, h: 88pt, label: "View（太さは 4 のまま）", mini-map(44pt, 74pt, road: map-green.darken(20%), road-w: 3.4pt)),
    ),
  ),
  note: [「レイヤに従う」で、View をレイヤと同じに戻せます。],
)

// ---- 一覧 ----
#fixes(
  "ほかにも変わりました",
  [引いた地図（ズーム 13 以下）は、フィーチャを地形の絵に描き込む。1 万面でも軽い],
  [CLI や URL から、開く・見せる・読み直すを頼める],
  [地図のメニューに「プロジェクトを読み直す」],
  [View が 1 枚だけのレイヤでも、View の行を出す],
  [写真のカードにも Google Maps リンクのコピー],
)

#fixes(
  "直したこと",
  [3D の地形で、タイルの継ぎ目に段差が出ていた],
  [消しゴムで消したフィーチャが残ることがあった],
  [GPS 軌跡は、10 分以上空いたら別の線にする],
  [通知や設定などに残っていた英語を日本語にした],
  [web 版で、フォルダを選ばずに地図を開けていた],
  [web 版で、右ドラッグのたびにメニューが出た],
)
