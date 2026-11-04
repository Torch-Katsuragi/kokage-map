// 更新履歴（図解）: v0.15.1。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.15.1 — 2026/11/04",
  [共有フォルダセット（JSON）の階層化と組み合わせ],
  [共有フォルダセット（JSON）の中に別の JSON プリセットを入れられるようになり、工区ごと・班ごとのプリセットを束ねて自由なフォルダ階層を組めるようになりました。各 JSON は単独でも、全体プリセットの一部としてもそのまま使えます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 7pt, align: horizon,
    stack(dir: ttb, spacing: 5pt,
      block(fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, width: 98pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(accent, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: accent)[全体地図.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[・北部エリア.json (参照)#linebreak()・南部エリア.json#linebreak()・共通ベースマップ]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 98pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(sub, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: ink)[北部エリア.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[・A工区\_施業図#linebreak()・A工区\_写真]
      })),
    ),
    arrow-r(w: 16pt),
    layer-panel(w: 120pt, header: "レイヤツリー", (
      (0, "dir", [全体地図], "hi"),
      (1, "dir", [北部エリア], "lock"),
      (2, "dir", [A工区\_施業図], "lock"),
      (2, "dir", [A工区\_写真], "lock"),
      (1, "dir", [南部エリア], "ok"),
      (1, "dir", [共通ベースマップ], "ok"),
    )),
  ),
  note: [全体を統括する人は「全体地図.json」、担当工区だけ見たい人は「北部エリア.json」のリンクを読むだけで、それぞれの立場で必要な構成が揃います。],
)

#fixes(
  "新機能・改善",
  [共有フォルダセット（JSON）の中に別の JSON プリセットを複数まとめて、レイヤツリーに階層フォルダとして展開できるよう改善],
  [各 JSON プリセットは単独の共有リンク・QR コードとしても、親プリセットの中の子要素としてもそのまま利用可能],
  [親 JSON 側で特定の子プリセットに読み取り専用（readOnly: true）を指定し、他班のエリアや共通図面を参照用としてまとめて取り込む設定に対応],
)
