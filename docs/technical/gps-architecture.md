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

## 向きは真北基準にそろえる（磁気偏角）

地図・GPS の進行方向・地点への案内の方位は真北基準。磁北基準で届く値は、使う前に一度だけ偏角を足して真北に直す。
紀伊半島の偏角は西偏 約 7.9°（北山村 33.93N 135.96E、2026.8 で −7.88°）なので、直さないとその分だけ向きがずれる。

| 値 | 基準 | 直す場所 |
|----|------|----------|
| 端末のコンパス（flutter_compass、Android） | 磁北 | `map_initialization_mixin.dart` の `initializeCompass`（`headingNotifier` には真北の値が入る。扇・案内の矢印・GPS パネルの方位はここから読む）、`level_screen.dart` |
| TruPulse の方位角 | 磁北（本体 dECLn = 0 の前提） | `TruPulseTool.trueAzimuth`（点の位置を出すときだけ。属性 `survey_az` は本体の値のまま） |
| GPS の進行方向（course） | 真北 | 直さない |

- 偏角は `lib/utils/wmm_declination.dart`（WMM2025、12 次の球面調和関数、測地→地心の変換、経年変化は小数年で一次補間）。直すのは `lib/utils/true_heading.dart`（`TrueHeadingConverter`: 10 km 以上動くか日付が変わったら出し直す。位置が一度も分からないうちは直さない）
- 係数は NOAA NCEI の `WMM2025COF.zip`（https://www.ncei.noaa.gov/sites/default/files/2024-12/WMM2025COF.zip）内の `WMM.COF`。SHA-256 `dfa8597825af4e0b87ff4198a5b4fb661b3c49f4cd090cd0164e0259b075582f`。public domain
- 検算は `test/wmm_declination_test.dart`: 同梱の `WMM2025_TestValues.txt` 100 点と技術報告の 12 点（`WMM2025_TEST_VALUES.txt`）を ±0.01° で、北山村を NOAA のオンライン計算機の値（−7.87666°）と、国土地理院の偏角一覧 2020.0 年値（西偏 7°30′、±0.5°）と照らす
- 有効期間は 2025.0〜2030.0
- **TODO(2030)**: WMM2025 は 2030.0 で期限切れ。WMM2030 が出たら `WMM.COF` を差し替え、係数表・SHA・テスト値を更新する
- TruPulse 本体の偏角設定（dECLn）はシリアルで読めない。アプリが偏角を足すので、本体は 0 のままにする（[[../devices/trupulse-360r]]）

## デバッグ時の確認ポイント

- `source_type`カラムの値: `GPS`（内蔵GPS）または`GNSS`（外部GNSS）
- フォアグラウンドサービスのログ: 常に内蔵GPSのみを使用
- メインisolateのログ: 外部GNSS使用時のデータ取得状況
- 属性テーブルでの確認: 外部GNSS使用時は`source_type = 'GNSS'`になっているか

## 関連ドキュメント

- [[foreground-service]] - フォアグラウンドサービス・Bluetooth制約
- [[../features/gps-map]] - GPS・地図機能

