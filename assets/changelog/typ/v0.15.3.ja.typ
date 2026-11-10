// 更新履歴（図解）: v0.15.3。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.15.3 — 2026/11/10",
  [ホーム画面から Google Play の更新ページへ直接移動],
  [Android 版で新しいバージョンが公開されているとき、ホーム画面の上部に更新案内ボタンが表示されるようになりました。タップすると Google Play ストアの「こかげマップ」ページが直接開きます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 98pt, h: 122pt, label: [ホーム画面], {
      place(rect(width: 92pt, height: 108pt, fill: white))
      place(dx: 5pt, dy: 5pt, rect(width: 82pt, height: 24pt, radius: 4pt, fill: rgb("#e3f0e8"), inset: 4pt, align(left + bottom, {
        text(size: 6.5pt, weight: "bold", fill: rgb("#2e6b4f"))[こかげマップ]
      })))
      place(dx: 5pt, dy: 33pt, rect(width: 82pt, height: 24pt, radius: 4pt, fill: accent-soft, stroke: 0.7pt + accent, inset: 3.5pt, align(left + horizon, {
        text(size: 5.2pt, weight: "bold", fill: accent)[新しい版 (v0.15.3)]
        linebreak()
        text(size: 4.8pt, fill: sub)[Google Play で更新 ↗]
      })))
      place(dx: 4pt, dy: 32pt, spot(84pt, 26pt))
      place(dx: 5pt, dy: 62pt, rect(width: 82pt, height: 22pt, radius: 4pt, fill: rgb("#2e6b4f"), inset: 4pt, align(left + horizon, {
        text(size: 6pt, weight: "bold", fill: white)[地図を開く]
      })))
    }),
    arrow-r(w: 16pt),
    block(fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 8pt, width: 98pt, align(left, {
      text(size: 7pt, weight: "bold", fill: okink)[Google Play ストア]
      v(4pt)
      text(size: 6.2pt, fill: ink)[こかげマップ]
      v(5pt)
      box(width: 100%, fill: okink, radius: 4pt, inset: (x: 6pt, y: 4pt), align(center, {
        text(size: 6.5pt, weight: "bold", fill: white)[更新]
      }))
    })),
  ),
  note: [山間部などのオフライン環境では自動的に確認をスキップし、エラー表示や起動の待ち時間は発生しません。],
)

#fixes(
  "改善・バグ修正",
  [Android 版のホーム画面に、新しいバージョンが公開された際の Google Play ストア誘導ボタンを追加],
  [Web 版で Google Drive 未サインイン時に地図画面を操作すると、内部確認ログが繰り返し出力されていた問題を修正],
  [Linux / Web 環境で転送進捗のフォルダ名を表示する際のパス区切り文字の正規化を改善],
)
