---
title: GPS追跡・測量アーキテクチャ
tags: [technical, gps, architecture]
---

# こかげマップでの実装方針

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
- ツールバーで GPS ツールを選んでいる間は、コンパスツール（TruPulse）のステータスパネルと同様に画面右下（左利き配置では左下、線・面の確定ボタン表示中はその上）に `GpsStatusPanel` を常時表示する:
  - 内蔵 GPS 使用時: 受信状態バッジ・記録先レイヤ・現在座標・水平精度・標高・測点数（または方位）を表示
  - 外部 GNSS 接続時: 機器名と測位状態バッジ（`RTK FIX` / `RTK FLOAT` / `DGPS` / `SBAS` / `GPS` / `No Fix` / `接続中` / `未接続`）・精度（GST 標準偏差または HDOP 推定）・衛星数・HDOP・補正情報、NTRIP 受信状態、および `GnssQualityGate`（足切り条件）のリアルタイム充足警告を表示
  - パネルをタップすると `GpsSettingsScreen` が開き、ソース切替や詳細確認にすぐ移れる（`設定 → 外部機器` からも Bluetooth 外部 GNSS として接続・切断可能）
- **RTK 解状態変化の効果音**（`GnssFixSoundSetting`、既定 ON）:
  - 外部 GNSS 使用中、`RTK FIX`（GGA 品質 `4`）に入った瞬間に上昇チャイム（`assets/sounds/gnss_rtk_fixed.wav`）、`RTK FIX` から `FLOAT` 以下または切断へ落ちた瞬間に下降アラート（`assets/sounds/gnss_rtk_lost.wav`）を再生する（樹冠下での連続チャタリングを防ぐ 1.5 秒のクールダウン付き）。
- **内蔵 NTRIP クライアント**（`lib/services/ntrip/`、Android/モバイル専用・Web は条件付き import スタブ）:
  - 善意の基準局（`rtk2go.com:2101` 等）や自治体・民間の NTRIP v1 / v2 キャスターへ生 TCP / TLS ソケットで接続し、`ICY 200 OK` および `HTTP/1.x 200 OK`（`Transfer-Encoding: chunked` 展開対応）の両方を受け付ける。
  - 受信した RTCM3 バイト列は遅延ゼロで `BluetoothGnssService.sendRtcm`（Bluetooth SPP `output`）へ転送しつつ、`Rtcm3StreamInspector`（`0xD3` プリアンブル + 10bit 長 + CRC-24Q 検証）で有効フレーム数とメッセージ番号（`1005` 基準局座標、`1077`/`1087`/`1097`/`1117` MSM 等）を集計表示する。
  - `SOURCETABLE` の `STR;` レコードをパースし、現在位置が分かっているときは最寄り基準局からの距離（km）順にマウントポイントを並べて選択できる。
  - VRS や最寄り自動選択ストリーム向けに NMEA `$GPGGA` アップリンク定期送信に対応。認証エラー（401）やマウントポイント不一致（`SOURCETABLE 200 OK` 返却）では自動リトライを即時停止し、一時的な回線断のみ 10s → 20s → 40s → 60s の指数バックオフで再接続して RTK2go / SNIP キャスターの IP バンを防ぐ。

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
紀伊半島南部の偏角は西偏 約 7.9°（33.93N 135.96E、2026.8 で −7.88°）なので、直さないとその分だけ向きがずれる。

| 値 | 基準 | 直す場所 |
|----|------|----------|
| 端末のコンパス（flutter_compass、Android） | 磁北 | `map_initialization_mixin.dart` の `initializeCompass`（`headingNotifier` には真北の値が入る。扇・案内の矢印・GPS パネルの方位はここから読む）、`level_screen.dart` |
| TruPulse の方位角 | 磁北（本体 dECLn = 0 の前提） | `TruPulseTool.trueAzimuth`（点の位置を出すときだけ。属性 `survey_az` は本体の値のまま） |
| GPS の進行方向（course） | 真北 | 直さない |

