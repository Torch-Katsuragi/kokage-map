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

:icon-folder_open: "Choose a folder to open" lets you pick one folder inside your everyday map (such as a map received in "共有") and open just that. Tap a folder to go into it and "<" to go back; "New folder" at the top right creates one. GeoPackage files (.gpkg) inside are recognized automatically and shown as layers. Folders outside your everyday map can be chosen from "Another place on the device…" in the top-right menu. If you last opened another folder, "Continue" appears on Home.

---

## Map Screen Layout

The map screen consists of the following elements:

- **Left edge**: Toolbar (vertical) — switch between tools
- **Top**: AppBar — project name, notification bell :icon-notifications:, settings :icon-settings:, attribute table :icon-table_view:, layer panel :icon-layers:
- **Right side**: Layer panel (toggle with :icon-layers: button)
- **Bottom**: Attribute table (toggle with :icon-table_view: button)
- **Bottom-left**: GPS survey buttons (when GPS tool is active), eraser FAB (when Pen tool is active)
- **Bottom-right**: Drawing confirm buttons (during drawing / GPS survey)

---

## Map Controls

### Basic Controls

| Action | Method |
|--------|--------|
| Pan the map | Drag with one finger (with :icon-pan_tool_alt: Pan tool selected) |
| Zoom | Pinch in/out with two fingers |
| Rotate | Rotate with two fingers |

> Even with the :icon-edit: Pen tool selected, you can pan, zoom, and rotate the map using **two-finger gestures**.

### Changing the Basemap

1. Tap :icon-settings: in the AppBar.
2. Select the :icon-map: "Basemap" category.
3. Choose a tile source (OpenStreetMap, GSI Tiles, etc.).

### Preparing Offline Maps

1. Go to Settings → :icon-map: "Basemap".
2. Use "Bulk Download" to save tiles for a specified area and zoom range.
3. Downloaded tiles are automatically used when offline.

---

## Layer Management

### Opening the Layer Panel

Tap the :icon-layers: button on the right side of the AppBar to open the **layer panel on the right side**. Tap again to close it. The panel width can be adjusted by dragging.

### Layer Hierarchy

The layer panel displays the following hierarchy:

- :icon-folder: **Folders** — correspond to subfolders in the project directory
- :icon-table_chart: **GeoPackage files** — .gpkg files within folders, shown as small headings; tap one to fold its layers
- :icon-layers: **Layers** — data layers within GeoPackage files (Point, Line, Polygon). The mark on the left is the color on the map, and the number next to the name is the feature count

The top shows the current folder and the path above it. Tap a name in the path to go back there.

### Opening a Menu

**Long-press** a folder, GeoPackage, layer, or photo row (right-click on a PC) for rename, style, delete and other actions.
- :icon-photo: **Photos** — image files within folders

### Creating a New Layer

1. Use the add buttons in the layer panel's title bar.
2. "GeoPackage" creates a new file. To add a layer to an existing GeoPackage, long-press its heading and choose "Add layer".
3. Select a geometry type (MultiPoint / MultiLineString / MultiPolygon) and enter a layer name.

### Toggling Layer Visibility

Tap the :icon-visibility: at the right end of a row to toggle between visible :icon-visibility: and hidden :icon-visibility_off:. The eye on a folder or GeoPackage toggles everything inside at once; its layers then turn gray.

### Moving Elsewhere

**Swipe a row to the left** in the layer panel for "Move" and choose where it goes. Folders, GeoPackages and photos move to a folder; a layer moves to another GeoPackage (migration).

### Using the Global Folder

The :icon-folder_special: global folder is a shared folder independent of any project. It appears under "System" in the layer panel regardless of which project is open. Useful for GPS history and shared data. By default it is `Documents/KokageMap/.kokage/Global`; the path can be customized from Settings → "General".

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

When an external device (TruPulse, etc.) is connected, additional tool buttons appear dynamically. When an overlay image is selected, a :icon-transform: transform tool also appears.

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

### Eraser Function

While the :icon-edit: Pen tool is active, press the :icon-delete: eraser FAB button in the bottom-left, then tap or drag over features to delete them.

### Selecting Features

1. Select the :icon-select_all: Select tool.
2. Tap a feature on the map to select it. Tap the same location repeatedly to **cycle through overlapping features** in priority order (Point > Line > Polygon).
3. **Drag** to use lasso selection — all features within the drawn area will be selected.

### Stylus and Touch Input

Kokage Map distinguishes between stylus and touch input:

- **Stylus (pen)**: Used for freehand drawing
- **Touch (finger)**: Used for tapping points and map interaction

On PC, use the mouse wheel to zoom and middle-click drag to pan the map.

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

### Connecting External GNSS Devices

1. Go to Settings → :icon-bluetooth_connected: "Devices".
2. Select and connect a Bluetooth-capable high-precision GNSS receiver.
3. Once connected, the external device's position data is automatically used for GPS surveys.

