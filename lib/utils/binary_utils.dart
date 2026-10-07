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
// Root Maps: Binary Utilities
// バイト変換ヘルパー（Shapefile等のバイナリファイル処理用）
import 'dart:typed_data';
import 'package:charset/charset.dart' as charset;
import 'package:root_maps/utils/app_logger.dart';

/// バイナリ変換ユーティリティクラス
class BinaryUtils {
  /// 32bit整数をリトルエンディアンで書き込み
  static List<int> writeInt32LittleEndian(int value) {
    return [
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];
  }

  /// 16bit整数をリトルエンディアンで書き込み
  static List<int> writeInt16LittleEndian(int value) {
    return [value & 0xFF, (value >> 8) & 0xFF];
  }

  /// 32bit整数をビッグエンディアンで読み込み
  static int readInt32BigEndian(Uint8List bytes, int offset) {
    return ByteData.sublistView(bytes, offset, offset + 4)
        .getInt32(0, Endian.big);
  }

  /// 32bit整数をリトルエンディアンで読み込み
  static int readInt32LittleEndian(Uint8List bytes, int offset) {
    return ByteData.sublistView(bytes, offset, offset + 4)
        .getInt32(0, Endian.little);
  }

  /// 64bit浮動小数点をリトルエンディアンで読み込み
  static double readFloat64LittleEndian(Uint8List bytes, int offset) {
    return ByteData.sublistView(bytes, offset, offset + 8)
        .getFloat64(0, Endian.little);
  }

  /// 文字列をShift-JIS（CP932）でエンコードし、指定バイト長に調整
  /// [padWithSpace] trueの場合はスペース(0x20)でパディング、falseの場合はNULL(0x00)
  static List<int> encodeToShiftJis(
    String text,
    int byteLength, {
    bool padWithSpace = false,
  }) {
    try {
      final encoded = charset.shiftJis.encode(text);
      final padByte = padWithSpace ? 0x20 : 0x00;

      if (encoded.length >= byteLength) {
        return encoded.sublist(0, byteLength);
      } else {
        final result = List<int>.from(encoded);
        result.addAll(List.filled(byteLength - encoded.length, padByte));
        return result;
      }
    } catch (e) {
      AppLogger.debug('[BinaryUtils] Shift-JISエンコード失敗: $e');
      final padByte = padWithSpace ? 0x20 : 0x00;
      final asciiBytes =
          text.codeUnits.where((c) => c < 128).take(byteLength).toList();
      if (asciiBytes.length < byteLength) {
        asciiBytes.addAll(List.filled(byteLength - asciiBytes.length, padByte));
      }
      return asciiBytes;
    }
  }
}

/// バウンディングボックスを表すクラス
class BoundingBox {
  double minX;
  double minY;
  double maxX;
  double maxY;

  BoundingBox({
    this.minX = double.infinity,
    this.minY = double.infinity,
    this.maxX = double.negativeInfinity,
    this.maxY = double.negativeInfinity,
  });

  /// 座標を追加してバウンディングボックスを更新
  void extend(double x, double y) {
    if (x.isFinite && y.isFinite) {
      if (minX.isFinite) {
        minX = minX < x ? minX : x;
        maxX = maxX > x ? maxX : x;
      } else {
        minX = maxX = x;
      }
      if (minY.isFinite) {
        minY = minY < y ? minY : y;
        maxY = maxY > y ? maxY : y;
      } else {
        minY = maxY = y;
      }
    }
  }

  /// バウンディングボックスが有効かチェック
  bool get isValid =>
      minX.isFinite && maxX.isFinite && minY.isFinite && maxY.isFinite;

  /// 無効な場合はデフォルト値を設定
  void ensureValid() {
    if (!minX.isFinite) minX = 0.0;
    if (!maxX.isFinite) maxX = 0.0;
    if (!minY.isFinite) minY = 0.0;
    if (!maxY.isFinite) maxY = 0.0;
  }
}

