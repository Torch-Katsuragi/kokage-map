---
tags: [technical, ui, layer-tree]
---

# レイヤツリー UI 更新ガイド

## 概要

root_mapsのレイヤツリーは `LayerTreeNode` を基底クラスとした階層構造で、ファイルシステムと同期している。UIを正しく更新するには `updateChildren()` メソッドを適切に呼び出す必要がある。

## ノード階層

```
LayerTreeNode（基底）
├─ FolderNode（フォルダ）
│  └─ DriveFolderNode（Drive連携フォルダ）
│  └─ GlobalFolderNode（グローバルフォルダ。SysNode の下に置く）
│  └─ SysNode（「System」。ルート直下の仮想フォルダ。[[docs/features/layer-management#System（sys）]]）
├─ GeoPackageNode（.gpkgファイル）
├─ LayerNode（GeoPackage内レイヤ）
├─ FeatureNode（フィーチャ）
│  ├─ PointFeatureNode
│  ├─ LineFeatureNode
│  └─ PolygonFeatureNode
└─ ImageNode（画像ファイル）
```

## updateChildren() の役割

各ノードタイプで子ノードを再読み込みする：

| ノードタイプ | 読み込み対象 |
|------------|-------------|
| FolderNode | サブフォルダ、GeoPackage、画像 |
| SysNode | なし（子は home_screen が差し込む。可視性だけ当て直す） |
| GeoPackageNode | レイヤ一覧 |
| LayerNode | フィーチャ一覧 |
| FeatureNode | なし（childrenクリアのみ） |
| ImageNode | なし（childrenクリアのみ） |

## 呼び出しが必要なケース

### ファイル操作後

```dart
// ファイル追加・削除・リネーム後
await parentFolder.updateChildren();

// GeoPackage内レイヤ変更後
await geoPackageNode.updateChildren();

// レイヤ内フィーチャ変更後
await layerNode.updateChildren();
```

### Drive同期後

```dart
// ダウンロード・削除があった場合
if (result.downloadedCount > 0 || result.deletedCount > 0) {
  await node.updateChildren();
}
```

### インポート後

```dart
// Shapefile/GeoJSONインポート後
await targetGeoPackage.updateChildren();
```

### レイヤ移植後

```dart
// 移植先
await targetGeoPackage.updateChildren();
await migratedLayerNode.updateChildren();

// 移植元（移動の場合）
await sourceLayer.geoPackageNode.updateChildren();
```

## UI更新の完全なフロー

```dart
// 1. データ変更
await someOperation();

// 2. 子ノード再読み込み
await affectedNode.updateChildren();

// 3. UI再描画
setStateCallback(() {});

// 4. 必要に応じてマップ更新
triggerMapRefresh();
```

## 注意点

### 競合防止

`LayerNode` は `_isUpdatingChildren` フラグで重複実行を防止している。

### 初期化

ノードの初回展開時は `initialize()` が自動的に `updateChildren()` を呼ぶ。

```dart
Future<void> initialize() async {
  if (_initialized) return;
  _initialized = true;
  await updateChildren();
}
```

### キャッシュクリア

`FolderNode.updateChildren()` は内部で `invalidateMetaCache()` を呼び出し、メタデータキャッシュをクリアする。

## 関連ファイル

- [[layer_tree_node.dart|lib/models/nodes/layer_tree_node.dart]] - 基底クラス
- [[folder_node.dart|lib/models/nodes/folder_node.dart]] - フォルダノード
- [[geopackage_node.dart|lib/models/nodes/geopackage_node.dart]] - GeoPackageノード
- [[layer_node.dart|lib/models/nodes/layer_node.dart]] - レイヤノード
- [[layer_drawer.dart|lib/widgets/layer_drawer/layer_drawer.dart]] - UI実装
