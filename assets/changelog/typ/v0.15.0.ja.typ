// 更新履歴（図解）: v0.15.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

// 標準 3D 地形（なだらかに潰れた斜面）と高度な 3D 地図（山道の段差や谷筋が見える斜面）
#let terrain-card(fine: false, label: "", sub-label: "") = box(width: 108pt, fill: white, stroke: 0.7pt + if fine { accent } else { line-c }, radius: 6pt, inset: 6pt, align(left, {
  text(size: 6.5pt, weight: "bold", fill: if fine { accent } else { sub })[#label]
  v(4pt)
  box(width: 96pt, height: 48pt, fill: rgb("#f4f7ef"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
    if not fine {
      // 粗い格子: 斜面がのっぺりして細かな道や段差が消えている
      place(polygon(fill: rgb("#cfe0be"), stroke: 0.8pt + rgb("#7cb342"),
        (0pt, 44pt), (24pt, 22pt), (58pt, 12pt), (96pt, 26pt), (96pt, 48pt), (0pt, 48pt)))
      place(curve(stroke: (paint: rgb("#9ab882"), thickness: 0.6pt),
        curve.move((16pt, 48pt)), curve.line((38pt, 17pt))))
      place(curve(stroke: (paint: rgb("#9ab882"), thickness: 0.6pt),
        curve.move((48pt, 48pt)), curve.line((66pt, 15pt))))
      place(curve(stroke: (paint: rgb("#7cb342"), thickness: 0.6pt),
        curve.move((10pt, 34pt)), curve.line((96pt, 38pt))))
    } else {
      // 細かい地形: 斜面に山道の路肩・段差がくっきり出る
      place(polygon(fill: rgb("#cfe0be"), stroke: 0.8pt + okink,
        (0pt, 44pt), (12pt, 34pt), (16pt, 28pt), (28pt, 27pt), (32pt, 19pt),
        (44pt, 18pt), (52pt, 10pt), (68pt, 14pt), (76pt, 22pt), (88pt, 21pt),
        (96pt, 28pt), (96pt, 48pt), (0pt, 48pt)))
      // 道のフラットな帯（段差）を強調
      place(polygon(fill: rgb("#ffe0b2"), stroke: 0.8pt + warm,
        (16pt, 28pt), (28pt, 27pt), (88pt, 21pt), (76pt, 22pt)))
      place(polygon(fill: rgb("#ffe0b2"), stroke: 0.8pt + warm,
        (32pt, 19pt), (44pt, 18pt), (72pt, 15pt), (62pt, 16pt)))
      place(dx: 18pt, dy: 32pt, box(fill: rgb(255, 255, 255, 210), radius: 2pt, inset: (x: 3pt, y: 1.5pt),
        text(size: 5.6pt, weight: "bold", fill: warm)[▲ 山道・路肩の段差]))
    }
  })
  v(3pt)
  text(size: 5.8pt, fill: if fine { accent } else { sub })[#sub-label]
}))

// トグルスイッチの小部品
#let toggle-pill(on: true) = box(
  width: 16pt, height: 9pt, radius: 4.5pt,
  fill: if on { accent } else { rgb("#c4c0c9") },
  place(dx: if on { 8pt } else { 1pt }, dy: 1pt, circle(radius: 3.5pt, fill: white)),
)

#hero(
  "v0.15.0 — 2026/11/02",
  [細かな道や微地形まで見える「高度な3D地図」],
  [「設定 → 3D地形」に「高度な3D地図」を追加しました。ON にすると全国25地域の 0.25〜1 m メッシュ高精細 DEM（和歌山県 1 m 点群を含む）を自動で使い、範囲外も地理院 DEM で継ぎ目なく補完します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 5pt, align: horizon,
    terrain-card(fine: false, label: "これまで（5m〜10m）", sub-label: "尾根・谷の大まかな起伏のみ"),
    arrow-r(w: 14pt),
    terrain-card(fine: true, label: "高度な3D地図（0.25〜1m）", sub-label: "山道の路肩や微地形まで再現"),
  ),
)

