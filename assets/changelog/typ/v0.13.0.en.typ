// Changelog (illustrated): v0.13.0. tool/changelog/build.py writes it out as SVG chunks
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.13.0 — 2026/10/23",
  [Keep GPS tracks, shared folders and settings in sync across devices],
  [Turn on "Consolidate data across devices" under Settings → Drive Sync to keep past GPS tracks, your shared folder list and portable settings aligned across devices via `AppData/kmap` in My Drive.],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(
      phone(w: 58pt, h: 96pt, label: [Device A], mini-map(52pt, 82pt, road: map-red)),
    ),
    arrow-lr(w: 22pt),
    box(
      cloud(w: 68pt, label: [AppData/kmap]),
    ),
    arrow-lr(w: 22pt),
    box(
      phone(w: 58pt, h: 96pt, label: [Device B], mini-map(52pt, 82pt, road: map-red)),
    ),
  ),
)

#fixes(
  "New",
  [Consolidate completed past-day GPS tracks across devices (today's active recording is untouched, and tracks recorded on the same day on multiple devices are kept separate)],
  [Keep the `Shared/` Drive folder list uniform across devices by automatically cloning newly added shared folders and propagating removals],
  [Sync portable settings (basemap layers, custom tile URLs, track recording filters and GNSS quality thresholds) via 3-way merge],
  [Added an opt-in toggle and "Consolidate now" button under Settings → Drive Sync (also runs automatically during Wi-Fi auto-sync)],
)
