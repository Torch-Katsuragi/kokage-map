# こかげマップ

山の現場で、追加の道具を用意せずに使える GIS（Flutter 製）。

- **紹介ページ**: https://kokage-map.sleeptree.jp/about/
- **web版**: https://kokage-map.sleeptree.jp

> web版アプリ本体（`/`）は検索に載せていません（noindex）。紹介ページ（`/about/`）とプライバシーポリシー（`/privacy/`）のみ検索対象です。Chrome / Edge 推奨
> （フォルダを開くのに File System Access API を使うため）。

## どんなアプリか

同種のツールが求めがちなものを、こかげマップは求めません。

- スタイラス不要（指で描ける）
- 専用クラウド不要（同期はユーザー自身の Google Drive）
- QGIS プラグイン不要（GeoPackage と QGIS のプロジェクト `.qgs` をそのまま開く）
- アカウント不要（ローカルで完結する）
- 専用ハードウェア不要（位置共有はスマホだけで成立する）

| | 役割 |
|---|---|
| **Android** | 本体。GPS 測量・軌跡の記録・外部 GNSS・TruPulse・オフライン地図など現場の機能 |
| **web** | 閲覧・共有・事務所作業。インストール不要で、ルームへの参加も URL で済む |

デスクトップ版（Windows / macOS / Linux）は 2026-08-25 に撤去し、web版が引き継いでいます。

考え方の詳細は [コンセプト](docs/features/concept.md)。

## 主な機能

- **QGIS と往復できる**: フォルダの `.gpkg` を直接読み書きし、`.qgs` にスタイル・View・表示を書き、QGIS で直したものを読み戻す。
  QGIS の分類・段階・ルールの表示、属性フォーム（値のリスト・日付・別名・既定値・制約）にも合わせる
- **gpkg 以外のファイルもそのまま開く**: フォルダに置いた Shapefile などを読み取り専用のレイヤとして出し、編集するときは gpkg に変換する。
  ラスタはオーバーレイとして重ねる（下の「対応形式」）
- **描画・編集**: 指でなぞって点・線・面を描く、投げ縄選択、消しゴム、属性テーブル（QGIS 式のフィルタ・フィールド計算機）、属性で探す
- **GPS 測量**: 平均化、線・面の測量、軌跡の記録と抽出、外部 GNSS（Bluetooth・NMEA）、測位の品質（RTK FIX・衛星数・HDOP など）の記録と足切り
- **計測と案内**: 距離・面積の計測、地物の長さ・面積、地点への案内（通信不要）。方位は磁気偏角（WMM2025）で真北に直す
- **TruPulse 360R**: Bluetooth で直接つなぎ、閉合補正（コンパス法則 / トランシット法則）・磁気偏角・器械高まで扱う
- **位置共有パーティ**: ルームコードで参加し、全員の位置を共有する。圏外の間の軌跡は復帰後に GPS 履歴から埋める
- **Google Drive 同期**: ユーザー自身の Drive のフォルダと同期。GeoPackage は行単位でマージ（geodiff）。QR で地図を渡せる
- **背景地図**: 地理院タイル・OpenStreetMap などを重ねて使う。URL で XYZ / WMS を足せる。一括ダウンロードでオフライン
- **3D 地形**: 2D と 3D（地形の立体表示）を切り替える。3D でも計測や GPS 測量ができる

使い方はアプリ内の使い方ガイド（[日本語](assets/user_guide/ja.md) / [English](assets/user_guide/en.md)）、変更は [更新履歴](assets/changelog/ja.md)。

## 対応形式

アプリに同梱した GDAL 3.13.3 / PROJ 9.9.0（QGIS と同じ GDAL）で読み書きします。Android と web で同じ版・同じドライバの組です。

| | 形式 |
|---|---|
| 読み書き | GeoPackage（`.gpkg`） |
| 読み取り専用のレイヤ（gpkg に変換して編集） | Shapefile、GeoJSON、KML / KMZ、CSV（経度・緯度の列）、GPX、FlatGeobuf、GML、DXF、MapInfo（`.tab` `.mif`） |
| ラスタのオーバーレイ | GeoTIFF、ワールドファイル付きの PNG / JPEG、VRT |
| 書き出し | Shapefile、GeoJSON、KML、CSV、GPX、FlatGeobuf、DXF、GeoPackage |

