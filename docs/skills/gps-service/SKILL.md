---
name: gps-service
description: GPS追跡・測量機能の実装ガイド。InternalGpsLocationStore、GpsHistoryRecorder、フォアグラウンドサービス、外部GNSS機器連携を含む。GPS関連機能を実装・修正・デバッグする際に使用。
---

# GPS/GNSS サービス実装ガイド

## 核心コンセプト

### 常に1ストリーム

GPSハードウェアへのアクセスは常に1箇所だけ。

| プラットフォーム | GPSストリームの場所 | Storeのモード |
|-----------------|---------------------|---------------|
| Android | 別isolate (ForegroundService) | delegated（常時稼働） |
| Windows | メインisolate | direct |

### GPS軌跡は常時記録（ハイブリッド方式）

GPSストリームは常時稼働し、`GpsHistoryRecorder` が全座標を自動保存。
明示的な「追跡開始/停止」は不要。

**保存は2段構成:**
- Raw Buffer（AppSupportDir内）: ポイント逐次INSERT（O(1)、高速・安全）
- Consolidated（グローバルフォルダ内）: 20秒ごとにLine+正規化テーブルに反映

## アーキテクチャ

```
InternalGpsLocationStore (常時稼働)
  └─→ positionStream
       ├─→ maplibre マーカー (map_initialization_mixin)
       ├─→ GpsHistoryRecorder
       │    ├─→ Raw Buffer (gps_raw_buffer.gpkg) ← Point逐次INSERT
       │    ├─→ Memory Cache (todayPoints) ← 即時追加
       │    └─→ Consolidation Timer (20秒)
       │         ├─→ gps_tracks (LineLayer) ← Line更新
       │         └─→ gps_track_details (テーブル) ← メタデータINSERT
       └─→ GpsManagerService → GPS情報バー、測量

TrackExtractionDialog (ユーザー操作時)
  └─→ GpsHistoryRecorder から日付別ポイント読み取り
       └─→ 時間範囲選択 + Douglas-Peucker簡略化
            └─→ LineFeatureNode 保存（sub_table JSON付き）
```

### ストレージ構成

```
AppSupportDir/gps_buffer/gps_raw_buffer.gpkg  ← UI非表示
  ├── gps_raw_2026_02_04  (PointLayer)
  ├── gps_raw_2026_02_05  (PointLayer)  ← 1日バックアップ保持
  └── gps_raw_2026_02_06  (PointLayer)  ← 本日

k_maps_global/gps_history.gpkg  ← グローバルフォルダ
  ├── gps_tracks  (LineLayer, 1日1フィーチャ)
  ├── gps_track_details  (非空間テーブル, 全日分)
```

### gps_track_details テーブル

| カラム | 型 | 説明 |
|--------|-----|------|
| track_date | TEXT | 日付キー（YYYY_MM_DD） |
| point_index | INTEGER | ポイント連番 |
| timestamp | TEXT | ISO8601タイムスタンプ |
| latitude/longitude | REAL | 座標 |
| altitude/accuracy/speed/bearing | REAL | メタデータ |
| source_type | TEXT | 'GPS' |

## 重要な制約

### Bluetooth通信はメインisolateのみ

```
NG: フォアグラウンドサービス（別isolate）→ Bluetooth
OK: メインisolate → Bluetooth
```

## 使用パッケージ

| パッケージ | 用途 |
|-----------|------|
| `geolocator` | 内蔵GPS位置取得 |
| `flutter_background_service` | フォアグラウンドサービス（Android） |
| `flutter_bluetooth_serial` | Bluetooth通信（SSP対応） |
| `path_provider` | AppSupportDir取得（rawバッファ配置先） |

## 関連ファイル

```
lib/models/
├── gps_position_record.dart        # GPS座標レコード・レスポンスモデル
└── gps_track.dart                  # GpsTrackPoint（Recorder内部で使用）

lib/services/
├── internal_gps_location_store.dart # 内蔵GPS位置情報ストア（中核）
├── gps_history_recorder.dart        # GPS軌跡ハイブリッド記録
├── foreground_service.dart          # フォアグラウンドサービス管理
├── gps_manager_service.dart         # 統合GPS管理（内蔵GPS+外部GNSS）
└── ...

lib/screens/map_page/
├── map_page.dart                    # PolylineLayer に本日軌跡表示
├── map_page_state_base.dart         # gpsHistoryRecorder 参照
└── mixins/
    ├── map_initialization_mixin.dart # Store+Recorder初期化（supportDir渡し）
    ├── map_gps_tracking_mixin.dart   # 軌跡抽出ダイアログ呼び出し
    └── map_gps_survey_mixin.dart     # GPS測量

lib/widgets/
└── track_extraction_dialog.dart     # 軌跡切り取りUI（sub_table JSON付き保存）

lib/tools/
└── gps_tool.dart                    # GPS測量ツール
```
