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
import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' as charset;
import 'package:charset_converter/charset_converter.dart';
import 'package:root_maps/utils/app_logger.dart';

import '../../../core/fs/k_file_system.dart';

/// DBF のフィールド記述子
typedef _DbfField = ({String name, String type, int length});

/// DBFファイルを読み込んで属性データを取得するクラス
class DbfReader {
  /// ASCII の範囲では ASCII と同じになる文字コード（[_normalizeCharset] の後の名前）
  static const _asciiCompatible = {'Shift_JIS', 'UTF-8', 'EUC-JP'};

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
  static Future<Map<String, List<dynamic>>?> read(String dbfFilePath, {String encoding = 'Shift_JIS'}) async {
    try {
      AppLogger.debug('[DbfReader] DBF読み込み開始: $dbfFilePath');
      AppLogger.debug('[DbfReader] 文字コード: $encoding');

      // fs 経由で読む（web で dart:io に触れると落ちる。読み取り専用レイヤは web でも開く）
      if (!await fs.exists(dbfFilePath)) {
        AppLogger.debug('[DbfReader] DBFファイルが見つかりません');
        return null;
      }

      final bytes = await fs.readAsBytes(dbfFilePath);
      if (bytes.length < 32) {
        AppLogger.debug('[DbfReader] DBFファイルが小さすぎます: ${bytes.length}bytes');
        return null;
      }

      // ヘッダー解析
      final header = ByteData.sublistView(bytes, 0, 12);
      final version = bytes[0];
      final recordCount = header.getUint32(4, Endian.little);
      final headerLength = header.getUint16(8, Endian.little);
      final recordLength = header.getUint16(10, Endian.little);

      AppLogger.debug('[DbfReader] DBFヘッダー情報:');
      AppLogger.debug('  バージョン: 0x${version.toRadixString(16)}');
      AppLogger.debug('  レコード数: $recordCount');
      AppLogger.debug('  ヘッダー長: $headerLength bytes');
      AppLogger.debug('  レコード長: $recordLength bytes');

      final decoder = _Decoder(encoding);

      // フィールド記述子を読み込み
      final fields = <_DbfField>[];
      int offset = 32;
      while (offset < headerLength - 1 && bytes[offset] != 0x0D) {
        if (offset + 32 > bytes.length) break;

        // フィールド名（11バイト、null-terminated）
        final nameBytes = bytes.sublist(offset, offset + 11);
        final nameEndIndex = nameBytes.indexOf(0);
        final decodedName = await decoder.decode(nameBytes.sublist(0, nameEndIndex >= 0 ? nameEndIndex : 11));
        fields.add((
          name: decodedName.replaceAll('\x00', '').replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim(),
          type: String.fromCharCode(bytes[offset + 11]),
          length: bytes[offset + 16],
        ));
        offset += 32;
      }

      // レコードデータを読み込み
      final data = <String, List<dynamic>>{for (final field in fields) field.name: []};
      final deleted = <int>{};

      offset = headerLength;
      for (int recordIndex = 0; recordIndex < recordCount; recordIndex++) {
        if (offset >= bytes.length) break;

        // 削除フラグをチェック（0x2A = 削除済み）
        final deletionFlag = bytes[offset];
        offset++;

        // 削除済みの行も詰めない（SHP のレコードとは行番号で対応するので、詰めると以降の属性がずれる）。
        // 値は null で埋め、行番号を覚えておく
        if (deletionFlag == 0x2A) {
          for (final field in fields) {
            data[field.name]!.add(null);
          }
          deleted.add(recordIndex);
          offset += recordLength - 1;
          continue;
        }

        // 各フィールドの値を読み込み
        for (final field in fields) {
          if (offset + field.length > bytes.length) break;
          final valueString = (await decoder.decode(
            Uint8List.sublistView(bytes, offset, offset + field.length),
          )).trim();
          data[field.name]!.add(_parseValue(field.type, valueString));
          offset += field.length;
        }
      }

      AppLogger.debug('[DbfReader] DBFデータ読み込み完了: $recordCountレコード（削除済み ${deleted.length}）');
      if (deleted.isNotEmpty) _deletedRecords[data] = deleted;
      return data;
    } catch (e, stack) {
      AppLogger.debug('[DbfReader] DBF読み込みエラー: $e');
      AppLogger.debug('[DbfReader] スタックトレース: $stack');
      return null;
    }
  }

