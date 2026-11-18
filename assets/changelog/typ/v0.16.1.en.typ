// Changelog (illustrated): v0.16.1. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.16.1 — 2026/11/18",
  [Role Presets, Official Open Data & RTK GNSS Upgrades],
  [Tailor tools and maps in one tap with 5 field presets, and overlay national forest compartments, GSJ seamless geology, on-device CS relief maps, and high-res aerial ortho imagery.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 102pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: accent)[5 Role Presets]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: okbg, stroke: 0.7pt + okink, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.4pt, weight: "bold", fill: okink)[Forestry: CS Relief + Forest ✓]),
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.4pt, weight: "bold", fill: accent)[Surveyor: RTK Gate + Devices]),
        box(width: 100%, fill: rgb("#f5f3f7"), radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.6pt, fill: ink)[Hunter / Civil / Standard]),
      )
      v(3pt)
      text(size: 5.4pt, fill: sub)[Hide unused buttons for glove-safe UI]
    })),
    arrow-r(w: 14pt),
    box(width: 108pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[CS Relief + Official Layers]
      v(4pt)
      box(width: 96pt, height: 52pt, fill: rgb("#e4ebe0"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
        place(dx: 6pt, dy: 6pt, rect(width: 40pt, height: 38pt, fill: rgb(200, 230, 201, 140), stroke: 1pt + okink, radius: 2pt))
        place(dx: 50pt, dy: 8pt, rect(width: 40pt, height: 36pt, fill: rgb(255, 224, 178, 140), stroke: 1pt + warm, radius: 2pt))
        place(dx: 9pt, dy: 19pt, text(size: 5.5pt, weight: "bold", fill: okink)[Natl. Forest])
        place(dx: 59pt, dy: 20pt, text(size: 5.5pt, weight: "bold", fill: warm)[Private])
      })
      v(3pt)
      text(size: 5.6pt, fill: sub)[Selectively cache layers for offline work]
    })),
  ),
)

#scene(
  [Built-in NTRIP, GNSS Status Card, Live Ring & 1Hz Archive],
  [Stream RTCM3 corrections from NTRIP casters (such as RTK2go) directly to Bluetooth GNSS, monitor RTK FIX / GST accuracy in the bottom-right card, view the live GNSS target ring on the map, and archive every 1-second epoch into `gps_history.gpkg`.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 100pt, fill: white, stroke: 0.6pt + accent, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: accent)[Built-in NTRIP + Audio]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.7pt, weight: "bold", fill: accent)[Caster RTCM3 → BT GNSS]),
        box(width: 100%, fill: okbg, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.7pt, weight: "bold", fill: okink)[RTK FIX / LOST sound cues]),
      )
      v(3pt)
      text(size: 5.5pt, fill: sub)[Nearest mountpoint picker & VRS GGA]
    })),
    arrow-r(w: 14pt),
    box(width: 110pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      grid(columns: (1fr, auto), align: horizon,
        text(size: 6.2pt, weight: "bold", fill: ink)[External GNSS],
        badge([RTK FIX]),
      )
      v(3pt)
      text(size: 5.7pt, fill: sub)[ACC(GST) ±0.014m · 18 sats · HDOP 0.5]
      v(4pt)
      box(width: 100%, fill: rgb("#f3f6f9"), radius: 3pt, inset: (x: 4pt, y: 3pt),
        text(size: 5.5pt, fill: ink)[Live map ring + 1Hz `gnss_tracks` log even while stationary])
    })),
  ),
)

#scene(
  [Resilient Dual Bluetooth SPP & Backsight-Only Undo],
  [Eliminated socket leaks and write stalls when running External GNSS and TruPulse 360R simultaneously. Disconnections never silently drop to Internal GPS, auto-reconnect caps at \~71 s to save battery when powered off, and backsights can be undone in place.],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 102pt, fill: white, stroke: 0.6pt + warm, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: warm)[No Silent Fallback (\#7)]
      v(4pt)
      text(size: 5.7pt, fill: ink)[• Alert sound + explicit fallback#linebreak()• Tags `internal_fallback` points#linebreak()• Zero-radio standby after 5 tries]
    })),
    arrow-r(w: 14pt),
    box(width: 108pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[GNSS + 360R Together]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: okbg, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.7pt, weight: "bold", fill: okink)[1Hz GNSS log × 360R survey]),
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.7pt, weight: "bold", fill: accent)[1-tap "Undo backsight" in place]),
      )
      v(3pt)
      text(size: 5.4pt, fill: sub)[Unconfirmed shots excluded by default]
    })),
  ),
)

#fixes(
  "Improvements & Bug Fixes",
  [Auto-reconnects to previously paired External GNSS and TruPulse 360R on app launch],
  [Persists device connect/disconnect/fallback events in Settings and inside `gps_history.gpkg` (`device_connection_events`) with cross-device sync],
  [Fixed native Bluetooth SPP `BluetoothSocket` port leaks, `AsyncTask` serial write locks, and concurrent 2.4GHz handshake collisions],
)
