---
title: 地物の写真（撮る・付ける・QGIS で見る）
tags: [features, photo, qgis, interop]
---

# 地物の写真（2026-10-11）

現場で撮った写真を点・線・面に付ける。機能一覧の #3。QGIS で開いても写真が属性フォームに出ることを優先して形を決めた。

## 使い方（UI）

- 情報パネル（地物を選んだとき）の「写真」の行: **写真を撮る**（端末のカメラアプリ）と **写真を選ぶ**（ギャラリー）
- 編集パネルの「属性」にも同じ行がある。写真はその場で付け外しし、保存・取消を待たない。写真の列は文字の欄には出さない
- 付けた写真は縮図で並ぶ。タップで全画面（`showPhotoViewer`）、長押しで外す（「外すだけ」か「ファイルも消す」）
- 情報パネルの属性の行には写真の列（`photo`・`photo_N`）を出さない（縮図で出すので）
- 読み取り専用レイヤ（shp・GeoJSON など）は列を足せないので、編集と同じく「gpkg に変換して編集」を出す

実装は `lib/widgets/feature_photo_strip.dart`（UI）、`lib/services/feature_photos/`（置き場所・列・EXIF）。

## 撮る: 端末のカメラアプリ

`image_picker` の `ImageSource.camera`（Android は `ACTION_IMAGE_CAPTURE`）。アプリ内にカメラ画面は持たない。

- 画質・露出・ピントはカメラアプリ任せでよく、CameraX の面倒を持たない
- `CAMERA` 権限は `mobile_scanner`（QR 読み取り）が既に宣言している。宣言があると Android は撮影インテントにも
  実行時の許可を求めるので、`image_picker_android` が初回に許可を聞く（QR で許可済みなら聞かない）
- `image_picker` は写真を受け取るための FileProvider を足すだけで、新しい権限は増えない。Play の申告（写真と動画の権限）も変わらない
- 縮小・再圧縮はしない（`maxWidth` 等を渡さない）。カメラアプリが書いた EXIF（向き・日時・機種）はそのまま残る

「選ぶ」は Android ならギャラリーの取り込みと同じアプリ内のギャラリー（`PhotoPickerScreen`。原本を読むので位置の EXIF が残る）。
web は `image_picker` の複数選択（ファイル入力）。web の「撮る」も `image_picker_for_web` が `capture` 付きのファイル入力にするので、スマホのブラウザならカメラが開く。

## 位置（EXIF GPS）

撮った JPEG に GPS の緯度経度が無ければ（カメラアプリの位置情報が切ってある）、アプリの GPS の今の位置（`GpsManagerService.currentInfo`。外部 GNSS も含む）を
EXIF に書き込む（`ExifGpsWriter`）。

- 規格どおり RATIONAL ×3（度・分・秒）で書く。`image` の `setGpsLocation` は DOUBLE 型で書き、読めない読み手がある（このアプリの `ExifParser` も RATIONAL しか読まない）
- APP1 だけ差し替え、画素は描き直さない。向き（Orientation）など他の EXIF は残る
- カメラアプリが位置を書いていれば触らない。ギャラリーから選んだ写真には書かない（別の場所で撮った写真かもしれない）

## 置き場所

```
<gpkg の dir>/photos/<レイヤ名>/<yyyyMMdd_HHmmss>_<fid>.jpg
```

- gpkg の隣に置く。dir ごと渡せば写真も付いていく（Drive 同期の単位と同じ）
- レイヤ名の `\ / : * ? " < > |` は `_` に。同じ秒の 2 枚目は `_1` を足す
- ギャラリーから選んだ写真の日時は撮影日時（`AssetEntity.createDateTime`）

## 付け方: 属性に相対パス（QGIS の ExternalResource）

| 列 | 値 |
|---|---|
| `photo` | 1 枚目。`photos/林小班/20261011_093012_12.jpg` |
| `photo_2`, `photo_3`, … | 2 枚目から |

- **gpkg の dir からの相対パス**、区切りは `/`。QGIS・QField の「添付（ExternalResource）」の普通の形（1 列 1 ファイル、プロジェクトからの相対）
- 複数枚は列を増やす。`;` 区切りで 1 列に詰めると QGIS の欄で写真が出ないため。1:N の別テーブル（QGIS のリレーション）は重いので採らない
- 列は要るときに作る（TEXT）。空いた写真の列があればそこへ入れる（外したあとの穴を埋める）
- `photo` 列が既にあれば（QGIS で作ったもの）そのまま使う。値が絶対パスでも開ける

## `.qgs` に写真の欄を書く

アプリが作った写真の列は、フォルダ設定（`kokage/meta`）の `photoFields`（レイヤキー → 列名）に覚える。
`.qgs` を書くとき、その列にだけ `<fieldConfiguration>` の `ExternalResource` を書く（`lib/services/qgis/qgs_photo_widget.dart`）。

- gpkg が `.qgs` と同じ dir: `RelativeStorage=1`（プロジェクトからの相対）
- gpkg が下の dir（子 dir のレイヤも写す `.qgs`）: `RelativeStorage=2`（既定のパスからの相対）にし、既定のパスを
  data-defined の式 `@project_folder || '/<dir>'` で与える。値はどの `.qgs` から開いても同じ（gpkg の dir からの相対）のまま
- ユーザーが QGIS で別の欄（ValueMap・TextEdit など）にした列は触らない。触るのは欄の指定が無いか空（QGIS の既定は `type=""`）か、既に ExternalResource のときだけ
- ユーザーが自分で作った `photo` 列（`photoFields` に無い）には書かない

> [!NOTE] QGIS 4.2.2 で確かめた（2026-10-11、開発機の PyQGIS を headless で）
> QGIS 自身に ExternalResource を設定させた `.qgs` の形と突き合わせて書き、アプリが書いた `.qgs` を `QgsProject.read()` → 編集ウィジェットを
> 作って地物を渡した。同じ dir の gpkg は `relativeStorage=1`、`sub/` の gpkg は `defaultRoot=<プロジェクト>/sub`（式が解けている）になった。
> `configurationFlags` は付けない（3.44 は `NoFlag`、4.2 は `0` と書き方が違う。無くても読める）。
> 画面に写真が出るところ（ドキュメントビューア）は GUI での目視が残っている。

## レイヤ一覧と地図での見え方

`photos/` は普通のフォルダとして一覧に出し、写真は今までどおり `ImageNode`（位置があれば地図に写真の印）になる。特別扱いはしない。

- 隠すと「Drive では見えるのにアプリで見えないフォルダ」ができ、移動・削除の扱いを別に持つことになる
- 写真の印と地物の縮図の両方に出るが、どちらも同じファイルなので食い違わない
- 付けた直後に gpkg の dir → `photos` → `<レイヤ>` を読み直す（`FeaturePhotoService.refreshTree`）

## Drive 同期

`*.jpg` は同期の対象（`SyncFileOperations.syncPatterns`）で、下の dir もたどるので `photos/<レイヤ>/` も一緒に上がる・下りる。
点で始まらない名前なので `isHiddenPath` にも当たらない。

## まだやっていないこと

- レイヤの改名で `photos/<旧名>/` と値は付いてこない（値が相対パスなので写真は開ける。新しく撮ったものは新しい名前の dir に入る）
- 地物を消しても写真のファイルは残る
- カメラアプリから戻る間にアプリのプロセスが落ちたとき（メモリの少ない端末）の取り戻し（`ImagePicker.retrieveLostData`）
- 縮図の並べ替え

関連: [[../technical/qgis-interop|QGIS相互運用]]、[[drawing-editing|描画・編集]]
