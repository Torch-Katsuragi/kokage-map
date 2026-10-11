# Changelog

## Next release

### Open files other than gpkg as they are

- Shapefiles (.shp with their companion files), GeoJSON, KML/KMZ, CSV (with longitude/latitude columns), GPX, FlatGeobuf, GML, DXF and MapInfo (.tab, .mif) placed in a folder now show up as layers without importing. They are read with GDAL, the same library QGIS uses. They are read-only; visibility, style, labels, Views, the attribute table and export all work. A .shp without a .cpg is read as Shift_JIS (CP932), as the Japanese QGIS does. KML folders become separate layers, and files mixing points, lines and polygons get one layer per kind
- Trying to draw or edit attributes offers "Convert to gpkg to edit". Converting writes a gpkg with the same name in the same folder, checks that the feature counts match, and then deletes the original files. The coordinate system is kept (a plane-rectangular shapefile becomes a plane-rectangular gpkg), and style, View and visibility settings carry over
- In read-only shared folders, "Copy as gpkg to my folder" is offered instead of converting
- QGIS projects (.qgs) reference the original files, and Views and styles edited in QGIS are read back
- Rasters made in QGIS and similar tools (GeoTIFF, JPEG2000, PNG/JPEG with a world file, VRT) placed in a folder now appear on the map as overlays. Any coordinate system works (including Japan Plane Rectangular), nodata is transparent, and numeric rasters such as DEMs are shown in grayscale, and paletted rasters keep their colors. Their position comes from the file, so they cannot be repositioned in the app. They are written to .qgs as the original files, and layers hidden in QGIS are read back as hidden. Deleting one also deletes its companion files such as the world file

### Changed

- "Open another folder" on Home is now "Choose a folder to open". Instead of the device's file picker, you browse the folders inside your everyday map, styled like the layer panel. Places outside it are under "Another place on the device…" in the top-right menu
- The layer panel is redone: tighter rows, and only the visibility eye at the right end. Long-press a row (right-click on a PC) for its menu; swipe it left to move it elsewhere
- Each layer row starts with a sample of its map color and shows its feature count. GeoPackages are small headings whose eye hides everything inside
- A path (KokageMap › 共有) above the list takes you back to any level. The top shows the folder name instead of "Home"
- Folders have a new "Add files" entry (long-press menu and the + button) that copies the picked files into the folder as they are (Android and web). For a Shapefile, pick its .dbf, .shx and other companion files too. Files dropped onto the list on the web are also put into the folder as they are, instead of being imported into a GeoPackage
- When moving a layer to another GeoPackage leaves the original GeoPackage empty, the empty file is now deleted (deleting the last layer still keeps the file)
- Layer export now writes with GDAL, the same library QGIS uses. GeoJSON, KML and CSV exports carried only the name and description; they now carry every attribute. GeoPackage, GPX, FlatGeobuf and DXF were added. The CRS stays the layer's by default (pick one to transform); GeoJSON, KML and GPX are always WGS 84 as the formats require. Shapefiles are written in UTF-8 with a .cpg, as QGIS does. The "Export as Point Cloud" option, which did nothing, is gone
- Drive-linked folders now also sync Shapefiles (with their companion files), GeoJSON, KML/KMZ, CSV, GPX, FlatGeobuf, GML, DXF and MapInfo. Files with upper-case extensions (such as IMG.JPG) were skipped; they now sync too
- Projects saved in QGIS now bring back whether each GeoTIFF is shown or hidden. If the project uses GSI or OpenStreetMap tiles, they are added to your background maps (once). Rasters that can't be read (such as WMS) are listed with the reason and left in the QGIS project

### Lighter

- Less battery drain while the map sits open (it no longer redraws the whole map on every compass and GPS update)
- Memory no longer keeps growing while you pan
- Data with many areas opens faster, and the basemap shows while it loads

### Safer

