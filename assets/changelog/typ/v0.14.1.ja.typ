// 更新履歴（図解）: v0.14.1。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.14.1 — 2026/10/30",
  [TruPulse 測量の前後差表示・許容誤差基準・音の刷新],
  [後視補正時に前視と後視の角度差・距離差を表示し、設定した許容基準を超えたときは下降音（ピ・ポ↓ーン）とオレンジ色の警告表示で知らせます。ポイントレイヤ未選択時の誤記録防止も追加しました。],
  grid(
    columns: (1fr, 1fr), column-gutter: 8pt, align: horizon,
    block(fill: okbg, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, width: 100%, align(left, {
      text(size: 7.2pt, weight: "bold", fill: okink)[✓ 後視補正済（基準内）]
      v(2pt)
      text(size: 6.5pt, fill: ink)[前後差: 角度 0.8° / 距離 0.12m]
      v(2pt)
      text(size: 6.3pt, fill: sub)[♪ ピ・ポ↑ーン（上昇2音）]
    })),
    block(fill: rgb("#fff3e0"), stroke: 0.7pt + warm, radius: 6pt, inset: 6pt, width: 100%, align(left, {
      text(size: 7.2pt, weight: "bold", fill: warm)[⚠ 後視補正済（許容差超過）]
      v(2pt)
      text(size: 6.5pt, fill: ink)[前後差: 角度 3.2° / 距離 0.65m]
      v(2pt)
      text(size: 6.3pt, fill: sub)[♪ ピ・ポ↓ーン（下降2音）]
    })),
  ),
)

#fixes(
  "新機能・改善",
  [後視補正済みの点について、ステータスパネルと地物情報パネルに前視・後視の角度差・水平距離差を表示],
  [TruPulse 詳細画面と「設定 → 外部計測機器」に後視の許容誤差基準（角度差の上限: 既定 2.0°、距離差の上限: 既定 0.5 m）を追加],
  [測距音を4種類に刷新（前視: 単音「ピッ」／後視OK: 上昇音「ピ・ポ↑ーン」／後視許容差超過: 下降音「ピ・ポ↓ーン」／記録不可: ブザー「ブブー」）],
)

#fixes(
  "バグ修正",
  [ポイントレイヤ未選択時（または別レイヤ・非表示レイヤ選択時）の誤記録を防止し、器械点設定時に対象レイヤを自動選択するよう修正],
  [測量等で地物を追加・削除した際にレイヤツリーの件数バッジと属性テーブルが即座に更新されるよう修正],
)
