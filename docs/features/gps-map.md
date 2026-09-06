---
title: GPS・地図機能
tags: [features, gps, map]
---

# GPS・地図機能

## GPSトラッキング

- 現在位置表示
- 移動軌跡の記録（ポイントフィーチャとして自動保存）
- GPS精度、速度などの情報表示
- **内蔵GPS使用**: フォアグラウンドサービスで継続的に記録
- **外部GNSS使用**: フォアグラウンドサービス（トリガー）+ メインisolate（データ取得）のハイブリッド方式

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

- `maplibre` を利用 (OpenStreetMapなど各種タイルソースに対応)
- オフラインタイルマップ (MBTiles。⚠ Android のみ — web には端末内タイルキャッシュが無い)

## 地図操作

- パン、ズーム (ピンチイン/アウト)
- 回転
- 現在位置へ移動
- 現在位置が画面外にあるときは、地図の縁に方向を示す矢印を表示（タップでジャンプ）。
  ドロワーに隠れている部分は「見えていない」扱い
- 任意地点へのジャンプは `MapJumpMixin`（`lib/screens/map_page/mixins/map_jump_mixin.dart`）に集約。
  起動時の現在位置ジャンプ・ドロワー/属性テーブルからの移動・矢印タップはすべてここを通す

## 関連ドキュメント

- [[../technical/gps-architecture]] - GPS追跡・測量アーキテクチャ
- [[../technical/foreground-service]] - フォアグラウンドサービス・Bluetooth制約

