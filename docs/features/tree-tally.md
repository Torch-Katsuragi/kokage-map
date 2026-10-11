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

gpkg に同じ名前で形の違うレイヤ（面でない `tally_plots`・点でない `tally_trees`）や、地物でない同名の表があると、
`TreeTallyLayers.ensure` は何も作らず・表も変えずに `TreeTallyLayerConflict` を投げ、シートは開かずに通知センターへ理由を出す
（前は型の不一致で落ちていた。地物でない表のときは `tally_plots_2` を作っていた）。形の合うレイヤに足りない列は足す（前の版で作った表のため）。足せなければ同じく通知して開かない。

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

### 材積（`stem_volume.dart`）

確かめた地域・樹種だけ出す。いまは「近畿・中国・石川・福井地方」（旧 大阪営林局管内。和歌山・北山村を含む）のスギとヒノキ。

- 式: 林野庁計画課編「立木幹材積表 西日本編」(1970) の山本式 log v = a + b·log d + c·log h（常用対数、d: 胸高直径 cm、h: 樹高 m、v: m³）
- 係数: 細田和男・光田靖・家原敏郎 (2010)「現行立木幹材積表と材積式による計算値との相違およびその修正方法」森林計画学会誌 44(2): 23-39
  （https://doi.org/10.20659/jjfp.44.2_23 、J-STAGE で全文公開）の表-2「材積式の係数」
  - No.55 大阪スギ: a = −4.19207, b = 1.82696, c = 0.99227
  - No.57 大阪ヒノキ: a = −4.31101, b = 1.83546, c = 1.10655
  - 同論文 表-1 で両式とも「単一式のため修正なし／修正不要」。接合部の移動平均（3点・5点）は要らない。
    表-6 では材積表の値 3348（スギ）・3350（ヒノキ）か所のうち不一致は 23・30 か所で、いずれも 0.01 m³ 以内
- 照合: 西日本編 近畿・中国・石川・福井地方 スギ（pp.64-67）・ヒノキ（pp.84-87）の表の写しを島根県が公開している
  （https://www.pref.shimane.lg.jp/industry/norin/ringyo/mizumori/tamenteki/index.data/kanzaisekihyou.pdf 、2026-10-11 取得。画像の PDF）。
  そこから読んだ樹種ごと 67 点（樹高 10/20/30/40 m × 胸高直径 4〜80 cm、小径木の 0.001 m³ 単位の欄を含む）が、
  式の値を表と同じ桁（0.01 m³、0.01 未満は 0.001 m³）に丸めて全て一致した（`test/stem_volume_test.dart`）
- 対象: スギの式は「山陽の人工林・天然林、山陰の人工林」。山陰の天然スギ（No.56）は別の式で、入れていない。
  樹種名は `スギ`・`ヒノキ`（`杉`・`檜`・`桧` も同じ）。ほかの樹種と、樹高の無い木は材積を出さない（空欄）
- 集計: 1本ずつ式の値（丸めない）を足し、ha あたりにする。一部の木しか材積が出ていない行は画面で `*` を付け、CSV の `volume_n` で本数が分かる
- 地域の選択: 集計の画面の「材積式」（既定は「出さない」、端末に覚える）。標準地の位置から地域を引く仕組み（都府県の境界）はアプリに無いので、選ぶ形にした

#### 使える材料と条件（調べたこと、2026-10-11）

- 森林総合研究所「幹材積計算プログラム」（https://www.ffpri.go.jp/database/stemvolume/index.html 、Excel のユーザー定義関数、83 種類の材積表に対応、細田ら 2010 の修正を実装）。
  「著作権者の許可なく改変、移植および再配布することを禁止」とある。このアプリはプログラムを移植せず、論文の係数から式を書いた。
  プログラム（stemvolume.zip）は取得していない
- 志水克人 (2024)「stemv: 日本における立木幹材積計算のRパッケージ」森林計画学会誌 58(2): 55-60。
  ソースは https://github.com/dulvrq/stemv （MIT）。都府県 → 材積式の対応（和歌山 → 大阪スギ・大阪ヒノキ）はこれの `R/data.R` で確かめた。係数は写していない
- 林野庁の材積表調製業務資料（全文 PDF、https://www.ffpri.go.jp/labs/shukakushiken/03gyomu/ ）は 72 種類分あるが、大阪営林局のスギ・ヒノキ・山陰天然スギ・コウヤマキ・モミは含まれない
- 係数は数値（事実）で、論文に載っている。ほかの地域を足すときも、論文の表-2 から写し、その地域の材積表の値と照合してから入れる。
  表-1 で 3点・5点移動平均が要るとされた式は、その修正も実装すること

## TruPulse の高さ（HT）

文の形はマニュアル（TruPulse 360 User's Manual 4th Ed. Section 8 p.44）の `$PLTIT,HT,HTvalue,units,*csum`。
`TruPulseService.heightStream` で流し、シートが受け取る。詳細は [[docs/devices/trupulse-360r#計測データフォーマット（Download Message）]]。

## 残り

- 材積式のほかの地域・樹種（照合できる材積表の値を手に入れてから。上の「使える材料と条件」）
- 標準地の位置から材積式の地域を選ぶ（都府県の境界が要る）
- QGIS 側の属性フォーム（樹種の選択肢を `.qgs` の `fieldConfiguration` に書く）
- 標準地の傾斜補正（斜面上で水平距離の半径を取っている前提）
- 立木の削除・修正はふつうの編集（属性表・編集パネル）で行う。シートからは直せない
