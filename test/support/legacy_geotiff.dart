// 旧版（v0.12.0 まで）のこかげマップが書いていた GeoTIFF を作る（読み込みの互換を確かめるため）。
//
// `package:image` の TIFF エンコーダに ModelTransformationTag と GeoKeyDirectoryTag を足した形。
// 無圧縮・1 タイル＝画像全体・ExtraSamples なし・タグの並びが昇順でない（GDAL が警告を出す）。
// アプリはもうこの形を書かない（GeoTiffService が GDAL で書く）が、端末や Drive に残っているものは読めて、
// 位置合わせで書き換えるときに GDAL の形へ書き直す。
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/services/geotiff_service.dart';

/// [image] を旧版の形の GeoTIFF にして [path] に書く
void writeLegacyGeoTiff(String path, img.Image image, KMetaImageOverlay params) {
  File(path).writeAsBytesSync(encodeLegacyGeoTiff(image, params));
}

Uint8List encodeLegacyGeoTiff(img.Image image, KMetaImageOverlay params) {
  var src = image;
  if (src.isHdrFormat) src = src.convert(format: img.Format.uint8);

  final exif = img.ExifData();
  final ifd = exif.imageIfd;
  final nc = src.numChannels;
  final type = nc == 1
      ? img.TiffPhotometricType.blackIsZero.index
      : src.hasPalette
          ? img.TiffPhotometricType.palette.index
          : img.TiffPhotometricType.rgb.index;

  ifd['ImageWidth'] = src.width;
  ifd['ImageHeight'] = src.height;
  ifd['BitsPerSample'] = src.bitsPerChannel;
  ifd['SampleFormat'] = img.TiffFormat.uint.index;
  ifd['SamplesPerPixel'] = src.hasPalette ? 1 : nc;
  ifd['Compression'] = img.TiffCompression.none;
  ifd['PhotometricInterpretation'] = type;
  ifd['RowsPerStrip'] = src.height;
  ifd['PlanarConfiguration'] = 1;
  ifd['TileWidth'] = src.width;
  ifd['TileLength'] = src.height;
  ifd['StripByteCounts'] = src.lengthInBytes;
  ifd['StripOffsets'] = img.IfdValueUndefined.list(src.toUint8List());

  final matrix = GeoTiffService.buildModelTransformationMatrix(params);
  ifd.data[GeoTiffService.kModelTransformationTag] = img.IfdValueDouble.list(matrix.toList());
  ifd.data[GeoTiffService.kGeoKeyDirectoryTag] = img.IfdValueShort.list(const [
    1, 1, 0, 3, //
    1024, 0, 1, 2, //  GTModelTypeGeoKey = Geographic
    1025, 0, 1, 1, //  GTRasterTypeGeoKey = PixelIsArea
    2048, 0, 1, 4326, // GeographicTypeGeoKey = EPSG:4326
  ]);

  final out = img.OutputBuffer();
  exif.write(out);
  return out.getBytes();
}
