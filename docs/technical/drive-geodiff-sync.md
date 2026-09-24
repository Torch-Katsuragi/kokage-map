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

## 実装状況（2026-09-24）

| 段 | 状態 | どこ |
|---|---|---|
| 1 ビルド | 済 | `third_party/geodiff/`、`android/app/src/main/jniLibs/arm64-v8a/libgeodiff.so`、`third_party/geodiff/windows/geodiff.dll` |
| 2 バインディング | 済 | `lib/services/geodiff/`（ffi + web stub）。`test/geodiff_rebase_test.dart`、`integration_test/geodiff_smoke_test.dart` |
| 3 base と差し込み | 済 | `SyncBaseStore`（`.sync/base/`）、`GpkgMerger`、`MergeChoice.merge`、`SyncConflictResolver._mergeGpkg()` |
| 4 後処理 | 済 | `GeoPackageConnection.closeAllFor()`、`GpkgIndexRepair`、`GeoPackageNode.reloadLoadedLayers()` |
| 5 2 台で往復 | 済（偽 Drive） | Pixel 9 + Pixel 11 Pro Fold で `tool/sync_relay/run_two_device.sh`。本物の Drive での往復は未 |

base は「gpkg を Drive と上げ下ろしした直後」に写す（push / pull / executeMerge の upload・download・merge の全経路）。
base が無い gpkg（この版より前に同期したもの）は、次に上げ下ろしした時点から持てるようになる。
それまでは両方 modified でも `mergeable=false` で、いままでどおり端末／クラウドの二択。

### 後処理（段4）

- **接続を閉じてから geodiff に触らせる。** geodiff は SQLite を静的リンクしているので、同じプロセスに
  アプリ側（Android の SQLite）と 2 つの SQLite が同居する。同じファイルを両方で開いていると、片方が閉じた瞬間に
  もう片方のロックが外れる（https://sqlite.org/howtocorrupt.html 2.2.1）。`GeoPackageConnection` に開いている
  接続の台帳を持ち、rebase・base の写し・Drive からの上書きダウンロードの前に `closeAllFor()` で閉じる。
  閉じた接続は次の `getDatabase()` で開き直る
- **rtree と範囲を焼き直す。** アプリは書き込みのために rtree の ST_ トリガーを落としているので、rebase で入った行は
  rtree に載らない。描画は rtree を使わないが QGIS は使う（行が消えて見える）。`GpkgIndexRepair` が rtree を
  実データから焼き直し、`gpkg_contents` の範囲（rtree から出している）と `gpkg_ogr_contents` の件数を合わせる
- **フィーチャを読み直す。** 同期後のツリー更新はレイヤ構造しか見ず、既存の LayerNode を使い回していた。
  読み込み済みレイヤだけ `updateChildren()` を呼び直す。merge だけでなく、既存の上書きダウンロードでも古いフィーチャが残っていた

### Android の SQLite には rtree が無い（2026-09-24）

Android 本体の SQLite（sqflite が使う）は rtree モジュールを持っていない（Pixel 9 / Android 17 で `no such module: rtree`）。
地物テーブルは読み書きできるが、QGIS 製の gpkg の `rtree_*` には触れない。`GpkgIndexRepair` は行と範囲を sqflite で読み、
rtree への書き込みだけ geodiff に入っている SQLite（`SQLITE_ENABLE_RTREE` 付き、`libgeodiff.so` が `sqlite3_*` を外に出している）で行う
（`Geodiff.execSql()`）。範囲も rtree から読まず、Dart で出した値を書く。実機で確認（`integration_test/gpkg_rtree_android_test.dart`）。

