---
title: GPS追跡・測量アーキテクチャ
tags: [technical, gps, architecture]
---

# Root Mapsでの実装方針

## GPS追跡機能のアーキテクチャ

### 内蔵GPS使用時

```
[フォアグラウンドサービス（別isolate）]
  ↓ 内蔵GPS位置取得（Geolocator）
  ↓ 1秒間隔でイベント送信
[メインisolate]
  ↓ イベント受信
  ↓ データ保存（時間・距離フィルタ適用）
```

### 外部GNSS使用時（改善版）

```
[フォアグラウンドサービス（別isolate）]
  ↓ 内蔵GPS位置取得（トリガー用）
  ↓ 1秒間隔でイベント送信
[メインisolate]
  ↓ イベント受信（トリガー）
  ↓ 外部GNSSデータ取得（Bluetooth経由）
  ↓ データ保存（時間・距離フィルタ適用）
```

**重要なポイント:**
- フォアグラウンドサービスは常に内蔵GPSで動作
- 外部GNSS使用時は、フォアグラウンドサービスからのイベントをトリガーにして、メインisolateで外部GNSSデータを記録
- これにより、開始・停止処理が統一され、フォアグラウンドサービスの停止で全て止まる
- フォアグラウンドサービスが動作していない時は外部GNSS記録も発火しない

## GPS測量機能との違い

### GPS測量モード（gps_tool）

- メインisolateで動作
- 外部GNSS機器を直接使用可能
- ユーザーの手動操作で位置を記録
- フォアグラウンドサービス不要

### GPS追跡機能

- フォアグラウンドサービスで継続的に動作
- 外部GNSS使用時はハイブリッド方式（トリガー + メインisolate処理）
- 自動的に位置を記録
- バックグラウンドでも動作継続

## 実装上の注意事項

1. **外部GNSS機器の接続はメインisolateで管理**
   - GPS設定画面でのスキャン・接続
   - 接続状態の監視
   - NMEAデータの受信・パース

2. **GPS追跡時の処理分離**
   - 内蔵GPS: フォアグラウンドサービスで完結
   - 外部GNSS: フォアグラウンドサービス（トリガー）+ メインisolate（データ取得）

3. **GPS測量時の処理**
   - 完全にメインisolateで動作
   - 外部GNSS機器を直接使用可能
   - ユーザー操作に応じて位置を記録

4. **ログ出力の最適化**
   - 定期的なログ出力は削減
   - エラー発生時のみ詳細ログを出力
   - デバッグ時の問題特定を容易にする

## デバッグ時の確認ポイント

- `source_type`カラムの値: `GPS`（内蔵GPS）または`GNSS`（外部GNSS）
- フォアグラウンドサービスのログ: 常に内蔵GPSのみを使用
- メインisolateのログ: 外部GNSS使用時のデータ取得状況
- 属性テーブルでの確認: 外部GNSS使用時は`source_type = 'GNSS'`になっているか

## GNSS の品質の記録と足切り

造林補助の GNSS 竣工検査（和歌山県・石川県など）は、測位の種類・衛星数・DOP・平均化の回数の記録を求める。
現場では悪い測位をその場で弾きたい。モデルは `lib/models/gnss_quality.dart`（2026-10-11）。

### 読むもの（外部 GNSS）

| NMEA | 使うもの |
| --- | --- |
| GGA | 品質番号 → `GnssFix`（0・6・7・8 → none、1 → gps、2・3・9 → dgps、5 → rtk_float、4 → rtk_fixed）、衛星数、HDOP |
| GSA | PDOP・VDOP（HDOP も上書き） |
| GST | 緯度・経度の標準偏差 → 精度 `√(σ緯度² + σ経度²)`。5 秒受けなければ品質番号 × HDOP の見積もりに戻す |

精度の出どころは `accuracySource`（`gst`・`hdop`、端末の GPS は `device`）として測位ごとに残す。
端末の GPS は測位の種類・衛星数が分からない。画面では「GNSS(端末)」、足切りでは単独測位（gps）とみなす。

### 記録の形

測量の記録（`drawing_points` の 1 件）の `quality` に入る。点も線・面の頂点と同じ形で `kmaps_metadata` に
`{"drawing_points": [記録]}` として残す（点はこれまでどおり accuracy・hdop・satellite_count・fix_type・sample_count の列にも書く）。

```json
{"source": "GNSS", "device": "R1", "fix": "rtk_fixed", "sats": 12, "hdop": 0.6, "pdop": 1.1,
 "hacc": 0.02, "hacc_src": "gst", "avg_n": 10, "avg_s": 10.2, "spread": 0.012,
 "time": "2026-10-11T09:00:00.000", "rejected": 1, "warnings": ["..."]}
```

- 長押しの平均: 種類・衛星数は最も悪い回、DOP は最大、精度は各回の平均、`spread` は中心からの水平距離の二乗平均平方根（2 回以上）
- `quality` の無い以前の記録は、残っている `usedGpsData` から組み立てて表示する（`GnssQuality.ofSurveyRecord`）
- 情報パネル: 点は「RTK FIX・12 衛星・±0.02 m・平均 10 回」、線・面は「GNSS 測量 5/6 点・最悪 ±0.05 m・中央値 ±0.02 m・最低 RTK FLOAT」

### 足切り

設定 → GPS・測位 の「測位の品質（足切り）」（`GnssQualityGateSetting`、SharedPreferences の `gnss_quality_gate`）。
精度の上限・測位の種類の下限・衛星数の下限。どれも指定しなければ何もしない（既定）。

- 値が分からない測位は満たさないとする（検査に出せる値が無いので）。端末の GPS に衛星数の条件を付けると記録できない
- 単発: 満たさなければ記録せず、通知センターに理由を出す。「記録しない」を切れば記録して警告し、`warnings` に残す
- 長押し: 満たさない回を平均から外し（`rejected` に数）、全部外れたら記録しない。長押し中は測量ボタンの上に「8点・除外 2」

### 書き出し

書き出しのダイアログの「GNSS の品質を列に」で `gnss_fix`・`gnss_sats`・`gnss_hacc`・`gnss_avg_n` を足す
（`ImportExportService.gnssQualityColumns`）。`-sql` で GPKG の SQLite の JSON 関数（`json_each`・`json_extract`）を使う。
線・面は頂点の中で最も悪い値。壊れた JSON は NULL にして書き出しは止めない。列名は shp の 10 文字に収める。

## 関連ドキュメント

- [[foreground-service]] - フォアグラウンドサービス・Bluetooth制約
- [[../features/gps-map]] - GPS・地図機能

