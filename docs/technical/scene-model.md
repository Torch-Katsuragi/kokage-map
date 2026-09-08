---
title: シーンモデルの切り出し（MapLibre を外すための抽象化）
tags: [technical, design, 3d, architecture]
---

# シーンモデルの切り出し（順1・設計メモ）

> [!NOTE] 位置づけ
> 3D 化の順1（Vault `3D化の詰め_2026-09-07` 6 節・7 節）。2026-09-08 夜に seam ①③ と ② の一部を
> `TerrainMapLayer` として本体に接続した（[[terrain-3d]] の「本体への接続」）。インターフェース抽出はこれから。
> 2026-09-08 に master@429f472 の map_page まわりを調査した結果に基づく。3D 描画系そのものは [[terrain-3d]]。

## 結論

いまの地図ページは、思っていたより **既に切れている**。

- 地図面への描画は `MapSourceManager`（`lib/services/map_source_manager.dart`）にほぼ集約されていて、
  MapLibre の `StyleController` を直接叩くのは **ここと `map_basemap_mixin` の 2 箇所だけ**
- ツール・選択・情報カード・ジェスチャは **`IMapState`（`lib/interfaces/map_state_interface.dart`）と
  `RMapController`（`lib/core/r_map_controller.dart`）にしか依存していない**
- 当たり判定は `queryRenderedFeatures` を使わず **Dart 側の LatLng 距離計算**（`lib/tools/select_tool.dart`）。
  3D になっても差し替え不要。投影（`latLngToOffset` / `offsetToLatLng`）が正しければ動く

したがって seam は 3 本。①カメラ＋投影 ②シーン投入 ③ベースマップ供給。
「地図面の窓口は 4 つ（カメラの読み書き／投影・逆投影／ヒットテスト／スナップショット）」という設計ルールのうち、
ヒットテストは既に地図面の外にある。

## 3 本の seam

### ① カメラ＋投影: `RMapController` をインターフェースに

`RMapController` / `KMapCamera` が実質「カメラ＋投影のポート」。`raw`（`ml.MapController`）と `style` が MapLibre 型を漏らしているので隠す。

```
abstract class MapSurfaceController {
  bool get isAttached;                 // attach 前の操作は 1 件だけ退避する契約も引き継ぐ
  KMapCamera get camera;               // center / zoom / bearing / pitch
  Offset? toScreenLocation(LatLng);    // 3D: 地形の高さで持ち上げて投影
  LatLng? toLngLat(Offset);            // 3D: 視線と地形の交点（平面ではない）
  void move(center, zoom);  void moveAndRotate(center, zoom, bearing);
  Future<void> animateTo({center, zoom, bearing, pitch});
  Future<void> fitCoordinates(coords, {padding});
}
```

- **pitch は既に `KMapCamera` にあり、アプリのどこからも 0 以外を設定していない**（契約テストも pitch≒0 固定）。
  3D 化で最も影響の少ない自由度
- 3D 側の `toLngLat` は **視線と DEM の交点**（`TerrainPainter.isOccluded` と同じ視線なぞり）。
  平面に落とすと傾けたとき選択がずれる
- `zoom` の定義を揃える: 3D の `scale`（px / Mercator m）から `zoom = log2(scale · 2πR / 256)`。
  `SelectTool._calcSelectRange`（`20 · 2^(16−zoom)` m）と `PanTool` のフォーカルアンカリングがこれに依存する
- 契約テスト `integration_test/map_contract_test.dart` をこのインターフェースに対して回す。
  3D バックエンドも同じ契約に通せば UI 側は無傷

### ② シーン投入: `MapSourceManager` の API 形を `SceneSink` に抜き出す

`MapSourceManager` は実質「シーングラフの投入 API」。この形をそのままインターフェースにする。

```
abstract class SceneSink {
  void updateFeatures(String sourceId, List<geo.Feature> features);   // 12 の固定ソース
  void setStyleGroups(List<MapStyleGroup> groups);                     // View 固有スタイル
  void updateLayerStyles(...);                                         // 全体設定の解決値
  void configureClustering(...);  void refreshClusters(double zoom);
  void updateGpsTrack(List<LatLng> points);
  void addOverlayImage(id, url, LngLatQuad); void updateOverlayCoordinates(...); void removeOverlayImage(id);
}
```

- フィーチャは **geobase の `Feature` + プロパティ `k-style`（スタイルグループ）/ `k-label`（ラベル文字列）** で届く
  （`feature_geojson_cache.dart`）。3D 側はこれを `LiftedPolyline` / `LiftedPolygon` / `TerrainLabel` に変換して DEM で持ち上げる。
  **スタイル解釈（`SettingsStore.resolveXxx` → `MapStyleGroup`）は既に描画系の外にある**ので、3D 側は解決済みの値を受けるだけ
- v1 は **12 個の固定ソースという粒度をそのまま持ち込む**（最小変更）。
  ⚠ その場合「全レイヤが 1 本のソースを共有するのでレイヤ間の真の z 順を表現できない」制約も引き継ぐ。
  3D で本当に欲しいのはレイヤ単位の投入。MapLibre を外す段でレイヤ単位に再設計する
