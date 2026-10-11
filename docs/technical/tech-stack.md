---
title: 技術スタック
tags: [technical, stack, flutter]
---

# 技術スタック

> [!NOTE] 2026-10-11 に今の作りに合わせて書き直した
> 依存の一覧と版の正は `pubspec.yaml`。ここは役割ごとの要約。

## フロントエンド

- **Flutter (Dart)**。対象は **Android と web**（デスクトップ版は 2026-08-25 に撤去、[[../features/concept#プラットフォームの役割分担]]）
- 文言は slang（`lib/i18n/*.i18n.json`、日本語と英語）

## 状態管理

- Riverpod（v3、`@riverpod` のコード生成）

## GeoPackage

- 読み書きは `sqflite`（Android）/ `sqflite_common_ffi_web`（web、sqlite3 の WASM）で SQLite として直接扱う
- Drive 同期の行単位マージは geodiff（FFI、[[drive-geodiff-sync]]）
- gpkg 以外の形式の読み取り・変換・書き出し、ラスタのワープは GDAL（Android は FFI、web は WASM。[[gdal]]）
- QGIS のプロジェクト（`.qgs` / `.qgz`）は `xml` / `archive` で読み書き（[[qgis-interop]]）

## 地図表示

- 自前の地図面 `TerrainMapLayer`（`lib/core/terrain/`）。2D は真上から見た 3D で、2D と 3D が同じ描画系（[[terrain-3d]]）
- 地形と大量の面は `flutter_gpu`（web は WebGL2 版）、それ以外は Canvas
- MapLibre は 2026-09-11 に地図ページから外し、その後依存ごと削除した（経緯は [[scene-model]]）
- 背景タイルのキャッシュは MBTiles（Android のみ。web は端末内キャッシュなし）

## GPS・センサー

- `geolocator`（端末の GPS）、外部 GNSS は Bluetooth の NMEA（`flutter_bluetooth_serial` を手元で直した版、`third_party/`）
- 常時記録は `flutter_background_service`（[[foreground-service]]）
- コンパスは `flutter_compass`、水準器は `sensors_plus`

## Google Drive連携

- `googleapis`（Drive API v3）＋ `google_sign_in`。web は `GOOGLE_WEB_CLIENT_ID` を渡したビルドだけ（[[google-drive-setup]]）

## 位置共有

- Firebase（Realtime Database・匿名 Auth・App Check、[[location-sharing]]）

## 地図操作ツール管理

- MapTool抽象クラス＋個別ツールクラス（PanTool, PenTool, SelectTool等）＋GlobalConfigで一元管理。

## 入力デバイス判別

- PointerEventのkindプロパティでペン/タップ/マウスを判別し、ツールごとに挙動を分岐。

---

# フリーハンド描画の実装詳細

フリーハンドでの線・領域描画は、以下のFlutter技術要素を組み合わせて実装する。

## ジェスチャー検出 (`GestureDetector`)

- `onPanStart`: 描画開始点を記録。
- `onPanUpdate`: ドラッグ中の座標を連続的に記録。
- `onPanEnd`: 描画終了処理、ジオメトリ確定。

## 描画処理 (`CustomPaint` と `CustomPainter`)

- 記録された座標リストに基づき、Canvasオブジェクトに線（Path）を描画する。
- `onPanUpdate`の度に`setState`を呼び出し、リアルタイムに描画を更新する。

## 座標管理

- 描画中の座標は一時的なリスト（例: `List<Offset>`）に保持する。
- 地図のズームレベルや表示範囲の変更に対応するため、画面座標と地理座標（緯度経度）の相互変換が必要 (`IMapState.mapController`＝`MapSurfaceController` 経由で地図面に投げる)。

## 線の平滑化 (オプション)

- より自然な曲線にするため、記録した座標点間にベジェ曲線やスプライン補間を適用することを検討。
- Flutterの`Path`オブジェクトはベジェ曲線描画メソッド（`quadraticBezierTo`, `cubicTo`）を持つ。

## GeoPackageへの保存

- 描画完了後、得られた地理座標のリストをLineStringまたはPolygonのジオメトリデータ（WKT: Well-Known Text や WKB: Well-Known Binary形式）に変換。
- 変換したジオメトリデータを、属性情報と共にGeoPackageの該当レイヤーにフィーチャとして保存する。

## 領域の描画

- 線の描画と同様の仕組みで境界線をフリーハンドで描画。
- 描画完了時にパスが閉じていなければ自動的に閉じるか、ユーザーに促す。
- 閉じたパスからPolygonジオメトリを生成する。

## 関連ドキュメント

- [[../features/drawing-editing]] - 描画・編集機能
- [[import-export]] - レイヤの書き出し（GDAL）
- [[gdal]] - GDAL（Android と web）

