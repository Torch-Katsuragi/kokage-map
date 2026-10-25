// Changelog (illustrated): v0.12.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.12.0 — 2026/10/11",
  [In-app folder browser & direct loading of external formats],
  ["Choose a folder to open" on Home browses folders inside your workspace using the same UI as the layer panel instead of the OS file picker. External folders remain accessible from the top-right menu.],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 0pt, clip: true, {
    box(width: 100%, fill: rgb("#424242"), inset: (x: 6pt, y: 5pt), align(left, text(size: 8pt, fill: white, weight: "bold")[KokageMap]))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#ffc107"), radius: 1pt), text(size: 7pt)[共有])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#7eb0d5"), radius: 1pt), text(size: 7pt)[龍神村])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#b0bec5"), radius: 1pt), text(size: 7pt, fill: gray)[マイ地図.gpkg])))
    box(width: 100%, inset: 6pt, box(width: 100%, fill: rgb("#2e6b4f"), radius: 8pt, inset: 4pt, align(center, text(size: 7pt, fill: white)[Open "共有"])))
  }),
)

#fixes(
  "Direct Loading of Non-GeoPackage Formats",
  [Load Shapefile, GeoJSON, KML, CSV, GPX, and more directly from a folder as read-only layers via GDAL],
  [Display GeoTIFF and other rasters created in QGIS directly as map overlays],
  [Prompt to convert read-only layers to GeoPackage on edit, preserving CRS and replacing the source files after verifying feature counts],
  [Preserve Z (elevation) values when editing 3D GeoPackages; moved or added vertices sample elevation from the 3D terrain tiles],
  [Support copying read-only shared layers as GeoPackage into your own folder for editing],
  [Reference original files in QGIS projects (.qgs) and read back updated styles and Views],
)

#fixes(
  "File Import & Export",
  [Added "Add files" to folder long-press and + menus (Android and Web)],
  [Automatically remove GeoPackage files left empty after moving layers],
  [Sync Shapefile sets, KML, CSV, and other formats (including uppercase extensions) in Drive-linked folders],
  [GDAL-powered export preserving all attributes and the source CRS by default],
)

#fixes(
  "Performance",
  [Reduced idle battery drain while the map screen is open],
  [Fixed memory growth during continuous map panning],
  [Faster loading for polygon-heavy datasets with immediate basemap display],
)

#fixes(
  "UI & Usability",
  [Redesigned layer panel with compact rows, single visibility toggle, long-press context menu, and left-swipe move],
  [Display color-coded geometry type icons and feature counts on layer rows],
  [Added clickable breadcrumb path navigation at the top of the layer panel],
)

#fixes(
  "Security",
  [Display folder name and owner for confirmation before importing maps received via QR or link],
  [Location sharing: automatically leave ended or expired rooms and stop transmitting location],
  [Location sharing: prevent removed members from rejoining with the same room code],
  [Restrict extracted map paths to app-managed directories (path traversal protection)],
)

#fixes(
  "Bug Fixes",
  [Fixed unfilled polygons disappearing between zoom levels 14 and 15 in large datasets],
)
