---
title: Root Maps ドキュメント
tags: [index, navigation]
---

# Root Maps ドキュメント

このディレクトリには、Root Mapsの機能設計と技術資料が格納されています。

---

## 機能設計ドキュメント

| ドキュメント | 概要 |
|-------------|------|
| [[features/concept]] | コンセプト・ターゲットユーザー・コアバリュー |
| [[features/drawing-editing]] | 描画・編集機能（基本図形、属性編集、ツール） |
| [[features/layer-management]] | レイヤー管理機能（階層構造、GeoPackage連動） |
| [[features/gps-map]] | GPS・地図機能（トラッキング、測量、GNSS対応） |
| [[features/project-management]] | プロジェクト・GeoPackage管理（フォルダ構造、メタデータ） |
| [[features/google-drive]] | Google Drive連携（同期、共有） |
| [[features/ui-ux]] | UI/UXの方向性（ツールバー、レイヤーパネル、ジェスチャー） |
| [[features/feature-photos]] | 地物の写真（カメラで撮って付ける・QGIS の ExternalResource） |
| [[features/geometry-types]] | レイヤジオメトリタイプ仕様（OGC Simple Features準拠） |

---

## 技術資料

| ドキュメント | 概要 |
|-------------|------|
| [[technical/tech-stack]] | 技術スタック・フリーハンド描画実装 |
| [[technical/development-phases]] | 開発ステップ（MVP〜フェーズ4） |
| [[technical/import-export]] | Import/Exportアーキテクチャ（モジュール構造） |
| [[technical/foreground-service]] | フォアグラウンドサービス・Bluetooth通信制約 |
| [[technical/gps-architecture]] | GPS追跡・測量アーキテクチャ |
| [[technical/google-drive-setup]] | Google Drive連携セットアップガイド |
| [[technical/ui-layer-tree]] | レイヤツリーUI更新ガイド（updateChildren） |
| [[technical/signing]] | Android署名鍵の管理（保管場所・リリースビルド手順） |
| [[technical/location-sharing]] | 位置共有（パーティ機能）設計（Firebase RTDB・接続途絶対処・セキュリティ） |
| [[technical/location-sharing-setup]] | 位置共有 Firebaseセットアップ手順（provisioningランブック） |
| [[technical/testing]] | テスト構成（Windows/Android両対応・地図バックエンド契約テスト） |
| [[technical/qgis-interop]] | QGIS相互運用（トリガー復元・範囲/件数の同期） |
| [[technical/project-format-design]] | プロジェクト形式の設計（View / .qgs / 共有単位）※未実装 |

---

## 外部機器

| ドキュメント | 概要 |
|-------------|------|
| [[devices/trupulse-360r]] | TruPulse 360R レーザー距離計（シリアルコマンド・キャリブレーション・トラブルシューティング） |

---

## 関連ファイル（ルート）

- `README.md` - プロジェクト概要・機能一覧
- `TODO.md` - タスク管理
- `AGENTS.md` - AI開発ガイドライン