---

## Attribute Table

### Opening the Attribute Table

Tap the :icon-table_view: button in the AppBar to display the **attribute table at the bottom of the screen**. It shows data for the currently selected layer and switches automatically when you change the selected layer.

### Editing Attributes

Tap any cell in the attribute table to edit its value directly. Text and numeric input are supported.

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
- Copy table data to clipboard
- Add / delete features
- Duplicate filtered results (copy to a new layer)
- Batch editing (change values for checked rows)

---

## Data Import & Export

### Importing Files

The following file formats can be imported:

- **Shapefile** (.shp + .shx/.dbf/.prj)
- **GeoJSON** (.geojson / .json)

Files are imported into a GeoPackage in the layer panel. For GeoJSON files, layers are automatically split by geometry type.

### Exporting Layers

1. Long-press the layer you want to export in the layer panel to open its menu.
2. Select :icon-file_download: "Export".
3. Choose the output format:
   - **Shapefile** (.shp) — with coordinate system (EPSG) selection
   - **GeoJSON** (.geojson)
   - **CSV** (.csv)
   - **KML** (.kml)
4. Specify the save location and export.

---

## Photo Management

### Importing Photos from Gallery

1. Tap the :icon-photo: "Photos" button in the layer panel's title bar.
2. Select photos from the gallery (file picker).
3. Photos are copied to the project folder. If EXIF data includes location, they are automatically displayed as markers on the map.

### Converting Photos to Overlays

Photos can be converted to overlays to display them on the map. Select "Convert to Overlay" from the photo's menu in the layer panel. Overlays can be moved, rotated, and scaled using the :icon-transform: transform tool.

---

## Google Drive Integration (Android)

### Receiving a Map by QR

1. The sender chooses "Share by QR" from a Drive-linked folder's menu.
2. The receiver scans the QR with the phone camera. Kokage Map opens, adds the map to "共有" in the everyday map and shows where it is.
3. "Scan a QR" on Home does the same with the app's camera.
4. You'll be asked to sign in to Google the first time.
5. Scanning the same QR again just opens the map. Phones and PCs without Kokage Map get install instructions.

### Adding a Drive-Linked Folder

1. In the layer panel, select "New Folder" → :icon-cloud: "Google Drive Clone".
2. Paste a Google Drive share URL or scan a QR code.
3. Authenticate with Google when prompted.
4. The folder contents are cloned locally.

### Syncing Data

1. Use the Drive-linked folder's menu or the sync button in the title bar.
2. Choose upload (local → Drive) or download (Drive → local) to sync.
3. Sync status is indicated by icons (synced / local changes / Drive changes / conflict).

> **On PC**, Google Drive Desktop sync is recommended. In-app Drive integration is Android-only.

---

## Survey Device Integration (TruPulse)

### Connecting a TruPulse Laser Rangefinder

1. Go to Settings → :icon-bluetooth_connected: "Devices".
2. Pair the TruPulse via Android's Bluetooth settings.
3. Select and connect the TruPulse from the device list.
4. Upon connection, a :icon-explore: compass tool is automatically added to the map toolbar.

### Capturing Survey Data

1. Switch to the compass tool in the toolbar.
2. Take measurements with TruPulse — distance, azimuth, and inclination data are sent to Kokage Map in real-time.
3. Points are calculated from the current GPS position and the measurement results.

### Closure Surveying

You can survey multiple points and convert them to lines/polygons:

- **Closure ratio** displayed in real-time
- **Compass rule (Bowditch)** / **Transit rule** for closure adjustment
- **Magnetic declination correction** (auto-calculated from WMM2025)
- **Instrument height and target height corrections**
- **Backsight correction** (automatic backsight calculation)

---

## Settings

Open the settings screen from the :icon-settings: button in the AppBar. The settings screen uses a responsive Split View layout with a category list on the left and details on the right.

| Category | Icon | Settings |
|----------|------|----------|
| General | :icon-settings: | Language, UI size (7 levels), global folder path, permissions |
| Basemap | :icon-map: | Tile source selection, offline cache management |
| GPS | :icon-gps_fixed: | GPS source selection/test, external GNSS settings |
| Devices | :icon-bluetooth_connected: | Bluetooth device connection (Android) |
| Layer Style | :icon-palette: | Point, line, polygon display styles (color, width, clustering, etc.) |
| Sync | :icon-sync: | Google Drive auto-sync settings (Android) |
| Feedback | :icon-feedback: | Bug reports, feature requests |
| App Info | :icon-info_outline: | Version info, license display |

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

### :icon-warning: Cannot Open File

- Verify that storage permissions are granted.
- Supported import formats are **Shapefile** and **GeoJSON**.

---

*This guide was generated by AI. Parts were updated for Kokage Map v0.11.0.*
