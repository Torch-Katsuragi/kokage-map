# Kokage Map User Guide

This guide explains the basics of Kokage Map.

---

## Getting Started

### Launching the App

1. Open Kokage Map to see the home screen.
2. On first launch, you'll be asked to grant permissions for Storage, Location, and Bluetooth. Follow the on-screen instructions to allow them.
3. Tap :icon-map: "Open my map" to open your everyday map. No folder needs to be chosen.

### Your Everyday Map

"Open my map" opens the `Documents/KokageMap` folder on the device. It contains:

- **マイ地図.gpkg** — where you write. Point, line and area layers are ready from the start.
- **共有** — maps received by QR go here.
- **KokageMap.qgs** — the folder settings. Open this file in QGIS on a PC to see the same map.

Folders the app uses itself (the global folder and the tutorial's practice map) live in the hidden `.kokage` folder and don't appear on the map.

### Opening Other Folders

:icon-folder_open: "Choose a folder to open" lets you pick one folder inside your everyday map (such as a map received in "共有") and open just that. Tap a folder to go into it and "<" to go back; "New folder" at the top right creates one. Folders outside your everyday map can be chosen from "Another place on the device…" in the top-right menu. If you last opened another folder, "Continue" appears on Home.

### Web Version

The web version (https://kokage-map.sleeptree.jp) runs in a PC browser. It opens folders on your PC, so use Chrome or Edge. Field features such as GPS recording and external devices are Android-only.

---

## Map Screen Layout

- **Left edge**: Toolbar (vertical) — switch between tools
- **Top**: notification bell, attribute table button, ≡ menu, :icon-layers: layer panel button
- **≡ menu**: Location Sharing Party, Reload project from disk, Map to PDF, Spirit Level, :icon-settings: Settings
- **Right side**: Layer panel (toggle with the :icon-layers: button)
- **Bottom**: Attribute table and the feature info panel
- **Bottom-left**: GPS survey buttons (when the GPS tool is active), eraser button (when the Pen tool is active)
- **Bottom-right**: Drawing confirm buttons (during drawing / GPS survey)

Where the toolbar and info panel go can be changed in Settings → "General" → "Screen layout" (Portrait, Landscape, Left-handed).

---

## Map Controls

### Basic Controls

| Action | Method |
|--------|--------|
| Pan the map | Drag with one finger (with :icon-pan_tool_alt: Pan tool selected) |
| Zoom | Pinch in/out with two fingers |
| Rotate | Rotate with two fingers |

> Even with the :icon-edit: Pen tool selected, you can pan, zoom, and rotate the map using **two-finger gestures**.

Tap the round compass button on the map to switch between 2D and 3D (terrain in relief). Double-tap it for north up, long-press it for the perspective view.

### Changing the Basemap

1. Open :icon-settings: Settings from the ≡ menu.
2. Select :icon-map: "Map & Tiles".
3. In the "Layers" list, choose the maps to use (OpenStreetMap, GSI Tiles, etc.).

Basemaps work like layers in a drawing app: you can stack several. The top one is in front, and each has its own order, visibility, opacity and blend mode. "Add layer" adds a map.

### Adding a Basemap by URL

XYZ tiles and WMS that are not in the list (such as forest planning maps or a prefecture's CS relief map) can be added from "Add layer" → "Add a background map from a URL…".

1. Enter a name and a URL template (`https://…/{z}/{x}/{y}.png`; for WMS use `BBOX={bbox-epsg-3857}`).
2. Enter an attribution; it is shown on the map while that map is visible.
3. "Check" fetches one tile; then add it.

Added maps work like the built-in ones for stacking, bulk download and 3D. Following the tile provider's terms of use is the responsibility of whoever adds it. Google and Bing tiles cannot be added.

### Preparing Offline Maps

1. Go to Settings → :icon-map: "Map & Tiles".
2. "Bulk Map Download" saves tiles for an area around the current view and a zoom range.
3. Saved tiles are used automatically when offline.

OpenStreetMap cannot be bulk-downloaded under its tile usage policy.

---

## Layer Management

### Opening the Layer Panel

Tap the :icon-layers: button at the top to open the **layer panel on the right side**. Tap again to close it.

### Layer Hierarchy

- :icon-folder: **Folders** — correspond to subfolders in the project directory
- :icon-table_chart: **GeoPackage files** — .gpkg files within folders, shown as small headings; tap one to fold its layers
- **Layers** — data layers within GeoPackage files. The icon on the left shows the type (point, line, polygon) in its map color, and the number next to the name is the feature count
- **Read-only files** — Shapefile, GeoJSON and other non-gpkg files (see "Opening Files Other Than gpkg" below)
- **Photos and overlays** — image files in the folder and images laid over the map

The top shows the current folder and the path above it. Tap a name in the path to go back there.

Layers set to "Categorized", "Graduated" or "Rule-based" in QGIS (such as stands colored by species or age) are drawn per feature just as in QGIS, with a legend in the panel. Change the colors in QGIS.

### Opening a Menu

**Long-press** a folder, GeoPackage, layer, or photo row (right-click on a PC) for rename, style, export, delete and other actions.

### Creating a New Layer

1. Choose "GeoPackage" from :icon-add: in the layer panel's title bar to create a new file.
2. To add a layer to an existing GeoPackage, long-press its heading and choose "Add Layer".
3. Select a geometry type (MultiPoint / MultiLineString / MultiPolygon) and enter a layer name.

### Adding Files

:icon-add: → "Files" in the title bar, or "Add files" in a folder's long-press menu, puts the chosen files into the folder as they are. For a Shapefile, also choose its .dbf, .shx and other files. On the web you can also drag and drop files.

### Toggling Layer Visibility

Tap the :icon-visibility: at the right end of a row to toggle between visible :icon-visibility: and hidden :icon-visibility_off:. The eye on a folder or GeoPackage toggles everything inside at once; its layers then turn gray.

### Adding a View

"Add view" in a layer's long-press menu shows the same layer another way. Each view has its own style and filter (a condition written as in QGIS, e.g. `樹種 = 'スギ'`). Deleting a view does not delete features.

### Moving Elsewhere

**Swipe a row to the left** for "Move" and choose where it goes. Folders, GeoPackages and photos move to a folder; a layer moves to another GeoPackage (migration). If the source GeoPackage becomes empty, its file is removed.

### Using the Global Folder

The :icon-folder_special: global folder is a shared folder independent of any project. It appears under "System" in the layer panel regardless of which project is open. Useful for GPS history and shared data. By default it is `Documents/KokageMap/.kokage/Global`; the path can be changed from Settings → "General".

---

## Opening Files Other Than gpkg

### Read-Only Layers

These files placed in a folder appear as layers without importing. They are read with GDAL, the same library QGIS uses.

- Shapefile (.shp and its sidecar files)
- GeoJSON, KML/KMZ, GPX, FlatGeobuf, GML, DXF, MapInfo (.tab, .mif)
- CSV (with longitude and latitude columns)

They are read-only; display, style, labels, views, the attribute table and export all work. A Shapefile without a .cpg is read as Shift_JIS (CP932), as the Japanese QGIS does. KML becomes one layer per folder, and a file mixing points, lines and polygons becomes one layer per type.

### Converting to gpkg to Edit

When you try to draw on a read-only layer or change its attributes, the app asks "This layer is read-only. Convert it to gpkg to edit?". "Convert to gpkg to edit" in the row's long-press menu does the same.

- A gpkg with the same name is created in the same folder. After checking that the feature counts match, the original files are deleted.
- The coordinate system stays as it was (a Shapefile in a Japan Plane Rectangular CRS becomes a gpkg in the same CRS). Style, views and display settings carry over.
- In a read-only shared folder, "Copy as gpkg to my folder" is offered instead. The original files stay.

### Raster Overlays

Rasters made in QGIS or elsewhere (GeoTIFF, PNG/JPEG with a world file, VRT) appear on the map as overlays just by placing them in a folder. Any coordinate system works. Nodata is transparent, numeric rasters such as DEMs are shown in grayscale, and rasters with a color table use those colors. The file defines the position, so they cannot be georeferenced in the app.

---

## Drawing & Editing

### Tool Types

Switch between tools using the toolbar on the **left edge** of the map screen:

| Tool | Icon | Function |
|------|------|----------|
| Pan | :icon-pan_tool_alt: | Move and zoom the map |
| Pen | :icon-edit: | Draw points, lines, and polygons |
| Select | :icon-select_all: | Select and edit features |
| GPS Survey | :icon-gps_fixed: | Create points, lines, and polygons using GPS |
| Measure | :icon-straighten: | Measure distance and area (creates no features) |

When an external device (TruPulse, etc.) is connected, additional tool buttons appear. While an overlay made from a photo is selected, a :icon-transform: transform tool also appears.

### Adding Points

1. Select the :icon-edit: Pen tool.
2. Select a point layer in the layer panel.
3. Tap on the map to add a point at that location.
4. Drag to create points along the drawn path.

### Drawing Lines

1. Select the :icon-edit: Pen tool.
2. Make sure a line layer is selected.
3. **Drag** on the map to draw freehand. Lifting your finger saves the line as a feature.
4. You can also **tap** to add vertices one by one, then press :icon-check: Confirm in the bottom-right to save.

### Drawing Polygons

1. Select the :icon-edit: Pen tool.
2. Make sure a polygon layer is selected.
3. **Drag** to draw freehand — the ring is automatically closed when you lift your finger, and saved as a polygon.
4. You can also **tap** to place 3+ vertices, then press :icon-check: Confirm to save.

On layers with heights (Z), vertices you don't move keep their height. Moved and added vertices and newly drawn features get the height from the same elevation tiles as the 3D terrain.

### Eraser Function

While the :icon-edit: Pen tool is active, press the :icon-delete: eraser button in the bottom-left, then tap or drag over features to delete them.

### Selecting Features

1. Select the :icon-select_all: Select tool.
2. Tap a feature on the map to select it. Tap the same location repeatedly to **cycle through overlapping features** in priority order (Point > Line > Polygon).
3. **Drag** to use lasso selection — all features within the drawn area will be selected.

The info panel of a selected feature shows the length of a line, or the area (m² and ha) and perimeter of a polygon, measured on the WGS84 ellipsoid (layers in projected CRSs too). With several features selected, it shows the total line length and total area.

### Measuring Distance and Area

1. Select the :icon-straighten: Measure tool.
2. Tap the map to place points. Each segment's distance and the total appear in the panel at the top left.
3. Press the :icon-pentagon_outlined: button at the bottom left, or tap the first point, to close the shape and see its area and perimeter. Press the button again to go back to distance.
4. Use :icon-undo: on the panel to remove the last point and :icon-delete: to clear.

Pan and zoom work as usual, including in 3D. Measurements are not saved as features and disappear when you switch tools.

### Searching Attributes

The :icon-search: magnifier in the layer panel's title bar searches the attributes of visible layers. Type a compartment number or name; tap a match to select that feature and move the map to it. Full-/half-width, upper/lower case and hiragana/katakana differences are ignored ("12" also finds "１２"). Exact matches are listed first.

### Stylus and Touch Input

Kokage Map distinguishes between stylus and touch input:

- **Stylus (pen)**: Used for freehand drawing
- **Touch (finger)**: Used for tapping points and map interaction

On the web, use the mouse wheel to zoom and drag with the right button to rotate (and tilt in 3D).

---

## GPS Features

### Recording Points with GPS Survey

1. Select the :icon-gps_fixed: GPS tool.
2. Tap the :icon-add_location: record button in the bottom-left to add a point at the current GPS position.
3. **Long-press** to collect multiple GPS readings and average them for improved accuracy. The number of collected readings is displayed in real-time.

### Creating Lines/Polygons with GPS Survey

1. Select the :icon-gps_fixed: GPS tool and choose a line or polygon layer.
2. Each tap (or long-press) on the :icon-add_location: record button accumulates a survey point.
3. As survey points accumulate, :icon-check: Confirm, :icon-undo: Undo, and :icon-clear: Cancel buttons appear in the bottom-right.
4. Confirming creates a line/polygon feature from the survey points.

### Extracting GPS Tracks

While the GPS tool is active, tap the :icon-timeline: track extraction button in the bottom-left. Select a date and time range from GPS position history, then save it to a line layer.

While the app is open, the track is recorded automatically to gps_history.gpkg (layer gps_tracks) in the global folder. A gap of 10 minutes or more starts a new segment (`2026_10_12 #2`). You can also open it by long-pressing gps_tracks in the layer list and choosing :icon-timeline: "Extract track / export GPX".

In the extraction screen, :icon-file_download: "Export GPX" saves the selected time range as GPX (GPX 1.1, with time and elevation per point). QGIS opens it directly as layers (tracks, track_points). Elevation is written as received (the phone's GPS reports ellipsoidal height, about 40 m above the elevation tiles in Japan).

Under Settings → "GPS & Positioning", **Track recording** sets the recording interval (seconds), minimum distance between points (m), accuracy limit, and jump rejection (speed). The defaults are every second, accuracy up to ±100 m, and dropping jumps faster than 200 km/h. The location update rate does not change; points are picked from fixes already received, so battery use does not increase.

### Getting Guided to a Point

Use this to walk to a boundary point or a plot center. It works without a network connection.

- Tap :icon-near_me: "Guide me here" in a feature's info panel. For a line it picks the nearest spot; for a polygon choose "center" or "nearest vertex".
- **Long-press** the map to be guided to that spot (with the Pan or Select tool).
- Tap :icon-near_me: next to a room member to walk to them. The target follows them as they move.

While guiding, the map shows the distance, bearing (true north), elevation difference and an arrow, with a line from your position to the target. The arrow follows the device heading, or your direction of travel when no heading is available. The distance includes GPS error (± m). When you are within 5 m (or the GPS accuracy, if worse) you get a notification. Tap × to stop. Guidance is cleared when the app restarts.

The device compass heading is corrected to true north using the magnetic declination (WMM2025) for your position and date.
### Sharing Pins in a Room

While you are in a room (location sharing), **long-press** the map and choose :icon-push_pin: "Drop a pin" to mark a meeting point, hazard tree, work site or note (with the Pan or Select tool). You can add a short note (up to 140 characters).

- Pins appear on everyone's map in the room. When someone else drops one you get a notification, and its "Guide me here" takes you there.
- Tap a pin to see who dropped it, when, its note and "Guide me here". The person who dropped it and the host can also edit or remove it.
- Pins dropped without a connection are kept on the device and sent as soon as you reconnect (they look faded and the card says "Not sent yet"). They survive closing the app and are sent when you rejoin the same room.
- Pins disappear when the room ends or expires. Draw features for places you want to keep.

### Connecting External GNSS Devices

1. Go to Settings → :icon-gps_fixed: "GPS & Positioning".
2. Select and connect a Bluetooth high-precision GNSS receiver.
3. Once connected, the external device's position data is automatically used for GPS surveys.

### Recording fix quality and rejecting poor fixes

Each point taken by GPS survey (each vertex of lines and polygons) records the fix type (RTK FIX, RTK FLOAT, DGPS, GPS; a phone's GPS is "GNSS (device)"), satellites, HDOP/PDOP, accuracy, averaging count and duration, time and device. The feature info panel shows it as "RTK FIX · 12 sats · ±0.02 m · avg of 10".

Under Settings → "GPS & Positioning" → **Fix quality (thresholds)**, set a maximum accuracy, a minimum fix type and a minimum number of satellites. Fixes that do not meet them are not recorded and a notification says why (turn off "Do not record fixes below thresholds" to record them with a warning instead). Long-press averaging drops the fixes that do not meet them. A phone's GPS does not report satellites, so a satellite threshold blocks it.

When exporting a layer, "Include GNSS quality" adds the columns gnss_fix, gnss_sats, gnss_hacc and gnss_avg_n (lines and polygons use the worst vertex).

---

## Location Sharing Party

"Location Sharing Party" in the ≡ menu shares everyone's position on the map.

1. One person creates a room with "Create (Host)" and passes on the room code, invite link or QR code.
2. Others enter the code or link under "Join", or scan the QR. The web version can join from the link too.
3. Tap :icon-near_me: next to a member to be guided to them. In ghost mode your own position is not sent.

While out of coverage the app stops sending and resumes when the connection returns. To finish, tap "Leave" (the host taps "End (Host)").

---

## Attribute Table

### Opening the Attribute Table

Tap the attribute table button at the top to display the **attribute table at the bottom of the screen**. It shows data for the currently selected layer and switches automatically when you change the selected layer. Choose the rows per page (50, 100, 200, 500) at the bottom. Tapping a header sorts all rows.

### Editing Attributes

Tap any cell in the attribute table to edit its value directly. Text and numeric input are supported.

If you set up a layer's attribute form in QGIS on your PC (Layer Properties → Attributes Form), the app's inputs follow it. Value maps become a list to choose from and dates are picked from a calendar. Aliases become field names, and default values are filled in for new features. A feature is not saved while it breaks a constraint such as "Not null" (constraints that are not enforced only show a warning). Change the settings in QGIS.

### Joining tables such as a stand register

Put a CSV file without coordinate columns (such as a stand register, UTF-8 or Shift_JIS) in a folder and it appears in the layer list as a :icon-table_chart: table. Tap it to view its contents.

Long-press the forest-plan layer → "Join table" and choose the table, the fields to match (for example the layer's compartment code and the table's), the fields to add and a field name prefix (`<table name>_` by default). The number of matching features is shown as you choose. Joined fields appear at the right of the attribute table with :icon-link: (read-only), and can be used in labels, QGIS-styled colors, attribute search and export ("Include joined table fields").

- This is the same as a QGIS join. It is written to the .qgs so QGIS shows the join too, and joins set up in QGIS are read back
- Matching is **exact**, as in QGIS (the integer 12 matches the text "12"). If codes mix full-width and half-width digits, turn on "Ignore full/half width and surrounding spaces". QGIS does not do this, so some features will not be joined there
- If compartment and sub-compartment are separate columns, make a single code column (such as "12-1") on both sides first. Joins use one field on each side, as in QGIS
- Joined fields cannot be used in the attribute table filter expression

### Filtering, Search & Replace

- **Filter**: Use QGIS-style filter expressions to narrow down data (e.g., `"area" > 100`).
- **Search & Replace**: Search attribute values and batch-replace them.
- **Field Calculator**: Calculate and update values using SQL expressions.

### Column Operations

- :icon-add: Add columns (Text, Integer, Real, Blob)
- Rename or delete columns
- Toggle column visibility

### Other Features

- CSV export
- Copy the table to the clipboard (all filtered rows, in the sorted order)
- Add / delete features
- Duplicate filtered results (copy to a new layer)
- Batch editing (change values for checked rows)

---

## Exporting Layers

1. Long-press the layer to export to open its menu.
2. Select :icon-file_download: "Export Layer".
3. Choose a format: Shapefile, GeoJSON, KML, CSV, GPX, FlatGeobuf, DXF or GeoPackage.
4. Choose a coordinate system if needed. By default the layer's own CRS is kept. GeoJSON, KML and GPX are always WGS 84, as their formats require.
5. Choose where to save and export.

Export uses GDAL, as QGIS does, and writes all attributes. Shapefiles are written in UTF-8 with a .cpg file.

### Printing the map as a PDF

Turn the map you are looking at into a one-page PDF, for paperwork or handouts on site.

1. Pan, zoom and rotate the map to the area you want.
2. Choose "Map to PDF" from the ≡ menu.
3. Choose the paper (A4 or A3) and orientation (landscape or portrait), and type a title and notes. The title defaults to the project folder name.
4. Press "Create" and choose where to save.

The map is drawn from straight above at a round scale (such as 1:5,000) that fits the current screen, even if the 3D view is tilted. If the map is rotated, the PDF keeps that rotation and the north arrow points to true north. The page has the title, date, scale bar, north arrow, a legend (visible layers, views and QGIS style classes) and the credits of the background maps.

---

## Photo Management

### Adding Photos

1. Choose "Photos" from :icon-add: in the layer panel's title bar.
2. Select photos. On Android, "With location" narrows the list to photos that have a location.
3. Photos are copied to the open folder. Photos with a location appear as markers on the map.

Android may strip the location from photos passed through the file picker. Allowing Kokage Map "All files access" keeps it.

### Converting Photos to Overlays

Choose "Convert to overlay" from a photo's long-press menu to lay the image over the map. While converting you can choose processing such as making bright areas transparent. Overlays can be moved, rotated, and scaled using the :icon-transform: transform tool. The overlay is a GeoTIFF, so QGIS can open it as is.

### Attaching Photos to a Feature

1. Select a point, line or polygon on the map and tap :icon-photo_camera: **Take photo** under "Photos" in the info panel (while editing, the same row is on the "Attributes" tab).
2. The device's camera app opens. Take and confirm the shot to attach it. To attach a photo you already have, use the "Choose photo" button next to it.
3. Attached photos appear as thumbnails. Tap one to view it full screen; long-press to remove it (you can also delete the file).

- Photos are saved in `photos/<layer name>/` next to the GeoPackage, and the location is written to the feature's `photo` attribute (`photo_2`, … from the second one). In QGIS the attribute form shows the photo.
- Even if the camera app's location setting is off, the current GPS position is written into the photo.
- The `photos` folder also appears in the layer panel and is synced along with a Drive-linked folder.

---

## Google Drive Integration

Syncs a folder in your own Google Drive with a folder on the device. Available on Android and the web version.

### Receiving a Map by QR

1. The sender chooses "Share via QR code" from a Drive-linked folder's menu.
2. The receiver scans the QR with the phone camera. Kokage Map opens and shows the folder name and owner before taking it in. The map is added to "共有" in the everyday map and shown.
3. "Scan a QR" on Home does the same with the app's camera.
4. You'll be asked to sign in to Google the first time.
5. Scanning the same QR again just opens the map. Phones and PCs without Kokage Map get install instructions.

### Adding a Drive-Linked Folder

1. Choose :icon-add: → "Folder" in the layer panel's title bar, and pick :icon-cloud: "Google Drive Clone" as the type.
2. Paste a Google Drive share URL or scan a QR code.
3. Authenticate with Google when prompted.
4. The folder contents are cloned locally.

### Syncing Data

1. Use the Drive-linked folder's long-press menu or the sync button in the title bar.
2. Choose upload (device → Drive) or download (Drive → device) to sync. Only changed files are transferred.
3. Sync status is indicated by icons (synced / local changes / Drive changes / conflict).
4. When the same GeoPackage was changed both on the device and in Drive, "Merge both, row by row" combines them row by row.

Besides GeoPackages, photos, Shapefiles (with sidecar files), GeoJSON, KML/KMZ, CSV, GPX, FlatGeobuf, GML, DXF and MapInfo are synced. Settings → :icon-sync: "Drive Sync" sets automatic sync on WiFi and its interval.

---

## Survey Device Integration (TruPulse)

### Connecting a TruPulse Laser Rangefinder

1. Pair the TruPulse via Android's Bluetooth settings.
2. Go to Settings → :icon-bluetooth_connected: "External Devices".
3. Select and connect the TruPulse from the device list.
4. Upon connection, a TruPulse tool is added to the map toolbar.

### Capturing Survey Data

1. Switch to the TruPulse tool in the toolbar.
2. Take measurements with TruPulse — distance, azimuth, and inclination data are sent to Kokage Map in real-time.
3. Points are calculated from the current GPS position and the measurement results.

The app corrects the azimuth to true north using the magnetic declination. Leave the declination setting on the TruPulse itself at 0.

### Closure Surveying

You can survey multiple points and convert them to lines/polygons:

- **Closure ratio** displayed in real-time
- **Compass rule (Bowditch)** / **Transit rule** for closure adjustment
- **Magnetic declination correction** (auto-calculated from WMM2025)
- **Instrument height and target height corrections**
- **Backsight correction** (automatic backsight calculation)

### Tree Tally (Plot Survey)

Record the trees in a sample plot one by one and get per-plot summaries. Works without a TruPulse too.

1. In the layer list, open the menu on a gpkg heading and choose :icon-park: "Tree tally". The first time, `tally_plots` (plots) and `tally_trees` (trees) layers are created in the gpkg.
2. Tap :icon-add_location: to create a circular plot centered on your position (0.05 ha = radius 12.62 m). For a polygon plot, draw a polygon in `tally_plots` and fill in its `plot_id` attribute.
3. Pick the species, type the DBH on the number pad and tap "Record". The species carries over to the next tree.
4. Enter the height by hand, or measure it in the TruPulse Height (HT) mode and it fills in automatically.
5. For the position, choose "GNSS" (where you stand; the fix quality is recorded) or "TruPulse (from center)" (shoot the tree from the plot center).
6. :icon-table_chart: "Summary" shows trees, trees/ha, basal area (m²/ha), mean DBH, mean height and top height per plot and per species. "Save as CSV" exports it.

Volume is not calculated yet.

---

## Settings

Open :icon-settings: Settings from the ≡ menu. On a wide screen the category list is on the left and the details on the right.

| Category | Icon | Settings |
|----------|------|----------|
| General | :icon-settings: | Language, UI size (7 levels), screen layout, global folder, permissions |
| Map & Tiles | :icon-map: | Basemap layers, adding by URL, bulk download, cache management |
| GPS & Positioning | :icon-gps_fixed: | GPS source, external GNSS connection, fix quality thresholds |
| External Devices | :icon-bluetooth_connected: | Laser rangefinders such as TruPulse (Android) |
| Layer Rendering | :icon-palette: | Point, line, polygon display styles (color, width, clustering, etc.) |
| Terrain look | | Slope and elevation coloring of the 3D terrain |
| Drive Sync | :icon-sync: | Google account, WiFi auto-sync, sync interval |
| Feedback | :icon-feedback: | Bug reports, feature requests |
| App Info | :icon-info_outline: | Version info, licenses, map data sources |

### Changing Language

Select the "General" category in Settings and change the language setting. Choose between Japanese or English — changes take effect immediately.

### Adjusting UI Size

Select the "General" category in Settings and use the slider to choose from 7 levels (XS / S / M− / M / M+ / L / XL). Text and UI element sizes update instantly.

---

## Troubleshooting

### :icon-warning: Map Not Displaying

- Check your internet connection.
- Try downloading offline map cache.

### :icon-warning: GPS Not Working

- Verify that location permissions are granted (Settings → "General" → Permissions).
- Try outdoors in an open area.
- Bluetooth permissions are also required for external GNSS devices.

### :icon-warning: A File Does Not Appear on the Map

- Verify that storage permissions are granted.
- The map shows GeoPackages and the formats listed in "Opening Files Other Than gpkg".
- For a Shapefile, put the .dbf and .shx with the same name in the same folder as the .shp.

---

*This guide was generated by AI. It was rewritten for Kokage Map v0.12.0 and the next release.*
