// Changelog (illustrated): v0.13.0. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.13.0 — 2026/10/23",
  [Keep tracks and settings the same on all your devices],
  [Turn on "Sync data across devices" under Settings → Drive Sync, and devices signed in to the same Google account share their GPS tracks up to yesterday, the folders in "共有" and some settings.],
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
  [Tracks up to yesterday go both ways],
  [Today's track is not sent, so you can sync while still recording.],
  stack(dir: ttb, spacing: 5pt,
    grid(
      columns: (112pt, 112pt), column-gutter: 8pt, align: center,
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[Device A (phone)]
        v(4pt)
        badge[Oct 21 (A)]
        v(3pt)
        badge(ok: false)[Today, recording]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[Device B (tablet)]
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
      text(size: 7.5pt, weight: "bold", fill: accent)[After syncing, on both devices]
      v(4pt)
      badge[Oct 21 (A)]; h(3pt); badge[Oct 21 (B)]; h(3pt); badge[Oct 22 (B)]
    })),
  ),
  note: [Tracks walked on the same day on two devices stay as separate lines, one per device.],
)

#scene(
  [Folders in "共有" follow too],
  [A folder added to "共有" on Device A appears in "共有" on Device B at the next sync.],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[Received on Device A],
      layer-panel(w: 104pt, header: "Layers", (
        (0, "dir", [共有], "ok"),
        (1, "dir", [Forestry team], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[Also on Device B],
      layer-panel(w: 104pt, header: "Layers", (
        (0, "dir", [共有], "ok"),
        (1, "dir", [Forestry team], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
  ),
  note: [A folder removed from "共有" stays on your other devices, and does not come back on the device you removed it from.],
)

#fixes(
  "Settings that follow",
  [Background maps (layering and maps added by URL), track recording, fix quality thresholds and the app language],
  [Screen layout and UI size stay per device],
  [If two devices change the same setting, the one that syncs later wins],
  [Turning the switch on for a second device replaces these settings with the ones already on Drive],
)

#fixes(
  "Good to know",
  [Syncing happens when you tap "Sync Now" and during Wi-Fi auto-sync (on the web, only the settings are synced)],
  [An AppData/kmap folder is created in My Drive. Do not delete or rename it],
)
