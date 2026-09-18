// geodiff（GeoPackage の行単位 3-way マージ）。
// Android / ホスト VM は dart:ffi 実装、web は stub（マージしない）。
// 設計: docs/technical/drive-geodiff-sync.md ／ ビルド: third_party/geodiff/README.md
export 'geodiff_stub.dart' if (dart.library.ffi) 'geodiff_ffi.dart';
