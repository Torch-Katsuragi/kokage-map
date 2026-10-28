// Changelog (illustrated): v0.13.0. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.13.0 — 2026/10/23",
  [Cross-device data sync via Google Drive],
  [Enable "Sync data across devices" under Settings → Drive Sync to sync past-day GPS tracks, shared folders in "共有", and core settings across devices signed in to the same Google account.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(phone(w: 58pt, h: 96pt, label: [Device A], mini-map(52pt, 82pt, road: map-red))),
    arrow-lr(w: 22pt),
    box(cloud(w: 68pt, label: [AppData/kmap])),
    arrow-lr(w: 22pt),
    box(phone(w: 58pt, h: 96pt, label: [Device B], mini-map(52pt, 82pt, road: map-red))),
  ),
)

#scene(
  [Two-way merge for past-day GPS tracks],
  [Today's active track is excluded from sync, so you can safely sync while recording.],
  stack(dir: ttb, spacing: 5pt,
    grid(
      columns: (112pt, 112pt), column-gutter: 8pt, align: center,
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[Device A (Phone)]
        v(4pt)
        badge[Oct 21 (A)]
        v(3pt)
        badge(ok: false)[Today (Recording)]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[Device B (Tablet)]
        v(4pt)
        badge[Oct 21 (B)]
        v(3pt)
        badge[Oct 22 (B)]
      })),
    ),
    arrows-in(232pt, h: 22pt),
    cloud(w: 72pt, label: [AppData/kmap]),
    arrow-d(h: 14pt),
    block(fill: white, stroke: 1.2pt + accent, radius: 6pt, inset: 7pt, width: 210pt, align(left, {
      text(size: 7.5pt, weight: "bold", fill: accent)[Merged on both devices]
      v(4pt)
      badge[Oct 21 (A)]; h(3pt); badge[Oct 21 (B)]; h(3pt); badge[Oct 22 (B)]
    })),
  ),
  note: [Tracks recorded on the same day on multiple devices are preserved as separate features per device.],
)

#scene(
  [Auto-clone shared folders in "共有"],
  [Drive shared folders added to "共有" on Device A are automatically cloned into "共有" on Device B on the next sync.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[Added on Device A],
      layer-panel(w: 104pt, header: "Layers", (
        (0, "dir", [共有], "ok"),
        (1, "dir", [Field Survey Team], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[Auto-cloned on Device B],
      layer-panel(w: 104pt, header: "Layers", (
        (0, "dir", [共有], "ok"),
        (1, "dir", [Field Survey Team], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
  ),
  note: [Removing a folder from "共有" removes it from the sync list so it is not re-cloned on that device (existing folders on other devices are kept).],
)

#fixes(
  "Settings Sync",
  [Synced keys: basemap layers, custom tile URLs, GPS track recording thresholds, GNSS fix quality thresholds, and display language],
  [Screen layout presets and UI scale remain independent per device],
  [Enabling sync on a second device applies the settings currently on Drive; if two devices modify the same setting, the device that syncs later takes precedence],
)

#fixes(
  "Notes",
  [Runs when tapping "Sync Now" or during Wi-Fi auto-sync (on Web, only settings are synced)],
  [Sync data is stored in AppData/kmap in My Drive (do not delete or rename this folder)],
)
