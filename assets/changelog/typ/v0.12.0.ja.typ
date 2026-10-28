// 更新履歴（図解）: v0.12.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.12.0 — 2026/10/11",
  [アプリ内フォルダブラウザと外部形式の直接読み込み],
  [ホームの「フォルダを選んで開く」で、OS のファイル選択画面を介さず、アプリ内のフォルダをレイヤ一覧と同じ UI で選択できるようになりました。外部フォルダは右上メニューから開けます。],
  box(width: 150pt, fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 0pt, clip: true, {
    box(width: 100%, fill: rgb("#424242"), inset: (x: 6pt, y: 5pt), align(left, text(size: 8pt, fill: white, weight: "bold")[KokageMap]))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#ffc107"), radius: 1pt), text(size: 7pt)[共有])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#7eb0d5"), radius: 1pt), text(size: 7pt)[調査エリアA])))
    box(width: 100%, inset: (x: 6pt, y: 4pt), align(left, grid(columns: (10pt, 1fr), column-gutter: 4pt, align: horizon, box(width: 8pt, height: 6pt, fill: rgb("#b0bec5"), radius: 1pt), text(size: 7pt, fill: gray)[マイ地図.gpkg])))
    box(width: 100%, inset: 6pt, box(width: 100%, fill: rgb("#2e6b4f"), radius: 8pt, inset: 4pt, align(center, text(size: 7pt, fill: white)[「共有」で開く])))
  }),
)

#fixes(
  "GeoPackage 以外の形式の直接読み込み",
  [Shapefile・GeoJSON・KML・CSV・GPX 等をフォルダに配置するだけで読み取り専用レイヤとして表示（QGIS と同じ GDAL で読み込み）],
  [QGIS 等で作成した GeoTIFF などのラスタもオーバーレイとして直接表示],
  [編集開始時に「gpkg に変換して編集しますか？」と確認し、座標系を維持したまま GeoPackage へ変換して編集を継続（件数確認後に元ファイルを置換）],
  [Z 値（標高）付き GeoPackage の編集時に Z 値を保持（移動・追加した頂点は 3D 地形と同じ標高タイル値を設定）],
  [読み取り専用の共有フォルダでは「自分のフォルダにgpkgとして複製」に対応],
  [QGIS プロジェクト（.qgs）にも元ファイル参照のまま書き出し・再読み込みに対応],
)

#fixes(
  "インポート・エクスポート",
  [フォルダ長押しおよび「＋」メニューに「ファイルを追加」を追加（Android・Web）],
  [レイヤ移動により空になった GeoPackage ファイルを自動削除],
  [Drive 同期の対象に Shapefile 一式・KML・CSV 等および大文字拡張子のファイルを追加],
  [エクスポート処理を GDAL ベースに刷新し、全属性と元の座標系を保持して書き出し],
)

#fixes(
  "パフォーマンス改善",
  [地図を開いたまま待機している際のバッテリー消費を削減],
  [連続パン操作時にメモリ使用量が増加し続ける問題を修正],
  [ポリゴン数の多いデータの読み込みを高速化し、背景地図を先行表示],
)

#fixes(
  "UI・操作性の改善",
  [レイヤ一覧の行間を詰め、右端を表示切替アイコンのみに整理（メニューは長押し、移動は左スワイプ）],
  [レイヤ行に描画色付きのジオメトリ種別アイコンとフィーチャ件数を表示],
  [一覧上部にパンくずリスト（パス階層）を表示し、タップで上位階層へ移動可能に],
)

#fixes(
  "セキュリティ",
  [QR やリンクで共有マップを受け取る際、インポート前にフォルダ名と所有者を確認表示],
  [位置共有: 終了または期限切れのルームから自動退出し位置送信を停止],
  [位置共有: ホストにより退出させられたメンバーの同一コードでの再参加を禁止],
  [受け取ったマップデータの展開先をアプリ管理ディレクトリ内に制限（パストラバーサル対策）],
)

#fixes(
  "バグ修正",
  [ポリゴン数の多いデータで、塗りなしのポリゴンがズーム 14〜15 の間で非表示になる問題を修正],
)
