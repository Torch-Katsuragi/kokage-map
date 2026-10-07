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
/// 画像ファイルをGeoTIFF形式に変換し、地理参照メタデータ
/// （ModelTransformationTag, GeoKeyDirectoryTag）を注入する。
/// `image` パッケージのTIFFエンコーダ/ExifData構造を活用。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/terrain/terrain_worker.dart';
import '../models/kmeta.dart';
import '../utils/app_logger.dart';
import '../widgets/dialogs/overlay_convert_dialog.dart';

/// GeoTIFF読み書きサービス
class GeoTiffService {
  GeoTiffService._();

  // ── GeoTIFFタグID ──────────────────────────────
  /// ModelTransformationTag: 4x4アフィン変換行列（DOUBLE[16]）
  static const int kModelTransformationTag = 34264;

  /// GeoKeyDirectoryTag: CRS定義等のキーディレクトリ（SHORT[N]）
  static const int kGeoKeyDirectoryTag = 34735;

  // ── 公開API ────────────────────────────────────

  /// 元画像からGeoTIFFを生成する
  ///
  /// [srcPath] 元画像ファイルパス（JPG/PNG等）
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
    final srcBytes = await File(srcPath).readAsBytes();
    var image = img.decodeImage(srcBytes);
    if (image == null) {
      throw Exception('画像のデコードに失敗: $srcPath');
    }

    // 画像処理を適用
    image = _applyMode(image, mode, threshold);

    final tiffBytes = _encodeGeoTiff(image, params);
    await File(outputPath).writeAsBytes(tiffBytes, flush: true);

    // 3D の地図面が読む PNG キャッシュも作る
    await ensurePngCache(outputPath);

