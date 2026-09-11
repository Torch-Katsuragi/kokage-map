---
title: QGIS相互運用
tags: [technical, geopackage, qgis, interop]
---

# QGIS相互運用

こかげマップ は「ユーザーの `.gpkg` をそのまま読み書きする」ことを identity にしている
（[[../features/concept|コンセプト]]）。変換もパッケージ化も要求しないのが競合に対する差なので、
**編集して返したファイルが QGIS で普通に開けること**が要件になる。

ここは「編集中には邪魔だが QGIS 側では必要」というものの面倒を見る仕組み。
実装は `lib/models/geopackage/qgis_interop.dart`、テストは `test/qgis_interop_test.dart`。

## `.qgs` はいつ書かれるか（2026-09-06）

- `.kmeta.json` が保存されるたび（可視性・スタイル・View・並び順の変更）、3秒のデバウンス後に
  root の `<dir名>.qgs` を `QgsAutoRefresh` が DOM 保持型で更新する
- Drive push の直前に `flushNow()` で待ちを消化する
- プロジェクトを開いたとき `.qgs` が無ければ、その場で最初の1本を作る（`QgsReadBack.run` が schedule する）
- 手動の「QGISプロジェクトを書き出す／取り込む」メニューは 2026-09-06 に撤去した（自動追従と読み戻しで不要）
- 失敗は logcat の `[QgsAutoRefresh]` に出るだけで通知しない（手動書き出しで再現できる）
- **逆方向**: プロジェクトを開いたとき `QgsReadBack` が root と子 dir の `.qgs` を見て、印（`kokage/savedAt`）と
  root の `saveDateTime` が食い違えば（＝QGIS が後から保存した）寛容インポータで View・スタイル・可視性を
  取り込み、続く自動更新で正規化＋印つきに書き戻す。ログは `[QgsReadBack]`
- **子 dir**: 自分の `.kmeta.json` を持つ子 dir は `<子dir名>.qgs` を持ち、親の `.qgs` には
  `layer-tree-group embedded="1" embedded_project="./子/子.qgs"` と `<maplayer embedded="1">` スタブで載る
  （`QgsProjectBuilder.writeTo` が子から先に書く）。QGIS 側では埋め込みグループは読み取り専用

## いつ走るか

`GeoPackageFile.dispose()` の中、**全ての書き込みが終わったあと・DBを閉じる直前**。

```
dispose()
  ├ flushChanges()              保留中の変更を書ききる
  ├ clearPendingChanges()
  ├ _finalizeForQgis()          ← ここ
  │   ├ QgisInterop.syncAllLayers()   範囲と件数を実データに合わせる
  │   └ qgisInterop.restoreTriggers() SpatiaLiteトリガーを戻す
  └ _connection.dispose()
```

> [!WARNING] トリガー復元は必ず最後
> 復元後に書き込むと、sqflite に `ST_IsEmpty` 等が無いため落ちる。
> 順序を入れ替えないこと。

## `.qgs`（QGISプロジェクト）の書き出し

