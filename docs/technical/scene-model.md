---
title: シーンモデルと地図面のインターフェース
tags: [technical, design, 3d, architecture]
---

# シーンモデルと地図面のインターフェース

> [!NOTE] 位置づけ
> 地図ページ・ツール群と 3D 地形描画系（`TerrainMapLayer`）の境界を定義するインターフェース。
> 3D 描画系そのものは [[terrain-3d]] を参照。

## 構成（2026-10-11）

地図面は `TerrainMapLayer` 1 つ。アプリ側（ツール・地図ページの mixin・ホルダー経由の画面）は描画系の具体的な型を知らない。

```
ツール / mixin ──IMapState.mapController──▶ MapSurfaceController ─(実装)─ MapSurfaceHandle ──attach──▶ MapSurface ◀─(実装)─ TerrainMapLayer
地図ページ ──SceneSink──▶ MapSceneStore ──MapScene（revision が増えたら読み直す）──▶ TerrainMapLayer
```

### ① カメラ＋投影: `MapSurfaceController` / `MapSurface`（`lib/interfaces/map_surface.dart`）

| 型 | 誰が実装 / 使う | 中身 |
|---|---|---|
| `MapSurface` | `TerrainMapLayer`（`_TerrainCameraControl`）が実装 | `project` / `unproject`（地形の高さ・視線と地形の交点）、`jumpTo`・`fitCoordinates`・`lookAt` |
| `MapSurfaceController` | ツール・mixin・`mapControllerHolderProvider` が使う | `isAttached`・`camera`・`lastCenter`、`toScreenLocation` / `toLatLng`、`move`・`moveAndRotate`・`jumpTo`・`animateTo`・`fitCoordinates`・`lookAt` |
| `MapSurfaceHandle`（`lib/core/map_surface_handle.dart`） | 地図ページが持つ実装 | 最後のカメラを覚える（地図面が `rememberCamera` で知らせる）。attach 前のカメラ操作は**最後の 1 件だけ**保留し、attach の時点で流す |

- `IMapState.offsetToLatLng` / `tryOffsetToLatLng` / `latLngToOffset` は `mapController` を通す（地図面が無ければ中心・画面中央で代える）
- 起動ルートのカメラ指定（`LaunchRequest`）は保留の 1 件と混ぜない。地図ページが持っておき、**attach の直前**に `MapSurface.lookAt` で流す
  （そのあと attach で保留分が流れる。旧 `jumpOverride` を置いたときと同じ順）
- ⚠ `moveAndRotate` の方位は覚えるだけで地図面へは渡さない（旧 `jumpOverride` の挙動のまま。地図面の回転は地図面自身のジェスチャが持つ）
- 地図面の 4 つの窓口のうち、**当たり判定**は地図面の外（ツールが投影とフィーチャの座標で Dart 側で計算する。`SelectTool.candidatesAt`。
  パーティの共有ピンだけは `TerrainMapLayer._pinAt`）。**スナップショット**は使い道がまだ無いので口を持たない
- 旧 `RMapController`（`jumpOverride` / `fitOverride` を差し替える形）と `TerrainProjection` はこれに置き換えて消した

### ② シーン投入: `SceneSink` / `MapScene`（`lib/interfaces/scene_sink.dart`）

| 型 | 誰が | 中身 |
|---|---|---|
| `SceneSink` | 地図ページが書く | `setStyleGroups`（変わったら true。フィーチャを組む**前**に）、`pushFeatures(input, selectionOnly:)`、`invalidate`（中身を変えずに組み直させる） |
| `MapScene` | `TerrainMapLayer` が読む | `features`（`FeatureGeoJsonCache`）・`styleGroups`・`overlayImages`・`revision` |
| `MapSceneStore`（`lib/screens/map_page/map_scene_store.dart`） | 両方の実装。所有は地図ページ（`MapPageStateBase.scene`） | 書いたら必ず `revision` を進める |

- 設計メモの案（差分を `updateFeatures(sourceId, …)` で押し込む）ではなく、**合図が来たら読み直す**形にした。
  3D は `FeatureGeoJsonCache` のリストの同一性と `contentRevision` で差分を見ているので、押し込み型にする理由が無い
- オーバーレイ画像の正は地図ページのフィーチャキャッシュ（選択ツールも読む）。シーンは覗くだけ
- 今日の GPS 軌跡・現在位置・方位・パーティ・描画プレビューは、いまも `TerrainMapLayer` の引数や provider から直接読む（動的シーン）。
  変わったときの合図だけ `invalidate` を通る（GPS 軌跡）

### ③ ベースマップ供給

変わらず `BaseMapService.getTile`（`TerrainMapLayer.baseMapService`）。インターフェースは切っていない。

### 契約テスト

`test/map_surface_handle_test.dart`・`test/map_surface_tools_test.dart`・`test/map_scene_store_test.dart`（[[testing#地図面の契約テスト]]）。
旧 `integration_test/map_contract_test.dart` は MapLibre と一緒に外した（2026-10-04）。

### 残り（切り出していないもの）

- `TerrainMapLayer` は `IMapState` も受け取る（ツールのジェスチャを `currentTool.onTap(d, mapState)` へ渡すため）。描画系がツールの入口を兼ねている
- GPU レンダラ（`TerrainGpuWorldRenderer` / web の WebGL2）と `TerrainWorldPainter` の内側は触っていない
- 名前の名残: `IMapState.mapController`・`mapControllerHolderProvider`（中身は `MapSurfaceController`）、`KMapCamera.rotation`（旧 flutter_map の名前）
