// 更新履歴（図解）: Next release.tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// 画面（56 × 98pt）の上に、案内先の枠と下の札を重ねる
#let screen(body, card: none, ring: none, dot: none) = box(width: 56pt, height: 98pt, {
  place(body)
  if dot != none { let (x, y) = dot; place(dx: x - 3pt, dy: y - 3pt, circle(radius: 3pt, fill: map-red, stroke: 1pt + white)) }
  if ring != none { let (x, y, w, h) = ring; place(dx: x, dy: y, spot(w, h)) }
  if card != none { place(dx: 3pt, dy: 74pt, card) }
})
// 上の帯。右端はレイヤ一覧のボタン（重なった板）
#let bar = box(width: 56pt, height: 9pt, fill: white, {
  place(dx: 45.5pt, dy: 3.4pt, polygon(fill: sub.lighten(30%), (0pt, 2pt), (3.5pt, 0pt), (7pt, 2pt), (3.5pt, 4pt)))
  place(dx: 45.5pt, dy: 1.4pt, polygon(fill: sub, (0pt, 2pt), (3.5pt, 0pt), (7pt, 2pt), (3.5pt, 4pt)))
})
#let map-with-bar(comps: true) = stack(bar, mini-map(56pt, 89pt, comps: comps))

// ---- 頭 ----
#hero(
  "Next release",
  [Try the basics on a practice map],
  [No data of your own needed. A practice map opens and a frame shows where to tap. Tap it to move on.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    phone(label: "Move the map", screen(map-with-bar(), card: coach-card(50pt, "1 / 8", [Move the map]))),
    arrow-r(w: 10pt),
    phone(label: "Open layers", screen(map-with-bar(), ring: (42pt, 0pt, 13pt, 9pt), card: coach-card(50pt, "2 / 8", [Open layers]))),
    arrow-r(w: 10pt),
    phone(label: "Place a point", screen(map-with-bar(), dot: (28pt, 42pt), card: coach-card(50pt, none, [Done]))),
  ),
)

// ---- いつ始めるか ----
#scene(
  [Offered once on first use],
  [After the first-run setup, the app asks once. Later, start it from Home or Settings.],
  stack(dir: ttb, spacing: 8pt,
    box(width: 170pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 9pt, align(left, {
      text(size: 9pt, weight: "bold")[Try the basics?]
      v(3pt)
      text(size: 7.5pt, fill: sub)[On a practice map, go from moving the map to placing a point in about 3 minutes.]
      v(5pt)
      align(right, { text(size: 7.5pt, fill: accent)[Later]; h(10pt); box(fill: accent, radius: 8pt, inset: (x: 7pt, y: 3pt), text(size: 7.5pt, fill: white)[Start]) })
    })),
  ),
  note: [The practice map is recreated each time. It lives in `Documents/KokageMap/Practice`.],
)

// ---- 細かな変更 ----
#fixes(
  "Fixes",
  [Layers whose names contain spaces or quotes could not be written to],
)
