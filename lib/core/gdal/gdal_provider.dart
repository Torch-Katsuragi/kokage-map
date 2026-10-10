// GDAL の実装の差し替え口。呼ぶ側は `createGdal()` で [Gdal] を得る（使い回してよい）。
//
// 各実装ファイルは同じ名前のトップレベル関数 `Gdal createGdal()` を持つこと:
//   - gdal_ffi.dart  … Android / ホスト VM（libgdal.so ／ QGIS の gdal*.dll ／ apt の libgdal）
//   - gdal_web.dart  … web（gdal3.js）
//   - gdal_stub.dart … どちらでもない環境（呼ぶと UnsupportedError）
// 設計: docs/technical/gdal.md
export 'gdal.dart';
export 'gdal_stub.dart'
    if (dart.library.ffi) 'gdal_ffi.dart'
    if (dart.library.js_interop) 'gdal_web.dart';