- クラスタリングは MapLibre 任せではなく Dart 側の supercluster（`refreshClusters(zoom)`）。3D でもそのまま使える
- 頂点表示・写真アイコン・クラスタ数のラベルは MapLibre の Circle / Symbol レイヤ。3D ではビルボードで描く
- ⚠ MapLibre 固有の事情（レイヤ remove→add、ラベルレイヤに filter を付けると R8 で落ちる、web の `addSource` バグ）は
  実装側に閉じ込め、インターフェースに漏らさない

### ③ ベースマップ供給: `BaseMapService.getTile` をそのまま使う

- 入口は **`BaseMapService.getTile(provider, z, x, y) → Uint8List?`**（`lib/services/basemap_service.dart`）。
  キャッシュ → ネット → 保存 → 祖先タイルからの切り出しフォールバックまで込み。
  3D のテクスチャ合成（`RasterTileComposer`）はいま http 直叩きなので、これに差し替えれば **同じ絵・同じオフライン挙動**になる
- 複数プロバイダのブレンド（`activeLayerConfig` の累積補正済み opacity）は合成時に同じ式で重ねる
- オーバーレイ画像（GeoTIFF・写真）はラスタなので、`LngLatQuad` → 合成テクスチャに `drawImage`（行列変換）で焼く。
  設計どおり「ラスタはテクスチャ」
- web はソースを初期スタイル JSON に焼き込む作りで、後からラスタソースを足せない（maplibre_web 0.3.5）。
  3D 描画系は自前なので無関係。**2D の hillshade だけがこの制約を食う**

## 残る MapLibre 依存（切り出し時に触るもの）

| 箇所 | 内容 | 対処 |
|---|---|---|
| `IMapState.activeOverlaySourceIds` | MapLibre のソース ID 概念が漏れている唯一の箇所 | 「オーバーレイ画像の集合」に抽象化 |
| `RMapWidget`（`lib/widgets/map/r_map_widget.dart`） | 地図ウィジェット生成の薄いラッパ。`onMapCreated / onStyleLoaded / onEvent / layers / children` | **レンダラ切替の物理的な差し込み口**。`MapSurface` にして中で MapLibre / 3D を選ぶ |
| `map_page.dart` の `ml.PolygonLayer / ml.PolylineLayer / ml.WidgetLayer` | 描画プレビュー・投げ縄・パーティ軌跡・DeviceTool のオーバーレイ・現在位置とパーティのマーカー | シーンの一時プリミティブ（線・面・マーカー）として `SceneSink` に流す |
| `DeviceTool.buildOverlayLayers / buildOverlayMarkers`（`lib/devices/base/device_tool.dart`） | `ml.Layer` / `ml.Marker` を返す唯一のプラグイン境界 | 同上のプリミティブを返す形に |
| `map_basemap_mixin.dart` | `addSource / addLayer / removeLayer` | ③ の実装側に移す |
| 現在位置・パーティのマーカー（`ml.Marker` = Widget） | 画面座標に置く Widget | 3D では `toScreenLocation` で置く `Stack` のオーバーレイ（`cameraTickNotifier` で追従）。既存の画面外インジケータと同じ作り |

## 2 モードの交代（順3 の前提）

- `MapSurface` が `pitch > 0`（かつロック解除）で 3D、真上ロックで MapLibre を前面にする。両方を `Stack` に置き、状態は捨てない
- カメラは `MapSurfaceController` 1 つを共有し、交代時に相手へ同期してから表示を入れ替える（逆順だと一瞬跳ぶ）
- 正射影なので真上視点の幾何は一致する。継ぎ目が出るとすればスタイルの見た目差（線幅・ラベルのフォント）。
  ここは 3D 側を MapLibre に寄せる

## 実装順序（案）

1. インターフェース抽出だけ（挙動を変えない）: `MapSurfaceController`、`SceneSink`、`IMapState` のオーバーレイ抽象化、
   `DeviceTool` のプリミティブ化。契約テストを新インターフェースに対して回す
2. 3D 実装: `TerrainSceneSink`（GeoJSON → 持ち上げ）、`TerrainSurfaceController`（`TerrainCamera` + 視線と DEM の交点）、
   `MapSurface` の切替、ベースマップを `getTile` から合成
3. 順3: 真上ロック・ツールのゲート・カメラ同期
4. 機能一覧の追い付き: クラスタ・頂点・写真アイコン・オーバーレイ画像・GPS 軌跡・パーティ・画面外インジケータ・描画プレビュー・ラベル衝突

## 参考（調査の要点）

- 可視レイヤの列挙＝z 順の根拠は `LayerTreeNode.getVisibleLayerNodes()`。データの正は `LayerNode._featureMap`（GeoPackage → Isolate で WKB パース）
- スタイル解決: `SettingsStore.resolveXxx`（KMeta → SharedPreferences → 既定）。View 固有スタイルは `LayerNode.refreshStyleGroups()`（最初に当たった View が勝つ）
- ラベル: `label_template.dart` → `_labelFor` → `k-label`。3 枚の Symbol レイヤ（面は重心、線は `symbol-placement: line`、点は下に）
- 選択: `SelectTool._buildCandidates`（現在位置は画面 22px で最優先、以降 点 → 線 → 面 を距離順、同じ場所を叩くとサイクル）