    AppLogger.debug(
      '[GeoTiffService] created: ${p.basename(outputPath)} '
      '(${tiffBytes.length} bytes)',
    );
  }

  /// 既存GeoTIFFのメタデータ（位置・スケール・回転）を更新して再書き出し
  ///
  /// 画像データはデコード→再エンコードされるが、ピクセル内容は不変。
  /// デバウンスされた呼び出しで使用するため、頻繁には実行されない。
  static Future<void> updateGeoTiffTags(
    String tifPath,
    KMetaImageOverlay params,
  ) async {
    final srcBytes = await File(tifPath).readAsBytes();
    final image = img.decodeImage(srcBytes);
    if (image == null) {
      throw Exception('TIFFのデコードに失敗: $tifPath');
    }

    final tiffBytes = _encodeGeoTiff(image, params);
    await File(tifPath).writeAsBytes(tiffBytes, flush: true);
    AppLogger.debug(
      '[GeoTiffService] updated tags: ${p.basename(tifPath)}',
    );
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

  /// TIFFファイルにGeoTIFFタグ（ModelTransformationTag）が含まれるか判定
  ///
  /// OverlayImageNode判定のための軽量チェック。
  static bool hasGeoTiffTags(Uint8List bytes) {
    try {
      final decoder = img.TiffDecoder();
      final info = decoder.startDecode(bytes);
      if (info == null || info.images.isEmpty) return false;
      // frames[0] のExifDataを確認
      final image = info.images.first;
      return image.tags.containsKey(kModelTransformationTag);
    } catch (_) {
      return false;
    }
  }

  /// GeoTIFFタグからオーバーレイパラメータを逆算する
  ///
  /// ModelTransformationTag（4x4行列）を読み取り、
  /// centerLng/centerLat/scale/rotation/imageWidth/imageHeight を復元する。
  /// GeoTIFFタグがない場合は null を返す。
  static KMetaImageOverlay? readGeoTiffParams(Uint8List bytes) {
    try {
      final decoder = img.TiffDecoder();
      final info = decoder.startDecode(bytes);
      if (info == null || info.images.isEmpty) return null;

      final tiffImage = info.images.first;
      if (!tiffImage.tags.containsKey(kModelTransformationTag)) return null;

      final matrixEntry = tiffImage.tags[kModelTransformationTag]!;
      // TiffEntry.read() で遅延読み込み → IfdValue を取得
      final matrixValue = matrixEntry.read();
      if (matrixValue == null) return null;

      // IfdValueから16要素のdouble配列を取得
      final matrix = <double>[];
      for (var i = 0; i < 16; i++) {
        matrix.add(matrixValue.toDouble(i));
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

  /// 画像をGeoTIFFタグ付きTIFFとしてエンコードする
  ///
  /// TiffEncoder.encode() のロジックを参考に、
  /// GeoTIFFタグを含む ExifData を手動構築して書き出す。
  static Uint8List _encodeGeoTiff(img.Image image, KMetaImageOverlay params) {
    // HDR画像はuint8に変換
    var src = image;
    if (src.isHdrFormat) {
      src = src.convert(format: img.Format.uint8);
    }

    final exif = img.ExifData();
    final ifd = exif.imageIfd;

    // ── 標準TIFFタグ（TiffEncoder.encode()と同等） ──
    final nc = src.numChannels;
    final type = nc == 1
        ? img.TiffPhotometricType.blackIsZero.index
        : src.hasPalette
            ? img.TiffPhotometricType.palette.index
            : img.TiffPhotometricType.rgb.index;

    ifd['ImageWidth'] = src.width;
    ifd['ImageHeight'] = src.height;
    ifd['BitsPerSample'] = src.bitsPerChannel;
    ifd['SampleFormat'] = _getSampleFormat(src).index;
    ifd['SamplesPerPixel'] = src.hasPalette ? 1 : nc;
    ifd['Compression'] = img.TiffCompression.none;
    ifd['PhotometricInterpretation'] = type;
    ifd['RowsPerStrip'] = src.height;
    ifd['PlanarConfiguration'] = 1;
    ifd['TileWidth'] = src.width;
    ifd['TileLength'] = src.height;
    ifd['StripByteCounts'] = src.lengthInBytes;
    ifd['StripOffsets'] = img.IfdValueUndefined.list(src.toUint8List());

    // パレット画像の場合
    if (src.hasPalette) {
      final palette = src.palette!;
      const numCh = 3;
      final numC = palette.numColors;
      final colorMap = Uint16List(numC * numCh);
      for (var c = 0, ci = 0; c < numCh; ++c) {
        for (var i = 0; i < numC; ++i) {
          colorMap[ci++] = palette.get(i, c).toInt() << 8;
        }
      }
      ifd['ColorMap'] = colorMap;
    }

    // ── GeoTIFFタグ注入 ──
    // exifImageTagsに未登録のタグはdata mapに直接設定
    final matrix = buildModelTransformationMatrix(params);
    ifd.data[kModelTransformationTag] =
        img.IfdValueDouble.list(matrix.toList());

    ifd.data[kGeoKeyDirectoryTag] = img.IfdValueShort.list(const [
      1, 1, 0, 3, //     Version=1, Revision=1.0, KeyCount=3
      1024, 0, 1, 2, //  GTModelTypeGeoKey = ModelTypeGeographic(2)
      1025, 0, 1, 1, //  GTRasterTypeGeoKey = RasterPixelIsArea(1)
      2048, 0, 1, 4326, // GeographicTypeGeoKey = EPSG:4326
    ]);

    // ── バイナリ書き出し ──
    final out = img.OutputBuffer();
    exif.write(out);
    return out.getBytes();
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

  /// 画像フォーマットからTIFF SampleFormatを決定
  static img.TiffFormat _getSampleFormat(img.Image image) {
    switch (image.formatType) {
      case img.FormatType.uint:
        return img.TiffFormat.uint;
      case img.FormatType.int:
        return img.TiffFormat.int;
      case img.FormatType.float:
        return img.TiffFormat.float;
    }
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
    final rgba = image.convert(numChannels: 4);

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
