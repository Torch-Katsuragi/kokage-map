# CLI / URL からの起動と読み直し（AI フレンドリーな口）

> [!NOTE] 何のためか
> データはローカルの `.gpkg` / `.qgs` にある（フォルダ設定は `.qgs` の `kokage/meta`）。AI やスクリプトはそれらを
> QGIS の API・sqlite・JSON で直接書き換えればよく、アプリには
> **「このプロジェクトを開いて」「ここを見せて」「読み直して」** だけ頼めれば足りる。
> その頼み方を 1 本の文字列（ルート）に決めたのが `LaunchRequest`（2026-09-12、松本の要望）。

## ルートの形

```
/map?project=<絶対パス>&lat=33.9&lon=135.57&zoom=15&bearing=30&pitch=45&reload=1
```

| キー | 意味 |
|---|---|
| `project` | 開くプロジェクトフォルダ（端末上の絶対パス）。web は `opfs:<名前>`（下の「web を外から動かす」）。起動時、またはホーム画面にいる間だけ効く |
| `lat` `lon`（`lng`） | 中心。両方そろって初めて効く |
| `zoom`（`z`） | ズーム |
| `bearing` | 方位（度、北 0・時計回り） |
| `pitch` | 傾き（度、0 が真上。上限は 3D の上限と同じ 75） |
| `reload` | `1` でディスクから読み直す（`.gpkg` / `.qgs` の読み戻しまで） |

カメラは保存しない方針（2026-09-09）なので、位置は起動側が毎回明示する。
指定が無いときの起動時のカメラ（2026-09-13）: フィーチャがあれば全部が入る範囲（GPS へは飛ばない）、無ければ東京で始めて GPS が取れたらそこへ飛ぶ（`fitToFeaturesAtStart`）。

## 届き方

- **Android・起動時**: Flutter の標準どおり `--route` / intent extra `route` → `defaultRouteName`。
  `LaunchRequest.init()` がそれを読む。`/map?...` は `routes` に無いので Navigator の既定の初期ルート生成が
  `/`（ホーム）に落とし、ホームが `project` を開き、地図がカメラを合わせる
  （`HomeScreen._maybeAutoOpenProjectDir`、`MapPage._applyLaunchRequest`）。
  ⚠ `onGenerateInitialRoutes` は `home:` と併用できない（debug で assert）ので使わない
- **Android・起動中**: `MainActivity` は `singleTop` なので `onNewIntent` に同じ intent が来る。
  MethodChannel `com.k_root.k_maps/launch` の `route` で Dart に渡し、`LaunchRequest.incoming` に流れる
- **web**: `#/map?...`。起動時は `window.location.hash`、起動中は `hashchange`
- ⚠ 素の `/map`（`#/map`）も**ホームから始まる**（`/map` は routes に置かない。置くと初期ルートが `/`+`/map` の 2 段になりホームが二重に積まれる）。地図ページへ直行させると、プロジェクト未設定の
  仮ルートのまま GeoPackage が作れてしまい、web ではブラウザの IndexedDB にしか残らない幽霊になった
  （2026-09-12）。プロジェクト未設定のときはレイヤ一覧の追加ボタンも出さない
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

## web を外から動かす（OPFS、2026-09-30）

web 版はふつうフォルダ選択（File System Access API）で開くが、選択と許可の確認は人が押さないと通らない。
ブラウザのサイト専用領域（OPFS）なら要らないので、テスト用のフォルダを流し込んで `#/map?project=opfs:<名前>` で開く。

```bash
python tool/web_opfs.py <テスト用フォルダ> --port 8098   # フォルダを配る（別に web 版を 8099 で出しておく）
```

アプリのページ（`http://localhost:8099`）の中で、DevTools のコンソールかブラウザを動かす道具から:

```js
const m = await import('http://localhost:8098/web_opfs.js');
await m.seed('http://localhost:8098', 'Kitayama-2026');    // 空にしてから丸ごと入れる
location.href = '/?r=1#/map?project=opfs:Kitayama-2026';     // 開く
await m.list('Kitayama-2026'); await m.read('Kitayama-2026/Kitayama-2026.qgs');  // 確かめる
```

- ⚠ タブが隠れていると（`document.visibilityState` が `hidden`）描画が止まり、地図の初期化が進まない。
  見えている画面で動かすか、スクリーンショットを撮って描画を進める
- 同じ名前のフォルダを何度も使うと、前の回の DB が sqlite3 WASM の worker に残っていることがある。確かめ直すときは名前を変える
- 前回のフォルダ（IndexedDB）には残さない。利用者の「前回のフォルダ」を上書きしない

⚠ Git Bash から `--es route "/map?..."` を渡すと MSYS がパスに変換することがある。`MSYS_NO_PATHCONV=1` を付ける
（[[reference-adb-device-and-msys]] と同じ）。`kokage.py` は Python の `subprocess` なので影響を受けない。

## 典型的な流れ（AI が編集 → 見せる）

1. QGIS の API か sqlite で `.gpkg` を編集し、`.qgs` を QGIS で保存する（QGIS で保存したものは開いたときに読み戻す）。
   アプリの設定を直接書くなら `.qgs` の `kokage/meta` の JSON を書き換え、`saveDateTime` と `kokage/savedAt` をそろえる
2. `kokage.py reload --at <編集した場所>,16` — 開き直さずに反映し、その場所へ寄る
3. スクショや `adb logcat` で確認

## 実装

- `lib/core/launch_request.dart`（解釈・生成・起動時の要求・到着の通知）、`launch_request_io.dart` / `launch_request_web.dart`
- `lib/interfaces/terrain_projection.dart` の `lookAt`（方位・傾きまで含めてカメラを合わせる）
- テスト: `test/launch_request_test.dart`
