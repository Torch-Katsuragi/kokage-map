# CLI / URL からの起動と読み直し（AI フレンドリーな口）

> [!NOTE] 何のためか
> データはローカルの `.gpkg` / `.kmeta.json` / `.qgs` にある。AI やスクリプトはそれらを
> QGIS の API・sqlite・JSON で直接書き換えればよく、アプリには
> **「このプロジェクトを開いて」「ここを見せて」「読み直して」** だけ頼めれば足りる。
> その頼み方を 1 本の文字列（ルート）に決めたのが `LaunchRequest`（2026-09-12、松本の要望）。

## ルートの形

```
/map?project=<絶対パス>&lat=33.9&lon=135.57&zoom=15&bearing=30&pitch=45&reload=1
```

| キー | 意味 |
|---|---|
| `project` | 開くプロジェクトフォルダ（端末上の絶対パス）。web では無視。起動時、またはホーム画面にいる間だけ効く |
| `lat` `lon`（`lng`） | 中心。両方そろって初めて効く |
| `zoom`（`z`） | ズーム |
| `bearing` | 方位（度、北 0・時計回り） |
| `pitch` | 傾き（度、0 が真上。上限は 3D の上限と同じ 75） |
| `reload` | `1` でディスクから読み直す（`.kmeta.json` / `.gpkg` / `.qgs` の読み戻しまで） |

カメラは保存しない方針（2026-09-09）なので、位置は起動側が毎回明示する。

## 届き方

- **Android・起動時**: Flutter の標準どおり `--route` / intent extra `route` → `defaultRouteName`。
  `MaterialApp.onGenerateInitialRoutes` が `/map?...` をホーム画面から始め、ホームが `project` を開き、
  地図がカメラを合わせる（`HomeScreen._maybeAutoOpenProjectDir`、`MapPage._applyLaunchRequest`）
- **Android・起動中**: `MainActivity` は `singleTop` なので `onNewIntent` に同じ intent が来る。
  MethodChannel `com.k_root.k_maps/launch` の `route` で Dart に渡し、`LaunchRequest.incoming` に流れる
- **web**: `#/map?...`。起動時は `window.location.hash`、起動中は `hashchange`
- 地図メニューの「プロジェクトを読み直す」は `reload=1` と同じ処理（`MapPage.reloadProjectFromDisk`）

## CLI

```bash
python tool/kokage.py open --project /sdcard/FieldSurvey/Kitayama-2026 --at 33.8985,135.5718,15
python tool/kokage.py open --at 33.8985,135.5718,16 --bearing 30 --pitch 45
python tool/kokage.py reload
python tool/kokage.py url --at 33.8985,135.5718,15     # web 版の URL を出すだけ
```

中身は `adb shell am start -n com.k_root.k_maps/.MainActivity --es route "/map?..."`。
`-s <serial>` で端末を選ぶ。Surface の adb をトンネル越しに使うときは `ADB_SERVER_SOCKET` がそのまま効く。

⚠ Git Bash から `--es route "/map?..."` を渡すと MSYS がパスに変換することがある。`MSYS_NO_PATHCONV=1` を付ける
（[[reference-adb-device-and-msys]] と同じ）。`kokage.py` は Python の `subprocess` なので影響を受けない。

## 典型的な流れ（AI が編集 → 見せる）

1. QGIS の API か sqlite で `.gpkg` を編集、`.kmeta.json` を書き換える（正典は `.kmeta.json`、`.qgs` は自動更新）
2. `kokage.py reload --at <編集した場所>,16` — 開き直さずに反映し、その場所へ寄る
3. スクショや `adb logcat` で確認

## 実装

- `lib/core/launch_request.dart`（解釈・生成・起動時の要求・到着の通知）、`launch_request_io.dart` / `launch_request_web.dart`
- `lib/interfaces/terrain_projection.dart` の `lookAt`（方位・傾きまで含めてカメラを合わせる）
- テスト: `test/launch_request_test.dart`
