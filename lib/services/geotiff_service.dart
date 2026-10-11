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
/// GeoTIFF変換サービス
///
/// 写真を「オーバーレイに変換」した GeoTIFF を書き、位置合わせ（移動・拡大縮小・回転）で位置を書き換える。
/// 書くのは GDAL（`gdal_translate`。Android は FFI、web は WASM）。QGIS で開いて警告が出ない形にするため
/// （以前の `package:image` の TIFF は「タグの並びが不正」「タイル幅が規格外」「ExtraSamples が合わない」と言われた）。
/// 形: EPSG:4326・DEFLATE・256 のタイル・RGBA（4 バンド目は ExtraSamples = 結合されていないアルファ）。
/// 位置は geoTransform（回転があれば GDAL が ModelTransformationTag、無ければ ModelTiepoint + ModelPixelScale で書く）。
/// 目印に TIFFTAG_SOFTWARE = [kSoftware] を入れ、これで外のラスタ（読み取り専用）と見分ける。
/// 設計: docs/technical/external-formats.md「アプリの GeoTIFF」
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/fs/k_file_system.dart';
import '../core/gdal/gdal_provider.dart';
import '../core/path_resolver.dart';
import '../core/terrain/terrain_worker.dart';
import '../models/kmeta.dart';
import '../utils/app_logger.dart';
import '../widgets/dialogs/overlay_convert_dialog.dart';
import 'global_folder_locator.dart';

/// GeoTIFF読み書きサービス
class GeoTiffService {
  GeoTiffService._();

  // ── GeoTIFFタグID ──────────────────────────────
  /// ModelTransformationTag: 4x4アフィン変換行列（DOUBLE[16]）
  static const int kModelTransformationTag = 34264;

  /// ModelPixelScaleTag（DOUBLE[3]）。回転の無い GeoTIFF を GDAL はこれと ModelTiepointTag で書く
  static const int kModelPixelScaleTag = 33550;

  /// ModelTiepointTag（DOUBLE[6n]）
  static const int kModelTiepointTag = 33922;

  /// GeoKeyDirectoryTag: CRS定義等のキーディレクトリ（SHORT[N]）
  static const int kGeoKeyDirectoryTag = 34735;

  /// TIFF の Software タグ
  static const int kSoftwareTag = 305;

  /// アプリが書いた GeoTIFF の目印（TIFFTAG_SOFTWARE の値）
  static const kSoftware = 'kokage-map';

  static Gdal? _gdal;
  static Gdal get _g => _gdal ??= createGdal();
  static String? _tempDirOverride;

  /// テストで GDAL（ホストの GdalFfi）と作業フォルダを差し込む
  @visibleForTesting
  static void configureForTest({Gdal? gdal, String? tempDir}) {
    _gdal = gdal;
    _tempDirOverride = tempDir;
  }

  // ── 公開API ────────────────────────────────────

  /// 元画像からGeoTIFFを生成する
  ///
  /// [srcPath] 元画像ファイルパス（JPG/PNG等、`fs` のパス）
  /// [outputPath] 出力GeoTIFFパス（.tif）
  /// [params] オーバーレイ変換パラメータ
  /// [mode] 変換時の画像処理モード
  /// [threshold] 閾値（0.0〜1.0、alphaBinarize/bwTransparent時に使用）
  static Future<void> createGeoTiff(
    String srcPath,
    String outputPath,
    KMetaImageOverlay params, {
    OverlayConvertMode mode = OverlayConvertMode.none,
    double threshold = 0.5,
  }) async {
    final srcBytes = await fs.readAsBytes(srcPath);
    // デコード・画像処理・PNG 化は作業用 isolate で（大きな写真で UI が止まらないように。web はその場で）
    final png = await TerrainWorker.instance.run<(Uint8List, OverlayConvertMode, double), Uint8List?>(
      _overlayPng,
      (srcBytes, mode, threshold),
    );
    if (png == null) {
      throw Exception('画像のデコードに失敗: $srcPath');
    }
    await _writeFromPng(png, outputPath, params);

    // 3D の地図面が読む PNG キャッシュも作る（Android だけ。作れなくても地図の描き直しでまた作る）
    if (!kIsWeb) {
      try {
        await ensurePngCache(outputPath);
      } catch (e) {
        AppLogger.debug('[GeoTiffService] PNG キャッシュを作れない: $e');
      }
    }

    AppLogger.debug('[GeoTiffService] created: ${p.basename(outputPath)}');
  }