#scene(
  [移動・ズーム中に粗い面と細かい面が混ざらない],
  [3D 地形を動かすとき、細かいタイルが 1 枚ずつバラバラに出ると境界や文字が乱れていました。裏で 4 枚（2×2）すべて焼き上がってから親タイルと一括で入れ替えるようにし、表示の乱れを抑えました。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    // 左: 1枚だけ細かいタイルが混ざって乱れている絵
    box(width: 104pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: sub)[これまで（1枚ずつ交代）]
      v(4pt)
      box(width: 92pt, height: 48pt, fill: map-bg, stroke: 0.6pt + line-c, radius: 3pt, clip: true, {
        // 親の粗い道路（太くぼやけた線）
        place(curve(stroke: (paint: map-road.lighten(35%), thickness: 3.5pt),
          curve.move((0pt, 38pt)), curve.line((92pt, 12pt))))
        // 左上1枚だけ先に細かいタイルが出て段差・ズレが見える
        place(rect(width: 46pt, height: 24pt, fill: rgb("#e2edd8"), stroke: 0.8pt + map-red))
        place(curve(stroke: (paint: map-road, thickness: 1.4pt),
          curve.move((0pt, 35pt)), curve.line((46pt, 22pt))))
        place(dx: 4pt, dy: 3pt, text(size: 5.5pt, weight: "bold", fill: map-red)[細])
        place(dx: 52pt, dy: 4pt, text(size: 5.5pt, fill: sub)[粗いまま])
        place(dx: 8pt, dy: 34pt, text(size: 5.5pt, fill: sub)[粗いまま])
      })
      v(3pt)
      text(size: 5.8pt, fill: map-red)[粗い面と細かい面が重なる]
    })),
    arrow-r(w: 14pt),
    // 右: 4枚揃ってから一括でパッと切り替わる絵
    box(width: 104pt, fill: white, stroke: 0.7pt + okink, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: okink)[今回（4枚揃って一括交代）]
      v(4pt)
      box(width: 92pt, height: 48pt, fill: rgb("#e2edd8"), stroke: 0.7pt + okink, radius: 3pt, clip: true, {
        place(dx: 46pt, line(angle: 90deg, length: 48pt, stroke: (paint: okink.lighten(40%), thickness: 0.5pt, dash: "dashed")))
        place(dy: 24pt, line(length: 92pt, stroke: (paint: okink.lighten(40%), thickness: 0.5pt, dash: "dashed")))
        place(curve(stroke: (paint: map-road, thickness: 1.5pt),
          curve.move((0pt, 38pt)), curve.line((92pt, 12pt))))
        place(dx: 4pt, dy: 3pt, text(size: 5.5pt, weight: "bold", fill: okink)[細 ✓])
        place(dx: 50pt, dy: 3pt, text(size: 5.5pt, weight: "bold", fill: okink)[細 ✓])
        place(dx: 4pt, dy: 27pt, text(size: 5.5pt, weight: "bold", fill: okink)[細 ✓])
        place(dx: 50pt, dy: 27pt, text(size: 5.5pt, weight: "bold", fill: okink)[細 ✓])
      })
      v(3pt)
      text(size: 5.8pt, fill: okink)[4枚揃うまで親タイルを維持]
    })),
  ),
)

