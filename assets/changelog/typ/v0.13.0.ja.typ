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

#scene(
  [過去の GPS 軌跡を双方向に統合],
  [確定済みの前日以前の軌跡だけを端末間で双方向にマージします。記録中の「今日」の軌跡には触れないため、山の中で歩いている最中に同期が走っても安全です。],
  stack(dir: ttb, spacing: 5pt,
    grid(
      columns: (112pt, 112pt), column-gutter: 8pt, align: center,
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[端末 A（スマホ）]
        v(4pt)
        badge[10/21 の軌跡 (A)]
        v(3pt)
        badge(ok: false)[今日 記録中…]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[端末 B（タブレット）]
        v(4pt)
        badge[10/22 の軌跡 (B)]
        v(3pt)
        badge[10/21 の軌跡 (B)]
      })),
    ),
    arrows-in(232pt, h: 22pt),
    cloud(w: 72pt, label: [AppData/kmap]),
    arrow-d(h: 14pt),
    block(fill: white, stroke: 1.2pt + accent, radius: 6pt, inset: 7pt, width: 210pt, align(left, {
      text(size: 7.5pt, weight: "bold", fill: accent)[統合後のどちらの端末にも]
      v(4pt)
      badge[10/21 (A)]; h(3pt); badge[10/21 (B)]; h(3pt); badge[10/22 (B)]
    })),
  ),
  note: [同じ日に 2 台の端末で歩いた場合も、端末 ID ごとに別々の地物として両方とも残ります。],
)

#scene(
  [「共有」フォルダと設定もそろえる],
  [片方の端末で受け取った Drive 共有フォルダは、もう片方の端末の `共有/` にも自動でクローンされます。背景地図や GPS 記録条件などの設定も 3-way マージでそろいます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    stack(dir: ttb, spacing: 4pt,
      caption[端末 A で共有を追加],
      layer-panel(w: 104pt, (
        (0, "dir", [共有], "ok"),
        (1, "dir", [北山村 施業班], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
    arrow-r(w: 20pt),
    stack(dir: ttb, spacing: 4pt,
      caption(fill: accent)[端末 B にも自動で並ぶ],
      layer-panel(w: 104pt, (
        (0, "dir", [共有], "ok"),
        (1, "dir", [北山村 施業班], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
  ),
  note: [スマホとタブレットで画面の大きさが違うため、ボタン配置プリセットなどの画面サイズ固有の設定は統合対象から除外しています。],
)

#fixes(
  "新しく",
  [前日以前の確定済み GPS 軌跡を端末間で双方向に統合する（記録中の当日分は触らず、同じ日に複数端末で歩いた軌跡も端末ごとに分けて残す）],
  [片方の端末の `共有/` フォルダに足した Drive 共有フォルダを、ほかの端末でも自動でクローンしてそろえる（消したフォルダは他端末にも反映）],
  [背景地図・カスタム背景地図 URL・GPS 軌跡の記録条件・測位の足切り条件などの設定を、端末固有の画面サイズ設定を除いて 3-way マージでそろえる],
  [設定 → Drive同期 に ON/OFF スイッチと「今すぐ統合を実行」ボタンを追加（WiFi 自動同期のタイミングでも自動で統合）],
)
