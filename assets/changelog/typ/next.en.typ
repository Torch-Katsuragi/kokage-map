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
  [Tree tally: record species, DBH and height in circular or polygon plots, then summarize trees/ha, basal area and mean height and save as CSV (height also from TruPulse HT)],
  [Tree tally summaries show sugi and hinoki stem volume (m³/ha) for Kinki, Chugoku, Ishikawa and Fukui, from the Forestry Agency's West Japan volume table equations],
  [Save the map as a one-page PDF (≡ menu): A4/A3, title, date, scale, north arrow, legend and credits, drawn from above],
  [Attach photos to features: the camera app saves them in photos/ next to the data and the photo column holds the path (shown in QGIS forms)],
  [Join a stand-register CSV to a forest-plan layer (QGIS join); joined fields in the attribute table, labels, styling, search and export; round-trips with .qgs],
  [Layers styled in QGIS by category, graduated range or rule (stands by species or age) are drawn feature by feature in the same colors as QGIS],
  [Add XYZ tiles and WMS not in the list as background maps by URL (forest planning maps, CS relief maps…); those in a .qgs are read back too],
  [Guidance to a point from the info panel, a map long-press or the member list: distance, bearing, elevation difference, arrow and line, with a notice on arrival],
  [Shared pins in a room (meeting point, hazard tree, work site, note), dropped by long-press and sent on reconnect when offline],
  [Measure tool (distance and area), length/area/perimeter in the info panel, and attribute search from the layer list that jumps to the feature],
  [Attributes are entered with the QGIS attribute form settings (value maps, dates, aliases, defaults, required fields and more)],
  [GPS survey records fix type, satellites, accuracy and averaging per point, and can reject fixes below thresholds (Settings → GPS & Positioning)],
  [GPS track interval, minimum distance, accuracy limit and jump rejection in Settings; export a track as GPX with time and elevation (opens in QGIS)],
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
)

#fixes(
  "Lighter",
  [Drive downloads only changed files],
  [Auto-sync reuses its connection],
  [TruPulse measurements no longer rebuild the whole screen],
)
