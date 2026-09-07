# Changelog

## Unreleased

### 🧹 Internal cleanup

- Removed code that was no longer reachable (old exporters, old dialogs, migration helpers;
  about 13k lines). No behaviour change.

### 🗺 Exporting a QGIS project no longer discards settings made in QGIS

- The file is now named `<folder name>.qgs` instead of `project.qgs` (old files are renamed automatically).
- Exporting again updates the existing file in place. Print layouts, field settings and symbol
  details set in QGIS are kept. Categorized and rule-based styles are left untouched.
- You are notified when layers that no longer exist in the folder are removed, or when a style was left as is.
- `<folder name>.qgs` now follows your changes automatically (visibility, styles, views, order),
  and is created when a project is opened if it does not exist yet. The manual
  "Export / Import QGIS project" menu items were removed.
- When you save the `.qgs` in QGIS, the app loads those changes (views, styles, visibility)
  the next time the project is opened, and tells you so.
- Subfolders that carry their own settings (e.g. Drive-linked ones) get their own `.qgs`,
  embedded into the parent project. A subfolder handed over on its own opens in QGIS.
- Label settings and folder expansion state are written too. QGIS `.qgz` files can be read.
- `.qgs` files are now included in Drive sync.
- Internal: sync bookkeeping moved out of the shared files into the device. Folder settings are
  no longer inherited from parent folders; each folder is self-contained.
- ⚠ Layer IDs are now generated in a platform-independent way, so a previously exported file
  gets its layers replaced once.

### 💾 GPS tracks now survive uninstalling the app (Android)

- The global folder (GPS tracks, shared GeoPackages, photos) moved from the app's
  private storage to shared storage at `Documents/KokageMap/Global`. It is visible
  in the Files app.
- Existing data is moved automatically on first launch (a notification tells you).
  The old folder is kept as `k_maps_global.migrated`; it is safe to delete.
- If you set a custom global folder in Settings, that setting still wins.

### 🧭 An arrow now points toward your location when it is off screen

- If you pan far away and lose track of where you are, a small blue arrow on the
  edge of the map shows which way to pan to get back.
- Tap the arrow to jump straight to your current location.
- Jumps land in the visible part of the map, not underneath the open layer panel.
- "Go here" from the layer list and the attribute table now animates instead of snapping.

### 📷 Follow-up fix for photos losing their location (Android)

- On devices without "All files access" granted, the previous fix did not apply and
  the location was silently dropped.
- Added a second path that uses the media location permission (ACCESS_MEDIA_LOCATION).
- When some photos still come in without location, a notification tells you how many
  and what to do (allow "All files access").

### 🔔 The ongoing notification now appears while recording GPS / sharing location (Android 13+)

- The app never asked for the notification permission, so on Android 13+ the
  "GPS active" / "sharing location" ongoing notification was never shown.
- The notification permission is now requested right after the location permission.

### 🧹 Startup fixes (Android)

- The app no longer asks for the "Nearby devices" permission on every launch
  (it is requested when you connect an external device / GNSS receiver).
- Fixed the "app updated" banner appearing right after a fresh install.
- Fixed the old app name (RootMap GIS) lingering in the notification channel name.

### 🗾 The default basemap is now GSI (standard map)

- Fixed OpenStreetMap tiles all turning into "Access blocked" images
  (the app now identifies itself the way the tile usage policy requires).
- The initial basemap is now the GSI standard map. OpenStreetMap remains
  available as a basemap choice.
- ⚠ Bulk download is no longer available for OpenStreetMap (prohibited by
  its tile usage policy; GSI maps can still be bulk-downloaded).
- ℹ If "Access blocked" images got cached, clear them via
  Settings → Basemap → Clear cache.

### 📷 Photos keep their location info when added (Android)

- The system photo picker strips GPS metadata for privacy; imported photos
  lost their capture location and direction.
- The app now re-reads the original file directly, preserving all metadata.
- Also fixed imports being named after a number (like "20.jpg") — the
  original file name is kept.
- ⚠ Cloud-only photos (no local copy on the device) still have no location;
  those show "no location info" as before.

### 🔗 Invite links and QR codes for location-sharing parties

- Copy an invite link or show a QR code from the room sheet.
- Opening the link launches the web build with the join dialog pre-filled — no app needed.
- The app's join screen can also scan the QR code.
- The join field accepts either a room code or an invite link.

### 👣 See where party members went while offline

- Tracks walked while a member was out of coverage now arrive when they
  reconnect, drawn as a faint line on the map.

### 🚪 Hosts can now remove members

- From the member list on the room sheet. The removed member gets a notification.

### 📝 Cleaned up leftover old names (Root Maps)

- Onboarding, permission disclosures, and the user guide now all say "Kokage Map".
- The location disclosure now matches the location-sharing feature
  (on-device only, shared with room members only while in a party).

### 🌳 The app is now called Kokage Map

- It used to be "RootMap GIS" in some places and "K-Maps" in others. One name now.
- ⚠ The Drive folder name (`RootMap GIS Projects`) is **unchanged** — renaming it
  would lose track of already-linked folders, and it does no harm.


### 👥 Location-sharing parties now work on the web build

- Create or join a room from the browser — the same rooms as the Android app.
- ⚠ Browser location is less accurate than the device GPS; use the Android
  app in the field.

### ☁️ Google Drive sync now works on the web build

- Clone a Drive folder from the browser and upload or download it.
- Google's sign-in prompt (One Tap) now fires as the app opens.
- Once you have granted access, a reload reconnects to Drive **without
  asking anything** (a small window opens for about a second and closes
  itself; no interaction needed).
- Syncing after leaving the tab open for over an hour now reconnects
  automatically before running.
