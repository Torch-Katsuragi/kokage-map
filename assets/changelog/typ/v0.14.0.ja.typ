// 更新履歴（図解）: v0.14.0。tool/changelog/build.py が切れごとの SVG に書き出す
#import "lib.typ": *
#show: page-setup

#hero(
  "v0.14.0 — 2026/10/28",
  [共有フォルダセット（JSON）と同期進捗の可視化],
  [複数の Drive 共有フォルダをまとめた JSON リンク・QR コードからの一括クローンと差分追従に対応しました。大容量データのバックグラウンド転送・3フェーズ進捗表示や、地物からレイヤツリーを直接開く機能も追加しています。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 96pt, align(left, {
      grid(columns: (10pt, 1fr), column-gutter: 3pt, align: horizon,
        file-icon(accent, w: 8.5pt),
        text(size: 6.5pt, weight: "bold", fill: accent)[現地調査セット.json],
      )
      v(4pt)
      text(size: 6.5pt, fill: sub)[・調査エリアA#linebreak()・調査エリアB#linebreak()・ルート・地点]
    })),
    arrow-r(w: 18pt),
    layer-panel(w: 118pt, header: "レイヤツリー", (
      (0, "dir", [現地調査セット], "hi"),
      (1, "dir", [調査エリアA], "lock"),
      (1, "dir", [調査エリアB], "lock"),
      (1, "dir", [ルート・地点], "ok"),
    )),
  ),
  note: [JSON から外れたフォルダは、未送信のローカル変更がないことを確認したうえで自動削除されます（未送信の変更がある場合は残して通知します）。鍵アイコンは読み取り専用フォルダです。],
)

#scene(
  [Drive 同期の3フェーズ進捗とバックグラウンド転送],
  [「1. 構成確認 → 2. ファイル転送（%・MB・ファイル名） → 3. 地図反映」を通知とフォルダ行に表示します。Android では画面を消してもダウンロードが止まりません。],
  stack(dir: ttb, spacing: 6pt,
    block(fill: white, stroke: 1pt + accent, radius: 6pt, inset: (x: 8pt, y: 6pt), width: 220pt, align(left, {
      grid(columns: (1fr, auto), align: horizon,
        text(size: 8pt, weight: "bold", fill: ink)[調査エリアA をダウンロード中...],
        text(size: 7.5pt, weight: "bold", fill: accent)[64%],
      )
      v(4pt)
      box(width: 100%, height: 4pt, fill: accent-soft, radius: 2pt,
        place(rect(width: 64%, height: 4pt, fill: accent, radius: 2pt)))
      v(4pt)
      text(size: 7pt, fill: sub)[17.6 / 27.5 MB · area2026.gpkg]
    })),
    grid(
      columns: (auto, auto, auto), column-gutter: 6pt, align: horizon,
      badge[1. フォルダ構成を確認],
      badge[2. ファイルを転送],
      badge[3. 地図データを反映],
    ),
  ),
)

#scene(
  [情報パネルから「レイヤツリーで開く」],
  [地図で選んだ地物や写真のパネルから、該当するレイヤや写真の行をレイヤツリー内で直接開いてハイライト表示します。],
  grid(
    columns: (auto, auto, auto), column-gutter: 8pt, align: horizon,
    block(fill: white, stroke: 0.6pt + line-c, radius: 6pt, inset: 6pt, width: 98pt, align(left, {
      text(size: 7.5pt, weight: "bold", fill: ink)[区画 12-A]
      v(3pt)
      text(size: 6.5pt, fill: sub)[状態: 調査済 / 担当: A班]
      v(5pt)
      box(width: 100%, fill: accent-soft, stroke: 0.7pt + accent, radius: 4pt, inset: (x: 4pt, y: 3pt),
        align(center, text(size: 6.8pt, weight: "bold", fill: accent)[レイヤツリーで開く]))
    })),
    arrow-r(w: 18pt),
    layer-panel(w: 114pt, header: "レイヤツリー", (
      (0, "dir", [現地調査], "ok"),
      (1, "layer", [ルート], "ok", map-road),
      (1, "layer", [調査区画], "hi", rgb("#2e6b4f")),
    )),
  ),
)

#fixes(
  "変更・改善",
  [起動時のカメラ移動を GPS 現在位置優先に変更（GPS 未取得の間だけ地物全体を表示し、GPS 測位完了時に現在位置へジャンプ）],
  [アプリ内の「レイヤドロワー」を「レイヤツリー」に表記統一],
  [地点への案内（「ここへ案内」）を廃止],
)