#scene(
  [スタイル画面のプレビューに地理院地図の背景],
  [レイヤの色や「濃さ（不透明度）」を変えるとき、白地のプレビューではどれだけ地図が透けるか分かりませんでした。背景に地理院地図を敷き、点・線・面の種別に合わせて表示します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    // 左: 白地プレビュー
    box(width: 100pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: sub)[これまで（白地）]
      v(4pt)
      box(width: 88pt, height: 42pt, fill: white, stroke: 0.5pt + line-c, radius: 3pt, {
        place(dx: 16pt, dy: 7pt, rect(width: 56pt, height: 28pt, fill: rgb(33, 150, 243, 110), stroke: 1.2pt + accent, radius: 2pt))
      })
      v(3pt)
      text(size: 5.8pt, fill: sub)[下の地図の透け感が不明]
    })),
    arrow-r(w: 14pt),
    // 右: 地理院地図背景つきプレビュー
    box(width: 112pt, fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.5pt, weight: "bold", fill: accent)[今回（地理院地図が背景）]
      v(4pt)
      box(width: 100pt, height: 42pt, fill: rgb("#ece8dc"), stroke: 0.5pt + line-c, radius: 3pt, clip: true, {
        // 等高線と道路を下に描く
        place(curve(stroke: (paint: rgb("#c4a482"), thickness: 0.6pt),
          curve.move((0pt, 12pt)), curve.cubic((30pt, 4pt), (60pt, 22pt), (100pt, 10pt))))
        place(curve(stroke: (paint: rgb("#c4a482"), thickness: 0.6pt),
          curve.move((0pt, 26pt)), curve.cubic((35pt, 18pt), (65pt, 36pt), (100pt, 24pt))))
        place(curve(stroke: (paint: rgb("#8d6e63"), thickness: 1.4pt),
          curve.move((8pt, 40pt)), curve.line((92pt, 6pt))))
        // 半透明ポリゴン（下の等高線・道路が透けて見える）
        place(dx: 18pt, dy: 7pt, rect(width: 64pt, height: 28pt, fill: rgb(33, 150, 243, 105), stroke: 1.3pt + accent, radius: 2pt))
        place(dx: 31pt, dy: 15pt, box(fill: rgb(255, 255, 255, 210), radius: 2pt, inset: (x: 3pt, y: 1.5pt),
          text(size: 6pt, weight: "bold", fill: ink)[サンプル]))
      })
      v(3pt)
      text(size: 5.8pt, fill: accent)[等高線や道路の透け具合が見える]
    })),
  ),
)

#scene(
  [OFF の設定は折りたたんで画面をすっきり],
  [ラベル表示や頂点表示、3D 色分けなど、スイッチが ON のときだけ意味のある詳細項目は、OFF のときは隠して ON にしたときだけ開くようにしました。],
  grid(
    columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
    // 左: OFF のとき（1行だけ）
    box(width: 98pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: sub)[OFF のとき]
      v(4pt)
      grid(columns: (1fr, auto), align: horizon,
        text(size: 7pt, fill: ink)[ラベル表示],
        toggle-pill(on: false),
      )
      v(3pt)
      text(size: 5.6pt, fill: sub)[詳細項目は折りたたむ]
    })),
    arrow-r(w: 14pt),
    // 右: ON のとき（詳細が下に展開）
    box(width: 114pt, fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, align(left, {
      text(size: 6.3pt, weight: "bold", fill: accent)[ON にすると展開]
      v(4pt)
      grid(columns: (1fr, auto), align: horizon,
        text(size: 7pt, weight: "bold", fill: ink)[ラベル表示],
        toggle-pill(on: true),
      )
      v(4pt)
      block(inset: (left: 6pt), stroke: (left: 1.5pt + accent-soft), {
        text(size: 6pt, fill: ink)[ラベル属性: 地点名#linebreak()文字サイズ: 12 pt#linebreak()文字色・背景色]
      })
    })),
  ),
)

#fixes(
  "バグ修正",
  [レイヤスタイル設定で「濃さ（不透明度）」を変更した際、既存の View スタイルおよび記録中の当日 GPS 軌跡にも即座に反映されるよう修正],
  [属性テーブルの CSV エクスポート時に、レイヤ名に含まれるファイル名禁止文字をアンダースコア（\_）に置き換えて保存するよう修正],
)