  /// タイプに応じて値を変換
  static Object? _parseValue(String fieldType, String valueString) {
    switch (fieldType) {
      case 'N': // 数値
      case 'F': // 浮動小数点
        return double.tryParse(valueString);
      case 'L': // 論理値
        return valueString == 'T' || valueString == 't' || valueString == 'Y' || valueString == 'y';
      case 'D': // 日付（YYYYMMDD）
        if (valueString.length != 8) return valueString;
        try {
          final year = int.parse(valueString.substring(0, 4));
          final month = int.parse(valueString.substring(4, 6));
          final day = int.parse(valueString.substring(6, 8));
          return DateTime(year, month, day).toIso8601String();
        } catch (e) {
          return valueString;
        }
      default: // 'C' (文字列) など
        return valueString;
    }
  }

  /// [read] の結果ごとの削除済みの行番号（戻り値の形を変えずに持たせるため Expando に置く）
  static final _deletedRecords = Expando<Set<int>>('dbfDeletedRecords');

  /// [recordIndex] 行目が削除フラグ（`*`）つきか。GDAL/QGIS はこの行の SHP レコードを読み飛ばす
  static bool isDeletedRecord(Map<String, List<dynamic>>? dbfData, int recordIndex) =>
      dbfData != null && (_deletedRecords[dbfData]?.contains(recordIndex) ?? false);

  /// DBFデータから指定したインデックスのレコード属性を取得（削除済みの行は空）。
  /// [recordIndex] は SHP のレコード番号（`ShpRecord.index`）と同じ 0 始まり
  static Map<String, dynamic> getAttributesForRecord(Map<String, List<dynamic>>? dbfData, int recordIndex) {
    if (dbfData == null || isDeletedRecord(dbfData, recordIndex)) return {};

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

/// バイト列 → 文字列。
///
/// 文字コードの変換はプラットフォームチャネル越しなので 1 回ずつが重い（1.5 万行 × 列の数だけ
/// 往復していた）。ASCII だけの値はその場で、同じバイト列は 2 度目から覚えた結果で返す。
class _Decoder {
  _Decoder(String encoding) : _charset = DbfReader._normalizeCharset(encoding);

  final String _charset;
  final Map<String, String> _cache = {};

  Future<String> decode(Uint8List bytes) async {
    if (bytes.isEmpty) return '';
    if (DbfReader._asciiCompatible.contains(_charset) && bytes.every((b) => b < 0x80)) {
      return String.fromCharCodes(bytes);
    }
    final key = String.fromCharCodes(bytes);
    return _cache[key] ??= await _decodeOnPlatform(bytes);
  }

  Future<String> _decodeOnPlatform(Uint8List bytes) async {
    // 日本語の文字コードは純 Dart で解く（charset_converter はプラットフォームチャネルで、web とホストのテストに無い）
    try {
      switch (_charset) {
        case 'Shift_JIS':
          return charset.shiftJis.decode(bytes);
        case 'EUC-JP':
          return charset.eucJp.decode(bytes);
        case 'UTF-8':
          return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (e) {
      AppLogger.debug('[DbfReader] charset.decode失敗 ($_charset): $e');
    }
    try {
      return await CharsetConverter.decode(_charset, Uint8List.fromList(bytes));
    } catch (e) {
      AppLogger.debug('[DbfReader] CharsetConverter.decode失敗 ($_charset): $e');
      // フォールバック: ASCII範囲のみ
      return String.fromCharCodes(bytes.where((c) => c >= 0x20 && c < 0x7F));
    }
  }
}