同じ理由で、**既存の `SpatialIndexManager.updateRTreeIndex`（編集のたびの rtree 更新）と
`QgisInterop.updateContentsBounds`（範囲を rtree から出す）も Android では効いていなかった**。
QGIS 製の gpkg を Android で編集して QGIS に戻すと、足した・動かした地物が空間索引に載らない（実機で再現）。
→ `GeoPackageFile.dispose()` の最後（接続を閉じたあと）で `GpkgIndexRepair.rebuildFile()` を呼び、
rtree と範囲を実データから焼き直すようにした。同じファイルを別の接続がまだ開いていれば最後に閉じる側に任せる。
rtree の無い gpkg（このアプリで作ったもの）は何もしない。編集のたびの更新は今も Android では失敗する（警告ログ）が、
閉じた時点で辻褄が合う

### 速さ（2026-09-24、`test/support/geodiff_bench.dart`）

森林簿を想定した面 2 万筆（各 12 頂点、属性 10 列、rtree 付き、12.6MB）。各側 50 行を変えて rebase。

| | base の写し | rebase | 索引の焼き直し（全件） |
|---|---|---|---|
| Pixel 9（実機） | 37ms | 66ms | 270ms |
| PC（Windows、ホスト VM） | 72ms | 128ms | 188ms |

同期のたびに回しても問題にならない。base は同期した gpkg と同じ大きさの写しなので、端末の容量はその分増える。

### リモートの変更判定は Drive の時刻どうしで（2026-09-24）

以前は Drive の `modifiedTime`（サーバーの時計）と帳簿の `lastSyncedTime`（端末の `DateTime.now()`）を比べていた。
端末の時計が Δ 秒進んでいると、同期の直後 Δ 秒以内に別の端末が上げた変更を「変わっていない」と見落とし、
次にこちらが上げたときに**相手の変更を上書きして消す**。行単位マージは「両方変わった」を検出できて初めて働くので、ここが崩れると働かない。

帳簿（`KMetaSyncFile`）に `remoteModifiedTime`（同期したときの Drive 側の `modifiedTime`）を持ち、
Drive の時刻どうしで比べる（`isRemoteNewer()`）。upload の応答に `modifiedTime` を含めるよう `$fields` を指定した。
この値を持たない古い帳簿は従来の比較にフォールバックする。ローカルの変更判定（ファイルの mtime と `lastSyncedTime`）はどちらも端末の時計なので変えていない。

### 衝突したときどちらが残るか（2026-09-24 に確認）

「相手」は先に Drive に上げた端末、「こちら」は後から合わせる端末。

| 相手 | こちら | 結果 | 通知 |
|---|---|---|---|
| 別の行・別の列を直す | 別の行・別の列を直す | 両方載る | なし |
| 同じ行の別の列（例: ジオメトリと属性） | 〃 | 両方載る | なし |
| 同じ行・同じ列を直す | 同じ行・同じ列を直す | **こちらの値** | 「この端末の値を残した（クラウドは…）」 |
| 行を消す | 同じ行を直す | **消える** | 「クラウドで消されていたので消えた（この端末の値は…）」 |
| 行を直す | 同じ行を消す | **消える** | 「この端末で消したので、クラウドでの変更は捨てた」（geodiff は記録しないので、rebase の前に両側の変更集合を突き合わせて拾う） |
| 行を消す | 同じ行を消す | 消える | なし |
| 行を足す | 行を足す（fid がぶつかる） | 両方残る（fid を振り直す） | なし |

削除は常に勝つ。5 行目は geodiff が衝突を記録しないので、`GpkgMerger` が rebase の前に
相手の変更集合（base → 相手、`listChanges`）の更新と、こちらの変更集合の削除を主キーで突き合わせて `mineDeleted` として拾う。

### 合わせられないとき（2026-09-24）

geodiff は**スキーマが変わった変更集合を作れない**（`GeoPackage Table schemas are not the same for table: ...`）。
列の追加・削除、レイヤ（テーブル）の追加は、どれも `createChangeset` の段階で断られる。
その場合は手元もリモートも変えずに衝突のまま残し、`SyncResult.failedMerges` で返す。

- 手動の同期: 通知（「列の追加・削除など…端末かクラウドを選んで同期し直して」）を出し、状態を「衝突」にする
- 自動同期: 本当の衝突として扱う。同じリモートの版では再試行しない（版が変わったらもう一度試す）
- レイヤの追加でテーブルの行だけ移って `gpkg_contents` に載らない、という中途半端な状態にはならない（テストで確認）

