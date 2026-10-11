---
title: GPS・地図機能
tags: [features, gps, map]
---

# GPS・地図機能

## GPSトラッキング

- 現在位置表示
- 移動軌跡の記録（`GpsHistoryRecorder`。グローバルフォルダの `gps_history.gpkg` の `gps_tracks` に区間ごとの線、点の詳細は `gps_track_details`）。
  10 分以上空いたら新しい区間（`2026_10_12 #2`）
- GPS精度、速度などの情報表示
- **内蔵GPS使用**: フォアグラウンドサービスで継続的に記録
- **外部GNSS使用**: フォアグラウンドサービス（トリガー）+ メインisolate（データ取得）のハイブリッド方式

## 軌跡の記録の設定

設定 → GPS・測位 →「軌跡の記録」（`trackRecordingSettingProvider`、SharedPreferences の `track_recording_settings`）。
判定は `TrackPointFilter`（`lib/models/track_recording_settings.dart`、純 Dart・`test/track_recording_settings_test.dart`）。

| 設定 | 既定 | 選択肢 | 中身 |
|---|---|---|---|
| 記録の間隔 | 1 秒 | 1・2・5・10・30・60 秒 | 前の記録からこの秒数未満の測位は入れない |
| 点の最小間隔 | 指定しない（同じ座標だけ捨てる） | 1・2・5・10・20 m | これ未満しか動いていなければ入れない。ただし前の記録から 5 分経ったら入れる |
| 精度の悪い点を捨てる | ±100 m | 指定しない・10・20・50・100・200 m | 精度がこれより悪い測位は入れない（精度が分からない測位は通す） |
| 飛びの除外 | 200 km/h | 指定しない・50・100・200・300 km/h | 前の記録からこの速さを超えて動いたことになる測位は入れない。3 回続いたら 4 回目は受け入れる |

- 言葉（2026-10-12）: 測量の足切り（[[docs/technical/gps-architecture#足切り]]）の「精度の上限」は精度の分からない測位を**弾く**が、軌跡は**通す**。
  同じ名前で並んでいたので、軌跡の側を「精度の悪い点を捨てる」にし、どちらにも精度の分からない測位の扱いを添えた。「使わない」はどちらも「指定しない」。
  保存の鍵（`maxAccuracy`）はそのまま。扱いを分けているのは、軌跡は端末 GPS（精度は普通ある）の連続記録で 1 点の取りこぼしより途切れの方が困り、
  足切りは測量の点を確かな値で残すためのもので値の分からないものを通すと意味がないから

- 既定の間隔・距離は以前の動き（1 秒・同じ座標だけ捨てる）のまま。精度と飛びは以前は見ていなかったが、
  GPS を見失ったときに混じる基地局・Wi-Fi 由来の測位（±数百 m〜）とマルチパスの跳び（1 秒で 100 m 超）が軌跡に棘を作るので既定で落とす。
  200 km/h は車の移動を残せる値
- **電池**: OS への位置の要求（`distanceFilter: 0`、前景サービスは 1 秒ごと）は変えない。現在位置の表示・GPS 測量と共用なので、
  間引きは届いた測位に対してだけ行う
- 最小間隔で止まっている間に点が入らないと、10 分の空きで区間が切れてしまう（記録と、抽出画面の読み出し `segmentOf` の両方）。
  そのため 5 分（`TrackPointFilter.keepAlive`）経ったら距離を見ずに 1 点入れる
- 飛びは「前に記録した点」との比較。前の点そのものが飛んでいると後の正しい点を弾き続けるので、続けて 3 回弾いたら受け入れて基準を移す
- 区間の切れ目（10 分以上の空き）では前の点と比べない（閉じていた間の移動を飛びとみなさない）
- 設定は地図ページが `ref.listenManual` で記録係（`GpsHistoryRecorder.filter`）へ流す。変えたら次の測位から効く。
  web は軌跡を記録しないので設定も出さない

## 軌跡の GPX 書き出し

- 軌跡の抽出画面（GPS ツールの左下の軌跡ボタン、またはレイヤ一覧で `gps_tracks` を長押し →「軌跡を抽出・GPXで書き出す」）の
  「GPXで書き出す」で、選んだ時間範囲の記録した点（簡略化する前）を GPX に保存する。保存は `FilePicker.saveFile`（Android は SAF、web はダウンロード）
- 書き手は `buildTrackGpx`（`lib/utils/gpx_writer.dart`、`test/gpx_writer_test.dart`）。GPX 1.1 の `trk` / `trkseg` / `trkpt`、
  点ごとに `<ele>`（あれば）と `<time>`（UTC）。QGIS は GPX ドライバで `tracks`・`track_points` として開く
- レイヤの書き出し（GDAL）の GPX は線の形だけで点ごとの時刻が無いので、軌跡はこちらを使う
- ⚠ 標高は受信した値のまま。端末の GPS は楕円体高（日本で標高より約 40 m 高い）、外部 GNSS の NMEA は標高

## GPS測量機能

- ユーザー操作で位置を記録（Point/Line/Polygon作成）
- 長押し測量による平均化機能
- **内蔵GPS・外部GNSS両対応**（メインisolateで動作）

## 外部GNSS機器対応

- SSP（Secure Simple Pairing）対応のBluetooth GNSS受信機との接続
- NMEAデータの解析と位置情報変換
- 高精度測位（RTK対応機器使用時）
- **重要**: 外部GNSS機器はメインisolateでのみ使用可能（詳細は[[../technical/foreground-service]]参照）

## 背景地図

- 自前の地図面（`TerrainMapLayer`、[[../technical/terrain-3d]]）で、地理院タイル・OpenStreetMap などを重ねて描く。URL で XYZ / WMS を足せる
- オフラインタイルマップ (MBTiles。⚠ Android のみ — web には端末内タイルキャッシュが無い)

## 地図操作

- パン、ズーム (ピンチイン/アウト)
- 回転
- 現在位置へ移動
- 現在位置が画面外にあるときは、地図の縁に方向を示す矢印を表示（タップでジャンプ）。
  ドロワーに隠れている部分は「見えていない」扱い
- 任意地点へのジャンプは `MapJumpMixin`（`lib/screens/map_page/mixins/map_jump_mixin.dart`）に集約。
  起動時の現在位置ジャンプ・ドロワー/属性テーブルからの移動・矢印タップはすべてここを通す
- 地点への案内（「ここへ案内」）: 状態は `guidanceProvider`（`lib/providers/guidance_providers.dart`、メモリだけ。再起動で消える）、
  計算は `NavigationMath`（`lib/utils/navigation_math.dart`）。位置は地図ページが既存の GPS 更新から `feedGuidance()` で流す（自前のタイマー無し）。
  札は `GuidanceOverlay`、目標への線は 3D 地図面の動的シーン（`terrain_map_layer_scene.dart` の 2.5）。
  高低差は標高タイル（`VertexZ.elevationLookup`）で目標と今の位置の両方を引く（GPS の高度は楕円体高なので使わない）。
  到着は max(5 m, 精度) で通知センターへ 1 回、半径の 2 倍より離れたら再び知らせる

## 関連ドキュメント

- [[../technical/gps-architecture]] - GPS追跡・測量アーキテクチャ
- [[../technical/foreground-service]] - フォアグラウンドサービス・Bluetooth制約

