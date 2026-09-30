// 更新履歴（図解）: v0.6.1 (English).tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup.with(lang: "en")

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

// ---- Head: in the browser too ----
#hero(
  "v0.6.1 — 2026/09/07",
  [Now in the browser, too],
  [Open a project folder in Chrome / Edge, view and edit GeoPackages, use Google Drive and location-sharing parties.],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(label: "Android", mini-map(56pt, 98pt)),
    stack(dir: ttb, spacing: 4pt, cloud(w: 34pt, label: "Drive"), arrow-lr(w: 30pt)),
    browser(label: "Chrome / Edge", w: 118pt, h: 84pt, url: "Kokage Map", mini-map(112pt, 69pt)),
  ),
  note: [Windows / macOS / Linux builds are discontinued in favour of the web version (installable as a PWA). Firefox / Safari cannot open folders. Browser location is coarse, so use the Android app in the field.],
)

// ---- Views ----
#scene(
  [One layer, several views],
  ["Add view" in the layer menu creates a view with its own condition (an SQL WHERE clause, as in QGIS filters). Colour and width can be set per view.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      layer-panel(w: 124pt, header: "Layers", (
        (0, "layer", "Stands", "ok"),
        (1, "layer", "species = 'cedar'", "hi", map-green),
        (1, "layer", "species = 'cypress'", "ok", map-red),
      )),
      caption[Two views on Stands],
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
  note: [Layer-level styles used to be saved but never drawn; they now take effect. Stacking order does not yet follow the folder structure.],
)

// ---- QGIS ----
#scene(
  [Every folder opens in QGIS],
  [Each folder gets a `<folder>.qgs`, written automatically as visibility and styles change. Views, styles and visibility saved in QGIS are read back the next time the project is opened.],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(w: 50pt, h: 88pt, label: "Kokage Map", mini-map(44pt, 74pt, road: map-red, road-w: 2.2pt)),
    stack(dir: ttb, spacing: 3pt, file-icon(accent, w: 14pt), text(size: 7pt, weight: "bold", fill: accent)[Stands.qgs], arrow-lr(w: 30pt)),
    pc(label: "QGIS", w: 110pt, h: 78pt, mini-map(104pt, 63pt, road: map-red, road-w: 2.2pt)),
  ),
  note: [Print layouts and symbol details set in QGIS are kept. `.qgz` files can be read too. Opening the result in QGIS has not been verified yet; please report if it does not open.],
)

// ---- Party ----
#scene(
  [Join a party by QR code],
  [Join via invite link or QR code. The link opens the web join screen.],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    phone(w: 50pt, h: 88pt, label: "Host", box(width: 44pt, height: 74pt, fill: white, align(center + horizon,
      stack(dir: ttb, spacing: 4pt, qr(s: 32pt), text(size: 5.5pt, fill: sub)[Invite])))),
    arrow-r(w: 18pt),
    phone(w: 50pt, h: 88pt, label: "New member", box(width: 44pt, height: 74pt, {
      place(mini-map(44pt, 74pt, comps: false))
      place(dx: 12pt, dy: 22pt, me-dot())
      place(dx: 28pt, dy: 46pt, circle(radius: 3.2pt, fill: warm, stroke: 1.2pt + white))
    })),
  ),
)

// ---- Off-screen location ----
#scene(
  [Off screen, but you know which way],
  [When your location is off screen, an arrow on the edge points toward it. Tap it to jump there.],
  grid(
    columns: (auto, auto, auto), column-gutter: 10pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      bubble[Tap the edge arrow],
      phone(w: 56pt, h: 100pt, box(width: 50pt, height: 86pt, {
        place(mini-map(50pt, 86pt))
        place(dx: 38pt, dy: 66pt, box(width: 10pt, height: 10pt, radius: 5pt, fill: white, stroke: 0.6pt + line-c,
          align(center + horizon, rotate(45deg, polygon(fill: accent, (0pt, -3pt), (2.5pt, 3pt), (-2.5pt, 3pt))))))
      })),
    ),
    arrow-r(w: 18pt),
    phone(w: 56pt, h: 100pt, label: "Your location", box(width: 50pt, height: 86pt, {
      place(mini-map(50pt, 86pt, comps: false))
      place(dx: 25pt - 3.2pt, dy: 43pt - 3.2pt, me-dot())
    })),
  ),
)

// ---- Lists ----
#fixes(
  "Also changed",
  [Now Kokage Map everywhere (the Drive folder `RootMap GIS Projects` is unchanged)],
  [The host can remove members],
  [Tracks walked out of coverage arrive later as thin lines],
  [Drive-linked folders can go by QR code, too],
  [Subfolders get their own `.qgs`],
  [Edited GeoPackages stay usable in QGIS],
  [GPS tracks etc. survive uninstalling (moved to `Documents/KokageMap/Global`)],
  [Photos keep location, direction and name],
  [The default basemap is now GSI],
  [Opaque layer list and attribute table],
)

#fixes(
  "Fixed",
  [OpenStreetMap "Access blocked" tiles],
  [Launch sometimes not jumping to you],
  [Jumps stopping short of the target],
  [The party dialog overflowing the screen],
  [Android 13+: ongoing notification missing],
  [The "Nearby devices" prompt each launch],
)