**片側だけの列の追加はそろえてから合わせる**（ブランチ `feature/geodiff-schema-align`、判断待ち）:
rebase の前に 3 つ（base・相手・こちら）の列を見比べ、片側だけが末尾に列を足していれば、残りにも同じ列を
`ALTER TABLE ADD COLUMN` で足してから rebase する（`GpkgSchemaAligner`）。両側が同じ列を足したなら base にだけ足す。
両側が別々の列を足した、列を消した・変えた、既定値の無い NOT NULL 列、テーブルの増減は触らず、今までどおり衝突に退く。

### テスト

| どこで | ファイル | 中身 |
|---|---|---|
| ホスト VM | `test/geodiff_sync_roundtrip_test.dart` | 下の 11 本（偽 Drive、2 台を 1 プロセスで模す。端末ごとの帳簿は差し替える） |
| 実機 1 台 | `integration_test/geodiff_sync_roundtrip_test.dart` | 同じ 11 本を Android の sqflite と `libgeodiff.so` で |
| 実機 2 台 | `integration_test/geodiff_two_device_test.dart` | PC 上の偽 Drive（`tool/sync_relay/relay_server.dart`）を 2 台で共有して往復 |
| ホスト VM | `test/gpkg_index_repair_test.dart` ほか | 索引の焼き直し・`closeAllFor`・帳簿の時刻・同期ダイアログ |

11 本: 別々の行の変更／同じ行・同じ列の衝突（後から合わせた端末の値が残る）／両端末の追加で fid がぶつかる／
端末の時計が Drive より進んでいる／片方が列を足す（合わせられず衝突に退く）／片方がレイヤを足す（同）／
同じ行でジオメトリと属性／片方が消し片方が直す／両方が同じ行を消す／
base が無い gpkg は mergeable にならない／merge の前にアプリの接続を閉じる。
シナリオ本体は `test/support/geodiff_roundtrip_scenarios.dart`、偽 Drive は `test/support/fake_google_drive.dart`
（`GoogleDriveService` を `implements` + `noSuchMethod`。同期層が呼ばないメソッドを呼ぶと落ちる）。

2 台の実機:

```bash
tool/sync_relay/run_two_device.sh <端末A> <端末B>
```

テスト用ビルドは applicationId に `.geodifftest` を付けて既存のアプリと並べて入れる（普段使いの端末のデータを置き換えない）。
そのためにスクリプトが `build.gradle.kts` と `google-services.json` を一時的に書き換え、終了時に必ず戻す。
2026-09-24 に Pixel 9（A）＋ Pixel 11 Pro Fold（B）で通過：B が `local=modified remote=modified mergeable=true` を検出して
行単位で合わせ（衝突 1 件＝B の値が残る）、A が取り込み、両端末の中身が一致した。

## 段取り

1. Android で `libgeodiff.so` をビルドし、アプリから `GEODIFF_version()` を呼ぶ（ビルドが本丸）
2. Dart バインディング＋ホスト VM のテスト（PoC と同じ A/B/衝突の 3 本）
3. base の保持と `executeMerge()` への差し込み
4. rtree / extent の後処理と強制再読込
5. Pixel 9 ＋ web（読むだけ）ではなく、**Android 2 台**で同じ gpkg を同時に編集して往復

## 未決

- `gps_history.gpkg`（グローバルフォルダ）にも使うか
- 衝突 UI（通知止まりか、相手の値を選べるようにするか）。いまは後から合わせた端末の値を残して通知だけ
- 本物の Drive での 2 台往復（Drive のサインインが要るので人の手が要る）
- ⚠ 同期の帳簿（`SyncLedger`）のキーが `drive:<driveId>` なので、**1 台の端末で同じ Drive フォルダを
  2 つのローカル dir にクローンすると帳簿が衝突する**（2 台テストを 1 プロセスで模したときに踏んだ。実運用では稀）