実装は `lib/services/qgis/`、テストは `test/qgs_writer_test.dart`。
設計の背景は [[project-format-design#View の導入]]。

```
QgsProjectBuilder   ツリーを辿って QgsProject を組み立てる（DB・FSに触る）
QgsProject / QgsLayer / QgsGroup   XMLと切り離した表現
QgsWriter           XMLにする（純粋関数。DBもFSも要らないのでテストしやすい）
QgsDocument         既存の .qgs を読み、自分の管轄だけ差し替えて書き戻す（DOM 保持型・2026-09-06）
```

> [!IMPORTANT] 書き出しは「上書き」ではなく「更新」（2026-09-06）
> `<dir名>.qgs` が既にあれば `QgsDocument.apply()` で読み込み、レイヤツリー・maplayer の参照と
> フィルタ・単一シンボルの色と太さ・`<layerorder>` だけを差し替える。QGIS 側で足した
> 印刷レイアウト・フィールド設定・単一シンボルの細部（破線・オフセット等）はそのまま残る。
> 単一シンボル以外のレンダラは触らず、件数を通知する。プロジェクトに無くなったレイヤは外して名前を通知する。
> `properties/kokage/` に印（`schemaVersion` `app` `savedAt` `dirName`）を書き、root の
> `saveDateTime` を同じ値にする。両者が一致していれば「最後に書いたのはこかげマップ」、
> 違えば QGIS が後から保存した、と読める。テストは `test/qgs_document_test.dart`。

対応:

| こかげマップ | QGIS |
|---|---|
| dir | レイヤグループ |
| GeoPackage | レイヤグループ |
| Layer | レイヤグループ |
| **View** | **レイヤ**（`layer-tree-layer` + `maplayer`） |

View だけがレイヤになるので **1:1 対応**が成立する。View のフィルタは OGR の
データソースURIに `|subset=` として載る（QGIS が subset string を書く場所と同じ）。

出力先は `<dir>/<dir名>.qgs`（2026-09-06 に `project.qgs` から改名。旧名が残っていれば
新名に改名して引き継ぐ）。**連携dirごとに1本**置く。パスは相対
（`<Absolute type="bool">false</Absolute>`）なので、そのdirを丸ごと渡された人が
そのdirだけで開ける。

> [!IMPORTANT] レイヤIDは決定的に作る
> 生成のたびに変わると `.qgs` の差分が毎回出て、Drive同期が無駄に動く。
> View のキーをサニタイズしたものに、キーのハッシュを添えている。
> ⚠ ハッシュは `stableHashHex()`（MD5）。以前の `String.hashCode` は VM と dart2js で値が違い、
> **web と Android で同じ View に別の id が付いていた**（2026-09-06 修正）。
> ⚠ `viewKey` は dir を含まないので、同名 gpkg が root とサブ dir にあると衝突する。
> ハッシュには gpkg の相対 dir を混ぜている（同日修正。QGIS は同じ id のレイヤを1つに畳む）。

> [!NOTE] QGIS 3.44.12 で実開封を確認済み（2026-08-26）
> ```
> read() = True
> --- '既定'        valid=True  count=12  crs=EPSG:4326
> --- '大きい区画'  valid=True  count=6   subset='area > 105'
>                   symbol=SimpleMarker color=#1e90ff
> [group] 林小班.gpkg → [group] rinshoban → [layer] 既定 / 大きい区画
> ```
> 相対パスの解決・subsetの適用（12→6）・レンダラの読み取り・グループ構造の
> いずれも意図どおり。

### QGISで確かめる手順

開発機にはQGISが**インストールされていない**（管理者権限が要るため）。
代わりにMSIを展開しただけのものを使っている。

```powershell
# 1. MSIを取得（署名がOSGeo財団のものであることを確認すること）
curl -L -o .temp/QGIS-LTR.msi https://download.osgeo.org/qgis/win64/QGIS-OSGeo4W-3.44.12-1.msi
Get-AuthenticodeSignature .temp\QGIS-LTR.msi   # Status が Valid であること

# 2. 管理者権限なしで「展開だけ」する（/a = 管理インストール）
msiexec /a .temp\QGIS-LTR.msi /qn TARGETDIR=C:\Users\<user>\qgis-extract

# 3. PyQGIS で開かせる
& 'C:\Users\<user>\qgis-extract\QGIS 3.44.12\bin\python-qgis-ltr.bat' `
    tool/qgis/check_qgs.py <project.qgs>
```

⚠ `winget install OSGeo.QGIS_LTR` は配信サービス側のエラー（0x8a15006d）で
落ちることがある。そのときは上のように直接MSIを取る。
⚠ `msiexec /i` は `Error 1925`（管理者権限が無い）で失敗する。`/a` なら通る。

書かないもの（`QgsProject.skipped` に入り、通知に出る）:

- 写真（`ImageNode`。QGIS には写真の概念が無い）
- GeoTIFF でないオーバーレイ画像（png/jpg は位置を QGIS に伝えられない）

オーバーレイ画像のうち **GeoTIFF（.tif/.tiff）はラスタレイヤとして書く**（2026-09-11）。
位置は `.tif` の GeoTIFF タグに焼き込み済み（`GeoTiffWriteScheduler`）なので、`.qgs` には
`provider=gdal` の参照（相対パス）だけを書き、レンダラ（`<pipe>`）は書かない。QGIS は読込時に既定の
レンダラを付ける。DOM 保持型の更新では参照と名前だけ直し、QGIS が付けた `<pipe>` は残す。
読み戻し（インポータ）はラスタを黙って飛ばす。⚠ QGIS での実開封は未確認（XML の形は `test/qgs_raster_test.dart`）
- プロジェクトフォルダの**外**を参照する `.gpkg`
  （渡された相手の環境には無いので、残すと「レイヤはあるが表示されない」になる）

## `.qgs` の読み込み（寛容側）

実装は `lib/services/qgis/qgs_importer.dart`、テストは `test/qgs_importer_test.dart`。

**一度読んで変換して捨てる。** `.qgs` を正典として持たない。
`<maplayer>` を1枚ずつ見て、飲めるものを View にする。

ルール:

1. **root外への参照は丸ごと捨てる。** `C:\work\data.shp` やPostGIS接続を指すレイヤは
   山の中のスマホでは開けない。残すと「レイヤはあるが表示されない」最悪の状態になる
   - ⚠ 相対パスで root 外を指すケース（`../shared/kyoyu.gpkg`）は林業では現実にありそう。
     判定は**正規化した絶対パス**で行う
2. **QGISのグループ階層は採らない。** レイヤ構造は dir 構造に置き換える
   （`.gpkg` の実在パスで既存ツリーのレイヤに突き合わせる）
3. **生き残った参照のスタイルは View として再利用する。**
   同じレイヤを指すQGISレイヤがN枚あれば **N個の View** になる。
   ここが View を入れた最大の理由で、これが無いと「1枚選んで残りを捨てる」しかなかった
4. **捨てたものは必ず報告する**（`QgsImportResult.discarded` → 通知）

> [!IMPORTANT] 取り込んだレイヤの View は丸ごと置き換える
> 何度読んでも増えないようにするため。`.qgs` に出てこなかったレイヤは触らない。

> [!IMPORTANT] テスト用 fixture は QGIS 本体に書かせたもの
> `test/fixtures/qgis_3_44_written.qgs` は `tool/qgis/write_fixture.py` を
> PyQGIS で走らせて作った**本物**。手で書いたXMLでは気づけない差がここで出る。
> 実際、これを入れて2件見つかった:
>
> - 色に浮動小数表記が付く: `30,144,255,255,rgb:0.1176471,0.5647059,1,1`
> - `<layer>` の中に `<data_defined_properties>` があり、そこにも
>   `name="name"` の `<Option>` が入っている。再帰で読むと本物の値を潰す
>
> QGISのバージョンを上げたら fixture を作り直すこと。

> [!NOTE] 読み取りは寛容に
> - シンボルのプロパティは QGIS 3.x の `<Option name= value=>` と、
>   それ以前の `<prop k= v=>` の**両方**を読む。他人のファイルは古い形式で来る
> - 拾うのは単一シンボルの1レイヤ目だけ。重ね合わせや分類分けの完全再現は狙わない。
>   狙うと「開けるファイルを選り好みする」方向に行く（コンセプトと逆）
> - `subset` は `|` で切らずに**最後まで丸ごと**取る（SQLの `||` で壊れるため）

読み込み口はファイル選択ダイアログではなく「**このフォルダの中の `.qgs`**」。
共有の単位が dir なので、それで足りる。複数あれば `project.qgs` を優先。

## 1. SpatiaLiteトリガーの復元

QGIS/GDAL 製の GeoPackage は RTree を自動更新するトリガーを持ち、
それらは `ST_IsEmpty` / `ST_MinX` 等の **SpatiaLite 関数**を使う。
sqflite にその拡張は無いので、こかげマップ は書き込み前にトリガーを落とし、
rtree は `SpatialIndexManager` が自前で更新している。

> [!IMPORTANT] 落としたまま返してはいけない
> トリガーが無いまま QGIS に戻すと、**その後 QGIS で編集しても空間インデックスが
> 更新されない**。インデックスと実データがズレて、空間検索の結果が欠ける。

対処: 落とす前に `sqlite_master` の `sql` を控えておき、クローズ時に**逐語的に**戻す。

規格から生成し直さない理由は、RTreeトリガーの構成が GDAL のバージョンで違うため
（`update1`〜`update7` 等）。生成し直すと元と違うものを書き込むことになる。

⚠ アプリが強制終了した場合は控えが失われ、トリガーが落ちたまま残る。
これは対処前と同じ状態なので退行ではないが、既知の穴。

## 2. `gpkg_contents` のバウンディングボックス

QGIS はここをレイヤの範囲として使う。空だと「レイヤにズーム」が効かない。

こかげマップ は新規レイヤ作成時に `min_x`/`min_y`/`max_x`/`max_y` を null で入れていたため、
クローズ時に rtree から集計して埋める。

rtree が無い場合はスキップする（全件走査は重く、こかげマップ は rtree を自前で維持しているので通常は存在する）。

## 3. `gpkg_ogr_contents` のフィーチャ数

GDAL 拡張の件数キャッシュ。こかげマップ が直接 INSERT/DELETE すると実態とズレる
（GDAL 製ファイルにはこれを維持するトリガーもあるが、上記1で一緒に落ちることがある）。

存在しない GeoPackage もあるので、**無ければ何もしない**。
こかげマップ が勝手に作ると、逆に GDAL の前提を崩す可能性がある。

## 既にQGISに合わせてある点

- **主キーは `fid`**（QGIS/GDAL標準）。旧 こかげマップ 形式の `id` も読める
- 任意の EPSG コードに対応（GPKG内蔵WKTから座標系を自動検出）

## 未対応

- **`layer_styles`**（QGISのスタイル保存テーブル）。こかげマップ で設定した色・線幅は
  QGIS に引き継がれない。逆も同様
- `gpkg_metadata` / `gpkg_metadata_reference`

## テストの注意点

`test/qgis_interop_test.dart` は GDAL 製 GeoPackage を模したフィクスチャを作って検証する。

> [!WARNING] フィクスチャには `PRAGMA user_version = 1` が必要
> 実物の GeoPackage は `user_version=1`（GDAL製・既存ファイルで確認済み）。
> これを立てないと sqflite が「新規DB」とみなして `onCreate` を走らせ、
> 既存テーブルと衝突して `table gpkg_spatial_ref_sys already exists` で落ちる。

## 関連

- [[../features/concept|コンセプト]]
- [[testing|テスト構成]]
