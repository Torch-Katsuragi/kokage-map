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
// Root Maps: DBF Reader
// DBFファイル（dBASE III）の読み込みクラス
import 'dart:io';
import 'dart:typed_data';

import 'package:charset_converter/charset_converter.dart';
import 'package:root_maps/utils/app_logger.dart';

/// DBFファイルを読み込んで属性データを取得するクラス
class DbfReader {
  /// バイト列を指定エンコーディングでデコード（非同期版）
  static Future<String> _decodeBytes(List<int> bytes, String encoding) async {
    if (bytes.isEmpty) return '';
    
    final charset = _normalizeCharset(encoding);
    
    try {
      final result = await CharsetConverter.decode(
        charset,
        Uint8List.fromList(bytes),
      );
      return result;
    } catch (e) {
      AppLogger.debug('[DbfReader] CharsetConverter.decode失敗 ($charset): $e');
      // フォールバック: ASCII範囲のみ
      return String.fromCharCodes(bytes.where((c) => c >= 0x20 && c < 0x7F));
    }
  }

  /// エンコーディング名をプラットフォームで認識される形式に正規化
  static String _normalizeCharset(String encoding) {
    final enc = encoding.toUpperCase().replaceAll('-', '').replaceAll('_', '');
    if (enc.contains('SHIFTJIS') || enc.contains('SJIS') || enc.contains('CP932')) {
      return 'Shift_JIS';
    } else if (enc.contains('UTF8')) {
      return 'UTF-8';
    } else if (enc.contains('EUCJP')) {
      return 'EUC-JP';
    } else if (enc.contains('ISO2022JP')) {
      return 'ISO-2022-JP';
    }
    return encoding;
  }

  /// DBFファイルを読み込んで属性データを取得
  /// [dbfFilePath] DBFファイルパス
  /// [encoding] 文字コード（デフォルト: Shift_JIS）
  /// 戻り値: Map<フィールド名, 値のリスト>
  static Future<Map<String, List<dynamic>>?> read(
    String dbfFilePath, {
    String encoding = 'Shift_JIS',
  }) async {
    try {
      AppLogger.debug('[DbfReader] DBF読み込み開始: $dbfFilePath');
      AppLogger.debug('[DbfReader] 文字コード: $encoding');

      final dbfFile = File(dbfFilePath);
      if (!dbfFile.existsSync()) {
        AppLogger.debug('[DbfReader] DBFファイルが見つかりません');
        return null;
      }

      final bytes = await dbfFile.readAsBytes();
      if (bytes.length < 32) {
        AppLogger.debug('[DbfReader] DBFファイルが小さすぎます: ${bytes.length}bytes');
        return null;
      }

      // ヘッダー解析
      final version = bytes[0];
      final recordCount = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
      final headerLength = ByteData.sublistView(bytes, 8, 10).getUint16(0, Endian.little);
      final recordLength = ByteData.sublistView(bytes, 10, 12).getUint16(0, Endian.little);

      AppLogger.debug('[DbfReader] DBFヘッダー情報:');
      AppLogger.debug('  バージョン: 0x${version.toRadixString(16)}');
      AppLogger.debug('  レコード数: $recordCount');
      AppLogger.debug('  ヘッダー長: $headerLength bytes');
      AppLogger.debug('  レコード長: $recordLength bytes');

      // フィールド記述子を読み込み
      final fields = <Map<String, dynamic>>[];
      int offset = 32;

      while (offset < headerLength - 1 && bytes[offset] != 0x0D) {
        if (offset + 32 > bytes.length) break;

        // フィールド名（11バイト、null-terminated）
        final nameBytes = bytes.sublist(offset, offset + 11);
        final nameEndIndex = nameBytes.indexOf(0);
        final fieldNameBytes = nameBytes.sublist(
          0,
          nameEndIndex >= 0 ? nameEndIndex : 11,
        );

        final decodedName = await _decodeBytes(fieldNameBytes, encoding);
        final fieldName = decodedName
            .replaceAll('\x00', '')
            .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
            .trim();

        // フィールドタイプ（1バイト）
        final fieldType = String.fromCharCode(bytes[offset + 11]);

        // フィールド長（1バイト）
        final fieldLength = bytes[offset + 16];

        // 小数点以下桁数（1バイト）
        final decimalCount = bytes[offset + 17];

        fields.add({
          'name': fieldName,
          'type': fieldType,
          'length': fieldLength,
          'decimal': decimalCount,
        });

        offset += 32;
      }

      // レコードデータを読み込み
      final data = <String, List<dynamic>>{};
      for (final field in fields) {
        data[field['name'] as String] = [];
      }

      offset = headerLength;
      for (int recordIndex = 0; recordIndex < recordCount; recordIndex++) {
        if (offset >= bytes.length) break;

        // 削除フラグをチェック（0x2A = 削除済み）
        final deletionFlag = bytes[offset];
        offset++;

        if (deletionFlag == 0x2A) {
          offset += recordLength - 1;
          continue;
        }

        // 各フィールドの値を読み込み
        for (final field in fields) {
          final fieldName = field['name'] as String;
          final fieldType = field['type'] as String;
          final fieldLength = field['length'] as int;

          if (offset + fieldLength > bytes.length) break;

          final valueBytes = bytes.sublist(offset, offset + fieldLength);
          final valueString = (await _decodeBytes(valueBytes, encoding)).trim();

          // タイプに応じて値を変換
          dynamic value;
          switch (fieldType) {
            case 'N': // 数値
            case 'F': // 浮動小数点
              value = double.tryParse(valueString);
            case 'L': // 論理値
              value = valueString == 'T' ||
                  valueString == 't' ||
                  valueString == 'Y' ||
                  valueString == 'y';
            case 'D': // 日付（YYYYMMDD）
              if (valueString.length == 8) {
                try {
                  final year = int.parse(valueString.substring(0, 4));
                  final month = int.parse(valueString.substring(4, 6));
                  final day = int.parse(valueString.substring(6, 8));
                  value = DateTime(year, month, day).toIso8601String();
                } catch (e) {
                  value = valueString;
                }
              } else {
                value = valueString;
              }
            default: // 'C' (文字列) など
              value = valueString;
          }

          data[fieldName]!.add(value);
          offset += fieldLength;
        }
      }

      AppLogger.debug('[DbfReader] DBFデータ読み込み完了: $recordCountレコード');
      return data;
    } catch (e, stack) {
      AppLogger.debug('[DbfReader] DBF読み込みエラー: $e');
      AppLogger.debug('[DbfReader] スタックトレース: $stack');
      return null;
    }
  }

  /// DBFデータから指定したインデックスのレコード属性を取得
  static Map<String, dynamic> getAttributesForRecord(
    Map<String, List<dynamic>>? dbfData,
    int recordIndex,
  ) {
    if (dbfData == null) return {};

    final attributes = <String, dynamic>{};
    for (final entry in dbfData.entries) {
      final fieldName = entry.key;
      final values = entry.value;

      if (recordIndex < values.length) {
        final value = values[recordIndex];
        if (value != null && value.toString().isNotEmpty) {
          attributes[fieldName] = value;
        }
      }
    }

    return attributes;
  }
}

