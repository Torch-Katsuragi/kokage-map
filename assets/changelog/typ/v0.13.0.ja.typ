// 更新履歴（図解）: v0.13.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.13.0 — 2026/10/23",
  [複数端末で軌跡・共有リスト・設定をそろえる],
  [設定 → Drive同期 の「端末間でデータを統合する」を ON にすると、マイドライブの `AppData/kmap` を通して、前日以前の GPS 軌跡・共有フォルダの一覧・主な設定を複数の端末でそろえます。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(
      phone(w: 58pt, h: 96pt, label: [端末 A], mini-map(52pt, 82pt, road: map-red)),
    ),
    arrow-lr(w: 22pt),
    box(
      cloud(w: 68pt, label: [AppData/kmap]),
    ),
    arrow-lr(w: 22pt),
    box(
      phone(w: 58pt, h: 96pt, label: [端末 B], mini-map(52pt, 82pt, road: map-red)),
    ),
  ),
)

#fixes(
  "新しく",
  [前日以前の確定済み GPS 軌跡を端末間で双方向に統合する（記録中の当日分は触らず、同じ日に複数端末で歩いた軌跡も端末ごとに分けて残す）],
  [片方の端末の `共有/` フォルダに足した Drive 共有フォルダを、ほかの端末でも自動でクローンしてそろえる（消したフォルダは他端末にも反映）],
  [背景地図・カスタム背景地図 URL・GPS 軌跡の記録条件・測位の足切り条件などの設定を、端末固有の画面サイズ設定を除いて 3-way マージでそろえる],
  [設定 → Drive同期 に ON/OFF スイッチと「今すぐ統合を実行」ボタンを追加（WiFi 自動同期のタイミングでも自動で統合）],
)
