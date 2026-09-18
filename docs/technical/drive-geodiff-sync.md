---
title: Drive 同期の行単位マージ（geodiff）
tags: [technical, google-drive, geopackage, geodiff, sync]
---

# Drive 同期の行単位マージ（geodiff）

いまの Drive 同期は GeoPackage を**ファイル単位**でしか扱えない
（[[../features/google-drive|Google Drive 連携]]「GeoPackage ファイルの競合」）。
2 台が同じ `.gpkg` を別々に編集すると、Keep Local / Keep Remote のどちらかを捨てるか、
`_conflict` 付きで両方残すしかない。ルーム（複数人）で同じ林班を触ると必ずここに当たる。

[geodiff](https://github.com/MerginMaps/geodiff)（Mergin Maps の中核、C++・C API・MIT）は
これを **行単位の 3-way マージ**で解く。base と 2 つの派生からチェンジセットを作り、
片方をもう片方の上に載せ直す（rebase）。同じ行・同じ列を両方が変えたときだけ衝突として
JSON に残し、それ以外は全部自動で通る。自前で ops.log から競合検出する案（TODO「レイヤ単位での競合解決」）より実績がある。

## PoC（2026-09-18・PC の pygeodiff 2.3.1）

このアプリ自身の `GeoPackageFile` で作った `.gpkg`（`fid` 主キー・トリガ無し）と、
GDAL 製（rtree・ST_ トリガ付き。アプリと同様に ST_ トリガだけ落とした）の 2 通りで確認した。

| 端末 | 変更 |
|---|---|
| A | 点を 1 つ追加、fid=1 の name を改名 |
| B | fid=2 の値を測り直し、fid=3 を削除、fid=1 の name を**別の名前に**改名 |

`rebase(base, B, A, conflict.json)` の結果、A は「A の追加 ＋ B の測り直し ＋ B の削除 ＋ 自分の改名」になり、
fid=1 の改名だけが `conflict.json` に `base / old(B) / new(A)` 付きで出た。ジオメトリは無傷。
rtree テーブルがあっても通る。スクリプトと出力は Vault `K-Maps/geodiff_poc/`。

## geodiff が触らないもの（`sqlitedriver.cpp`）

- `gpkg_*`・`rtree_*`・`sqlite_sequence` は**チェンジセットの対象外**
- apply の前にトリガを落とす。**rtree の再構築も `gpkg_contents` の extent 更新もしない**

→ rebase の後はアプリ側で `SpatialIndexManager.createSpatialIndex()` と `updateLayerEnvelope()` を回す。
どちらも既にある。

## 同期モデル

3-way には **base（最後に同期が成立した時点の写し）**が要る。Drive はただのファイル置き場なので、
base は端末ごとにローカルで持つ。

```
<プロジェクト dir>/.sync/base/<相対パス>.gpkg   ← 同期対象から除外。Drive には上げない
```

| 状態 | 処理 |
|---|---|
| local だけ変更 | upload → base を local の写しに |
| remote だけ変更 | download → base を写しに |
| **両方変更** | remote を一時ファイルへ download → `rebase(base, remoteTmp, local, conflict.json)` → local に両方が載る → upload → base を写しに |
| 追加・削除・移動 | 今までどおりファイル単位 |

取り違えを防ぐため、upload の直前に Drive の `modifiedTime`（できれば `headRevisionId` / `md5Checksum`）を
同期開始時の値と比べ、変わっていたらもう一周する。Drive は版を残すので取りこぼしても復元できる。

差し込む場所は `SyncConflictResolver.executeMerge()` の「local も remote も modified」の枝。
判定側 `checkSyncStatusDetail()` はそのまま。

### アプリ側の前後処理

1. `flushChanges()` → 接続を閉じる（geodiff は自前の sqlite で開くので、こちらの書き込みトランザクションが無い状態にする）
2. `rebase`
3. 再オープン → 変わったテーブルの rtree を作り直す → `gpkg_contents` の extent を更新
4. レイヤ再読込（「削除したフィーチャの残留」対策で入れた「未ロードのレイヤだけ読み直す」条件に注意。ここは**強制**で読み直す）

### 衝突

geodiff は同じ行・同じ列の衝突を**ローカル優先**で解き、`conflict.json` に残す。
アプリはそれを通知（テーブル・fid・列・base/old/new）に出す。「相手の値を採用」は後回し。

## 対象外

- **web**: geodiff の wasm ビルドは無い。web は「読むだけ」へ降格する方針なので、web ではマージしない
  （ファイル単位の現行動作のまま）
- **`.qgs`**: maplayer / tree ノード単位の別の 3-way（[[project-format-design]] 7 条）
- 写真などバイナリ

## Android ビルド

- geodiff は**外部 SQLite3 必須**（内蔵オプションは削除済み）。session 拡張と preupdate hook を有効にした
  sqlite3 が要る（vcpkg なら `sqlite3[session]`）。libgpkg はビルド時に自動取得。C++17
- 実例は Mergin Maps の [mobile-sdk](https://github.com/MerginMaps/mobile-sdk)：vcpkg、`vcpkg-overlay/ports` に geodiff の port、
  triplet `arm64-android` / `arm-android`、NDK 25、API 24
- 成果物 `libgeodiff.so` は `android/app/src/main/jniLibs/<abi>/` に置く（arm64-v8a・armeabi-v7a。x86_64 は要らない、実機主義）
- ホスト VM のテストのために `x64-windows` の `.dll` も作る（sqflite_common_ffi と同じ流儀）
- Dart 側は `dart:ffi` ＋ ffigen で `geodiff.h` から生成。使うのは
  `createContext` `CX_destroy` `CX_lastError` `CX_setTablesToSkip` `createChangeset` `hasChanges`
  `changesCount` `listChangesSummary` `rebase` `makeCopySqlite` `version` くらい。
  戻り値は `0 成功 / 1 失敗 / 2 衝突あり / 3 未対応の変更`

## 段取り

1. Android で `libgeodiff.so` をビルドし、アプリから `GEODIFF_version()` を呼ぶ（ビルドが本丸）
2. Dart バインディング＋ホスト VM のテスト（PoC と同じ A/B/衝突の 3 本）
3. base の保持と `executeMerge()` への差し込み
4. rtree / extent の後処理と強制再読込
5. Pixel 9 ＋ web（読むだけ）ではなく、**Android 2 台**で同じ gpkg を同時に編集して往復

## 未決

- base の置き場（`.sync/base/` 案）と Drive 除外の実装
- `gps_history.gpkg`（グローバルフォルダ）にも使うか
- 衝突 UI（通知止まりか、相手の値を選べるようにするか）