  /// 既存GeoTIFFの位置（中心・スケール・回転）を書き換える
  ///
  /// GDAL で書いたもの（[kSoftware] の目印あり）は `gdal_translate -a_gt` で同じ形のまま書き直す。
  /// 旧版の `package:image` で書いたものは `package:image` で解いて GDAL の形に書き直す（この時に移行する）。
  /// どちらも隣の一時ファイルに書いてから置き換える。デバウンスされた呼び出しで使うので、頻繁には走らない。
  ///
  /// GDAL のハンドルを開いたまま geoTransform だけ変える（gdal_edit）方が軽いが、web の WASM に
  /// `GDALSetGeoTransform` が入っていない（足すと焼き直しと Release の上げ直しが要る）ので、作り直しにしている
  static Future<void> updateGeoTiffTags(
    String tifPath,
    KMetaImageOverlay params,
  ) async {
    final bytes = await fs.readAsBytes(tifPath);
    final tmp = '$tifPath.kokage-tmp';
    try {
      if (isGdalWritten(bytes)) {
        await _g.translate(tifPath, tmp, args: creationArgs(params));
      } else {
        final png = await TerrainWorker.instance.run<Uint8List, Uint8List?>(_legacyTiffToRgbaPng, bytes);
        if (png == null) {
          throw Exception('TIFFのデコードに失敗: $tifPath');
        }
        await _writeFromPng(png, tmp, params);
      }
      await fs.rename(tmp, tifPath);
    } finally {
      await _deleteQuietly(tmp);
    }
    AppLogger.debug(
      '[GeoTiffService] updated tags: ${p.basename(tifPath)}',
    );
  }

  /// `gdal_translate` に渡す書き出しの引数（位置・座標系・目印・圧縮・タイル・アルファ）
  @visibleForTesting
  static List<String> creationArgs(KMetaImageOverlay params) => [
        '-of', 'GTiff',
        '-a_srs', 'EPSG:4326',
        '-a_gt', ...geoTransform(params).map((v) => v.toString()),
        '-mo', 'TIFFTAG_SOFTWARE=$kSoftware',
        // package:image（PNG キャッシュ・web の 3D）も解ける形にする:
        // - ストリップ（タイルにしない）。package:image 4.10 は圧縮したタイルの右端（幅に満たないタイル）を崩して解く
        // - DEFLATE は予測子なし（package:image は DEFLATE の予測子を戻さない）
        '-co', 'TILED=NO',
        '-co', 'COMPRESS=DEFLATE',
        '-co', 'PHOTOMETRIC=RGB', '-co', 'ALPHA=YES',
      ];

  /// PNG（RGBA）を GeoTIFF にして [dst] に書く。PNG は作業フォルダに置いて GDAL に渡し、終わったら消す
  static Future<void> _writeFromPng(Uint8List png, String dst, KMetaImageOverlay params) async {
    final src = p.join(await _tempDir(), 'kokage_overlay_${DateTime.now().microsecondsSinceEpoch}.png');
    await fs.writeAsBytes(src, png);
    try {
      await _g.translate(src, dst, args: creationArgs(params));
    } finally {
      await _deleteQuietly(src);
      await _deleteQuietly('$src.aux.xml');
      await _deleteQuietly('$dst.aux.xml');
    }
  }

