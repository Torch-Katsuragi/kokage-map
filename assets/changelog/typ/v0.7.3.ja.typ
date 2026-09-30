// 更新履歴（図解）: v0.7.3。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ---- この版だけの部品 ----

/// 属性テーブル（画面の中）。rows は (小班, 状態, 直したか)
#let attr-table(w, head, rows) = box(width: w, height: 100%, fill: white, {
  let cell(body, fill: white, bold: false, c: ink) = box(width: 100%, fill: fill, inset: (x: 2.5pt, y: 2.2pt),
    text(size: 6pt, weight: if bold { "bold" } else { "regular" }, fill: c)[#body])
  grid(columns: (1fr, 1fr), stroke: 0.4pt + line-c,
    ..head.map(h => cell(h, fill: rgb("#f1eff4"), bold: true, c: sub)),
    ..rows.map(r => {
      let (a, b, on) = r
      (cell(a, fill: if on { accent-soft } else { white }), cell(b, fill: if on { accent-soft } else { white }, bold: on, c: if on { accent } else { ink }))
    }).flatten(),
  )
})

/// 「地図・タイル」の画面。rows は (名前, 表示, 不透明度 0〜1, 合成モード)
#let tiles-panel(w: 132pt, title: "地図・タイル", rows) = box(width: w, fill: white, stroke: 0.6pt + line-c, radius: 3pt, clip: true, align(left, {
  block(width: 100%, fill: rgb("#f1eff4"), inset: (x: 5pt, y: 3pt), below: 0pt, text(size: 6.5pt, weight: "bold", fill: sub)[#title])
  for (name, on, op, mode) in rows {
    block(width: 100%, inset: (x: 5pt, y: 3pt), above: 0pt, below: 0pt, stroke: (top: 0.4pt + line-c), stack(dir: ttb, spacing: 3pt,
      grid(columns: (8pt, 1fr, auto), column-gutter: 3pt, align: horizon,
        check-box(on: on),
        text(size: 7.3pt, fill: if on { ink } else { sub })[#name],
        text(size: 6pt, fill: sub)[≡],
      ),
      grid(columns: (1fr, auto), column-gutter: 4pt, align: horizon,
        box(width: 100%, height: 3pt, {
          place(rect(width: 100%, height: 3pt, radius: 1.5pt, fill: line-c))
          place(rect(width: op * 100%, height: 3pt, radius: 1.5pt, fill: if on { accent } else { sub.lighten(40%) }))
        }),
        text(size: 6pt, fill: sub)[#calc.round(op * 100)% · #mode],
      ),
    ))
  }
}))

/// 等高線の入った地図。n 本の輪
#let contour-map(w, h, n, bg: true) = box(width: w, height: h, clip: true, {
  if bg { place(rect(width: w, height: h, fill: map-bg)) }
  for i in range(n) {
    let k = (i + 1) / n
    let ew = w * 1.5 * k
    let eh = h * 1.2 * k
    place(dx: w * 0.55 - ew / 2, dy: h * 0.5 - eh / 2, ellipse(width: ew, height: eh, stroke: 0.5pt + map-road.lighten(20%)))
  }
})

/// 傾けた地図（3D）。上は空、下は奥へ細る地面
#let tilted-map(w, h) = box(width: w, height: h, clip: true, {
  let top = h * 0.3
  place(rect(width: w, height: h, fill: rgb("#dbe9f7")))
  let p(u, v) = {
    let tw = w * 0.9
    let bw = w * 2.2
    let ww = tw + (bw - tw) * v
    (w / 2 + (u - 0.5) * ww, top + v * (h - top))
  }
  place(polygon(fill: map-bg, p(0, 0), p(1, 0), p(1, 1), p(0, 1)))
  for (x, y) in ((0.05, 0.08), (0.52, 0.08), (0.05, 0.53), (0.52, 0.53)) {
    place(polygon(fill: map-comp.lighten(20%), stroke: 0.6pt + map-comp.darken(35%),
      p(x, y), p(x + 0.42, y), p(x + 0.42, y + 0.36), p(x, y + 0.36)))
  }
  place(curve(stroke: (paint: map-road, thickness: 1.6pt, cap: "round"),
    curve.move(p(0, 0.78)), curve.line(p(0.3, 0.45)), curve.line(p(0.6, 0.8)), curve.line(p(1, 0.3))))
})

