---
title: こかげマップ ドキュメント
tags: [index, navigation]
---

# こかげマップ ドキュメント

こかげマップの機能設計と技術資料の目次。使い方はアプリ内の使い方ガイド（`assets/user_guide/`）、変更は更新履歴（`assets/changelog/`）。

---

## 機能設計ドキュメント

| ドキュメント | 概要 |
|-------------|------|
| [[features/concept]] | コンセプト・ターゲットユーザー・プラットフォームの役割分担（Android と web） |
| [[features/drawing-editing]] | 描画・編集機能（基本図形、属性編集、ツール） |
| [[features/layer-management]] | レイヤー管理機能（階層構造、GeoPackage連動） |
| [[features/gps-map]] | GPS・地図機能（トラッキング、測量、GNSS対応） |
| [[features/project-management]] | プロジェクト・GeoPackage管理（フォルダ構造、メタデータ） |
| [[features/google-drive]] | Google Drive連携（同期、共有） |
| [[features/ui-ux]] | UI/UXの方向性（ツールバー、レイヤーパネル、ジェスチャー） |
| [[features/feature-photos]] | 地物の写真（カメラで撮って付ける・QGIS の ExternalResource） |
| [[features/tree-tally]] | 毎木調査（標準地の立木の記録・TruPulse の樹高・ha あたりの集計と CSV） |
| [[features/geometry-types]] | レイヤジオメトリタイプ仕様（OGC Simple Features準拠） |

---

## 技術資料

### データ・形式・QGIS

| ドキュメント | 概要 |
|-------------|------|
| [[technical/qgis-interop]] | QGIS相互運用（.qgs の読み書き・トリガー復元・範囲/件数の同期） |
| [[technical/project-format-design]] | プロジェクト形式の設計（View / .qgs / 共有単位） |
| [[technical/gdal]] | GDAL（Android の libgdal.so と web の WASM、使いどころ） |
| [[technical/external-formats]] | gpkg 以外の形式（読み取り専用レイヤ・gpkg への変換・ラスタのオーバーレイ） |
| [[technical/import-export]] | レイヤの書き出し（GDAL） |

### 地図の描画・3D

| ドキュメント | 概要 |
|-------------|------|
| [[technical/terrain-3d]] | 3D 地形描画系（純 Dart、2D と 3D の地図面） |
| [[technical/scene-model]] | シーンモデルの切り出し（MapLibre 撤去前の調査記録） |
| [[technical/3d-map-design]] | 3D 地図の旧設計メモ（2026-09-07、terrain-3d で上書き） |
| [[technical/ui-layer-tree]] | レイヤツリーUI更新ガイド（updateChildren） |
| [[technical/performance]] | 性能（電池・メモリ・起動）の洗い直し |

### GPS・機器

| ドキュメント | 概要 |
|-------------|------|
| [[technical/gps-architecture]] | GPS追跡・測量アーキテクチャ |
| [[technical/foreground-service]] | フォアグラウンドサービス・Bluetooth通信制約 |

### 同期・共有

| ドキュメント | 概要 |
|-------------|------|
| [[technical/google-drive-setup]] | Google Drive連携セットアップガイド |
| [[technical/drive-geodiff-sync]] | Drive 同期の行単位マージ（geodiff） |
| [[technical/location-sharing]] | 位置共有（パーティ機能）設計（Firebase RTDB・接続途絶対処・セキュリティ） |
| [[technical/location-sharing-setup]] | 位置共有 Firebaseセットアップ手順（provisioningランブック） |

### 開発・配布

| ドキュメント | 概要 |
|-------------|------|
| [[technical/tech-stack]] | 技術スタック |
| [[technical/testing]] | テスト構成（Android / web・地図の契約テスト） |
| [[technical/cli-launch]] | CLI / URL からの起動と読み直し |
| [[technical/web-hosting]] | web版のホスティング（デプロイ・セキュリティヘッダ） |
| [[technical/signing]] | Android署名鍵の管理（保管場所・リリースビルド手順） |
| [[technical/closed-test-invite]] | クローズドテストへの招待手順 |
| [[technical/play-permission-video-plan]] | Google Play 権限申請の動画・宣言の計画 |
| [[technical/development-phases]] | 開発ステップ（MVP〜フェーズ4、初期の計画） |

### 同梱のネイティブライブラリ

| ドキュメント | 概要 |
|-------------|------|
| [[../third_party/gdal/README]] | GDAL / PROJ の焼き方（Android 3 ABI と WebAssembly）・ドライバの組・ライセンス |
| [[../third_party/geodiff/README]] | geodiff の焼き方（行単位マージ用） |

---

## 外部機器

| ドキュメント | 概要 |
|-------------|------|
| [[devices/trupulse-360r]] | TruPulse 360R レーザー距離計（シリアルコマンド・キャリブレーション・トラブルシューティング） |

---

## 関連ファイル（ルート）

- `README.md` - アプリの概要・対応形式・ビルド・ライセンス
- `TODO.md` - タスク管理
- `AGENTS.md` - AI開発ガイドライン