- When you receive a map by QR or link, the app now shows the folder name and its owner and asks before importing
- Location sharing: you leave rooms automatically, and stop sending your position, once the host ends the room or it expires
- Location sharing: members removed by the host can no longer rejoin with the same code
- File and folder names in a received map can no longer write outside the app's own folders
- App settings are no longer included in device backups (they won't carry over to a new phone; your map data in Documents/KokageMap is unaffected)

### Fixed

- In data with many areas (such as forest compartments), areas without a fill disappeared at some in-between zoom levels (between 14 and 15). They now stay visible

## v0.11.1 — 2026/10/05

### Fixed

- Signing in with a Google account for the first time no longer shows "Sign-in failed" while the Drive permission screen is still open. If you back out of that screen, the app tells you how to get through it

### Also changed

- The user guide and the tutorial's "Your own data" chapter now describe "Open my map" and receiving maps by QR
- Jumping to your location with the layer panel open lands where the panel doesn't cover it
- Removed an unused old map engine; the app no longer downloads map font data at startup

## v0.11.0 — 2026/10/04

### Home

- "Open my map" on Home opens your everyday map (Documents/KokageMap) directly. No folder needs to be chosen
- Your everyday map comes with "マイ地図" (points, lines, areas) to write to. Maps received by QR go into "共有"
- Other folders still open with "Open another folder". "Continue" appears when you last opened one of those
- Folders the app uses itself (Global, practice) moved into a hidden folder (.kokage) inside your everyday map, automatically on first launch
- Home has a new look

### Receive maps by QR

- Scan a "Share by QR" code with a phone camera: Kokage Map opens, adds the map and opens it at its location
- Phones and PCs without Kokage Map get install instructions
- "Scan a QR" on Home works too, including older QR codes (Drive URLs)

### Tutorial

- The tutorial now runs on the web too. The practice map is made inside the browser (the photo chapter is not shown on the web)
- Each chapter starts with the map in 2D, north up (after switching to 3D, the next chapter used to start tilted)

## v0.10.0 — 2026/10/02

### Views

- A layer with a single View no longer shows a View row in the layer list. Change its look with "Style" in the layer's ⋮ menu
- After "Add view", a View named after the layer and the added View are listed together. The one named after the layer uses the layer style (it used to be called "Default"; QGIS shows the layer name too)
- "Add view" puts the new View at the top (the View on top wins, so one added at the bottom drew nothing)

### Photos

- Photos on the map now use the same camera mark as the layer list. A selected photo turns the selection color, and the mark is easier to tap
- The photo info panel shows the photo faintly in the background, with a zoom button at the top right

### Tutorial

- "Changing the look" now adds a View, gives it another color and switches between looks with its mark
- After each color change the guide has you close the layer list to see the map. Each chapter starts with the practice data clear of the guide card
- The glow around the red frame that marks where to tap next is larger and easier to spot

### Fixes

- Newly drawn lines and areas used the default color instead of the layer's until the project was reopened
- Changing a color and then quickly toggling visibility could leave patches in the old color
- Area fills had gaps on ridges where the map showed through white. Fills are now painted into the terrain image; only the outline follows the terrain
- Color and opacity changed through a View's "Style" were sometimes lost when the project was reopened
- In the tutorial's practice map, areas now have a visible fill (it was 10% black, so changing the color showed nothing)

## v0.9.0 — 2026/10/02

### Tutorial

- Try the basics on a practice map. A red frame shows where to tap next, and tapping moves on. Hands-on steps such as moving the map wait for "Next". Any step can be skipped
- Eight chapters: reading the map (up to laying red relief over the basemap), how data is organized, changing the look, recording (points, names, lines, areas), fixing and deleting, importing photos, recording with GPS, your own data. Start from any chapter
- Each chapter starts from the same screen layout. If you wander into another screen, the guide points to the back button
- Offered once on first use. Start it again from "Tutorial" on Home or from Settings

### Importing photos

- Photos are now chosen inside the app. Thumbnails are grouped by date like Google Photos, and you can switch albums
- Tap a photo to import it. Long-press to select several
- Photos without a location are dimmed and marked. "With location" filters them

### Editing features

- "Edit" in the info panel header now edits the feature on the map without leaving the panel. The map locks to top-down and the left toolbar switches to edit tools
- Move, add and delete vertices; move, rotate and scale the whole feature; extend, simplify and trim lines (tools differ for points, lines and areas). Undo and redo work too
- Switching to attributes raises the panel to the top; it comes back down when you finish
- Per-vertex records of GPS-surveyed lines stay aligned when you add or delete vertices
- The old edit screen (simplify and trim only) is gone
- Edit attributes in the panel as well. Nothing is written until you tap Save
- The info panel now shows the selected feature's shape faintly in the background
- Map buttons are hidden while editing. The ← at the top left and the device back button stop editing (asking first if there are changes to discard)

### Also changed

- On a phone in portrait, the layer list starts closed when the map opens

### Fixes

- Layers whose names contain spaces or quotes could not be written to
- In the attribute table, cells other than the first in a row sometimes could not be edited
- Opening the attribute table after selecting on the map did not highlight that row
- Lines and areas got thin and faint when zoomed out and were easy to lose. They now keep the same width at every scale
- The color of a selected area had gaps on ridges where the map showed through
- A selected line was drawn under its unselected self
- Point labels no longer put a black dot over the point; the label sits just above the marker
- The color chooser in the style screen did not open (broken since v0.8.0)
- The area shown while drawing an area was far off
- The panel overflowed when the keyboard was up while entering attributes

## v0.8.0 — 2026/09/30

### Project format

- Folder settings (visibility, styles, Views, order, overlay alignment) moved from `.kmeta.json` into the QGIS project file (`<folder name>.qgs`). They are migrated automatically on opening; the old file is kept as `.kmeta.json.migrated`
- In folders shared through Drive, the `.qgs` is named after the Drive folder, so every device uses the same file even when local folder names differ
- Settings now reach other devices through Drive sync (they used to stay on each device). Link details such as read-only stay per device
- When two devices change settings separately, Drive sync keeps both changes. If both changed the same item, each device keeps its own value
- Changing settings in quick succession could lose the earlier change. Fixed
- Renaming a GeoPackage inside a subfolder failed with "file does not exist". Fixed
- In Drive-linked folders, renaming a folder or photo was undone by auto-sync. Fixed; the name changes on Drive too
- Colors and widths changed in QGIS sometimes did not come back to the app (layers without their own Views). Fixed
- Hiding a GeoPackage or folder group in QGIS now hides that group in the app too (it used to hide the layer instead, which changed the QGIS tree after a round trip)
- Opening any folder's `.qgs` in QGIS now lets you edit the layers of its subfolders too (they used to be read-only). Colors and visibility changed in QGIS go back to the settings of the folder that holds the layer
- App-only settings (such as photo visibility) are no longer lost when a `.qgs` is re-saved in QGIS 4
- GeoPackages and layers with the same name in different folders (e.g. a copied folder) no longer share one style on the map
- Web: a GeoPackage could be overwritten with empty content right after opening a project (overlapping loads saw an empty database and saved it back). Fixed
- A `.qgs` saved in QGIS that arrives through Drive sync is read back right away (before, it waited until the project was reopened, and saving in the app first discarded the QGIS changes)
- Layers styled in QGIS by category or rule now show "Style set in QGIS" on the style screen, and their colors and widths are not editable in the app (changes would not reach QGIS). The app draws them in a representative color

### Changelog

- The changelog is now illustrated. Each release folds, and only the newest one starts open

## v0.7.3 — 2026/09/27

### Drive sync

- When two devices edit the same GeoPackage, changes are now merged row by row. Edits to different rows are both kept. If both sides changed the same column of the same row, this device's value wins, and the notification's "Revert to cloud value" button restores the other side
- If only one side added columns, the schemas are aligned first and then merged
- Auto-sync uploads only files that changed, and does nothing when nothing changed
- Editing a QGIS-made GeoPackage on Android no longer leaves new features out of QGIS's spatial index
- A GeoPackage downloaded from Drive is no longer uploaded again just because it was opened
- Opening the same folder via another path (`/sdcard/…` vs `/storage/emulated/0/…`) no longer re-downloads every file

### Map and 3D

- Base maps are now layers. In Maps & Tiles you can reorder them, show or hide them, and set opacity and blend mode (multiply, screen, …). Existing stacks keep their look, and the settings screen shows a one-tile preview
- Contours are now one of the base maps. Intervals match the GSI standard map (2 m at zoom 18, 10 m at 15–17, 100 m at 12–14, 200 m at 9–11), and generated tiles stay in the cache so they work offline
- The compass toggles 2D and 3D. 2D is top-down (one finger pans, two fingers zoom and rotate); in 3D one finger rotates and tilts. Double-tap resets north; long-press toggles the perspective view in 3D
- On opening, the map starts at the extent of all features in the project
- 3D loads faster: a coarse image appears first and is refined when idle. Waits drop by more than half on slow connections
- On high-density screens the base map is drawn at twice the resolution when zoomed in
- Bulk map download saves every stacked layer (contours included); only OpenStreetMap is skipped
- Attributions moved to Maps & Tiles → Data sources (still shown on the map while OpenStreetMap is in use)

### Usability

- The layer list now starts with a "System" folder, and the global folder has moved inside it. It holds device-side data that doesn't belong to the project. The folder stays where it was on disk, and its shown/hidden state carries over
- The attribute form now saves when you leave a field or move to another record (previously only Enter saved, and input could be lost). Numeric columns open the number keyboard

### Fixes

- Android: slope coloring under Terrain look had no effect. Fixed
- 3D terrain could show rectangular plateaus over rivers and lakes. Fixed
- The heading indicator on the location marker is a fan again, as in 2D
- The Drive clone dialog and the map toolbar no longer run off screen while the keyboard is up
- In portrait, a point layer's attribute table no longer pushes its top-row buttons off screen
- With the Left-handed layout, the web zoom buttons no longer overlap the record button
- Web: the first "Choose folder" no longer fails

## v0.7.2 — 2026/09/13

### Fixes

- 3D terrain no longer borrows edge heights from coarser, interpolated neighbour tiles, which produced step-like seams
- Features removed with the eraser could stay on the map. Fixed
- GPS tracks start a new line after a gap of 10 minutes or more, so reopening the app somewhere else no longer draws a straight line (later segments are named with `#2`, `#3`, …)
- Remaining untranslated strings (notifications, layer list, drawing buttons, import/export, settings, TruPulse screens) now follow the app language
- Web: opening the map URL (`#/map`) without choosing a folder let you create a GeoPackage that was never saved anywhere. It now starts from the folder picker, and the layer list hides its add button until a folder is chosen
- Web: rotating the map with a right-drag no longer pops up the browser context menu

### Usability

- When zoomed out (zoom 13 and below), features are baked into the terrain image instead of being lifted as geometry, so 10,000 polygons stay smooth without clustering or dropped outlines. Zooming in switches back to draped geometry
- New "Terrain look" settings: color the terrain by slope or elevation (pick your own three colors; blend it over the base map, or set 100% for terrain only) and draw contour lines from the elevation tiles. Both come from the terrain mesh itself, so they stay sharp when tilted
- Screen layout presets in Settings (Auto / Portrait / Landscape / Left-handed). The info card slides up from the bottom like the attribute table and the two never show together; Landscape puts the card on the right, Left-handed moves the toolbar and buttons to the right
- The app can be driven from a CLI or URL: open a project, look at a place, reload from disk (`/map?project=…&lat=…&lon=…&zoom=…&reload=1`, `tool/kokage.py`). The map menu also has "Reload project from disk"
- Label composition moved to the style screen (layer / View) and works for line and polygon layers too. Columns are ordered by how often they hold a value, and expressions can be typed directly
- A View's style now holds only the items that differ from the layer, so layer changes reach the View for untouched items. "Follow the layer" resets it
- The View row is shown even when a layer has only one View
- The photo card also has a "copy Google Maps link" button

### QGIS

- Labels are now stored as QGIS expressions (`"field"`, `'text'`, `concat(...)`, …), written to `.qgs` as expressions and read back from QGIS. Existing settings are converted automatically

## v0.7.1 — 2026/09/12

### Fixes

- Features of a hidden View could stay on the map. Fixed
- The current-location dot is now translucent so points and short lines beneath it stay visible
- Elevation tiles load faster: the three GSI sources are fetched together and, when zooming in, the nearest level fills first. AWS tiles are only fetched where Japan has no coverage

### Usability

- "Zoom to layer" was added to the layer ⋮ menu (double-tapping the row also works). It is the way in when your data is far from your location
- Tapping "Selected folder" on the home screen reopens the map without picking the folder again
- The Drive folder dialog is now translated

### QGIS

- GeoTIFF overlays are written to the QGIS project (`.qgs`) as raster layers, so QGIS opens them as they are. Non-GeoTIFF images are still left out
- Verified the export/read-back round trip in QGIS 4.2 itself
- GeoPackages created by the app no longer make QGIS warn about an unknown version (applies to newly created files)

## v0.7.0 — 2026/09/11

### ⛰ The map is now 3D

- It opens top-down as before. Drag with one finger to rotate and tilt, use two fingers to pan and zoom. Tap the compass at the top right to return to north-up, top-down
- Compartments, routes, survey points, photos, GPS tracks, your location, room members and overlay images (GeoTIFF) are draped on the terrain. Tap-to-select, info cards and TruPulse measurements work while tilted
- Drawing (Pen, overlay transform) locks the view top-down automatically and restores the tilt when you finish
- Elevation prefers the GSI DEM (1 m → 5 m → 10 m) and falls back to AWS Terrain Tiles. Areas you have viewed once work offline
- Terrain shading follows slope rather than a light direction: steeper is darker, ridges and valley floors stay bright
- Long-press the compass for the "view mode": a perspective view where the distance fades into haze. Long-press again to return
- Rendering runs on the GPU, so rotating and tilting stay smooth
- Like tool changes, switching the view mode or resetting to north-up briefly shows a label in the middle of the map

### Web

- The web app opens in the same 3D map, drawn on the GPU through WebGL2. Controls match Android; with a mouse, left-drag pans, right-drag (or Ctrl + left) rotates and tilts, and the wheel zooms

### Fixes

- On a fresh install the app could quit right after you granted location access

## v0.6.2 — 2026/09/07

### 🏷 Labels on the map

- From the attribute table's label button (🏷), pick columns, reorder the cards and insert fixed text to
  compose a label. Works for points, lines and polygons (polygons at the centroid, lines along the line).
- Font size, colour and halo are under Settings → Layer style → Label.

### ✅ Multi-select and bulk actions

- With the select tool, enable the bottom-left button to select across layers by tap or lasso.
- The panel shows counts, the centroid of points, total line length and total polygon area, and deletes them together.
- The eraser no longer deletes on touch: it collects candidates and you confirm with "Delete N". It only affects the selected layer, and its hit area is a third of before.

### 🧭 Usability

- The layer list button moved to the right edge.
- Switching tools briefly shows the tool name in the centre of the map.
- The always-on GPS bar is gone. The location marker is selectable with the select tool like any feature and shows its card in the same place (more room for the map).
- Every info card on the map now has a close button.
- The point "Open in Google Maps" button now copies the link; hold to open.

### 🐛 Fixes

- The Google account chooser no longer appears on every launch. A previous authorization is restored silently;
  the chooser only shows when you sign in.
- Deleted features sometimes stayed on the map.
- Basemap tiles stayed blurry forever in places where a fetch had failed once, even after connectivity returned.
  Already-blurry tiles: Settings → Basemap → Clear cache.
- Cached basemap tiles sometimes did not appear until restart when far from home.
- With per-layer or per-view styles set, release builds could stop drawing every feature on the map.

## v0.6.1 — 2026/09/07

Everything since v0.6.0 (April 16), in one place.

### 🌳 The app is now "Kokage Map"

- "RootMap GIS" and "K-Maps" were used in different places; it is now Kokage Map everywhere, including in-app text.
- ⚠ The Drive folder name `RootMap GIS Projects` is unchanged (renaming it would orphan linked folders).

### 🌐 Web version (Chrome / Edge)

- Open a project folder in the browser, view and edit GeoPackages, use Google Drive (clone, upload, download) and location-sharing parties. The last folder is remembered.
- ⚠ Firefox / Safari cannot open folders and only show the basemap. Folder renaming and the global-folder setting are not available on web. Browser location is coarser than a phone's GPS, so use the Android app in the field.
- Windows / macOS / Linux builds are discontinued in favour of the web version (distributed as a URL; installable as a PWA).

### 🔍 Views, and per-layer / per-view styles

- A layer can have several "views", each with its own condition (an SQL WHERE clause, the same syntax as QGIS filters). "Add view" in the layer menu.
- Colour and width can be set per layer or per view. ⚠ Layer-level styles used to be saved but never drawn; they now take effect.
- ⚠ Stacking order does not yet follow the folder structure.

### 🗺 QGIS interoperability

- Each folder gets a `<folder>.qgs` that is written automatically and follows visibility and style changes. Print layouts and symbol details set in QGIS are kept (categorized and rule-based styles are left alone).
- When you save the `.qgs` in QGIS, views, styles and visibility are read back the next time the project is opened. `.qgz` files can be read too.
- Subfolders with their own settings (e.g. Drive-linked) get their own `.qgs`, embedded into the parent project. A subfolder handed over on its own opens in QGIS.
- GeoPackages edited in Kokage Map stay usable in QGIS: spatial index, extent and feature-count records are fixed up on save.
- ⚠ Opening the result in QGIS has not been verified yet. Please report if it does not open.

### 👥 Location-sharing party

- Join via invite link or QR code (the link opens the web join screen).
- Tracks walked while a member was out of coverage arrive when they reconnect and are drawn as thin lines.
- The host can remove members.
- Drive-linked folders can also be handed over by QR code ("Add folder" → "Scan QR code"; no server involved).

### 📍 GPS and photos (Android)

- The global folder (GPS tracks etc.) moved to `Documents/KokageMap/Global`, so it survives uninstalling the app. Existing data is migrated on first launch (the old folder is kept as `k_maps_global.migrated` and can be deleted).
- When your location is off screen, an arrow on the edge points toward it; tap to jump there.
- Photos keep their location, direction and original file name when added (also on devices without "All files access"). You are notified if a photo could not keep its location. ⚠ Cloud-only photos still have no location.
- On Android 13+ the ongoing "recording GPS" / "sharing location" notification now appears (notification permission is requested). The "Nearby devices" prompt no longer shows on every launch.

### 🗾 Basemap and other fixes

- The default basemap is now GSI (standard map). The OpenStreetMap "Access blocked" tiles are fixed, but bulk download of OpenStreetMap is not allowed by its terms (stale tiles: Settings → Basemap → Clear cache).
- Fixed: the map sometimes not moving to your location on launch, stopping short of the target when jumping, and the party dialog overflowing the screen.
- The layer list and attribute table backgrounds are now opaque (they were hard to read over aerial photos).
- Internal: removed unused code, restructured the map screen and coordinate modules, tightened static analysis.

## v0.6.0 — 2026/04/16

### 📐 Spirit Level Tool

- Added a full-screen spirit level screen (accessible from the map AppBar)
- Integrated accelerometer, compass, and GPS into a unified level tool
  - Floating bubble within a large circle (sphere metaphor) moves via spherical projection (sin(θ))
  - Real-time angle display on the line connecting center point and floating point
  - N/E/S/W labels rotate around the circle, always pointing to true north
- Info panel displays comprehensive data
  - GPS coordinates (latitude/longitude), altitude, accuracy
  - Bearing, Pitch/Roll angles, compass accuracy indicator
  - Right triangle calculation with diagram (tap to switch reference side)
- Haptic feedback on level detection, color-coded status indicators
- Responsive layout for both portrait and landscape orientations

### 🌍 Support for Any Coordinate Reference System in GeoPackage

- GeoPackage files created with any EPSG code (e.g., in QGIS) can now be loaded and edited
  - Automatically detects CRS from WKT embedded in the GPKG
  - 3-stage fallback when WKT is missing: EpsgRegistry → epsg.io HTTP
  - epsg.io results are written back to the GPKG, serving as an effective offline cache
- Automatic WGS84 conversion on read, reverse conversion to source CRS on write
  - Verified with JGD2011 Plane Rectangular CS, UTM, Web Mercator, and more

### 🔧 Improved Compatibility with External GeoPackage Files

- SpatiaLite triggers (ST_IsEmpty, etc.) generated by QGIS/GeoPandas are detected and removed just before writes
  - Read-only access does not modify files, preventing unnecessary Google Drive sync events
  - Designed as an extensible pre-write cleanup mechanism
- Fixed GPBinary header srsId being hardcoded to 4326

### 📡 GPS Track Display Optimization

- Revamped GPS track recording and display with a hybrid approach
  - Pending points shown in real-time from memory cache; consolidated data rendered via GPKG layer tree
  - Auto-refresh gps_tracks layer on consolidation completion for immediate map updates
- Correctly flatten MultiLineString geometry readback to ensure track continuity

### 🗺️ New Basemap Options & Blending

- Added GSI Red Relief Image Map to basemap lineup (zoom levels 2–14)
- "Advanced Settings" mode enables blending multiple basemaps with sliders
  - Cumulative alpha correction ensures visual weight matches slider ratios
  - Example: overlay standard map + red relief to see both place names and terrain

### 🎨 Drawing Style Improvements

- Changed default polygon color from orange to black (both border and fill)
- Changed default polygon fill opacity from 30% to 10%
- Clustering radius now scales with point size (pointSize × 2)
- Cluster circle visual size enforces a minimum of 6px for point size

### 🔐 Google Account Switch / Sign-out

- Added Google Account management section to Settings (Drive Sync)
  - Switch Account: sign in with a different Google account
  - Sign Out: disconnect from Credential Manager
- Added "Switch Account" button to Drive connect dialog
- Fully localized in English and Japanese

### 🔄 Bulk Dependency Version Upgrades

- Updated major packages to latest versions (37 packages updated)
  - file_picker 10 → 11 (migrated to static method API)
  - google_sign_in 6 → 7 (singleton & event-based auth flow migration)
  - googleapis 14 → 16, extension_google_sign_in_as_googleapis_auth 2 → 3
  - geolocator 10 → 14, permission_handler 11 → 12
  - sensors_plus 6 → 7, trina_grid 1 → 2, nmea 2 → 3
  - desktop_drop 0.4 → 0.7, riverpod_annotation/generator 3 → 4
  - flutter_lints 5 → 6
- Updated Gradle wrapper from 8.11.1 → 8.13
- Removed unused flutter_secure_storage (resolved win32 version conflict)

### 🛠 Bug Fixes & Maintenance

- Completely removed maplibre_webview dependency, now using MapLibre Native only
  - Eliminated WebView-specific workarounds (JS bridge, CORS headers, font HTTP proxy)
  - Windows support paused until native Windows support is available in MapLibre
- Fixed ANR freeze when rapidly double-tapping layer tiles to jump on the map
  - Added debounce (150ms) and mutual exclusion to camera animations
  - Ongoing animations are instantly cancelled before starting new jumps
- Fixed mojibake (encoding corruption) in Japanese comments across 3 import/export dialog files

---

## v0.5.7 — 2026/04/13

### 🗺️ Save Overlay Images as GeoTIFF

- Introduced GeoTIFF format for overlay image storage (full compatibility with QGIS and other GIS software)
- Position, scale, and rotation expressed via ModelTransformationTag (4x4 affine transformation matrix)
- Overlay parameters automatically restored from GeoTIFF tags (eliminates dependency on kmeta)
- TIFF-to-PNG conversion via TileServer for MapLibre display (with caching)
- Debounced GeoTIFF file writes on parameter changes (10-second interval)
- Removed opacity parameter (transparency managed via GeoTIFF alpha channel)
- Added dedicated detail panel for overlay images

### 🖼️ Overlay Conversion Dialog

- Added image processing options to make scanned paper maps easier to overlay with GIS data
  - Brightness → Alpha: bright areas transparent, dark areas opaque (gradient)
  - Split transparent/opaque: full transparent or opaque by threshold (colors preserved)
  - B&W binarize + white transparent: convert to B&W, then make white areas transparent
- Output file name can be specified in the conversion dialog

### ⚡ Performance Improvements

- Significantly improved responsiveness of overlay image transforms (move, scale, rotate)
  - Handle UI updates instantly; MapLibre source updates debounced at 100ms intervals
  - Avoids expensive per-frame source removal and re-addition

### 🐛 Bug Fixes

- Fixed overlay images not displaying in offline mode
  - Android: Changed to load images directly via file:// instead of routing through localhost HTTP server (supported by MapLibre Native)
  - Avoids OS-level blocking of localhost connections when network interfaces are disabled

---

## v0.5.6 — 2026/04/12

### 📍 Open Points in Google Maps from Detail Panel

- Added "Open in Google Maps" button to the point detail panel
- On Android, launches Google Maps app directly via geo: intent
- Falls back to browser on PC or when the app is not installed

### 🗑️ Long-Press Delete from Detail Panel

- Added a "Delete" button to all feature and photo detail panels
- Requires a 1-second long press to prevent accidental deletion
- Red gauge animation provides visual feedback during the hold

### 🐛 Bug Fixes

- Fixed SymbolStyleLayers (photo markers, cluster counts) not rendering due to missing font specification
- Fixed potential issue where map text disappears in offline mode (font PBF glyphs now cached locally and served via file://)
- Cluster circle and text sizes now scale proportionally with point size setting

- Fixed EXIF location and timestamp data being lost when importing photos from gallery (bypassed Android Photo Picker's EXIF stripping via native file copy)
- Fixed crash when loading images with NaN GPS coordinates from EXIF (0/0 Ratio)
- Suppressed tile server success logs to reduce console noise

### 🔧 Maintenance

- Upgraded MapLibre to v0.3.5 (Android: MapLibre Native 13.0, jni v1.0.0)
- Removed obsolete `third_party/jni` override (no longer needed with jni v1.0.0)

---

## v0.5.5 — 2026/04/11

### 🏷️ First rename: k_maps → RootMap GIS (the current name, Kokage Map, dates from v0.6.1)

- Application name changed from "k_maps" to "RootMap GIS"
- Unified app name display across all platforms (Android / Windows / Web)
- Internal package name changed to `root_maps`
- Google Drive sync folder renamed to "RootMap GIS Projects"

### 📝 Auto-Fill Version & Device Info in Feedback Form

- Feedback form now auto-fills app version and device model when opened
- Makes bug reports smoother and more informative

---

## v0.5.4 — 2026/04/10

### 🌐 Now Available in English

- Introduced type-safe internationalization framework using the slang package
- All UI strings localized to Japanese and English
- One-tap language switching in Settings

### 📶 Maps Work Smoothly Even Offline

- Migrated tile caching from HTTP server-based delivery to direct MBTiles access
- Native MapLibre loading via `mbtiles://` protocol dramatically improves offline stability
- Fixed blank map issue on Android when returning from background

### 🔤 Adjustable UI Size (7 Levels)

- Adjust the size of text and UI elements in 7 levels (XS / S / M− / M / M+ / L / XL) from Settings → General
- Changes apply instantly with a simple slider — no restart required

### 📖 In-App User Guide

- Access the user guide from the home screen AppBar
- Available in Japanese and English (auto-switches with app language)
- Custom Markdown renderer displays actual app icons inline within the guide
- *Note: Guide content is AI-generated*

### 🎓 Permission Setup on First Launch

- Added first-launch onboarding screen that walks you through required permissions (Storage, Location, Bluetooth)
- Clearly explains the purpose of each permission on screen (compliant with Google Play's "Prominent Disclosure" policy)
- Permission status can be checked and re-configured anytime from Settings

### 🔔 In-App Update History

- Added update notification banner on the home screen (animated pop-in when unread)
- View the full changelog in Markdown format within the app
- Multi-language support (auto-switches between Japanese and English)

### 📱 Auto-Hide Android Navigation Bar

- 3-button navigation bar (◁□○) is now hidden by default for a full-screen experience
- Swipe from the bottom edge to temporarily reveal; auto-hides after 3 seconds

---

## v0.5.1 — 2026/04/02

### 📊 Smarter Data Search & Editing

- Added QGIS-style filter functionality (filter features with expressions like `"area" > 100`)
- Feature duplication (create new features based on existing data)
- Sub-table timestamp display
- Eliminated flickering when toggling selected feature highlights

### 🖼️ Freely Transform Images on the Map

- Implemented Photoshop-style transform handles for OverlayImageNode
- Drag handles to move, scale, and rotate intuitively
- Improved hit-test accuracy so even small images are easy to manipulate
- Transform results reflected on the map instantly

### 📋 Published to Google Play Internal Testing

- Created and published privacy policy on GitHub
- Configured AAB build and signing for Google Play

### 🖥️ Windows Support Temporarily Paused

- Windows development paused due to maplibre_webview performance falling short of requirements and significant behavioral differences from maplibre core
- Will resume once native Windows support is available in maplibre

---

## v0.5.0 — 2026/03/31

### 🔫 Field Surveying with Laser Rangefinder

- Connection and real-time data retrieval with TruPulse 360R (Bluetooth Classic)
- Instantly record distance, azimuth, and inclination measurements as points
- Closure adjustment (Compass rule / Transit rule) ensures accuracy
- Magnetic declination, instrument height, and target height corrections
- Real-time closure ratio display with instant accuracy warnings
- Automatic conversion from survey points to Line/Polygon

### ⚡ Overall App Stability Improvements

- Full Riverpod normalization (removed GlobalConfig, unified providers) for cleaner state management
- Async race condition prevention with Completer introduction
- Declarative settings framework (SettingDef + SettingsStore)
- Select tool redesigned for cross-layer traversal with priority cycling
- WKB parsing delegated to geobase & multi-geometry support

### 🛠️ Small But Important Fixes

- AppBar notification center (integrated SnackBar into structured notifications)
- Global folder custom path settings & containment checking
- GeoJSON import automatically splits layers by geometry type
- Restored Windows GPS position, marker, and initial jump functionality

---

## v0.4.0 — 2026/03/18

### ☁️ Share & Backup Data via Google Drive

- Google Sign-In authentication and Drive API integration
- Folder-level clone and manual sync (Push/Pull)
- Drive info persisted in .kmeta.json for state restoration on next launch
- Auto-sync checks with visual sync status icons
- Drive sync UI integrated into title bar for one-tap access

### 📊 Attribute Table Made Easier to Use

- QGIS-style filter for quick searching through large datasets
- Feature duplication (one-click copy of similarly structured data)

### 🚀 Faster Data Loading

- Migrated maplibre from vendored fork to official pub.dev release
- Large file splitting (feature_converter, layer_drawer_tiles, sync_engine, etc.)
- GeoPackage loading acceleration (N+1 query elimination, parallelization, Isolate)

---

## v0.3.3 — 2026/03/11

### 📥 Download Maps Ahead for Offline Use

- Implemented offline basemap cache functionality
- Bulk download with area & zoom level selection
- Fixed SymbolStyleLayer rendering issues
- Fixed feature layers hiding behind basemap on network change
- Added Drive auto-sync check functionality
- GeoPackageTile refactoring & drag-move bug fix

---

## v0.3.2 — 2026/03/10

### 📷 Pick Photos from Your Gallery

- Replaced camera capture with gallery import (easier to use existing photos)
- LayerDrawer UI unification (single add button, folder action menu)

---

## v0.3.1 — 2026/03/09

### 🔧 Layer Panel Cleanup

- Split the massive God Object LayerDrawer class into manageable pieces
- LayerDrawerService extraction & ConsumerWidget migration for better maintainability

---

## v0.3.0 — 2026/03/09

### 🗺️ Blazing Fast Map Rendering

- Full map engine migration from FlutterMap to MapLibre
- High-performance rendering with GeoJSON Source + Style Layers
- Point clustering (supercluster) handles massive marker counts smoothly
- GPU-accelerated photo markers (SymbolStyleLayer)
- Windows performance optimization (vertex marker GPU rendering, batchSetPaintProperties)
- Unified settings screen UI (responsive Split View)
