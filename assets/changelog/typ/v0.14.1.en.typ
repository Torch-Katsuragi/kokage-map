// Changelog (illustrated): v0.14.1. Exported to chunked SVGs by tool/changelog/build.py
#import "lib.typ": *
#show: page-setup.with(lang: "en")

#hero(
  "v0.14.1 — 2026/10/30",
  [TruPulse FS–BS Diff, Tolerance Settings & Audio Cues],
  [Displays the angle and distance difference between foresight and backsight, and plays a descending tone with an orange warning badge when the difference exceeds your configured tolerance. Also prevents accidental shots when no point layer is selected.],
  grid(
    columns: (1fr, 1fr), column-gutter: 8pt, align: horizon,
    block(fill: okbg, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, width: 100%, align(left, {
      text(size: 7.2pt, weight: "bold", fill: okink)[✓ Backsight OK]
      v(2pt)
      text(size: 6.5pt, fill: ink)[FS-BS diff: AZ 0.8° / HD 0.12m]
      v(2pt)
      text(size: 6.3pt, fill: sub)[♪ Ascending 2-note chime]
    })),
    block(fill: rgb("#fff3e0"), stroke: 0.7pt + warm, radius: 6pt, inset: 6pt, width: 100%, align(left, {
      text(size: 7.2pt, weight: "bold", fill: warm)[⚠ Tolerance Exceeded]
      v(2pt)
      text(size: 6.5pt, fill: ink)[FS-BS diff: AZ 3.2° / HD 0.65m]
      v(2pt)
      text(size: 6.3pt, fill: sub)[♪ Descending 2-note tone]
    })),
  ),
)

#fixes(
  "New Features & Improvements",
  [Display foresight–backsight angle and horizontal distance differences on the status panel badge and feature info panel],
  [Added configurable Backsight Tolerance thresholds (default: 2.0° angle, 0.5 m distance) in TruPulse details and External Devices settings],
  [Distinct audio cues for foresight (beep), backsight OK (ascending chime), backsight over tolerance (descending tone), and rejected shots (buzzer)],
)

#fixes(
  "Bug Fixes",
  [Block recording with a buzzer and warning if the station's point layer is not selected or visible, and auto-select the layer when setting a station],
  [Immediately refresh the layer tree feature count badge and open attribute tables when features are added or deleted],
)
