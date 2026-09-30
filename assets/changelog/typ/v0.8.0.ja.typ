// 更新履歴（図解）: v0.8.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// ---- 頭: アプリで決めた見た目が、QGIS でもそのまま ----
#hero(
  "v0.8.0 — 2026/09/30",
  [QGIS とそのまま行き来できるように],
  [フォルダの設定が QGIS のプロジェクトファイル（`.qgs`）になりました。アプリで決めた色や表示が、QGIS で開いても同じに見えます。],
  grid(
    columns: (auto, 1fr, auto), align: (center + horizon, center + horizon, center + horizon),
    phone(label: "こかげマップ", mini-map(56pt, 98pt, road: map-red, road-w: 2.4pt)),
    stack(dir: ttb, spacing: 3pt, file-icon(accent, w: 14pt), text(size: 7pt, weight: "bold", fill: accent)[林小班.qgs], arrow-lr(w: 30pt)),
    pc(label: "QGIS", w: 110pt, h: 78pt, mini-map(104pt, 63pt, road: map-red, road-w: 2.4pt)),
  ),
)

// ---- 設定の置き場所 ----
#scene(
  [設定はフォルダの `.qgs` に],
  [表示／非表示・色・View・並び順が、フォルダに置かれる 1 つのファイルに入ります。Drive で共有すれば、ほかの端末にも届きます。],
  grid(
    columns: (1fr, auto, 1fr), column-gutter: 6pt, align: horizon,
    block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 7pt, width: 100%, align(left, {
      text(size: 7pt, fill: sub, weight: "bold")[これまで]
      v(4pt)
      folder-icon(sub.lighten(30%)); h(3pt); text(size: 8.5pt, fill: sub)[林小班]
      v(3pt)
      h(6pt); file-icon(sub.lighten(20%)); h(3pt); text(size: 8pt, fill: sub)[.kmeta.json]
      v(5pt)
      badge(ok: false)[この端末だけ]
    })),
    arrow-r(w: 16pt),
    block(fill: white, stroke: 1.2pt + accent, radius: 6pt, inset: 7pt, width: 100%, align(left, {
      text(size: 7pt, fill: accent, weight: "bold")[これから]
      v(4pt)
      folder-icon(warm); h(3pt); text(size: 8.5pt, weight: "bold")[林小班]
      v(3pt)
      h(6pt); file-icon(accent); h(3pt); text(size: 8pt, fill: accent, weight: "bold")[林小班.qgs]
      v(5pt)
      badge[QGIS で開ける]; h(2pt); badge[共有できる]
    })),
  ),
  note: [開いたときに自動で移し、元のファイルは `.kmeta.json.migrated` として残します。],
)

// ---- QGIS で下のフォルダまで ----
#scene(
  [QGIS で下のフォルダまで直せる],
  [どのフォルダの `.qgs` を開いても、サブフォルダのレイヤまで編集できます。QGIS で変えた色は、アプリにも戻ります。],
  stack(dir: ttb, spacing: 10pt,
    grid(
      columns: (auto, auto, auto), column-gutter: 5pt, align: horizon,
      stack(dir: ttb, spacing: 4pt,
        caption[これまで],
        layer-panel(w: 84pt, (
          (0, "layer", "路網", "ok"),
          (0, "dir", "区域B", "lock"),
          (1, "layer", "小班", "lock"),
        )),
        caption[子フォルダは読み取り専用],
      ),
      arrow-r(w: 14pt),
      stack(dir: ttb, spacing: 4pt,
        caption(fill: accent)[これから],
        layer-panel(w: 84pt, (
          (0, "layer", "路網", "ok"),
          (0, "dir", "区域B", "ok"),
          (1, "layer", "小班", "hi", map-green),
        )),
        caption(fill: accent)[小班の色を変える],
      ),
    ),
    grid(
      columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
      pc(w: 84pt, h: 58pt, label: "QGIS で変えて保存", mini-map(78pt, 43pt, comp: map-green)),
      arrow-r(w: 20pt),
      phone(w: 44pt, h: 78pt, label: "アプリにも", mini-map(38pt, 64pt, comp: map-green)),
    ),
  ),
)

// ---- 2 台で同時に ----
#scene(
  [2 台で同時に変えても両方残る],
  [別々の端末で変えた設定は、Drive 同期で 1 つにまとまります。],
  stack(dir: ttb, spacing: 5pt,
    grid(
      columns: (96pt, 96pt), align: center,
      stack(dir: ttb, spacing: 4pt, bubble[路網を赤に], phone(w: 44pt, h: 78pt, label: "端末A", mini-map(38pt, 64pt, road: map-red, road-w: 2.4pt))),
      stack(dir: ttb, spacing: 4pt, bubble[小班を隠す], phone(w: 44pt, h: 78pt, label: "端末B", mini-map(38pt, 64pt, comps: false))),
    ),
    arrows-in(192pt),
    cloud(w: 64pt, label: "Drive"),
    arrow-d(),
    stack(dir: ttb, spacing: 4pt,
      phone(w: 44pt, h: 78pt, mini-map(38pt, 64pt, road: map-red, road-w: 2.4pt, comps: false)),
      badge[どちらの端末もこの状態に],
    ),
  ),
  note: [同じ項目を両方で変えたときは、その端末の値を残します。通知の「クラウドの値に戻す」で相手の値にもできます。],
)

// ---- 細かな変更 ----
#fixes(
  "ほかにも変わりました",
  [更新履歴を図で見られるように。版ごとに畳めます],
  [QGIS で分類やルールで描き分けたレイヤはスタイル画面に「QGIS で設定されたスタイル」と出します],
)

#fixes(
  "直したこと",
  [web 版でプロジェクトを開いた直後に GeoPackage が空で上書きされることがあった],
  [設定を続けて変えると先の変更が消えることがあった],
  [サブフォルダの GeoPackage の改名が失敗していた],
  [Drive 連携フォルダで名前を変えると自動同期が元に戻していた],
  [QGIS の色が View の無いレイヤに届かなかった],
  [QGIS で隠したグループがアプリではレイヤの非表示になっていた],
  [別のフォルダの同じ名前の GeoPackage で色が混ざっていた],
  [QGIS で保存した `.qgs` が同期で届いても開き直すまで反映されなかった],
  [QGIS 4 で保存し直すとアプリだけの設定（写真の表示など）が読めなかった],
)
