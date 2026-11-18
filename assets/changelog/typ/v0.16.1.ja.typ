// 更新履歴（図解）: v0.16.1。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.16.1 — 2026/11/18",
  [用途プリセット・公式データ連携と外部 GNSS 測量の大強化],
  [5種の用途プリセットで画面の引き算と地図構成を一括設定でき、林野庁の林班界・産総研の地質図・CS立体図・高精細オルソを重ねられるようになりました。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    // 左: 用途プリセット選択カード
    box(width: 102pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: accent)[用途プリセット]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: okbg, stroke: 0.7pt + okink, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.6pt, weight: "bold", fill: okink)[林業：CS立体図＋林班界 ✓]),
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.5pt, weight: "bold", fill: accent)[測量：RTK品質判定＋外部機器]),
        box(width: 100%, fill: rgb("#f5f3f7"), radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.6pt, fill: ink)[猟師 / 土木防災 / 標準]),
      )
      v(3pt)
      text(size: 5.4pt, fill: sub)[不要なボタンを隠して誤タップ防止]
    })),
    arrow-r(w: 14pt),
    // 右: 公式データ＋CS立体図プレビュー
    box(width: 108pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[CS立体図 ＋ 公式データ]
      v(4pt)
      box(width: 96pt, height: 52pt, fill: rgb("#e4ebe0"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
        // CS風の尾根・谷陰影と林班区画
        place(dx: 6pt, dy: 6pt, rect(width: 40pt, height: 38pt, fill: rgb(200, 230, 201, 140), stroke: 1pt + okink, radius: 2pt))
        place(dx: 50pt, dy: 8pt, rect(width: 40pt, height: 36pt, fill: rgb(255, 224, 178, 140), stroke: 1pt + warm, radius: 2pt))
        place(dx: 12pt, dy: 18pt, text(size: 6pt, weight: "bold", fill: okink)[国有林 12])
        place(dx: 56pt, dy: 20pt, text(size: 6pt, weight: "bold", fill: warm)[民有林 4])
      })
      v(3pt)
      text(size: 5.6pt, fill: sub)[必要なレイヤだけ選んでオフライン保存]
    })),
  ),
)

#scene(
  [内蔵 NTRIP・GNSS パネル・常時ライブマーカーと毎秒履歴],
  [アプリ単体で NTRIP 基準局（RTK2go 等）の補正データを受信して外部 GNSS へ転送し、画面右下に RTK 解状態・GST 精度を表示します。接続中は地図上に解状態カラーの現在地リングを常時描き、`gps_history.gpkg` へ毎秒の全測位データを残します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 100pt, fill: white, stroke: 0.6pt + accent, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: accent)[内蔵 NTRIP ＋ 効果音]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.7pt, weight: "bold", fill: accent)[基準局 RTCM3 → BT転送]),
        box(width: 100%, fill: okbg, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.7pt, weight: "bold", fill: okink)[RTK FIX / LOST を音で通知]),
      )
      v(3pt)
      text(size: 5.5pt, fill: sub)[近い順のマウントポイント選択・VRS対応]
    })),
    arrow-r(w: 14pt),
    box(width: 110pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      grid(columns: (1fr, auto), align: horizon,
        text(size: 6.2pt, weight: "bold", fill: ink)[外部GNSS],
        badge([RTK FIX]),
      )
      v(3pt)
      text(size: 5.7pt, fill: sub)[精度(GST) ±0.014m · 18基 · HDOP 0.5]
      v(4pt)
      box(width: 100%, fill: rgb("#f3f6f9"), radius: 3pt, inset: (x: 4pt, y: 3pt),
        text(size: 5.5pt, fill: ink)[地図上に緑リング常時表示＋静止中も毎秒 `gnss_tracks` へ記録])
    })),
  ),
)

#scene(
  [Bluetooth 機器の切断防止・2台同時運用と後視やり直し],
  [外部 GNSS と TruPulse 360R の 2 台同時接続時の通信詰まり・ソケット漏れを根治しました。万一電波が切れても無断で内蔵 GPS へ切り替わらず、電源 OFF 時は約 71 秒で省電力待機へ移り 1 タップで再接続できます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 102pt, fill: white, stroke: 0.6pt + warm, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: warm)[切断時も混入ゼロ (\#7)]
      v(4pt)
      text(size: 5.6pt, fill: ink)[・警告音＋無断切替を禁止#linebreak()・明示切替は `internal_fallback`#linebreak()・電源OFFは5回で待機し省電力]
    })),
    arrow-r(w: 14pt),
    box(width: 108pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[GNSS ＋ 360R 同時測量]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: okbg, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.5pt, weight: "bold", fill: okink)[毎秒GNSS記録 × 距離計 並列]),
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.6pt, weight: "bold", fill: accent)[その場で「後視をやり直す」]),
      )
      v(3pt)
      text(size: 5.4pt, fill: sub)[後視なしの未確定点はライン変換で自動保護]
    })),
  ),
)

#fixes(
  "改善・バグ修正",
  [アプリ再起動時に前回接続していた外部 GNSS・TruPulse 360R の両方へ自動再接続するよう改善],
  [接続・切断・一時切替イベントをアプリ内設定画面および `gps_history.gpkg`（`device_connection_events`）へ永続記録し、端末間統合にも対応],
  [ネイティブ Bluetooth SPP 通信層のソケット解放漏れ・直列キュー詰まり・2台同時ハンドシェイク干渉を修正],
)