- 偏角は `lib/utils/wmm_declination.dart`（WMM2025、12 次の球面調和関数、測地→地心の変換、経年変化は小数年で一次補間）。直すのは `lib/utils/true_heading.dart`（`TrueHeadingConverter`: 10 km 以上動くか日付が変わったら出し直す。位置が一度も分からないうちは直さない）。偏角を引く位置は今の測位（`GpsInfo.positionOr`。外部 GNSS だけ先に測れて地図の現在位置がまだ無い間も直す）、測れていなければ地図の現在位置
- 係数は NOAA NCEI の `WMM2025COF.zip`（https://www.ncei.noaa.gov/sites/default/files/2024-12/WMM2025COF.zip）内の `WMM.COF`。SHA-256 `dfa8597825af4e0b87ff4198a5b4fb661b3c49f4cd090cd0164e0259b075582f`。public domain
- 検算は `test/wmm_declination_test.dart`: 同梱の `WMM2025_TestValues.txt` 100 点と技術報告の 12 点（`WMM2025_TEST_VALUES.txt`）を ±0.01° で、紀伊半島南部（33.93N 135.96E）を NOAA のオンライン計算機の値（−7.87666°）と、国土地理院の偏角一覧 2020.0 年値（西偏 7°30′、±0.5°）と照らす
- 有効期間は 2025.0〜2030.0
- **WMM2025 の有効期限（2030年）**: WMM2025 は 2030.0 で期限切れ。WMM2030 が出たら `WMM.COF` を差し替え、係数表・SHA・テスト値を更新する
- TruPulse 本体の偏角設定（dECLn）はシリアルで読めない。アプリが偏角を足すので、本体は 0 のままにする（[[../devices/trupulse-360r]]）

## デバッグ時の確認ポイント

- `source_type`カラムの値: `GPS`（内蔵GPS）または`GNSS`（外部GNSS）
- フォアグラウンドサービスのログ: 常に内蔵GPSのみを使用
- メインisolateのログ: 外部GNSS使用時のデータ取得状況
- 属性テーブルでの確認: 外部GNSS使用時は`source_type = 'GNSS'`かつ`gps_source = 'external'`、切断時の一時フォールバック使用時は`gps_source = 'internal_fallback'`、通常内蔵GPS時は`gps_source = 'internal'`になっているか

## Bluetooth 機器の切断耐性・自動再接続・接続ログ（Issue #7）

- **無断フォールバックの禁止**: 外部 GNSS が電波断などで切断された際は警告音（`gnss_rtk_lost.wav`）と通知センターへのエラー通知を出し、無断で端末内蔵 GPS へは切り替えない（切断中は誤って数 m 精度の点を記録しないようブロックする）。
- **明示的な一時切替と自動復帰**: `GpsStatusPanel` の「内蔵GPSへ一時切替して続行」を明示的に選んだ場合のみ内蔵 GPS で記録を再開し、記録された点には属性 `gps_source = 'internal_fallback'` と `gnss_device` を残す。バックグラウンドでの自動再接続が成功した時点で自動的に外部 GNSS へ復帰する。
- **再起動時の全機器自動再接続**: `PreferredGpsSourceType`・`SelectedGnssDeviceAddress`・`TruPulseService` の前回接続アドレスを `SharedPreferences` に永続化し、アプリ再起動時に外部 GNSS と測距器の両方へ自動でつなぎ直す。
- **手動電源OFF・無操作オートパワーオフに対する有界自動再接続と待機モード（省電力・2.4GHz帯域保護）**:
  - Bluetooth Classic（SPP / RFCOMM）では、相手機器の手動電源OFF（および TruPulse 360R 本体の無操作オートパワーオフ）と電波圏外によるリンク断はいずれも L2CAP Supervision Timeout によるストリーム終了として届くため、プロトコル上は区別できない。
  - 無制限に `BluetoothConnection.toAddress()` を回し続けると、1回の試行ごとに約 5.12 秒間の高出力 Bluetooth Page Scan が走り、スマホのバッテリーを急速に消費するだけでなく、2.4GHz 帯の ACL タイムスロットを奪って同時接続中のもう一方の Bluetooth 機器（外部GNSSと測距器の併用時など）のパケ詰まり・切断を誘発する。
  - そのため自動再接続は **最大 5 回（`3s → 6s → 12s → 20s → 30s`、合計約 71 秒）** で打ち切り、数十秒以内の電波瞬断は手放しで自動復帰させつつ、電源OFF時は約 1 分強で電波発信ゼロの **待機（Standby）モード** へ移行する（スマホ本体の Bluetooth が OFF の場合は即座に停止）。
  - 待機モード中も測距器ツールや器械点（`STN`）は解除されず、機器の電源を入れ直した際は画面右下の `GpsStatusPanel`（「外部GNSSへ再接続」）または `TruPulseStatusPanel`（「再接続」）から 1 タップで即座に再接続できる。
