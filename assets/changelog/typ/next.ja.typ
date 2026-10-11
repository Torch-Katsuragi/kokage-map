// 更新履歴（図解）: 次のリリース。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "次のリリース",
  [フォルダはアプリの中で選ぶ],
  [ホームの「フォルダを選んで開く」は、端末のファイル選択ではなく、いつもの地図の中のフォルダをレイヤ一覧と同じ見た目でたどります。外の場所は右上のメニューから選べます。],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 0pt, clip: true, {
    box(width: 100%, fill: rgb("#424242"), inset: (x: 6pt, y: 5pt), align(left, text(size: 8pt, fill: white, weight: "bold")[KokageMap]))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#ffc107"), radius: 1pt), text(size: 7pt)[共有])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#7eb0d5"), radius: 1pt), text(size: 7pt)[龍神村])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#b0bec5"), radius: 1pt), text(size: 7pt, fill: gray)[マイ地図.gpkg])))
    box(width: 100%, inset: 6pt, box(width: 100%, fill: rgb("#2e6b4f"), radius: 8pt, inset: 4pt, align(center, text(size: 7pt, fill: white)[「共有」で開く])))
  }),
)

#fixes(
  "gpkg 以外のファイルをそのまま開く",
  [shp・GeoJSON・KML・CSV・GPX などがフォルダに置くだけでレイヤに（読み取り専用。QGIS と同じ GDAL で読む）],
  [QGIS で作った GeoTIFF などのラスタもオーバーレイとして出る],
  [編集しようとすると「gpkgに変換して編集」。座標系は元のまま、確かめてから元を置き換え],
  [読み取り専用の共有フォルダでは「自分のフォルダにgpkgとして複製」],
  [QGIS のプロジェクトにも元のファイルのまま書き、読み戻す],
)

#fixes(
  "ファイルの出し入れ",
  [フォルダの長押しと「＋」に「ファイルを追加」（Android・web）],
  [移して空になった GeoPackage は消える],
  [Drive 連携で shp 一式・KML・CSV なども同期。大文字の拡張子も],
  [書き出しは QGIS と同じ GDAL で。属性を全部・座標系はそのまま],
)

#fixes(
  "軽くしました",
  [置いたままの電池の減りを抑えた],
  [パンを続けてもメモリが膨らまない],
  [面の多いデータの読み込みを速く],
)

#fixes(
  "変わりました",
  [レイヤ一覧: 行を詰め、右端は目だけ。メニューは長押し、移動は左スワイプ],
  [レイヤの行に色の見本と件数],
  [一覧の上に道筋。押すとその階層へ],
)

#fixes(
  "安全にしました",
  [受け取る前にフォルダ名と持ち主を確かめる],
  [位置共有: 終了・期限切れのルームから自動で抜ける],
  [位置共有: 外したメンバーは同じコードで戻れない],
  [受け取った地図が決まった場所の外へ書けない],
)

#fixes(
  "直しました",
  [面の多いデータで、塗りの無い面がズーム 14〜15 の間でだけ消えていた],
)
