// Changelog (illustrated): v0.5.4. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

// Settings screen (phone screen 56 × 98). rows are (item, value); size sets the text size
#let settings-screen(title, rows, size: 6pt) = box(width: 56pt, height: 98pt, clip: true, fill: white,
  place(top + left, stack(dir: ttb,
    block(width: 56pt, fill: accent-soft, inset: (x: 4pt, y: 4pt),
      text(size: size + 0.5pt, weight: "bold", fill: accent)[#title]),
    ..rows.map(((k, val)) => block(width: 56pt, inset: (x: 4pt, y: size * 0.6), stroke: (bottom: 0.4pt + line-c), {
      text(size: size)[#k]
      if val != none { h(1fr); text(size: size, fill: accent, weight: "bold")[#val] }
    })),
  )))

// "Offline" at the top of the screen
#let offline-chip = box(fill: ink.transparentize(25%), radius: 2pt, inset: (x: 2.5pt, y: 1.5pt),
  text(size: 5pt, fill: white, weight: "bold")[Offline])

// Permission screen (step, permission name)
#let perm-screen(step, name) = box(width: 50pt, height: 84pt, fill: white, {
  place(dx: 4pt, dy: 5pt, text(size: 5pt, fill: sub)[#step / 3])
  place(dx: 15pt, dy: 15pt, circle(radius: 10pt, fill: accent-soft))
  place(dy: 40pt, box(width: 50pt, align(center, text(size: 6pt, weight: "bold")[#name])))
  place(dx: 6pt, dy: 51pt, rect(width: 38pt, height: 2pt, fill: line-c))
  place(dx: 6pt, dy: 56pt, rect(width: 30pt, height: 2pt, fill: line-c))
  place(dx: 6pt, dy: 66pt, box(width: 38pt, height: 10pt, radius: 3pt, fill: accent,
    align(center + horizon, text(size: 5pt, weight: "bold", fill: white)[Allow])))
})

#hero(
  "v0.5.4 — 2026/04/10",
  [Now available \ in English],
  [All UI strings are in Japanese and English. Switch languages with one tap in Settings.],
  grid(
    columns: (auto, auto, auto), column-gutter: 12pt, align: horizon,
    phone(label: "日本語", settings-screen([設定], (([言語], [日本語]), ([一般], none), ([権限], none)), size: 5pt)),
    arrow-lr(w: 30pt),
    phone(label: "English", settings-screen([Settings], (([Language], [English]), ([General], none), ([Permissions], none)), size: 5pt)),
  ),
)

#scene(
  [Maps show up even offline],
  [Cached map tiles (MBTiles) are now read directly by the map engine, so maps are much more stable offline. Also fixed the blank map on Android when returning from background.],
  grid(
    columns: (auto, auto, auto), column-gutter: 12pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[Before],
      phone(box(width: 56pt, height: 98pt, fill: white, place(dx: 3pt, dy: 3pt, offline-chip))),
      badge(ok: false)[Blank on return],
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[Now],
      phone(box(width: 56pt, height: 98pt, { place(mini-map(56pt, 98pt)); place(dx: 3pt, dy: 3pt, offline-chip) })),
      badge[Shown offline],
    ),
  ),
)

#let size-slider(w) = box(width: w, height: 24pt, {
  let labels = ("XS", "S", "M−", "M", "M+", "L", "XL")
  let step = (w - 12pt) / 6
  place(dx: 6pt, dy: 5pt, line(length: w - 12pt, stroke: 2pt + line-c))
  for (i, l) in labels.enumerate() {
    place(dx: 6pt + step * i - 1.5pt, dy: 3.5pt, circle(radius: 1.5pt, fill: sub.lighten(20%)))
    place(dx: 6pt + step * i - 10pt, dy: 12pt, box(width: 20pt, align(center, text(size: 6.5pt, fill: if i == 3 { accent } else { sub }, weight: if i == 3 { "bold" } else { "regular" })[#l])))
  }
  place(dx: 6pt + step * 3 - 5pt, dy: 0pt, circle(radius: 5pt, fill: accent))
})

#let size-rows = (([Language], none), ([UI size], none), ([General], none))

#scene(
  [Text and UI size in 7 levels],
  [Pick it with the slider in Settings → General. Changes apply instantly, no restart required.],
  stack(dir: ttb, spacing: 12pt,
    size-slider(200pt),
    grid(
      columns: (auto, auto), column-gutter: 30pt, align: bottom,
      phone(label: "XS", settings-screen([Settings], size-rows, size: 4.5pt)),
      phone(label: "XL", settings-screen([Settings], size-rows, size: 8pt)),
    ),
  ),
)

#scene(
  [Permissions, one at a time],
  [On first launch, you are walked through Storage, Location and Bluetooth in turn, with what each is for. Check or set them again anytime in Settings.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 4pt, align: horizon,
    phone(w: 56pt, h: 98pt, perm-screen(1, [Storage])),
    arrow-r(w: 14pt),
    phone(w: 56pt, h: 98pt, perm-screen(2, [Location])),
    arrow-r(w: 14pt),
    phone(w: 56pt, h: 98pt, perm-screen(3, [Bluetooth])),
  ),
)

#fixes(
  "Also in this release",
  [In-app user guide (AI-generated)],
  [Update banner and in-app update history],
  [Android navigation bar auto-hides],
)
