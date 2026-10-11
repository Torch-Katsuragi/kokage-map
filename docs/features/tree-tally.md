---
title: 毎木調査（標準地の立木の記録と集計）
tags: [features, survey, trupulse, forestry]
---

# 毎木調査（2026-10-11）

標準地の立木を1本ずつ記録し、標準地ごとに集計する。機能一覧の #3（現場計測）の続き。TruPulse の高さ（HT）で樹高を取れるが、TruPulse が無くても使える。

## 使い方（UI）

- 入口: レイヤ一覧の gpkg の見出しのメニュー「毎木調査」。初回にその gpkg へ `tally_plots`・`tally_trees` を作る。新しい画面は足さず、地図の上のシート（`showModalBottomSheet`）にした
- 標準地: シートの上の段で選ぶ。「＋」で現在地（GNSS）を中心に円形の標準地を作る（0.01 / 0.02 / 0.04 / 0.05 / 0.1 ha）。
  多角形の標準地は `tally_plots` にペンで面を描き、属性 `plot_id` を入れる（シートの一覧に出る）
- 1本の記録: 樹種（チップ。前の木の樹種を選んだまま。使った樹種が多い順に先頭）→ 胸高直径（数字の鍵盤）→ 「記録」。
  樹高と備考は任意。記録すると直径・樹高・備考を空にして番号を進める
- 樹高: 手入力か、TruPulse の高さルーチンの結果（HT）が届くと入る。TruPulse の値のまま記録すると `height_src=trupulse`
- 位置: 「GNSS」は GPS ツールの単発測量と同じ処理（`GpsTool.recordCurrentGpsPosition(into:, extra:)`）で、足切り・品質の列・`kmaps_metadata` もそのまま付く。
  「TruPulse（中心から）」は最後に届いた HV を標準地の中心からの水平距離・方位として点を置く（方位は `TruPulseTool.trueAzimuth` で真北に直す）
- シートを開いている間、TruPulse サービスの `claimedByTally` を立て、地図の TruPulse ツールは点を作らない。開く・閉じるで地図に「毎木調査」「毎木調査を終了」をフラッシュする
- 集計: シート右上の「集計」。標準地ごとに全体と樹種別の行を出し、「CSVで保存」（`FilePicker.saveFile`、UTF-8 BOM 付き）

実装は `lib/widgets/tree_tally/tree_tally_sheet.dart`（UI）、`lib/services/tree_tally/`（置き場所・集計）、`lib/devices/trupulse/trupulse_sentence.dart`（HT の解釈）。

## データの形（gpkg）

QGIS でそのまま使えるよう、普通の点・面のレイヤにした。列は `TreeTallySchema` で型付きで作る。

`tally_trees`（点、1本1行）:

| 列 | 型 | 内容 |
|----|----|------|
| `plot_id` | TEXT | 標準地（`tally_plots.plot_id`） |
| `tree_no` | INTEGER | 標準地の中の番号（1から） |
| `species` | TEXT | 樹種 |
| `dbh_cm` | REAL | 胸高直径 (cm) |
| `height_m` | REAL | 樹高 (m)。無ければ空 |
| `height_src` | TEXT | `trupulse` / `manual` |
| `pos_src` | TEXT | `gnss` / `trupulse` |
| `note` | TEXT | 備考 |
| `measured_at` | TEXT | 記録時刻 (ISO8601) |

GNSS で記録した点には GPS ツールと同じ列（`accuracy`・`fix_type`・`satellite_count`・`hdop` など）が、TruPulse で置いた点には TruPulse ツールと同じ `survey_*` 列（器械点 = 標準地の中心）が足される（[[docs/devices/trupulse-360r#自動記録される属性]]）。

`tally_plots`（面）: `plot_id`・`shape`（`circle` / `polygon`）・`radius_m`・`area_m2`（作ったときの値）・`center_lon`/`center_lat`・`note`・`created_at`。
円形は 64 角形で近似して保存し、集計の面積は `radius_m` から πr² で出す（64 角形の面積は πr² より約 0.16% 小さい）。
`radius_m` の無い面は楕円体の上の面積（`Geodesic.areaOf`）。いずれも水平面積で、傾斜補正はしない。

### 属性フォームについて（判断）

QGIS の属性フォームの仕組み（[[docs/technical/qgis-interop]]）は、編集パネルで後から直すとき用に使う。
`TreeTallyLayers.ensure` が、フォームが未設定のレイヤにだけ別名と `UniqueValues`（一覧から選ぶ・新しい値も打てる）を `KMeta.forms` に付ける。

- 記録の入力そのものは専用のシートにした。属性フォームの欄（ドロップダウン・文字の欄）では、樹種を引き継いで直径だけ打つ、という手数にならない
- 樹種を `ValueMap` にしなかった: ValueMap は一覧外の値を拒む。樹種は現場で増えるので、使った値から一覧を作る UniqueValues が合う
- `KMeta.forms` はアプリの `.qgs` の `kokage/meta` に入るだけで、QGIS の `fieldConfiguration` には書かない（今は写真の欄だけ書く）。
  QGIS 側で樹種を選べるようにするには `.qgs` への書き出しが要る → 残り

## 集計（`tree_tally_stats.dart`）

| 値 | 式 |
|----|----|
| 胸高断面積 g | π/4 × (DBH[m])² |
| ha あたり本数 | 本数 ÷ 面積[ha] |
| 胸高断面積合計 (m²/ha) | Σg ÷ 面積[ha] |
| 平均直径 | 直径のある木の算術平均 |
| 平均樹高 | 樹高のある木の算術平均 |
| 上層高 | 胸高直径の大きい順に ha あたり 100 本ぶん（面積[ha]×100 本、最低 1 本）の、樹高のある木の平均 |

上層高はこの定義に決めた（現場の「上層木」は目で選ぶことが多いが、アプリでは決まった手順で出せるものにした）。画面と CSV に定義を出す。
標準地の無い `plot_id` の立木は面積 0 として並べ、ha あたりの値は出さない。

### 材積は出さない

材積は出典つきの式を入れるまで出さない。係数を作らない。

- 林野庁の立木幹材積表（東日本編・西日本編）は地域・樹種ごとの材積式（83 式）で、森林総合研究所の「幹材積計算プログラム」は細田ら（2010）の補正を加えた式を使う。
  R での再実装と照合（森林計画学会誌 58 巻）もある
- 入れるなら、上の出典から地域（北山村は西日本編の該当地域）・樹種ごとの式と係数を写し、プログラムの出力と突き合わせるテストを付ける

## TruPulse の高さ（HT）

文の形はマニュアル（TruPulse 360 User's Manual 4th Ed. Section 8 p.44）の `$PLTIT,HT,HTvalue,units,*csum`。
`TruPulseService.heightStream` で流し、シートが受け取る。詳細は [[docs/devices/trupulse-360r#計測データフォーマット（Download Message）]]。

## 残り

- 材積（上の「材積は出さない」）
- QGIS 側の属性フォーム（樹種の選択肢を `.qgs` の `fieldConfiguration` に書く）
- 標準地の傾斜補正（斜面上で水平距離の半径を取っている前提）
- 立木の削除・修正はふつうの編集（属性表・編集パネル）で行う。シートからは直せない
