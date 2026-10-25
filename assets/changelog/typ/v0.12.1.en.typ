// Changelog (illustrated): v0.12.1. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.12.1 — 2026/10/23",
  [QGIS styling, table joins, point guidance & measure tool],
  [Supports QGIS categorized, graduated, and rule-based styling, table joins (such as stand-register CSVs), and attribute form settings. Also adds point guidance, shared room pins, and a measure tool.],
  [],
)

#fixes(
  "New Features",
  [Read table joins configured in QGIS (such as stand-register CSVs) and display joined fields in the attribute table, styling, labels, search, and export],
  [Render layers styled in QGIS by category, graduated range, or rule (e.g. compartments colored by species or age) in matching per-feature colors],
  [Add custom XYZ tiles and WMS as background maps by URL (forest planning maps, CS relief maps, etc.), including those defined in .qgs files],
  [Point guidance from the info panel, map long-press, or member list, showing distance, bearing, elevation difference, heading arrow, and arrival notification],
  [Shared room pins (meeting point, hazard tree, work site, note) placed via long-press and queued offline until reconnected],
  [Measure tool (distance and area), length/area/perimeter display in the info panel, and cross-layer attribute search in the layer panel],
  [Support QGIS attribute form widgets and constraints (value maps, dates, aliases, default values, required fields, tabs, and groups)],
  [Record per-vertex GNSS metadata (fix type, satellites, accuracy, averaging) in GPS surveys, with configurable quality thresholds (Settings → GPS & Positioning)],
  [Configurable GPS track recording interval, minimum distance, accuracy filter, and speed-jump filter (Settings → GPS & Positioning)],
  [Batch-convert read-only Shapefile, GeoJSON, KML, and other files in a folder to GeoPackage (long-press folder → "Convert files inside to gpkg")],
  [Support return-pass backsight correction in TruPulse traverses, averaging each leg and stepping the station back automatically],
)

#fixes(
  "Bug Fixes",
  [Removed JPEG2000 (.jp2) from the supported format list (decoder not bundled)],
  [Fixed magnetic vs. true-north offset (~8°) in device compass heading and TruPulse azimuths using WMM2025 magnetic declination],
  [Write app-generated overlay GeoTIFFs via GDAL so QGIS opens them without tag-order warnings],
  [Fixed initial sync after reinstall overwriting newer local files with older cloud copies; now selects the newer side with a confirmation notice],
  [Fixed sync uploading files to the Drive root when the target folder could not be found],
  [Fixed "Copy Table" copying only the first page; added rows-per-page selector and full-table sorting],
  [Fixed attribute table filter status reset on reload, NULL numeric cells showing as 0, date/time formatting issues, and full-width digit input in the edit panel],
  [Fixed per-vertex GNSS survey metadata being discarded on lines and polygons],
  [Fixed KMZ files whose doc.kml contains only NetworkLink entries failing to open],
  [Fixed failed file downloads during Drive pull causing the next sync to overwrite newer cloud files with older local copies],
  [Fixed switching layers while drawing causing autosave to overwrite another feature],
  [Fixed attribute table Replace counting unchanged rows (such as case-only differences)],
  [Fixed layers reverted to Single Symbol in QGIS remaining categorized after reload],
  [Fixed deleting a feature immediately after editing attributes preventing subsequent attribute edits in the same GeoPackage from saving],
  [Fixed Web page reload signing out of Google Drive (session is now retained for ~1 hour in the same tab)],
  [Fixed switching dates rapidly in GPS track extraction showing or saving the previous date's points],
  [Fixed opening a table without a primary key modifying the file by adding an fid column; now uses rowid without altering the schema],
  [Fixed opening a GeoPackage without a CRS definition writing online lookup results into the file; JGD2000 and Tokyo datum are now built in],
  [Improved error message when adding a column whose name differs from an existing column only in letter case],
  [Fixed attribute table Replace allowing non-numeric text in numeric columns],
  [Added automatic backoff retry and background flush for pending attribute edits that temporarily failed to save],
  [Added UTF-8 BOM to exported attribute CSVs so Japanese text opens cleanly in Excel],
  [Unified track extraction length and GNSS spread calculations on the WGS84 ellipsoid (matching QGIS)],
  [Fixed reading and writing GeoPackages with non-default geometry column names (GeoPandas geometry, ArcGIS Pro Shape) and stopped rewriting rtree extents on read-only close],
  [Fixed columns named id, geometry, latitude, longitude, vertex\_count, timestamp, and \_\_id colliding with internal fields; primary key (fid) is now shown read-only],
  [Fixed manual Upload/Download showing "Synced" when fetching the Drive file list failed],
  [Fixed QGIS settings (.qgs Views, legends, basemaps) not applying immediately after cloning from Drive or receiving sync updates],
  [Fixed attribute table pager overflow in portrait, "Unnamed feature" display on layers without a name column, and target layer mismatch when opening the attribute table],
  [Fixed features added on Android to QGIS-made GeoPackages missing from the rtree spatial index after Drive upload],
  [Replaced raw exception strings when signing in to Drive offline with a clear offline message],
  [Distinguished offline network errors (with Retry) from permission and not-found errors when checking Drive folders],
  [Automatically rebuild GeoPackage rtree triggers and spatial indexes on files uploaded by earlier versions that lacked triggers],
  [Display boolean columns as Yes/No instead of raw true/1 in the feature info panel],
  [Fixed race condition where QGIS raster overlays sometimes failed to appear right after opening or cloning],
  [Fixed toggling vector layer visibility waiting for raster overlay rendering to finish],
  [Aligned map layer drawing order with the layer panel and QGIS (.qgs layer tree order, top item drawn in front)],
  [Retained raw foresight and backsight values (survey\_fs\_\*, survey\_bs\_\*) and averaged inclination in TruPulse backsight correction],
  [Fixed UI freeze when returning to the app after backgrounding during GPS track recording],
)

#fixes(
  "Performance",
  [Drive pull now downloads only modified files instead of re-downloading all files],
  [Auto-sync reuses its Drive connection and skips reloading layers when nothing changed],
  [TruPulse measurements redraw only measurement lines and status instead of rebuilding the entire map screen],
  [Stopped rebuilding all features and re-baking 3D textures every 20 seconds during GPS track recording; only new track segments are appended],
)
