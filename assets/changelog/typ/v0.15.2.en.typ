// Changelog (illustrated): v0.15.2. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.15.2 — 2026/11/09",
  [Faster Shared Folder Sets & Zero Duplicate Downloads],
  [Shared folders used across multiple JSON presets or existing shared folders now share a single local directory via reference mounting. Combined with MD5-verified local file seeding and GIS-first priority downloads, initial syncs of large presets are dramatically faster.],
  grid(
    columns: (auto, auto, auto), column-gutter: 7pt, align: horizon,
    stack(dir: ttb, spacing: 5pt,
      block(fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, width: 96pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(accent, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: accent)[office_set.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[· Base Ortho#linebreak()· Zone A Plan]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 96pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(sub, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: ink)[field_set.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[· Base Ortho#linebreak()· Zone A Plan]
      })),
    ),
    arrow-r(w: 16pt),
    layer-panel(w: 122pt, header: "Single local store", (
      (0, "dir", [drive\_store (shared)], "hi"),
      (1, "dir", [Base Ortho (1x DL)], "ok"),
      (1, "dir", [Zone A Plan (seeded)], "ok"),
      (0, "gpkg", [GIS files prioritized first], "hi"),
    )),
  ),
  note: [Files already present in another synced folder on the device are verified by MD5 checksum and copied locally with zero network transfer.],
)

#fixes(
  "Improvements & Bug Fixes",
  [Share a single local folder across multiple JSON presets and existing shared folders without duplicate downloads],
  [Seed identical files (matching size & MD5 checksum) directly from existing local folders without network transfer],
  [Prioritize GIS files (.qgs, .gpkg, .tif) before photos, read only the first 64 KB for EXIF GPS headers, and defer auto-sync during active transfers],
  [Fixed initial auto-sync of shared folders being skipped on startup and child "Syncing..." notifications remaining on Android],
)
