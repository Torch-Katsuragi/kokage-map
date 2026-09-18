# geodiff（行単位マージ用のネイティブライブラリ）

[geodiff](https://github.com/MerginMaps/geodiff) 2.3.1（MIT）を、このアプリ向けにビルドしたもの。
設計は [[../../docs/technical/drive-geodiff-sync|Drive 同期の行単位マージ]]。

| 成果物 | 置き場 | 作り方 |
|---|---|---|
| `libgeodiff.so`（Android arm64-v8a） | `android/app/src/main/jniLibs/arm64-v8a/` | `build_android.sh` |
| `geodiff.dll`（Windows x64、ホスト VM テスト用） | `third_party/geodiff/windows/` | `build_windows.cmd` |

## 方針

- **vcpkg は使わない**。Mergin の mobile-sdk は QGIS ごと焼くので vcpkg だが、こちらは sqlite3 と geodiff の 2 つだけ。
  sqlite3 は amalgamation 1 ファイルを直接コンパイルし、geodiff に静的リンクする
- geodiff は外部 SQLite3 必須で、**session 拡張と preupdate hook** が要る
  （`SQLITE_ENABLE_SESSION` `SQLITE_ENABLE_PREUPDATE_HOOK`）。加えて `RTREE` `COLUMN_METADATA` `FTS5` を有効にしてある
- libgpkg は geodiff の CMake がビルド時に GitHub から取ってくる（ネットワークが要る）
- Android は NDK 28.2（`ndkVersion` と同じ）、API 24、libc++ は静的。`NEEDED` は `libm` `libdl` `libc` だけ
- 依存するのは Android SDK 同梱の cmake 3.22.1 / ninja と NDK。Windows 側は Visual Studio の `cl`

## Dart からの呼び方

`DynamicLibrary.open('libgeodiff.so')`（Android）／`DynamicLibrary.open('third_party/geodiff/windows/geodiff.dll')`（ホスト VM テスト）。
C API は `geodiff/src/geodiff.h`。戻り値は `0` 成功・`1` 失敗・`2` 衝突あり・`3` 未対応の変更。

## 確認

`integration_test/geodiff_smoke_test.dart`（実機）: version が返る／このアプリの gpkg で A・B の独立編集が rebase で 1 つに載り、
同じ行の衝突だけ `conflict.json` に出る。
