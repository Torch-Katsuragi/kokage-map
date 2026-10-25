// 更新履歴（図解）: v0.13.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.13.0 — 2026/10/23",
  [複数端末でのデータ統合に対応],
  [設定 → Drive同期 の「端末間でデータを統合する」を ON にすると、同じ Google アカウントの端末間で、前日までの GPS 軌跡・「共有」フォルダ・主要設定を同期します。],
  grid(
    columns: (auto, auto, auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(phone(w: 58pt, h: 96pt, label: [端末 A], mini-map(52pt, 82pt, road: map-red))),
    arrow-lr(w: 22pt),
    box(cloud(w: 68pt, label: [AppData/kmap])),
    arrow-lr(w: 22pt),
    box(phone(w: 58pt, h: 96pt, label: [端末 B], mini-map(52pt, 82pt, road: map-red))),
  ),
)

#scene(
  [前日までの GPS 軌跡をマージ],
  [記録中の当日の軌跡は同期対象外のため、移動・記録中でもそのまま同期を実行できます。],
  stack(dir: ttb, spacing: 5pt,
    grid(
      columns: (112pt, 112pt), column-gutter: 8pt, align: center,
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[端末 A（スマホ）]
        v(4pt)
        badge[10/21 (A)]
        v(3pt)
        badge(ok: false)[当日 記録中]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 100%, align(left, {
        text(size: 7.5pt, weight: "bold", fill: sub)[端末 B（タブレット）]
        v(4pt)
        badge[10/21 (B)]
        v(3pt)
        badge[10/22 (B)]
      })),
    ),
    arrows-in(232pt, h: 22pt),
    cloud(w: 72pt, label: [AppData/kmap]),
    arrow-d(h: 14pt),
    block(fill: white, stroke: 1.2pt + accent, radius: 6pt, inset: 7pt, width: 210pt, align(left, {
      text(size: 7.5pt, weight: "bold", fill: accent)[統合後（両端末に反映）]
      v(4pt)
      badge[10/21 (A)]; h(3pt); badge[10/21 (B)]; h(3pt); badge[10/22 (B)]
    })),
  ),
  note: [同じ日に複数端末で記録した軌跡は、端末ごとに別々のフィーチャとして保持されます。],
)

#scene(
  [「共有」フォルダの自動クローン],
  [片方の端末の「共有」に追加した Drive 共有フォルダは、次回同期時に他端末の「共有」にも自動でクローンされます。],
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
      caption(fill: accent)[端末 B にも自動クローン],
      layer-panel(w: 104pt, (
        (0, "dir", [共有], "ok"),
        (1, "dir", [北山村 施業班], "hi"),
        (0, "layer", [マイ地図], "ok", rgb("#2e6b4f")),
      )),
    ),
  ),
  note: [「共有」から削除したフォルダは同期リストから外れ、削除した端末に再クローンされることはありません（他端末の既存フォルダは残ります）。],
)

#fixes(
  "設定の同期",
  [対象項目: 背景地図（レイヤ構成・カスタム URL）、GPS 軌跡の記録条件、測位品質（足切り基準）、表示言語],
  [画面レイアウトや UI サイズなど、画面サイズに依存する設定は端末ごとに保持],
  [2 台目以降の初回 ON 時は Drive 側の設定を適用。同じ項目を複数端末で変更した場合は後から同期した端末の値を優先],
)

#fixes(
  "仕様・注意事項",
  [手動の「今すぐ統合を実行」ボタン、または Wi-Fi 自動同期のタイミングで実行（Web 版は設定の同期のみ対応）],
  [同期データはマイドライブ直下の AppData/kmap フォルダに保存されます（削除・改名しないでください）],
)
