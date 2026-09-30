// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が SVG（明・暗）に書き出す
#import "lib.typ": *
#show: page-setup

#release-head("次のリリース", "フォルダの設定が QGIS のプロジェクトファイルになりました")

// ---- 図1 ----
#fig("設定の置き場所", "アプリだけのファイルから、QGIS で開けるファイルへ")
#grid(
  columns: (1fr, auto, 1fr), column-gutter: 6pt, align: horizon,
  panel(dim: true)[
    #folder("林小班")
    #file-row(".kmeta.json", note: "アプリ専用")
    #file-row("林小班.gpkg")
    #v(3pt)
    #chip-off[この端末の中だけ]
  ],
  arrow-r(),
  panel[
    #folder("林小班")
    #file-row("林小班.qgs", hot: true, note: "QGIS で開ける")
    #file-row("林小班.gpkg")
    #v(3pt)
    #chip-on[Drive で他の端末にも届く]
  ],
)
#fignote[開いたときに自動で移します。元のファイルは `.kmeta.json.migrated` として残ります。Drive で共有しているフォルダでは、`.qgs` の名前を Drive のフォルダ名にそろえます。]

// ---- 図2 ----
#fig("QGIS で開いたとき", "どのフォルダを開いても、下の階層まで直せます")
#grid(
  columns: (1fr, 1fr), column-gutter: 8pt,
  panel(dim: true)[
    #label-small[これまで]
    #tree-node(0, "区域A.qgs", open: true)
    #tree-node(1, "路網.gpkg", file: true, note: "直せる")
    #tree-node(1, "小班", locked: true, note: "読み取り専用")
  ],
  panel[
    #label-small[これから]
    #tree-node(0, "区域A.qgs", open: true)
    #tree-node(1, "路網.gpkg", file: true, note: "直せる")
    #tree-node(1, "小班", note: "直せる", hot: true)
  ],
)
#fignote[QGIS で変えた色や表示は、そのレイヤがあるフォルダの設定に戻ります。QGIS 4 で保存し直したファイルからも、写真の表示などアプリだけの設定を読めるようになりました。]

// ---- 図3 ----
#fig("2 台で設定を変えたとき", "Drive 同期で両方の変更がそろいます")
#merge-diagram(
  a: ("端末A", "路網の色を赤に"),
  b: ("端末B", "小班を非表示に"),
  result: ("同期のあと", "路網は赤・小班は非表示（両方）"),
)
#fignote[同じ項目を両方で変えたときは、その端末の値を残し、通知から「クラウドの値に戻す」を選べます。「読み取り専用」などのリンク情報は端末ごとのままです。]

// ---- 直したこと ----
#section[直したこと]
#fixes(
  [設定を続けて変えたとき、先の変更が消えることがあった],
  [サブフォルダの中の GeoPackage を改名すると失敗していた],
  [Drive 連携フォルダでフォルダや写真の名前を変えると、自動同期が元の名前に戻していた],
  [QGIS で変えた色や太さが、View を作っていないレイヤに届かなかった],
  [QGIS でグループごと非表示にすると、アプリではレイヤが非表示になっていた],
  [別のフォルダに同じ名前の GeoPackage があると、地図で片方の色で両方描いていた],
  [QGIS で保存した `.qgs` が Drive で届いても、開き直すまで取り込まなかった],
)
#fignote[QGIS で分類やルールで描き分けたレイヤは、スタイル画面に「QGIS で設定されたスタイル」と出し、アプリでは代表の色で描きます。]
