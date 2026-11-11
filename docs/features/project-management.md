---
title: プロジェクトとGeoPackage管理
tags: [features, project, geopackage]
---

# プロジェクトとGeoPackage管理

## プロジェクトの概念

- こかげマップでの作業単位は「プロジェクト」（フォルダ）とし、専用のフォルダでローカルストレージに保存・管理されることを基本とする。
- プロジェクトフォルダ内およびそのサブフォルダ内に、複数のGeoPackageファイル（.gpkg）や外部GISファイルを格納できる。
- プロジェクトフォルダ内を再帰的にスキャンし、フォルダ構造とGeoPackage・読み取り専用レイヤ・画像をレイヤツリーに反映する。
- フォルダ設定は QGIS プロジェクトファイル（`<dir名>.qgs` の `kokage/meta`）に保存し、QGIS と同じフォルダをそのまま共有できる。

## いつもの地図（2026-10-03〜）

ホームの「地図を開く」は `Documents/KokageMap`（Android の共有ストレージ。ほかの OS はアプリの文書フォルダの下の `KokageMap`）を
そのまま 1 つのプロジェクトとして開く。スマホが苦手な人は何も考えずにここだけを使い、地図にメモし、たまに事務員から
QR で現場の地図を受け取る、という使い方が前提。

```
KokageMap/
├─ KokageMap.qgs        フォルダの設定（QGIS でも開ける）
├─ マイ地図.gpkg         書き込み先。点・線・面を最初から作る（無ければ「地図を開く」で作る）
├─ 共有/                QR で受け取った地図（Drive と同期）。[[google-drive#QRコード共有]]
└─ .kokage/             アプリ用。点で始まるフォルダは地図のツリーに出さない
   ├─ Global/           グローバルフォルダ（GPS 軌跡など）
   └─ 練習/             チュートリアルの練習用の地図
```

- 名前は端末の言語に依らず固定（Drive で共有したとき、どの端末でも同じ形になるように）
- 写真の決めた入れ先は作らない。取り込みはレイヤツリーで開いている場所に入る（ほかのフォルダと同じ決まり）
- 「フォルダを選んで開く」（2026-10-06〜）は `lib/screens/home/folder_browser_screen.dart` のアプリ内の画面。KokageMap より上へは行けず、点で始まるフォルダと `.sync` は出さない。
  見た目はレイヤツリー（タイトルバー・フォルダの行・Drive 連携の雲）に揃え、gpkg の中身は読まずにファイル名だけ薄く並べる。
  外の場所は右上のメニュー「端末の別の場所…」からだけ OS のピッカーで選べる。web はブラウザのフォルダ選択のまま
- 最後に開いたのがほかのフォルダなら、ホームに「続きから」を出す
- 実装は `lib/services/projects_home.dart`（形）・`lib/screens/home/project_launcher.dart`（ホームの入口）

> [!WARNING] 後方互換（オープンベータで消す）
> 2026-10-03 まで Global と練習用は `KokageMap/Global` `KokageMap/練習` にあった。`GlobalFolderLocator._migratePrevious` が
> 初回に Global を `.kokage/Global` へ改名で移し、移せなかった旧 Global と旧練習用は `hiddenLegacyDirs` で地図に出さない。

## GeoPackage保存

- 編集内容は、対応するGeoPackageファイルに保存される。
- 属性テーブル表示・編集（QGIS の属性フォーム設定にも対応）。

## フォルダ設定（`<dir名>.qgs` の `kokage/meta`）

置き場所は 2026-09-29 に `.kmeta.json` から QGIS のプロジェクトファイルへ移した
（[[../technical/project-format-design|プロジェクト形式の設計]]）。旧 `.kmeta.json` は開いたときに移して
`.kmeta.json.migrated` に改名する。Drive 連携している dir は `<Drive のフォルダ名>.qgs`。

設定を持つフォルダにだけ `.qgs` を置く。親からの継承は無い（サブ dir 単体で持ち出せるように）。

- 保存可能な設定:
  - `visibility`: レイヤー/GeoPackage/フォルダの表示/非表示状態
  - `styles`: レイヤー個別のスタイル設定（色、サイズ、QGIS レンダラ等）
  - `views`: レイヤーごとの View（フィルタ・スタイル）
  - `forms`: QGIS から読み取った属性フォーム定義
  - `joins`: 表（CSV）の結合設定
  - `layout`: 並び順、展開状態
  - `sync`: Google Drive 連携情報（`driveId`、`driveFolderName`、`isReadOnly`、`isFolderSet` 等）

## 関連ドキュメント

- [[layer-management]] - レイヤー管理機能
- [[google-drive]] - Google Drive連携

