// 更新履歴（図解）: v0.15.2。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.15.2 — 2026/11/09",
  [共有フォルダセットの重複ダウンロード削減と高速化],
  [複数の JSON プリセットや既存の共有フォルダで同じフォルダを使う場合、端末内の実体を1つだけ保持して参照共有するようになりました。既に端末内にある同一ファイル（MD5 一致）のローカルコピー展開や GIS ファイル優先取得により、大容量フォルダの同期時間を大幅に短縮しています。],
  grid(
    columns: (auto, auto, auto), column-gutter: 7pt, align: horizon,
    stack(dir: ttb, spacing: 5pt,
      block(fill: white, stroke: 0.7pt + accent, radius: 6pt, inset: 6pt, width: 96pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(accent, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: accent)[全体セット.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[・共通地図#linebreak()・Aエリア\_調査図]
      })),
      block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 96pt, align(left, {
        grid(columns: (9pt, 1fr), column-gutter: 3pt, align: horizon,
          file-icon(sub, w: 8pt),
          text(size: 6.5pt, weight: "bold", fill: ink)[北部班セット.json],
        )
        v(3pt)
        text(size: 6.2pt, fill: sub)[・共通地図#linebreak()・Aエリア\_調査図]
      })),
    ),
    arrow-r(w: 16pt),
    layer-panel(w: 124pt, header: "端末内の実体（参照共有）", (
      (0, "dir", [drive\_store（単一実体）], "hi"),
      (1, "dir", [共通地図 (DL 1回)], "ok"),
      (1, "dir", [Aエリア\_調査図 (流用)], "ok"),
      (0, "gpkg", [調査図.gpkg (優先取得)], "hi"),
    )),
  ),
  note: [別の共有フォルダに同じファイルが既にある場合は、MD5 ハッシュを照合して端末内コピーで即座に展開します（通信量ゼロ）。],
)

#fixes(
  "改善・バグ修正",
  [複数の JSON プリセットや既存共有フォルダの間で同一フォルダの実体を共有し、重複ダウンロードを防止],
  [端末内の別フォルダに同一ファイル（MD5 一致）がある場合はローカルコピーで即座に展開],
  [GIS ファイル（.qgs / .gpkg / .tif 等）の優先ダウンロード・EXIF 先頭 64 KB 読み込み・転送中の自動同期競合抑止で同期を高速化],
  [起動直後に Drive セッション復元待ちで共有フォルダの初回自動同期が走らないことがあった問題と、Android の「同期中...」通知が残る問題を修正],
)
