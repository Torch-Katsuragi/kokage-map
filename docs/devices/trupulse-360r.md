---
title: TruPulse 360R リファレンス
tags: [device, trupulse, bluetooth, survey]
---

# TruPulse 360R リファレンス

LTI (Laser Technology, Inc.) 製レーザー距離計。Bluetooth SPP (38400 baud) 経由でアプリと通信する。

- 公式マニュアル: [ManualsLib](https://www.manualslib.com/manual/1373387/Laser-Technology-Trupulse-360r.html)
- Quick Reference: [PDF](https://lasertech.com/wp-content/uploads/TruPulseSeriesQuickReferenceGuide_e.pdf)

---

## 接続

| 項目 | 値 |
|------|-----|
| プロトコル | Bluetooth Classic SPP |
| ボーレート | 38400 (または 4800) |
| 改行 | CR+LF |
| デフォルト PIN | `1111` |
| デバイス名候補 | `TRUPULSE`, `TP360`, `LTI` |

### 接続手順

1. デバイス本体で Bluetooth を有効化: DOWN 長押し 4秒 → `UnitS` → DOWN で `bt` → FIRE → ON
2. スマホの Bluetooth 設定でペアリング（PIN: `1111`）
3. アプリの設定 → 外部機器 → スキャン → Connect

---

## シリアルコマンド（Section 8, p.49）

すべてのコマンドは `$` で始まり、CR+LF で送信する。

### 利用可能なコマンド一覧

| コマンド | 機能 | 値 |
|----------|------|-----|
| `$ID` | デバイス識別（通信確認） | レスポンスあり |
| `$GO` | 計測開始 (Fire) | 15秒で `E01`（ターゲットなし） |
| `$ST` | 計測停止 | - |
| `$DU,n` | 距離単位 | 0=メートル, 1=ヤード, 2=フィート |
| `$AU,n` | 角度単位 | 0=度, 1=パーセント |
| `$MM,n` | 計測モード | 下記参照 |

**これ以外のシリアルコマンドは存在しない。** ターゲットモード・偏差・キャリブレーションはデバイス本体操作のみ。

### 計測モード ($MM) インデックス

| Index | Mode | 説明 |
|-------|------|------|
| 0 | HD (Horizontal Distance) | 水平距離。標高差を無視した地図上の距離 |
| 1 | VD (Vertical Distance) | 垂直距離。デバイスとターゲットの高低差 |
| 2 | SD (Slope Distance) | 斜距離。レーザーが実測する直線距離 |
| 3 | INC (Inclination) | 傾斜角（度）。0°=水平 |
| 4 | HT (Height) | 高さ計測。2ショットで対象物の高さを算出 |
| 5 | AZ (Azimuth) | 方位角（0°–360°） |
| 6 | ML (Missing Line) | ミッシングライン。2点間距離を2ショットで算出 |

### 計測データフォーマット（HV Download Message）

```
$PLTIT,HV,<HD>,M,<AZ>,DEG,<INC>,DEG,<SD>,M
```

- カンマ区切り、9+ フィールド
- HD=[2], AZ=[4], INC=[6], SD=[8] (0-indexed)
- VD は HD×tan(INC) で算出

### 応答

- `$OK` — コマンド受理
- `E01` — ターゲット未検出（`$GO` のタイムアウト）

---

## ターゲットモード（デバイス本体操作のみ）

シリアルコマンドでの切替は不可。デバイスの `FIRE長押し → DOWN` で切替。

| モード | 説明 |
|--------|------|
| Standard | 最初にヒットしたターゲットを返す |
| Filter | 複数回の平均値を返す。長距離やブレ低減に有効 |
| Farthest | 最も遠いターゲットを返す。フェンスや藪の奥を狙う |
| Closest | 最も近いターゲットを返す。まばらな植生越しに有効 |
| Continuous | FIRE 押下中に連続計測 |

---

## キャリブレーション

いずれもデバイス本体メニューから開始する。**シリアルコマンドでの開始は不可。**

### Tilt Calibration（Section 4, p.24–26）

**条件**: 平坦で水平な面（±15°以内）の上で実施。

1. メニュー: DOWN 長押し 4秒 → `UnitS` → DOWN で `inC` → FIRE → `no CAL` → UP/DOWN で `YES CAL` → FIRE → `C1_Fd`
2. **C1**: レンズ前向き → ~1秒待って FIRE
3. **C2**: 90° 回転 → レンズ下向き → ~1秒待って FIRE
4. **C3**: 90° 回転 → レンズ後向き → ~1秒待って FIRE（短押し！）
   - **360R 固有**: ボタンを面の端からはみ出させて押す
5. **C4**: 90° 回転 → レンズ上向き → ~1秒待って FIRE
6. **C5**: 光軸に沿って90°ロール → レンズ前向き → ~1秒待って FIRE
7. **C6–C8**: C2–C4 と同じ回転（ロール後の姿勢で）→ 各 FIRE
8. PASS → FIRE で保存 / FAIL → FIRE で再試行

**中止**: UP または DOWN の長押しで中止（以前のキャリブレーションが復元される）

**FAILコード**: FAiL1=動きすぎ / FAiL2=磁気飽和 / FAiL3=計算エラー / FAiL4=収束エラー / FAiL6=向き間違い

### Compass Calibration（Section 4, p.32–34）

**条件**:
- **必ず屋外で実施**
- 車両・フェンス・建物・電子機器から離れる（距離目安は下記）
- **磁北に向かって立つ**

1. メニュー: DOWN 長押し 4秒 → `UnitS` → DOWN で `H_Ang` → FIRE → `dECLn` → DOWN で `HACAL` → FIRE → `no CAL` → UP/DOWN で `YES CAL` → FIRE → `C1_Fd`
2. **C1**: 磁北に向かい、レンズ前向き → ~1秒待って FIRE
3. **C2**: 90° 回転 → レンズ下向き → ~1秒待って FIRE
4. **C3**: 90° 回転 → レンズ後向き → ~1秒待って FIRE
5. **C4**: 90° 回転 → レンズ上向き → ~1秒待って FIRE
6. **C5**: 光軸に沿って90°ロール → レンズ前向き（シリアルポート上向き） → ~1秒待って FIRE
7. **C6–C8**: C2–C4 と同じ回転（ロール後の姿勢で）→ 各 FIRE
8. PASS → FIRE で保存 / FAIL → Tilt Cal を先にやってから再試行

### コンパスからの距離目安

| 距離 | 対象物 |
|------|--------|
| 15 cm | メガネ・ペン・腕時計・ナイフ・ジッパー・バックル・電池・携帯 |
| 50 cm | クリップボード・データコレクタ・PC・GPSアンテナ・無線機 |
| 2 m | 自転車・消火栓・道路標識・ATV・チェーンフェンス |
| 5 m | 配電盤・乗用車・電線・コンクリート建造物 |
| 10 m | 大型トラック・金属建築・重機 |

---

## 偏差（Declination）設定

デバイス本体で設定: DOWN 長押し 4秒 → `UnitS` → DOWN で `H_Ang` → FIRE → `dECLn` → FIRE

UP/DOWN で値を変更し FIRE で確定。日本の偏差は地域により 6°–10°W 程度。
国土地理院の地磁気値一覧を参照。

**アプリで使うときは本体の偏差を 0 のままにする**（2026-10-11 決定）。

- 本体の偏差設定はシリアルで読み書きできないので、アプリからは本体が偏差を足しているか分からない
- アプリは AZ を磁北基準として受け取り、点の位置を出すときに WMM2025 の偏角（測点の位置・その日）を足して真北に直す（`TruPulseTool.trueAzimuth`）。北山村では約 −7.9°
- 属性 `survey_az` には本体の値（磁北基準）をそのまま残す。ライン化ダイアログの「磁気偏角補正」（既定 ON・WMM2025 から自動算出）はこの値に足すので、その場の点の位置とライン化の結果が一致する
- 本体でも偏差を設定すると二重に足される。過去に本体で設定して測ったデータをライン化するときは、ダイアログの偏角補正を OFF にする（点の位置はずれたまま）

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| ペアリングできない | PIN `1111` を入力。BT が ON か確認 |
| ペアリングしたが接続できない | SPP は OS レベルでは "接続" 表示にならない。アプリから Connect |
| アプリに表示されない | デバイス名が `TRUPULSE` / `TP360` / `LTI` を含むか確認。Try Connect で手動接続も可 |
| `$ID` にレスポンスがない | ボーレート（38400 or 4800）を確認 |
| コンパスが不正確 | コンパスキャリブレーション実施。金属物から離れる。偏差設定を確認 |
| 傾斜値が不正確 | チルトキャリブレーション実施 |
| `E01` エラー | ターゲットが見つからない。反射面を確認、距離やモードを変更 |

---

## ポイント測量ワークフロー

アプリは**ポイント逐次生成方式**で測量を行う。ライン保存ではなく、計測ごとにポイントフィーチャを即座に生成する。

### 手順

1. ポイントレイヤを選択し、起点となるポイントを地図上に配置
2. TruPulse ツールを有効化
3. 既存ポイントをタップ → **Station**（器械点）として設定
4. TruPulse で測距 → アプリがターゲット座標を算出し、同レイヤに新ポイントを自動生成
5. 生成されたポイントが自動的に新しい Station になる（連続測量）
6. ポイント生成時に効果音が鳴る

### 座標計算

```
target = Distance().offset(station, HD, AZ)
```

- HD: 水平距離 (m)
- AZ: 方位角 (deg)。本体の値は磁北基準で、`TruPulseTool.trueAzimuth` が WMM2025 の偏角を足して真北に直してから使う

### 自動記録される属性

| カラム名 | 内容 |
|----------|------|
| `survey_az` | 方位角 (deg) |
| `survey_inc` | 傾斜角 (deg) |
| `survey_hd` | 水平距離 (m) |
| `survey_sd` | 斜距離 (m) |
| `survey_vd` | 鉛直距離 (m) |
| `survey_stn` | Station 位置 (GeoJSON Point: `{"type":"Point","coordinates":[lon,lat]}`) |
| `survey_timestamp` | 計測時刻 (ISO8601) |

### オーバーレイ表示

ツール選択中、レイヤ内の `survey_stn` (GeoJSON Point) 属性を持つポイントから Station 座標への線分を動的に描画する。ポイントを削除すれば対応する線も消える。

---

## アプリ実装ファイル

| ファイル | 役割 |
|----------|------|
| `lib/devices/trupulse/trupulse_service.dart` | BT SPP 接続・コマンド送受信・計測データパース |
| `lib/devices/trupulse/trupulse_tool.dart` | 地図ツール（Station選択・座標算出・ポイント逐次生成） |
| `lib/devices/trupulse/trupulse_detail_screen.dart` | 詳細操作画面（モード切替・リモート操作） |
| `lib/devices/trupulse/trupulse_calibration_guide.dart` | キャリブレーション手順ガイド |
| `lib/devices/trupulse/trupulse_status_panel.dart` | ステータスパネル（計測値・Station表示） |
| `lib/devices/trupulse/trupulse_measurement.dart` | 計測データモデル |
| `lib/screens/device_settings_screen.dart` | 接続設定画面 |
