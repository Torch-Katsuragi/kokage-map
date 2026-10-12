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
  [Save the map as a one-page PDF (≡ menu): A4/A3, title, date, scale, north arrow, legend and credits, drawn from above],
  [Join a stand-register CSV to a forest-plan layer (QGIS join); joined fields in the attribute table, labels, styling, search and export; round-trips with .qgs],
  [Layers styled in QGIS by category, graduated range or rule (stands by species or age) are drawn feature by feature in the same colors as QGIS],
  [Add XYZ tiles and WMS not in the list as background maps by URL (forest planning maps, CS relief maps…); those in a .qgs are read back too],
  [Guidance to a point from the info panel, a map long-press or the member list: distance, bearing, elevation difference, arrow and line, with a notice on arrival],
  [Shared pins in a room (meeting point, hazard tree, work site, note), dropped by long-press and sent on reconnect when offline],
  [Measure tool (distance and area), length/area/perimeter in the info panel, and attribute search from the layer list that jumps to the feature],
  [Attributes are entered with the QGIS attribute form settings (value maps, dates, aliases, defaults, required fields and more)],
  [GPS survey records fix type, satellites, accuracy and averaging per point, and can reject fixes below thresholds (Settings → GPS & Positioning)],
  [Set the GPS track interval, minimum distance, dropping of inaccurate points and jump rejection (Settings → GPS & Positioning)],
)

#fixes(
  "Fixed",
  [JPEG2000 is removed from the supported formats (it could not be read)],
  [Compass heading and TruPulse azimuths were magnetic, about 8° off; now corrected to true north (WMM2025)],
  [Overlay GeoTIFFs made by the app are now written with GDAL, the same library QGIS uses, so QGIS opens them without warnings],
  [First sync after reinstalling overwrote files present on both sides with older cloud copies; the newer side is now chosen, with a warning],
  [Sync uploaded to the top of Drive when the file's folder could not be found],
  [Attribute table copy covered only the first page; rows per page can be chosen and sorting covers all rows],
  [Attribute table filter indicator, empty numeric cells shown as 0 and date values shown as (NULL) or date only, and full-width digits in the edit panel],
  [Per-point records of GPS-surveyed lines and polygons were dropped],
  [KMZ whose doc.kml only links (NetworkLink) to other KML could not be opened; each linked KML inside becomes a layer],
  [A file that failed to download from Drive was later overwritten in the cloud by the device's older copy],
  [Selecting another layer while drawing made the autosave overwrite a different feature],
  [Replace in the attribute table counted values it did not change (such as a different letter case)],
  [A layer set back to Single symbol in QGIS stayed categorized after reading back],
  [Deleting a feature right after editing it kept later attribute edits in that gpkg from being saved],
  [Web: reloading the page signed you out of Drive; within about an hour it now stays signed in in the same tab],
  [Track extraction could show and save the previous date's points after switching dates quickly],
  [Opening a table without a primary key added an fid column; it is now read and edited by rowid, as in QGIS, without changes],
  [Opening a gpkg whose CRS had no definition wrote a definition looked up online into it; JGD2000 and the Tokyo datum are now built in and nothing is written],
  [Adding a column differing from an existing one only in letter case failed with an unclear error; you are now told which column exists],
  [Replace in the attribute table could write text into numeric columns; such rows are now skipped and counted],
  [Attribute changes that failed to save were not retried until the next edit; they are now retried with backoff and written when going to the background],
  [Attribute table CSV showed garbled Japanese in Excel; a UTF-8 BOM is now added],
  [Track extraction length and GNSS spread are now measured on the ellipsoid (same as QGIS)],
  [GeoPackages whose geometry column is not geom (GeoPandas geometry, ArcGIS Pro Shape) showed no features and could not be added to; a gpkg with an rtree was rewritten on close even when only viewed],
  [A column named id showed the feature number (fid) and could not be edited, a column named geometry did not appear, columns named latitude, longitude, vertex\_count and timestamp were hidden behind computed values in the info panel, and tables with a column named \_\_id gave no search results; they now show and save their own values, and the primary key column is shown read-only],
  [Upload or Download in sync showed "Synced" when the Drive list could not be fetched (such as while Wi-Fi was switching); it now shows an error and keeps the sync records, retrying once after a brief failure],
  [QGIS settings (Views, legends, background maps) of a folder cloned from Drive were not applied until the map was reopened; they are now read back when the clone finishes (and when a .qgs arrives by sync)],
  [The attribute table pager overflowed on a phone in portrait, the info panel showed "Unnamed feature" for layers without a name column, and the attribute table would not open with no layer selected; it now opens the layer of the feature selected on the map],
  [Features added on Android to a QGIS-made gpkg were missing from the rtree of the file uploaded to Drive, so QGIS extent queries did not find them; triggers are now restored and the rtree rebuilt before upload and when going to the background],
  [Files uploaded by earlier versions could have none of the rtree triggers left, so QGIS extent queries missed features; after the app writes to them, standard triggers are recreated and the rtree rebuilt before they leave the device]
)

#fixes(
  "Lighter",
  [Drive downloads only changed files],
  [Auto-sync reuses its connection],
  [TruPulse measurements no longer rebuild the whole screen],
)
