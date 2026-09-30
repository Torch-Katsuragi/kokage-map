// Changelog (illustrated): v0.8.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.8.0 — 2026/09/30",
  [Back and forth with QGIS, as is],
  [Folder settings now live in the QGIS project file (`.qgs`). Colors and visibility you set in the app look the same when you open it in QGIS.],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(label: "Kokage Map", mini-map(56pt, 98pt, road: map-red, road-w: 2.4pt)),
    stack(dir: ttb, spacing: 3pt, file-icon(accent, w: 14pt), text(size: 7pt, weight: "bold", fill: accent)[Stands.qgs], arrow-lr(w: 30pt)),
    pc(label: "QGIS", w: 110pt, h: 78pt, mini-map(104pt, 63pt, road: map-red, road-w: 2.4pt)),
  ),
)

#scene(
  [Settings go into the folder's `.qgs`],
  [Visibility, colors, Views and order are kept in one file inside the folder. Share it on Drive and your other devices get them too.],
  grid(
    columns: (1fr, auto, 1fr), column-gutter: 6pt, align: horizon,
    block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 7pt, width: 100%, align(left, {
      text(size: 7pt, fill: sub, weight: "bold")[Before]
      v(4pt)
      folder-icon(sub.lighten(30%)); h(3pt); text(size: 8.5pt, fill: sub)[Stands]
      v(3pt)
      h(6pt); file-icon(sub.lighten(20%)); h(3pt); text(size: 8pt, fill: sub)[.kmeta.json]
      v(5pt)
      badge(ok: false)[This device only]
    })),
    arrow-r(w: 16pt),
    block(fill: white, stroke: 1.2pt + accent, radius: 6pt, inset: 7pt, width: 100%, align(left, {
      text(size: 7pt, fill: accent, weight: "bold")[Now]
      v(4pt)
      folder-icon(warm); h(3pt); text(size: 8.5pt, weight: "bold")[Stands]
      v(3pt)
      h(6pt); file-icon(accent); h(3pt); text(size: 8pt, fill: accent, weight: "bold")[Stands.qgs]
      v(5pt)
      badge[Opens in QGIS]; h(2pt); badge[Shareable]
    })),
  ),
  note: [Moved automatically when you open the folder. The old file stays as `.kmeta.json.migrated`.],
)

#scene(
  [Edit subfolders from QGIS, too],
  [Whichever folder's `.qgs` you open, the layers in its subfolders are editable. Colors you change in QGIS come back to the app.],
  stack(dir: ttb, spacing: 10pt,
    grid(
      columns: (auto, auto, auto), column-gutter: 5pt, align: horizon,
      stack(dir: ttb, spacing: 4pt,
        caption[Before],
        layer-panel(w: 84pt, header: "Layers", (
          (0, "layer", "Roads", "ok"),
          (0, "dir", "Area B", "lock"),
          (1, "layer", "Stands", "lock"),
        )),
        caption[Subfolders were read-only],
      ),
      arrow-r(w: 14pt),
      stack(dir: ttb, spacing: 4pt,
        caption(fill: accent)[Now],
        layer-panel(w: 84pt, header: "Layers", (
          (0, "layer", "Roads", "ok"),
          (0, "dir", "Area B", "ok"),
          (1, "layer", "Stands", "hi", map-green),
        )),
        caption(fill: accent)[Change the stands' color],
      ),
    ),
    grid(
      columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
      pc(w: 84pt, h: 58pt, label: "Change and save in QGIS", mini-map(78pt, 43pt, comp: map-green)),
      arrow-r(w: 20pt),
      phone(w: 44pt, h: 78pt, label: "The app follows", mini-map(38pt, 64pt, comp: map-green)),
    ),
  ),
)

#scene(
  [Two devices at once, both changes kept],
  [Settings changed on different devices are merged by Drive sync.],
  stack(dir: ttb, spacing: 5pt,
    grid(
      columns: (96pt, 96pt), align: center,
      stack(dir: ttb, spacing: 4pt, bubble[Roads in red], phone(w: 44pt, h: 78pt, label: "Device A", mini-map(38pt, 64pt, road: map-red, road-w: 2.4pt))),
      stack(dir: ttb, spacing: 4pt, bubble[Hide the stands], phone(w: 44pt, h: 78pt, label: "Device B", mini-map(38pt, 64pt, comps: false))),
    ),
    arrows-in(192pt),
    cloud(w: 64pt, label: "Drive"),
    arrow-d(),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 44pt, h: 78pt, mini-map(38pt, 64pt, road: map-red, road-w: 2.4pt, comps: false)),
      badge[Both devices end up like this],
    ),
  ),
  note: [If both change the same item, each device keeps its own value. "Restore cloud value" in the notification switches to the other one.],
)

#fixes(
  "Also changed",
  [The changelog is now illustrated, and each release folds],
  [Layers styled in QGIS by category or rule show "Style set in QGIS" on the style screen],
)

#fixes(
  "Fixes",
  [Web: a GeoPackage could be overwritten empty right after opening a project],
  [Changing settings in a row could lose the earlier change],
  [Renaming a GeoPackage in a subfolder failed],
  [In Drive-linked folders, auto sync undid renames],
  [Colors changed in QGIS did not reach layers without Views],
  [Hiding a group in QGIS hid the layer in the app instead],
  [Same-named GeoPackages in different folders mixed their colors],
  [A `.qgs` saved in QGIS was not picked up right after sync],
  [After re-saving in QGIS 4, app-only settings (such as photo visibility) were not read],
)