  /// 作業フォルダ（`fs` のパス）。Android はアプリの一時フォルダ、web はプロジェクトの `.kokage/tmp`
  /// （web の GDAL は入力を `fs` から読むので、OPFS の中に置く）
  static Future<String> _tempDir() async {
    final String dir;
    final override = _tempDirOverride;
    if (override != null) {
      dir = override;
    } else if (fs.hasRealPaths) {
      dir = (await getTemporaryDirectory()).path;
    } else {
      final root = ProjectPathResolver.instance.rootPath ?? '/';
      dir = p.join(root, GlobalFolderLocator.systemDirName, 'tmp');
    }
    if (!await fs.isDirectory(dir)) await fs.createDirectory(dir);
    return dir;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      if (await fs.exists(path)) await fs.delete(path);
    } catch (_) {}
  }

  /// PNGキャッシュディレクトリ（遅延初期化）
  static Directory? _pngCacheDir;

  /// TIFFファイルパスに対応するPNGキャッシュのパスを返す
  static String _pngCachePath(String tifPath) {
    final hash = tifPath.hashCode.abs();
    return '${_pngCacheDir!.path}/$hash.png';
  }

  /// GeoTIFFに対応するPNGキャッシュファイルのパスを返す
  ///
  /// アプリのキャッシュ領域に `{hash}.png` を生成。
  /// キャッシュが存在し、TIFFより新しい場合は再変換をスキップ。
  /// 3D の地図面はこの PNG を読む（TIFF を直接デコードできない）。
  /// キャッシュがOSに掃除されても自動的に再生成される。
  static Future<String> ensurePngCache(String tifPath) async {
    _pngCacheDir ??= Directory(
      '${(await getApplicationCacheDirectory()).path}/overlay_png_cache',
    );
    await _pngCacheDir!.create(recursive: true);

    final pngPath = _pngCachePath(tifPath);
    final pngFile = File(pngPath);
    final tifFile = File(tifPath);

    // キャッシュ有効判定
    if (pngFile.existsSync()) {
      final pngMod = pngFile.lastModifiedSync();
      final tifMod = tifFile.lastModifiedSync();
      if (pngMod.isAfter(tifMod)) {
        return pngPath;
      }
    }

    // TIFF → PNG変換
    AppLogger.debug('[GeoTiffService] converting to PNG cache: $pngPath');
    final pngBytes = await decodeTiffToPng(tifPath);
    await pngFile.writeAsBytes(pngBytes, flush: true);
    return pngPath;
  }

  /// PNGキャッシュの更新日時を現在時刻に更新する
  ///
  /// GeoTIFFタグ更新（位置・スケール等）後に呼ぶ。
  /// TIFFの再書き出しで更新日時が変わるが、ピクセルデータは不変なので
  /// PNGの再変換は不要。タイムスタンプだけ更新して「古い」判定を回避。
  static Future<void> touchPngCacheTimestamp(String tifPath) async {
    if (_pngCacheDir == null) return;
    final pngFile = File(_pngCachePath(tifPath));
    if (pngFile.existsSync()) {
      await pngFile.setLastModified(DateTime.now());
    }
  }

  /// TIFFをデコードしてPNGバイト列に変換（常駐の作業用 isolate で。大きなオルソ画像だと UI が数秒止まっていた）
  static Future<Uint8List> decodeTiffToPng(String tifPath) async {
    final srcBytes = await File(tifPath).readAsBytes();
    final png = await TerrainWorker.instance.run<Uint8List, Uint8List?>(_tiffToPng, srcBytes);
    if (png == null) {
      throw Exception('TIFFのデコードに失敗: $tifPath');
    }
    return png;
  }

  /// アプリが書いた GeoTIFF か（GDAL で書いた今の形。TIFFTAG_SOFTWARE が [kSoftware]）
  static bool isGdalWritten(Uint8List bytes) {
    try {
      final info = img.TiffDecoder().startDecode(bytes);
      if (info == null || info.images.isEmpty) return false;
      return _software(info.images.first) == kSoftware;
    } catch (_) {
      return false;
    }
  }

  static String? _software(img.TiffImage tiff) =>
      tiff.tags[kSoftwareTag]?.read()?.toString().replaceAll('\u0000', '').trim();

  /// GeoTIFFタグからオーバーレイパラメータを逆算する（アプリの GeoTIFF でなければ null）
  ///
  /// アプリの GeoTIFF とみなすのは、座標系が EPSG:4326 で、次のどちらか:
  /// - 今の形: TIFFTAG_SOFTWARE が [kSoftware]。位置は ModelTransformationTag（回転あり）か
  ///   ModelTiepointTag + ModelPixelScaleTag（回転なし。GDAL はこちらで書く）
  /// - 旧版（`package:image` で書いていた頃）: ModelTransformationTag がある
  ///
  /// それ以外（QGIS / GDAL で作ったラスタ）は null で、呼ぶ側が GDAL で開いて読み取り専用のオーバーレイにする。
  /// 中心・m/px・回転・画素数は 4x4 行列から逆算する。
  static KMetaImageOverlay? readGeoTiffParams(Uint8List bytes) {
    try {
      final decoder = img.TiffDecoder();
      final info = decoder.startDecode(bytes);
      if (info == null || info.images.isEmpty) return null;

      final tiffImage = info.images.first;
      if (_geographicEpsg(tiffImage) != 4326) return null;
      final ours = _software(tiffImage) == kSoftware;

      final List<double> matrix;
      final transform = tiffImage.tags[kModelTransformationTag]?.read();
      if (transform != null) {
        matrix = [for (var i = 0; i < 16; i++) transform.toDouble(i)];
      } else {
        if (!ours) return null;
        final scale = tiffImage.tags[kModelPixelScaleTag]?.read();
        final tie = tiffImage.tags[kModelTiepointTag]?.read();
        if (scale == null || tie == null) return null;
        // 画素 (I, J) が地点 (X, Y)。経度 = X + (i - I)·sx、緯度 = Y − (j − J)·sy
        final sx = scale.toDouble(0), sy = scale.toDouble(1);
        final i0 = tie.toDouble(0), j0 = tie.toDouble(1);
        final x0 = tie.toDouble(3), y0 = tie.toDouble(4);
        matrix = [sx, 0, 0, x0 - i0 * sx, 0, -sy, 0, y0 + j0 * sy, 0, 0, 0, 0, 0, 0, 0, 1];
      }

      final a = matrix[0]; // scaleX * cosR
      final b = matrix[1]; // -scaleY * sinR
      final d = matrix[3]; // originLng
      final e = matrix[4]; // scaleX * sinR
      final f = matrix[5]; // -scaleY * cosR
      final h = matrix[7]; // originLat

      // 画像サイズ取得
      final imageWidth = tiffImage.width;
      final imageHeight = tiffImage.height;

      // 回転角度を逆算: rotation = atan2(e, a)
      final rotRad = math.atan2(e, a);
      final rotation = rotRad * 180.0 / math.pi;

      // スケール逆算（緯度方向）
      // f = -scaleY * cosR, b = -scaleY * sinR
      final scaleY = math.sqrt(b * b + f * f); // 度/ピクセル (緯度方向)

      // 中心座標を逆算
      // center = origin + matrix * (halfW, halfH)
      final halfW = imageWidth / 2.0;
      final halfH = imageHeight / 2.0;
      final centerLng = d + a * halfW + b * halfH;
      final centerLat = h + e * halfW + f * halfH;

      // 度/ピクセル → メートル/ピクセル に戻す
      // scaleY(度/px) = scale(m/px) * degPerMeterLat = scale / 111320
      final scaleMetersFromLat = scaleY * 111320.0;

      return KMetaImageOverlay(
        centerLng: centerLng,
        centerLat: centerLat,
        scale: scaleMetersFromLat,
        rotation: rotation,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
    } catch (e) {
      AppLogger.debug('[GeoTiffService] readGeoTiffParams error: $e');
      return null;
    }
  }

  // ── 内部実装 ──────────────────────────────────

  /// GeoKeyDirectoryTag の GeographicTypeGeoKey（2048）。無ければ null
  static int? _geographicEpsg(img.TiffImage tiff) {
    final keys = tiff.tags[kGeoKeyDirectoryTag]?.read();
    if (keys == null || keys.length < 4) return null;
    final count = keys.toInt(3);
    for (var k = 0; k < count && 4 + k * 4 + 3 < keys.length; k++) {
      final base = 4 + k * 4;
      // 値が別のタグにあるもの（TIFFTagLocation ≠ 0）は見ない
      if (keys.toInt(base) == 2048 && keys.toInt(base + 1) == 0) return keys.toInt(base + 3);
    }
    return null;
  }

  /// kmetaパラメータから4x4 ModelTransformationMatrixを構築
  ///
  /// ラスタ座標(I, J) → モデル座標(Lng, Lat) の変換行列:
  /// ```
  /// | a  b  0  d |   | I |   | Lng |
  /// | e  f  0  h | × | J | = | Lat |
  /// | 0  0  0  0 |   | 0 |   |  0  |
  /// | 0  0  0  1 |   | 1 |   |  1  |
  /// ```
  static Float64List buildModelTransformationMatrix(KMetaImageOverlay params) {
    // メートル→度の変換係数
    final cosLat = math.cos(params.centerLat * math.pi / 180.0);
    final degPerMeterLng = 1.0 / (111320.0 * cosLat);
    const degPerMeterLat = 1.0 / 111320.0;

    // ピクセル→度のスケール
    final scaleX = params.scale * degPerMeterLng;
    final scaleY = params.scale * degPerMeterLat;

    // 回転行列要素
    final rotRad = params.rotation * math.pi / 180.0;
    final cosR = math.cos(rotRad);
    final sinR = math.sin(rotRad);

    // 行列要素（ラスタ→モデル変換）
    final a = scaleX * cosR; //     ΔLng per ΔI
    final b = -scaleY * sinR; //    ΔLng per ΔJ
    final e = scaleX * sinR; //     ΔLat per ΔI
    final f = -scaleY * cosR; //    ΔLat per ΔJ (J増→南=Lat減)

    // 画像左上(0,0)のモデル座標
    // center = origin + matrix * (halfW, halfH) を逆算
    final halfW = params.imageWidth / 2.0;
    final halfH = params.imageHeight / 2.0;
    final originLng = params.centerLng - (a * halfW + b * halfH);
    final originLat = params.centerLat - (e * halfW + f * halfH);

    return Float64List.fromList([
      a, b, 0, originLng,
      e, f, 0, originLat,
      0, 0, 0, 0,
      0, 0, 0, 1,
    ]);
  }

  /// GDAL の geoTransform（`-a_gt` の 6 つ）。[buildModelTransformationMatrix] と同じ変換で、並びが GDAL の形
  /// （経度 = gt0 + i·gt1 + j·gt2、緯度 = gt3 + i·gt4 + j·gt5。i, j は画素の左上の角）
  static List<double> geoTransform(KMetaImageOverlay params) {
    final m = buildModelTransformationMatrix(params);
    return [m[3], m[0], m[1], m[7], m[4], m[5]];
  }

  /// 元画像のパスからGeoTIFF出力パスを生成
  /// [outputName] を指定した場合はそれを使い、省略時は元ファイル名をベースに
  static String outputPathForSource(String srcPath, {String? outputName}) {
    final dir = p.dirname(srcPath);
    final baseName = outputName ?? p.basenameWithoutExtension(srcPath);
    return p.join(dir, '$baseName.tif');
  }

  // ── 画像処理 ────────────────────────────────────

  /// 変換モードに応じた画像処理を適用する
  static img.Image _applyMode(
    img.Image image,
    OverlayConvertMode mode,
    double threshold,
  ) {
    // 8bit RGBA にそろえる（16bit の PNG などから UInt16 の GeoTIFF を作らない）
    // （`alpha:` を渡すと元のアルファまで上書きされるので渡さない。足したチャンネルは不透明になる）
    final rgba = image.convert(format: img.Format.uint8, numChannels: 4);

    switch (mode) {
      case OverlayConvertMode.none:
        // そのまま（αチャンネル確保のみ）
        return rgba;

      case OverlayConvertMode.brightnessToAlpha:
        // 輝度→透明度（グラデーション）
        // 明→透明、暗→不透明
        for (final pixel in rgba) {
          final lum = pixel.luminanceNormalized;
          pixel.a = pixel.maxChannelValue * (1.0 - lum);
        }
        return rgba;

      case OverlayConvertMode.alphaBinarize:
        // 輝度で透明/不透明に分離（色は維持）
        // 閾値以上（明るい）→ 完全透明、未満（暗い）→ 完全不透明
        for (final pixel in rgba) {
          final lum = pixel.luminanceNormalized;
          pixel.a = lum >= threshold ? 0 : pixel.maxChannelValue;
        }
        return rgba;

      case OverlayConvertMode.bwTransparent:
        // 白黒2値化 → 白部分を透明化
        // 閾値未満（暗い）→ 黒＋不透明、閾値以上（明るい）→ 透明
        for (final pixel in rgba) {
          final lum = pixel.luminanceNormalized;
          if (lum >= threshold) {
            // 白→透明
            pixel.a = 0;
          } else {
            // 黒化＋不透明
            pixel
              ..r = 0
              ..g = 0
              ..b = 0
              ..a = pixel.maxChannelValue;
          }
        }
        return rgba;
    }
  }
}

/// TIFF → PNG（isolate で回すので top-level・同期）
Uint8List? _tiffToPng(Uint8List src) {
  final image = img.decodeImage(src);
  if (image == null) return null;
  return Uint8List.fromList(img.encodePng(image, level: 3));
}

/// 旧版の TIFF → 8bit RGBA の PNG（GDAL の形に書き直す入力。isolate で回すので top-level・同期）
Uint8List? _legacyTiffToRgbaPng(Uint8List src) {
  final image = img.decodeImage(src);
  if (image == null) return null;
  final rgba = image.convert(format: img.Format.uint8, numChannels: 4);
  return Uint8List.fromList(img.encodePng(rgba, level: 1));
}

/// 元画像 → 画像処理 → 8bit RGBA の PNG（GDAL に渡す入力。isolate で回すので top-level・同期）。
/// 圧縮は軽く（level 1）: すぐ GDAL が読んで消す一時ファイル
Uint8List? _overlayPng((Uint8List, OverlayConvertMode, double) job) {
  final (bytes, mode, threshold) = job;
  final image = img.decodeImage(bytes);
  if (image == null) return null;
  final rgba = GeoTiffService._applyMode(image, mode, threshold);
  return Uint8List.fromList(img.encodePng(rgba, level: 1));
}
