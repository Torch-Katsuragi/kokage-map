// Changelog (illustrated): next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "Next release",
  [No View row when there is only the default View],
  [Change the look with "Style" in the layer's ⋮ menu. After "Add view", the default View and the added one are listed together. The default View always looks like the layer style.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, header: "Layers", ((0, "layer", [Areas], "ok", rgb("#2e7d32")),)), caption[Default View only]),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt, layer-panel(w: 96pt, header: "Layers", ((0, "layer", [Areas], "ok", rgb("#2e7d32")), (1, "layer", [Default], "ok", rgb("#2e7d32")), (1, "layer", [Large], "hi", rgb("#c0504d")))), caption[After adding a View]),
  ),
)

#fixes(
  "Fixes",
  [Color and opacity changed for the default View were lost on reopening],
  [Areas in the practice map had a 10% black fill, so changing the color showed nothing],
)
