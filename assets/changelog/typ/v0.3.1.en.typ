// Changelog (illustrated): v0.3.1. tool/changelog/build.py writes it out as SVG chunks
// Internal cleanup only, so no picture
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.3.1 — 2026/03/09",
  [Layer panel cleanup],
  [The massive LayerDrawer class is split into manageable pieces (LayerDrawerService extraction, ConsumerWidget migration) for better maintainability.],
  none,
)
