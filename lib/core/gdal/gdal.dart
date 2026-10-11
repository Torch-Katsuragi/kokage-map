// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
// GDAL の窓口。Android は FFI（libgdal.so）、web は同じ GDAL を WebAssembly に焼いたもの。
// 設計は docs/technical/gdal.md
//
// QGIS と同じ部品で読むために、GDAL のコマンドラインユーティリティ（gdal_utils.h の C API、web も同じ関数を WASM から）を
// 引数の文字列でそのまま呼ぶ形にしている。引数は ogr2ogr / gdalwarp などのコマンドと同じ書き方。
// パスは KFileSystem（`fs`）のパス。web の実装は OPFS とのあいだで中身を受け渡す。

/// GDAL の呼び出しに失敗した（CPLGetLastErrorMsg の文言を持つ）
class GdalException implements Exception {
  GdalException(this.message);
  final String message;
  @override
  String toString() => 'GdalException: $message';
}

abstract class Gdal {
  /// GDAL の版（`GDALVersionInfo("RELEASE_NAME")`）。初回は読み込みを待つ（web は WASM の取得）
  Future<String> version();

  /// `gdalinfo -json <args> <path>` の JSON
  Future<Map<String, dynamic>> rasterInfo(String path, {List<String> args = const []});

  /// `ogrinfo -json <args> <path>` の JSON（`GDALVectorInfo`）
  Future<Map<String, dynamic>> vectorInfo(String path, {List<String> args = const []});

  /// `ogr2ogr <args> <dst> <src>`（`GDALVectorTranslate`）。[dst] は書き出し先のパス
  Future<void> vectorTranslate(String src, String dst, {List<String> args = const []});

  /// `gdalwarp <args> <src> <dst>`（`GDALWarp`）
  Future<void> warp(String src, String dst, {List<String> args = const []});

  /// `gdal_translate <args> <src> <dst>`（`GDALTranslate`）
  Future<void> translate(String src, String dst, {List<String> args = const []});

  /// [path] と一緒に読まれる付属ファイル（`GDALGetFileList`。shp なら .dbf .shx .prj …、GeoTIFF なら .ovr .aux.xml …）。
  /// 自分自身を含む。変換後の削除・更新時刻の判定・web での受け渡しに使う
  Future<List<String>> fileList(String path);
}