- A small "LOG" chip sits in the bottom-left corner. Tap it to see the
  activity record (copy and paste it when reporting a problem).
- Fixed a Drive URL you had finished typing sometimes staying stuck on
  "cannot access this folder".
- Fixed the "General" settings page, which used to spin forever in a browser.
- Fixed creating, deleting, moving and renaming folders in a browser.
- ⚠ A browser has no notion of a storage path, so the "Global folder"
  setting is not shown on the web build.
- ⚠ Renaming a folder is not possible in a browser (it would mean rebuilding
  its whole contents).

### 📱 Hand over a Drive-linked folder with a QR code

- "Share via QR code" from a linked folder's row.
- The receiving device picks it up with "Add folder" → "Scan QR code"
  (data, styles and `project.qgs` all at once — no server involved).
- ⚠ Reading a QR code needs a camera, so it is phone-only (the web build
  shows only the URL field).

### 🗺️ QGIS project (.qgs) export and import

**Import**

- If a folder contains a `.qgs`, views can be created from it
  ("Import QGIS project" in the ≡ menu or a folder's menu).
- **If QGIS held the same layer several times with different styles or filters,
  you get one view for each.**
- Anything that couldn't be taken in (layers outside the folder, PostGIS
  connections, …) is reported in a notification.
- ⚠ Views on the imported layers are replaced, so re-importing doesn't pile up.

**Export**

- From the ≡ menu on the map, or a folder's menu: "Export QGIS project".
- A `project.qgs` appears in the folder. **Hand the whole folder to someone
  and they can open it in QGIS as-is** (paths are written relative).
- Folders, GeoPackages and layers become QGIS layer groups;
  **views become QGIS layers**, filters included.
- Anything left out (photos, GeoPackages referenced from outside the folder)
  is reported in a notification.
- ⚠ **Not yet verified against QGIS itself.** Please report if it won't open.

### 🎨 Per-layer and per-view colours and widths

- "Style" from a layer's menu, or from any view's menu.
- **Each view can look different** — e.g. large blue dots for
  "big parcels" and small green ones for the rest.
- ⚠ **Until now, per-layer style settings were saved but never drawn.**
  They take effect from this release.
- ⚠ Stacking order (z-order) still doesn't follow the folder structure.

### 🔍 Layers can now have "views"

- Give one layer **several ways of showing it**, each with its own condition.
  - e.g. keep "cedar only" and "cypress only" side by side and show just one.
- Conditions are written as a SQL WHERE clause (same syntax as a QGIS filter).
- Add one from the layer menu ("Add view"); each view's own menu has
  rename, edit filter, duplicate, reorder and delete.
- Layers without views behave exactly as before.

### 🌐 Web usability improvements

- **Switching the base map now takes effect immediately** (a reload used to be required).
- **The app now remembers the last folder you opened.**
  Reopen the browser and you'll see "Reopen last folder".
  - ⚠ The browser will ask for access permission again when reopening.
- Opening a folder is faster (it used to be scanned three times).

### 🗺️ Fixed map animations stopping short of their destination

- On the web build, the map could stop before reaching the target location.

### 🎨 The layer list and attribute table are now opaque

- The map used to show through them, which made text hard to read over aerial imagery.

### 🖥️ Windows Support Discontinued

- Windows, macOS and Linux builds are gone; **the web build replaces them**
  - The web build now handles project folders and GeoPackages, so it took over the role
- ⚠ **Distribution is now a URL** (open it in a browser, or install it as a PWA).
  It is no longer an application you download and run
- Android is unchanged

### 🌐 The Web Build Starts Up and Shows a Map

- Opening the app in a browser now gets you as far as a rendered base map (stage 1)
  - Platform checks are collected in one place, closing the calls that crashed on web
  - No local tile server on web — the browser fetches tiles directly
- Not yet available: opening a project folder, reading or writing GeoPackages
  (file handling comes in the next stage)

### 📂 Project Folders on Web

- Pick a folder in the browser and its subfolders, GeoPackages and photos appear in the layer list
- ⚠ **Requires Google Chrome or Microsoft Edge.** Firefox and Safari have no way to open
  a folder, so they only show the base map

### 🗂️ Reading and Writing GeoPackages on Web

- Layers and features now display and can be edited
- Edits are written back to the original `.gpkg` automatically, as on Android and Windows

### 📍 Faster Current Location (Web / Windows)

- The location marker used to take over a minute to appear on web; it is now almost immediate
  - A PC has no GPS receiver, so the browser derives your location from Wi-Fi and similar.
    Asking it for high accuracy did not improve the result, it only made you wait longer
- While a location is being acquired, a rough position is now shown straight away

### 🖥️ Windows Support Restored

- Map rendering works again on Windows (paused since April 2026)
  - Fixed a build failure on Japanese-locale systems
  - Fixed map tiles not loading
  - Fixed map labels not rendering
- Verified with 10,000 polygons in a release build

### 🐛 Bug Fixes

- Fixed the map sometimes not jumping to your current location on startup
  (both Android and Windows)
  - The camera move was lost when the first GPS fix arrived before the map was ready
- Fixed the party create/join dialog overflowing the screen
- Fixed camera operations (move, rotate, fit bounds) being silently dropped
  when called before the map was ready

### 🔗 Better QGIS Interoperability

- GeoPackages edited in RootMap now keep working in QGIS
  - Spatial index auto-update, temporarily removed while editing, is restored on save
  - Layer extent is updated to match the actual data (so "Zoom to Layer" works)
  - Feature count is kept in sync

### 🔧 For Developers

- File access now goes through a single filesystem abstraction, groundwork for web
- Added a single command to run the test suite on both Windows and Android
- Added a map backend contract test (same assertions on both platforms)
- The project folder can now be passed as a launch option

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
