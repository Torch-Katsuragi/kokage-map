---
name: k-maps-conventions
description: k_mapsプロジェクト固有のコーディング規約とワークフロー。Flutter/Dartでの地図アプリ開発、GeoPackage処理、GPS機能実装に関するガイドライン。このプロジェクトでコードを書く際に参照する。
---

# k_maps プロジェクト規約

Flutter製の地図アプリケーション開発プロジェクト。

## プロジェクト構造

```
lib/
├── main.dart           # エントリーポイント
├── core/               # コア機能
├── models/             # データモデル
├── screens/            # 画面
├── services/           # サービス層
├── widgets/            # ウィジェット
├── utils/              # ユーティリティ
├── converters/         # データ変換
└── tools/              # ツール類
```

## コーディング規約

### 言語

- **日本語**: コメント、ドキュメント、コミットメッセージ
- **英語**: 変数名、関数名、クラス名

### Dart/Flutter スタイル

```dart
// クラス名: UpperCamelCase
class LayerNode { ... }

// 変数・関数名: lowerCamelCase
final currentLayer = getActiveLayer();

// 定数: lowerCamelCase (Dartの慣例)
const defaultZoomLevel = 15.0;

// プライベート: アンダースコアプレフィックス
int _internalCounter = 0;
```

### コメント

```dart
/// 公開APIには日本語ドキュメントコメント
/// [parameter] パラメータの説明
/// Returns: 戻り値の説明
Future<void> saveLayer(LayerNode layer) async { ... }

// 実装内部のコメントも日本語
// GPSの精度が低い場合はスキップ
if (accuracy < threshold) return;
```

## ドキュメント参照

作業開始前に確認すべきファイル：

| ファイル | 内容 |
|----------|------|
| `TODO.md` | 現在のタスクと優先順位 |
| `docs/` | 設計書・技術資料 |
| `README.md` | プロジェクト概要 |

## 開発フロー

1. **調査**: 既存のパッケージやライブラリを検索
2. **確認**: 関連ドキュメントを読む
3. **実装**: 既存のコードスタイルに従う
4. **テスト**: 動作確認を行う
5. **更新**: TODO.md、README.md を更新

## 優先順位

1. バグ修正・リンターエラー解消
2. 既存機能の改善・最適化
3. 新機能の実装
4. ドキュメント更新

## 環境

- **OS**: Android / web（開発は Windows）
- **シェル**: PowerShell
- **パッケージ管理**: pubspec.yaml

## 主要な依存関係

プロジェクトで使用している主要パッケージ（新機能実装時に参照）：

- `geolocator`: GPS位置情報
- `sqflite`: SQLiteデータベース
- `path_provider`: ファイルパス取得

## ベストプラクティス

### やるべきこと

- 既存のパッケージを優先使用
- リンターエラーを必ず修正
- エッジケースを考慮
- 適切なエラーハンドリング
- パフォーマンスを意識

### やってはいけないこと

- 機密情報のハードコード
- 不要な依存関係の追加
- 一時ファイルの放置
- 過度な抽象化

## ファイル操作

### 作成するもの

- 実装に必要なファイルのみ
- 要求されたドキュメントのみ

### 削除するもの

- 一時ファイル
- テスト用ダミーファイル
- 不要になったスクリプト
