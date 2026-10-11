// Changelog (illustrated): next release. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "Next release",
  [Next release],
  [Fixes going into the next version.],
  [],
)

#fixes(
  "New",
  [Layers styled in QGIS by category, graduated range or rule (stands by species or age) are drawn feature by feature in the same colors as QGIS],
)

#fixes(
  "Fixed",
  [Overlay GeoTIFFs made by the app are now written with GDAL, the same library QGIS uses, so QGIS opens them without warnings],
  [First sync after reinstalling overwrote files present on both sides with older cloud copies; the newer side is now chosen, with a warning],
  [Sync uploaded to the top of Drive when the file's folder could not be found],
  [Attribute table copy covered only the first page; rows per page can be chosen and sorting covers all rows],
  [Attribute table filter indicator, and full-width digits in the edit panel],
  [Per-point records of GPS-surveyed lines and polygons were dropped],
)

#fixes(
  "Lighter",
  [Drive downloads only changed files],
  [Auto-sync reuses its connection],
  [TruPulse measurements no longer rebuild the whole screen],
)
