// 更新履歴（図解）: v0.16.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.16.0 — 2026/11/13",
  [縁取り線・ハッチング対応と 19 種のスタイルテンプレート],
  [QGIS の複層シンボル（白フチ線・斜線ハッチング・破線・SVG マーカー）をそのまま再現し、`.qml` の入出力にも対応しました。スタイル設定画面では 19 種の定番テンプレートからワンタップで選べます。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    // 左: スタイルテンプレート選択カード
    box(width: 102pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: accent)[テンプレートから選択]
      v(4pt)
      stack(dir: ttb, spacing: 3.5pt,
        box(width: 100%, fill: accent-soft, stroke: 0.7pt + accent, radius: 3pt, inset: (x: 4pt, y: 2.8pt), {
          grid(columns: (16pt, 1fr), column-gutter: 4pt, align: horizon,
            box(width: 16pt, height: 6pt, {
              place(dy: 0.8pt, line(length: 16pt, stroke: 4.2pt + white))
              place(dy: 0.8pt, line(length: 16pt, stroke: 3.6pt + line-c))
              place(dy: 0.8pt, line(length: 16pt, stroke: 1.8pt + map-red))
            }),
            text(size: 6pt, weight: "bold", fill: accent)[白フチ強調線],
          )
        }),
        box(width: 100%, fill: white, stroke: 0.5pt + line-c, radius: 3pt, inset: (x: 4pt, y: 2.8pt), {
          grid(columns: (16pt, 1fr), column-gutter: 4pt, align: horizon,
            box(width: 14pt, height: 8pt, clip: true, stroke: 0.8pt + warm, {
              place(line(start: (-2pt, 9pt), end: (7pt, -1pt), stroke: 0.8pt + warm))
              place(line(start: (3pt, 9pt), end: (12pt, -1pt), stroke: 0.8pt + warm))
              place(line(start: (8pt, 9pt), end: (17pt, -1pt), stroke: 0.8pt + warm))
            }),
            text(size: 6pt, fill: ink)[斜線ハッチング],
          )
        }),
        box(width: 100%, fill: white, stroke: 0.5pt + line-c, radius: 3pt, inset: (x: 4pt, y: 2.8pt), {
          grid(columns: (16pt, 1fr), column-gutter: 4pt, align: horizon,
            align(center, box(width: 8pt, height: 8pt, {
              place(circle(radius: 4pt, fill: white, stroke: 1pt + okink))
              place(dx: 2pt, dy: 2pt, circle(radius: 2pt, fill: okink))
            })),
            text(size: 6pt, fill: ink)[二重丸ポイント],
          )
        }),
      )
    })),
    arrow-r(w: 14pt),
    // 右: 背景地図上でくっきり見える地図プレビュー
    box(width: 108pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[オルソ・地図上でくっきり]
      v(4pt)
      box(width: 96pt, height: 54pt, fill: rgb("#dce7d0"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
        // 斜線ハッチング面
        place(dx: 8pt, dy: 7pt, box(width: 44pt, height: 28pt, clip: true, fill: rgb(255, 243, 224, 120), stroke: 1.1pt + warm, radius: 2pt, {
          for k in range(-3, 8) {
            place(line(start: (k * 7pt, 30pt), end: (k * 7pt + 22pt, -2pt), stroke: 0.8pt + warm))
          }
        }))
        // 白フチ付き路線
        place(curve(stroke: (paint: white, thickness: 4.2pt, cap: "round"),
          curve.move((4pt, 46pt)), curve.cubic((32pt, 38pt), (58pt, 18pt), (92pt, 12pt))))
        place(curve(stroke: (paint: map-red, thickness: 2pt, cap: "round"),
          curve.move((4pt, 46pt)), curve.cubic((32pt, 38pt), (58pt, 18pt), (92pt, 12pt))))
        // 二重丸ポイント
        place(dx: 66pt, dy: 28pt, circle(radius: 4.8pt, fill: white, stroke: 1.2pt + accent))
        place(dx: 68.6pt, dy: 30.6pt, circle(radius: 2.2pt, fill: accent))
      })
      v(3pt)
      text(size: 5.8pt, fill: okink)[QGIS とも `.qgs` / `.qml` でそのまま往復]
    })),
  ),
)

#scene(
  [大規模な Drive 共有フォルダも高速・確実に同期],
  [数千のサブフォルダを持つ共有フォルダを一括バッチ走査＋差分キャッシュ化し、通信回数を大幅に削減しました。さらに変更のないフォルダを先に緑（同期済み）へ確定させ、軽量なフォルダから優先転送します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    box(width: 102pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: sub)[これまで]
      v(4pt)
      text(size: 6pt, fill: map-red)[・フォルダごとに個別照会#linebreak()・先頭の大容量データで後続が待ち状態に]
      v(4pt)
      box(width: 100%, fill: rgb("#fdecea"), radius: 3pt, inset: (x: 4pt, y: 3pt),
        text(size: 5.8pt, weight: "bold", fill: map-red)[× レート制限で同期エラー])
    })),
    arrow-r(w: 14pt),
    box(width: 110pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[今回（一括走査＋2パス優先）]
      v(4pt)
      stack(dir: ttb, spacing: 3pt,
        box(width: 100%, fill: okbg, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.8pt, weight: "bold", fill: okink)[① 無変更フォルダは即座に緑へ ✓]),
        box(width: 100%, fill: accent-soft, radius: 3pt, inset: (x: 4pt, y: 2.5pt),
          text(size: 5.8pt, weight: "bold", fill: accent)[② 軽量フォルダから優先転送 ↗]),
      )
      v(3pt)
      text(size: 5.6pt, fill: sub)[読み取り専用フォルダの誤送信も抑止]
    })),
  ),
)

#fixes(
  "改善・バグ修正",
  [共有フォルダセットで端末から消した子セットの復元、単体削除時のストア自動退避、新規子セットの表示レイヤ自動読込、孤児キャッシュ整理に対応],
  [第4バンドが未定義（Undefined）の RGBA GeoTIFF や多バンドラスタの表示に対応し、変換失敗時は通知で案内],
  [GPS 履歴記録の停止直前に届いた測位点が統合から漏れることがあった競合を修正],
)
