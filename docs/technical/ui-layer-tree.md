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
│  └─ ExternalLayerNode（shp・GeoJSON など。読み取り専用。裏はキャッシュ gpkg → [[external-formats]]）
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
| FolderNode | サブフォルダ、GeoPackage、gpkg 以外の形式（`loadExternalNodes`）、画像 |
| SysNode | なし（子は home_screen が差し込む。可視性だけ当て直す） |
| GeoPackageNode | レイヤ一覧 |
| ExternalLayerNode | キャッシュ gpkg を元に合わせてから（作り直したら読み込み済みのレイヤも読み直す）レイヤ一覧 |
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

### ファイルを追加したあと

```dart
// 「ファイルを追加」・ドラッグ＆ドロップでフォルダに写したあと（gpkg への取り込みは 2026-10-09 にやめた）
await folder.updateChildren();
```

### レイヤ移植後

```dart
// 移植先
await targetGeoPackage.updateChildren();
await migratedLayerNode.updateChildren();

// 移植元（移動の場合）
await sourceLayer.geoPackageNode.updateChildren();
```

移動で移し元の gpkg が空になったら（`gpkg_contents` が空。`layer_styles` だけなら空扱い）、`migrateToGeoPackage` の中で
`GeoPackageNode.deleteIfEmptiedByMove()` がファイル（`-wal` `-shm` `-journal` も）を消し、ノードを親から外し、
フォルダ設定からその gpkg の鍵を落とす。System・グローバルフォルダの下では消さない。削除で空になったときは消さない。

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

## 行の見た目と操作（2026-10-06 に刷新）

- 1 行は `lib/widgets/layer_drawer/drawer_row.dart` の `DrawerRow`（高さ 48px・細い区切り）。右端は表示/非表示の目
  （`VisibilityEye`）だけで、⋮ は置かない。メニューは長押しか右クリック（`RowMenuItem` → `showRowMenu`）
- 動かせる行（レイヤ・gpkg・ローカルのフォルダ・写真）は**左スワイプで「移動」**（`Dismissible` を戻して `MoveTargetDialog`）。
  フォルダ・gpkg・写真はフォルダへ、レイヤは別の gpkg へ移植。sys の下へは移さない。
  2026-10-06 に長押しドラッグから替えた（長押しのメニューと取り合い、ドラッグ中の枠の付け外しで中身が作り直されて長押し中の行が消える、
  という事故も踏んだ）。ファイルのドラッグ＆ドロップ（`DropTarget`）は 2026-10-09 に gpkg への取り込みをやめ、
  一覧に 1 つだけ置いて、落とした位置の下のフォルダの行（無ければ開いているフォルダ）にファイルをそのまま写す
  （フォルダの「ファイルを追加」と同じ `add_files_action.dart` → `FolderFileAdder`）。行ごとに置くと入れ子で両方に届く
- gpkg は行ではなく小さい見出し（`DrawerGroupHeader`。▾ で畳む・目で中をまとめて隠す・長押しにレイヤ追加）。
  空の gpkg にだけ「レイヤ追加」の行を出す
- レイヤ・View の行の左端は描画色の見本（`tiles/layer_swatch.dart`。View → レイヤ → 全体設定の順に合成）、名前の横に件数
- タイトルバーに道筋（`KokageMap › 共有`）。ルートの name は内部の `Home` なので、表示は `NodePresenter.getDisplayName` が
  開いているフォルダの名前にする
- チュートリアルの「⋮ を押す」案内は「行を長押し」に替え、`areaLayerMenu` / `newViewMenu` の鍵は行に付けた

## 関連ファイル

- [[layer_tree_node.dart|lib/models/nodes/layer_tree_node.dart]] - 基底クラス
- [[folder_node.dart|lib/models/nodes/folder_node.dart]] - フォルダノード
- [[geopackage_node.dart|lib/models/nodes/geopackage_node.dart]] - GeoPackageノード
- [[layer_node.dart|lib/models/nodes/layer_node.dart]] - レイヤノード
- [[layer_drawer.dart|lib/widgets/layer_drawer/layer_drawer.dart]] - UI実装