/// コンパスのボタン
#let compass-btn(label) = box(width: 22pt, height: 22pt, {
  place(circle(radius: 11pt, fill: white, stroke: 0.7pt + line-c))
  place(dx: 11pt - 3pt, dy: 4pt, polygon(fill: map-red, (3pt, 0pt), (6pt, 7pt), (0pt, 7pt)))
  place(dy: 12pt, box(width: 22pt, align(center, text(size: 5.5pt, weight: "bold", fill: ink)[#label])))
})

/// lib の layer-panel を左寄せで（場面の中は中央寄せなので、字下げが消えないように）

/// hero の下の注記（scene の note と同じ字）

// ---- 頭: 2 台で直した GeoPackage が行ごとに合わさる ----
#hero(
  "v0.7.3 — 2026/09/27",
  [2 台で直しても、\ 行ごとに合わさる],
  [同じ GeoPackage を 2 台で直しても、Drive 同期で行ごとに合わせます。別々の行を直したなら、両方の変更が残ります。],
  {
    let head = ([小班], [状態])
    stack(dir: ttb, spacing: 5pt,
      grid(
        columns: (96pt, 96pt), align: center,
        stack(dir: ttb, spacing: 4pt, bubble[1 の行を直す],
          phone(w: 58pt, h: 60pt, label: "端末A", attr-table(52pt, head, (([1], [済], true), ([2], [未], false), ([3], [未], false))))),
        stack(dir: ttb, spacing: 4pt, bubble[3 の行を直す],
          phone(w: 58pt, h: 60pt, label: "端末B", attr-table(52pt, head, (([1], [未], false), ([2], [未], false), ([3], [済], true))))),
      ),
      arrows-in(192pt),
      cloud(w: 64pt, label: "Drive"),
      arrow-d(),
      stack(dir: ttb, spacing: 4pt,
        phone(w: 58pt, h: 60pt, attr-table(52pt, head, (([1], [済], true), ([2], [未], false), ([3], [済], true)))),
        badge[両方の変更が残る],
      ),
    )
  },
  note: [同じ行の同じ列を両方で直したときは、この端末の値を残します。通知の「クラウドの値に戻す」で相手の値に戻せます。],
)

// ---- 背景地図がレイヤに ----
#scene(
  [背景地図を、レイヤのように重ねる],
  [「地図・タイル」で、並び替え・表示／非表示・不透明度・合成モード（乗算やスクリーンなど）を設定できます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    tiles-panel(w: 128pt, (
      ([等高線], true, 1.0, [通常]),
      ([地理院地図], true, 0.6, [乗算]),
      ([OpenStreetMap], false, 1.0, [通常]),
    )),
    arrow-r(w: 16pt),
    phone(w: 58pt, h: 100pt, {
      place(mini-map(52pt, 86pt, comps: false, road-w: 1.6pt))
      place(contour-map(52pt, 86pt, 5, bg: false))
    }),
  ),
  note: [これまでの重ねは、同じ見た目のまま引き継ぎます。設定の画面では、タイル 1 枚のプレビューが出ます。],
)

// ---- 等高線 ----
#scene(
  [等高線も、背景地図の 1 つに],
  [間隔は地理院地図と同じで、寄るほど細かくなります。作ったタイルはキャッシュに残るので、圏外でも出ます。],
  stack(dir: ttb, spacing: 8pt,
    grid(
      columns: (auto,) * 4, column-gutter: 6pt, align: center,
      ..(("ズーム 18", "2 m", 12), ("15〜17", "10 m", 8), ("12〜14", "100 m", 5), ("9〜11", "200 m", 3)).map(((z, iv, n)) =>
        stack(dir: ttb, spacing: 3pt,
          box(stroke: 0.6pt + line-c, radius: 2pt, clip: true, contour-map(52pt, 52pt, n)),
          text(size: 7.5pt, weight: "bold")[#iv],
          caption(z),
        )
      ),
    ),
    badge[圏外でも出る],
  ),
)

// ---- 2D と 3D ----
#scene(
  [コンパスで、2D と 3D を切り替え],
  [2D は真上から見たまま、3D は傾けて見ます。指の動きもそれぞれ違います。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: (top, top + center, top),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 58pt, h: 100pt, label: "2D", {
        place(mini-map(52pt, 86pt))
        place(dx: 27pt, dy: 61pt, compass-btn[2D])
      }),
      bubble[1 本指で移動\ 2 本指で拡縮と回転],
    ),
    pad(top: 46pt, arrow-lr(w: 26pt)),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 58pt, h: 100pt, label: "3D", {
        place(tilted-map(52pt, 86pt))
        place(dx: 27pt, dy: 61pt, compass-btn[3D])
      }),
      bubble[1 本指で回転と傾き],
    ),
  ),
  note: [北を上に戻すのはダブルタップ、眺めモードは 3D で長押しです。],
)

// ---- System フォルダ ----
#scene(
  [レイヤ一覧の先頭に「System」],
  [グローバルフォルダは「System」の中に移りました。プロジェクトに属さない、端末側のデータの置き場です。],
  grid(
    columns: (auto, auto, auto), column-gutter: 5pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[これまで],
      layer-panel(w: 84pt, (
        (0, "dir", "グローバル", "ok"),
        (0, "layer", "路網", "ok"),
        (0, "layer", "小班", "ok", map-comp),
      )),
    ),
    arrow-r(w: 14pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[これから],
      layer-panel(w: 84pt, (
        (0, "dir", "System", "hi"),
        (1, "dir", "グローバル", "ok"),
        (0, "layer", "路網", "ok"),
        (0, "layer", "小班", "ok", map-comp),
      )),
    ),
  ),
  note: [フォルダの実体の場所と、表示／非表示はそのままです。],
)

// ---- 一覧 ----
#fixes(
  "ほかにも変わりました",
  [片方だけ列を足しても、そろえてから合わせる],
  [自動同期は、変わったファイルだけを上げる],
  [開くと、フィーチャ全体が入る範囲から始まる],
  [3D はまず粗く出す。遅い回線でも待ちが半分以下],
  [細かい画面では、寄ると背景地図を 2 倍の解像度に],
  [一括ダウンロードは、重ねたレイヤ全部（等高線も）を保存。OpenStreetMap は除く],
  [出典は「地図・タイル」の「出典」に],
  [属性フォームは、欄を離れたときも保存する],
  [数値の列では、数字のキーボードが出る],
)

#fixes(
  "直したこと",
  [Android で足した地物が QGIS の索引に無かった],
  [落とした GeoPackage を開いただけで上げ直した],
  [別のパスで開くと、全ファイルを落とし直していた],
  [Android で「傾斜」の色分けが効かなかった],
  [3D で、川や湖の上に四角い台地が出ることがあった],
  [現在位置の向きを、2D と同じ扇形に戻した],
  [キーボードが出ると、ダイアログや道具列がはみ出した],
  [縦持ちで、点の属性テーブルのボタンがはみ出した],
  [「左利き」で、web 版の拡大・縮小ボタンが記録ボタンと重なった],
  [web 版で、最初の「フォルダを選択」が失敗した],
)