詳細は [gpkg 以外の形式](docs/technical/external-formats.md)・[GDAL](docs/technical/gdal.md)・[レイヤの書き出し](docs/technical/import-export.md)。

## ビルド

Flutter の stable（CI は `.github/workflows/ci.yml` の `FLUTTER_VERSION`）。

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # *.g.dart はリポジトリに入れていない
```

### Android

```bash
flutter build apk --release        # Play に出すときは flutter build appbundle --release
```

- ネイティブライブラリ `libgdal.so` と `libgeodiff.so`（arm64-v8a / armeabi-v7a / x86_64）は `android/app/src/main/jniLibs/` にコミット済み。
  `proj.db` と `gdal_data.zip` は `assets/gdal/`。焼き直すときは [third_party/gdal](third_party/gdal/README.md)・[third_party/geodiff](third_party/geodiff/README.md)
- 署名鍵（`android/key.properties`）が無いとリリースビルドは署名されない（[署名鍵の管理](docs/technical/signing.md)）

### web

```bash
bash tool/web/fetch_gdal_wasm.sh   # GDAL の WebAssembly を web/gdal3/<組>/ に置く（約 24 MB、リポジトリに入れていない）
flutter build web --release        # Drive 連携を使うなら --dart-define=GOOGLE_WEB_CLIENT_ID=...
```

`build/web/` を HTTP サーバーで配ります（`file://` では動きません）。配り方は [web版のホスティング](docs/technical/web-hosting.md)。

### テスト

Android と web の両方で通します。手順と落とし穴は [テスト構成](docs/technical/testing.md)。

```powershell
pwsh tool/test_matrix.ps1 -Only analyze,unit   # 端末の要らない段だけ
```

## ドキュメント

- [ドキュメント目次](docs/index.md)
- [コンセプト](docs/features/concept.md)
- [QGIS 相互運用](docs/technical/qgis-interop.md)
- [Drive 同期の行単位マージ](docs/technical/drive-geodiff-sync.md)
- [位置共有の設計](docs/technical/location-sharing.md)
- [TruPulse 360R](docs/devices/trupulse-360r.md)
- [AGENTS.md](AGENTS.md)（開発の決まり）

## ライセンス

こかげマップは [GNU General Public License v2.0 or later（GPL-2.0-or-later）](LICENSE) で公開しています。

- 商用利用・個人利用・配布・改変ができます
- 改変したものを配布するときは、全体のソースコードを同じ GPL で公開する必要があります

同梱しているネイティブライブラリは、それぞれのライセンスに従います。GDAL・PROJ・expat・libiconv・geodiff・libgpkg の本文は、アプリの「アプリ情報 → オープンソースライセンス」でも読めます。

| もの | ライセンス | 本文 |
|---|---|---|
| GDAL 3.13.3（内蔵の libtiff・libgeotiff・libjpeg・libpng・json-c・LERC・flatbuffers などを含む） | MIT ほか（本文に各条文） | [assets/licenses/gdal.txt](assets/licenses/gdal.txt) |
| PROJ 9.9.0 | MIT | [assets/licenses/proj.txt](assets/licenses/proj.txt) |
| expat 2.9.0 | MIT | [assets/licenses/expat.txt](assets/licenses/expat.txt) |
| GNU libiconv 1.18 | LGPL-2.1-or-later | [assets/licenses/libiconv.txt](assets/licenses/libiconv.txt) |
| SQLite | パブリックドメイン | — |
| geodiff 2.3.1 | MIT | [assets/licenses/geodiff.txt](assets/licenses/geodiff.txt) |
| libgpkg（geodiff に静的に入る） | Apache-2.0 | [assets/licenses/libgpkg.txt](assets/licenses/libgpkg.txt) |
| flutter_bluetooth_serial（手元で直した版） | MIT | [third_party/flutter_bluetooth_serial/LICENSE](third_party/flutter_bluetooth_serial/LICENSE) |

Dart / Flutter のパッケージのライセンスは、同じ画面に一覧が出ます。

## リンク

- **リポジトリ**: https://github.com/Torch-Katsuragi/kokage-map
- **プライバシーポリシー**: [PRIVACY_POLICY.md](docs/PRIVACY_POLICY.md)
