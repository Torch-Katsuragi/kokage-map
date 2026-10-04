---
title: プロジェクトとGeoPackage管理
tags: [features, project, geopackage]
---

# プロジェクトとGeoPackage管理

## プロジェクトの概念

- Root Mapsでの作業単位は「プロジェクト」とし、各プロジェクトは専用のフォルダでローカルストレージに保存・管理されることを基本とする。
- プロジェクトフォルダ内およびそのサブフォルダ内に、複数のGeoPackageファイル（.gpkg）を格納できる。
- Root Mapsはプロジェクトフォルダ内を再帰的にスキャンし、全てのGeoPackageファイルを認識する。
- プロジェクトフォルダのルートには、プロジェクト設定やメタデータ（例: `project_meta.json`）を保存する。
- オプションとして、このメタデータ内にGoogle Driveの特定のフォルダへのアクセス情報（フォルダIDなど）を保持し、ユーザーの任意のタイミングでの同期を可能にする。
- Gitによるバージョン管理も視野に入れる。

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
- 写真の決めた入れ先は作らない。取り込みはレイヤ一覧で開いている場所に入る（ほかのフォルダと同じ決まり）
- 置き場所の外のフォルダも「ほかの場所を開く」で開ける。最後に開いたのがほかの場所なら、ホームに「続きから」を出す
- 実装は `lib/services/projects_home.dart`（形）・`lib/screens/home/project_launcher.dart`（ホームの入口）

> [!WARNING] 後方互換（オープンベータで消す）
> 2026-10-03 まで Global と練習用は `KokageMap/Global` `KokageMap/練習` にあった。`GlobalFolderLocator._migratePrevious` が
> 初回に Global を `.kokage/Global` へ改名で移し、移せなかった旧 Global と旧練習用は `hiddenLegacyDirs` で地図に出さない。

## 新規プロジェクト作成

- **ローカルで作成する場合**: プロジェクト名（フォルダ名として使用）とローカルの保存場所を指定。プロジェクトフォルダを自動生成。
- **Google Driveから作成する場合**: 後述の「[[google-drive|Google Drive連携]]」セクションの通り、指定されたDriveフォルダをローカルに複製し、連携情報をメタデータに保存する。
- 初期GeoPackageファイルの作成はオプションとするか、最初のレイヤー作成時に促す。

## 既存プロジェクトを開く

- ホームの「ほかの場所を開く」でローカルストレージからプロジェクトフォルダを選択して開く。
- Google Driveから既存プロジェクトを開く場合も、一度ローカルにプロジェクトを複製（または最新状態に同期）してから開くことを基本とする。
- フォルダ内の全てのGeoPackageファイルを再帰的に読み込み、フォルダ構造とGeoPackageファイルの配置をレイヤーパネルに正確に反映する。

## GeoPackage保存

- 編集内容は、対応するGeoPackageファイルに保存される。
- 属性テーブル表示・簡易編集 (Root Maps内での確認用)

## フォルダ設定（`<dir名>.qgs` の `kokage/meta`）

※実装済み。置き場所は 2026-09-29 に `.kmeta.json` から QGIS のプロジェクトファイルへ移した
（[[../technical/project-format-design|プロジェクト形式の設計]]）。旧 `.kmeta.json` は開いたときに移して
`.kmeta.json.migrated` に改名する。Drive 連携している dir は `<Drive のフォルダ名>.qgs`。

設定を持つフォルダにだけ `.qgs` を置く。親からの継承は無い（2026-09-06 に廃止。サブ dir 単体で持ち出せるように）。

- 保存可能な設定:
  - `visibility`: レイヤー/GeoPackageの表示/非表示状態
  - `styles`: レイヤー個別のスタイル設定（色、サイズ等）
  - `layout`: 並び順、展開状態
  - `sync`: Google Drive同期情報（将来拡張用）

## 関連ドキュメント

- [[layer-management]] - レイヤー管理機能
- [[google-drive]] - Google Drive連携

