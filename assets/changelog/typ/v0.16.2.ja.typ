// 更新履歴（図解）: v0.16.2。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.16.2 — 2026/11/19",
  [測量中の戻る誤操作防止と GPU 地図描画の安定化],
  [Android の戻るボタンや画面端のスワイプで誤ってホーム画面へ戻らないよう、ホーム移動を左上の「←」ボタンに限定しました。未確定の作図・測量中（GPS 長押し・TruPulse 器械点設定中）に「←」を押したときは確認ダイアログを出します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    phone(w: 98pt, h: 126pt, label: [地図画面（左上の ← 限定）], {
      place(mini-map(92pt, 112pt))
      place(rect(width: 92pt, height: 15pt, fill: white))
      place(dx: 4pt, dy: 3pt, text(size: 7pt, weight: "bold", fill: ink)[←   現場調査])
      place(dx: 2pt, dy: 1.5pt, spot(11.5pt, 12pt))
      // 未確定の赤い測線
      place(curve(stroke: (paint: map-red, thickness: 1.6pt, cap: "round"),
        curve.move((18pt, 78pt)), curve.line((46pt, 46pt)), curve.line((76pt, 62pt))))
      place(dx: 16pt, dy: 76pt, circle(radius: 2pt, fill: map-red))
      place(dx: 44pt, dy: 44pt, circle(radius: 2pt, fill: map-red))
      place(dx: 74pt, dy: 60pt, circle(radius: 2pt, fill: map-red))
      // 端スワイプ無効の表示
      place(dx: 6pt, dy: 92pt, rect(width: 80pt, height: 15pt, radius: 3pt, fill: white, stroke: 0.5pt + line-c, inset: 2.5pt, align(center + horizon, {
        text(size: 5.2pt, fill: sub)[端スワイプ・戻るキーは無効]
      })))
    }),
    arrow-r(w: 16pt),
    phone(w: 98pt, h: 126pt, label: [未確定データの保護], {
      place(mini-map(92pt, 112pt))
      place(rect(width: 92pt, height: 112pt, fill: rgb(0, 0, 0, 28%)))
      place(dx: 6pt, dy: 28pt, rect(width: 80pt, height: 56pt, radius: 5pt, fill: white, stroke: 0.6pt + line-c, inset: 5pt, align(left, {
        text(size: 5.6pt, weight: "bold", fill: ink)[未確定の測量・作図データがあります。]
        v(2pt)
        text(size: 5pt, fill: sub)[破棄して戻りますか？]
        v(6pt)
        grid(columns: (1fr, 1fr), column-gutter: 3pt,
          box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 2pt, y: 3pt), align(center, text(size: 4.9pt, weight: "bold", fill: accent)[留まる])),
          box(width: 100%, fill: accent, radius: 3pt, inset: (x: 2pt, y: 3pt), align(center, text(size: 4.9pt, weight: "bold", fill: white)[戻る])),
        )
      })))
    }),
  ),
  note: [放射メニュー表示中や地物の頂点編集中にシステムの戻る操作をした場合は、ホームへ戻らずメニュー閉鎖・編集キャンセルとして動作します。],
)

#fixes(
  "改善・バグ修正",
  [地図画面でのシステムの戻るボタン・端スワイプによるホーム画面への誤遷移を防止（左上の「←」ボタンに限定）],
  [未確定の作図データ、GPS 長押し測位中、TruPulse 器械点（Station）設定中に「←」を押した際の離脱確認ダイアログを追加],
  [GeoTIFF 選択中のピンチ拡縮時や TruPulse 測線表示時の高ズームで、地図全体がグレー一色になる GPU バッファ境界バグを修正],
)
