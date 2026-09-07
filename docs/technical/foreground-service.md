---
title: フォアグラウンドサービスとBluetooth通信の制約
tags: [technical, bluetooth, gnss, isolate]
---

# フォアグラウンドサービスとBluetooth通信の制約

## 外部GNSS機器との通信における技術的制約

### 問題の背景

Root Mapsでは、SSP（Secure Simple Pairing）対応の外部GNSS機器（例：u-blox Geode）との通信を実装していますが、フォアグラウンドサービス（別isolate）での実装には重大な制約があります。

### 技術的制約の詳細

#### 1. Flutter Isolateの制約

- **Flutterのisolateは独立したメモリ空間で動作**
  - メインisolateとフォアグラウンドサービスisolateは別々のDart VM上で実行
  - isolate間でオブジェクトを直接共有できない
  - プリミティブ型やJSONシリアライズ可能なデータのみ送受信可能

#### 2. Bluetooth通信の制約

- **Bluetoothプラグイン（flutter_bluetooth_serial）はMethodChannelを使用**
  - MethodChannelはメインisolateでのみ動作
  - フォアグラウンドサービス（別isolate）からはMethodChannelにアクセス不可
  - Bluetooth接続、データ受信、NMEAパース等の処理が実行できない

#### 3. プラットフォーム固有の制限

- **AndroidのBluetooth APIアクセス**
  - Bluetooth通信はUIスレッド（メインisolate）からのみ安全にアクセス可能
  - バックグラウンドサービスからのBluetooth操作は不安定
  - 接続状態の監視、データストリームの受信が困難

### 実装上の結論

**外部GNSS機器はフォアグラウンドサービスで使用すべきではない**

理由：
1. MethodChannelがフォアグラウンドサービスisolateで動作しない
2. Bluetooth接続の確立・維持がメインisolateでのみ可能
3. NMEAデータの受信・パースがメインisolateでのみ実行可能
4. 実装が複雑化し、エラーハンドリングが困難

## 使用パッケージ

- `flutter_background_service`: ^5.0.10 - フォアグラウンドサービス実装
- `flutter_bluetooth_serial`: ^0.4.0 - Bluetooth通信（SSP対応）
- `geolocator`: ^13.0.2 - 内蔵GPS位置情報取得
- `location`: ^7.0.0 - Mock Location Provider連携

## 関連ファイル

- `lib/services/foreground_service.dart` - フォアグラウンドサービス管理（内蔵GPS専用）
- `lib/services/gps_manager_service.dart` - 統合GPS管理サービス（メインisolate）
- `lib/models/bluetooth_gnss_service.dart` - 外部GNSS通信サービス（メインisolate）
- `lib/screens/map_page/mixins/map_gps_tracking_mixin.dart` - GPS追跡機能実装（ハイブリッド方式）
- `lib/tools/gps_tool.dart` - GPS測量機能（メインisolate専用）

## 技術的参考情報

- Flutter Isolateは独立したメモリ空間で動作し、MethodChannelはメインisolateでのみ利用可能
- Bluetooth通信はプラットフォームチャネル経由でネイティブコードを呼び出すため、メインisolateが必須
- フォアグラウンドサービスでの外部GNSS使用は技術的に不可能
- 代替案として、フォアグラウンドサービスをトリガーとして使用し、メインisolateで外部GNSSデータを処理

## 関連ドキュメント

- [[gps-architecture]] - GPS追跡・測量アーキテクチャ
- [[../features/gps-map]] - GPS・地図機能

