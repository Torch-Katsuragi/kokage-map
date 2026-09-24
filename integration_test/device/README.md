# 実機専用の統合テスト

`dart:io` / `dart:ffi`（geodiff のネイティブライブラリ）を使うので、web では動かない。
CI の e2e(web) は `integration_test/*_test.dart` だけを回すので、ここは対象外。

| ファイル | 中身 |
|---|---|
| `geodiff_smoke_test.dart` | `libgeodiff.so` が読めて rebase が通るか |
| `geodiff_sync_roundtrip_test.dart` | 2 台の往復シナリオ（偽 Drive、1 台で模す。ホスト VM 版と共有） |
| `geodiff_two_device_test.dart` | 実機 2 台で往復（`tool/sync_relay/run_two_device.sh` から） |
| `gpkg_rtree_android_test.dart` | Android の SQLite に rtree が無いこと、geodiff の SQLite で焼き直せること |
| `geodiff_bench_test.dart` | 面 2 万筆での速さ |

```bash
flutter test integration_test/device/geodiff_sync_roundtrip_test.dart -d <device>
```

⚠ `flutter test` は終わるとアプリを消す。普段使いの端末では `run_two_device.sh` のように
applicationId に接尾辞を付けて並べて入れること。
