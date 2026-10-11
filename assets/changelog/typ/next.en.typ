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
  "Fixed",
  [Overlay GeoTIFFs made by the app are now written with GDAL, the same library QGIS uses, so QGIS opens them without warnings],
)
