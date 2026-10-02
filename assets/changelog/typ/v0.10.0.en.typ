// Changelog (illustrated): v0.10.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.10.0 — 2026/10/02",
  [No View row when a layer has a single View],
  [Change the look with "Style" in the layer's ⋮ menu. After "Add view", a View named after the layer (formerly "Default") and the added one are listed together.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, header: "Layers", ((0, "layer", [Areas], "ok", rgb("#2e7d32")),)), caption[Single View]),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, header: "Layers", ((0, "layer", [Areas], "ok", rgb("#2e7d32")), (1, "layer", [Large], "hi", rgb("#c0504d")), (1, "layer", [Areas], "ok", rgb("#2e7d32")))), caption[After adding a View]),
  ),
)

#fixes(
  "Photos",
  [Photos on the map use a camera mark; selected ones turn the selection color],
  [The photo panel shows the photo faintly behind, with a zoom button at the top right],
)

#fixes(
  "Tutorial",
  ["Changing the look" now adds a View and switches between looks],
  [After each color change, close the list and see the map],
  [A larger glow around the red frame that marks where to tap],
)

#fixes(
  "Fixes",
  [Newly drawn features used the default color until reopening],
  [Quickly toggling visibility after a color change could leave old-color patches],
  [Area fills had gaps on ridges where the map showed through],
  [Color and opacity changed through a View's "Style" were sometimes lost on reopening],
  [A View added with "Add view" went to the bottom and drew nothing (it now goes on top)],
  [Areas in the practice map had a 10% black fill, so changing the color showed nothing],
)