- **複数 Bluetooth SPP 機器（外部GNSS ＋ 測距器/TS）の同時接続安定化**:
  - `third_party/flutter_bluetooth_serial` のネイティブ実装を改修し、相手側切断・接続失敗時の `BluetoothSocket.close()` 漏れ（RFCOMM チャネル枯渇）、`AsyncTask.SERIAL_EXECUTOR` による接続中スレッド直列ロック（片方の再接続中に他方の RTCM 送信等が止まる問題）、非スレッドセーフな `SparseArray` の競合、スキャン中でないときの無条件 `cancelDiscovery()`、および Dart 側の 111ms 常時ポーリングをすべて解消。
  - さらに `BluetoothConnectionCoordinator`（`lib/services/bluetooth_connection_coordinator.dart`）により、起動時や同時瞬断時に 2 台分の `BluetoothSocket.connect()`（Page Scan + SDP + RFCOMM ネゴシエーション）が同時に走って 2.4GHz ベースバンドが衝突しないよう発信ハンドシェイクを直列化・安定化待機（600ms）させる。
- **永続接続・切断ログ**: `DeviceConnectionLogService`（`lib/services/device_connection_log_service.dart`）がリリースビルドでも外部 GNSS・測距器・NTRIP の接続／切断／自動再接続／一時フォールバックの時刻を永続記録し、「外部機器」および「GPS・測位」設定画面から閲覧・コピーできる。
- **外部 GNSS の地図上常時マーカー表示と詳細軌跡（`gnss_tracks`）保管**:
  - 外部 GNSS 接続中は GPS 測量ツールを選んでいない通常閲覧・作図・コンパス測量中でも、NMEA ストリームから届く外部 GNSS のライブ位置を端末内蔵 GPS（青丸＋方位扇）とは別の **白い外輪＋解状態カラー（RTK FIX=緑 / FLOAT=シアン / DGPS=紫 / GPS=橙）のターゲットリング** として `TerrainMapLayer` 上にリアルタイム表示する（切断・No Fix 時は即時消去）。
  - 同時に `GpsHistoryRecorder` が `Global/gps_history.gpkg` 内に端末内蔵の `gps_tracks` と並べて **`gnss_tracks`（LineString）＋ `gnss_track_details`**（`gps_quality`, `fix_type`, `accuracy`, `accuracy_source`, `satellite_count`, `hdop`, `pdop`, `vdop`, `gnss_device`, `ntrip_mountpoint`, `raw_gga` を毎秒保持、クラッシュ耐性 Raw バッファ `gnss_raw_YYYY_MM_DD` 付き）を常時保管する。三脚・ポール据え置きによる静止観測中（TruPulse 360R との同時併用時など）に RTK FIX 座標がミリ単位で完全一致しても、また Bluetooth SPP のバッファ到着ジッター（±150ms）があっても、`gnss_track_details` には毎秒全エポックを欠かさず蓄積し、地図・QGIS 用の `gnss_tracks` LineString 側のみ連続重複頂点を除去する。「軌跡から抽出」ダイアログからも `YYYY/MM/DD [GNSS]` として全 GNSS テレメトリ付きの `sub_table` 込みでライン抽出できる。
- **AI エージェント協働を前提とした単一 GeoPackage 構造化アーカイブ**:
  - アプリ内に複雑な事後解析 UI（時刻指定の静止点自動抽出など）を肥大化させず、こかげマップ自身は「現場で確実に・欠損なくオープン標準の SQLite（GeoPackage）へ構造化記録する」役割に徹し、事後解析・外れ値除去・静止点同定・調書作成は PC 側の AI エージェントと協働する設計方針をとる。
  - `Global/gps_history.gpkg` 1 ファイルの中に `gps_tracks` / `gps_track_details`（内蔵GPS）、`gnss_tracks` / `gnss_track_details`（外部GNSS全テレメトリ・生GGA）、および **`device_connection_events`**（機器接続・切断・再接続上限停止・一時フォールバックのミリ秒時刻イベント）をすべて同居させ、`AppData/kmap` の端末間統合でも過去日分を自動同期するため、AI エージェントは `gps_history.gpkg` と案件 `.gpkg` を SQLite として開くだけで現場の全時系列を突合できる。

## GNSS の品質の記録と足切り

公共測量や各種補助事業の GNSS 竣工検査は、測位の種類・衛星数・DOP・平均化の回数の記録を求める。
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

