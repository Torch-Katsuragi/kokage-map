# Changelog

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

### 🏷️ Rebranded to "RootMap GIS"

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
