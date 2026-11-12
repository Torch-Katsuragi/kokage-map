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
// こかげマップ: GeoPackage 埋め込み（`qgis_projects` / `layer_styles`）および横置き `.qml` からのスタイル救済
//
// ⚠ すべての GeoPackage アクセスは既存の接続に対する読み取り専用 SELECT のみとし、
// `.gpkg` ファイルを 1 バイトたりとも書き換えないこと（不変条件: 開いただけで gpkg を変えない）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/fs/k_file_system.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'qgs_renderer_reader.dart';
import 'qgs_style_reader.dart';

abstract final class QgsEmbeddedStyleLoader {
  /// `.qgz` のバイト列（ZIP 書庫）から中の `.qgs` XML 文字列を展開する
  static String extractQgsXmlFromQgzBytes(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final qgs = archive.files.where((f) => f.isFile && f.name.toLowerCase().endsWith('.qgs')).firstOrNull;
    if (qgs == null) {
      throw const FormatException('.qgz の中に .qgs が見当たりません');
    }
    return utf8.decode(qgs.content, allowMalformed: true);
  }

  /// フォルダ内に `.qgs` / `.qgz` がまだ無いとき、直下の `.gpkg` 内の `qgis_projects` テーブルから
  /// 最初のプロジェクト XML を読み出す（無ければ null。`.gpkg` には一切書き込まない）
  static Future<String?> readEmbeddedProjectXml(FolderNode folder) async {
    for (final gpkg in folder.children.whereType<GeoPackageNode>()) {
      try {
        final db = await gpkg.geoPackageFile.getDatabase();
        final exists = await db.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name='qgis_projects' LIMIT 1",
        );
        if (exists.isEmpty) continue;
        final rows = await db.rawQuery('SELECT content FROM qgis_projects LIMIT 1');
        if (rows.isEmpty) continue;
        final raw = rows.first['content'];
        final xml = _decodeProjectContent(raw);
        if (xml != null && xml.contains('<qgis')) return xml;
      } on Object catch (e) {
        AppLogger.debug('[QgsEmbeddedStyleLoader] qgis_projects 読み取り失敗: $e');
      }
    }
    return null;
  }

  static String? _decodeProjectContent(Object? raw) {
    if (raw is Uint8List && raw.length >= 4) {
      if (raw[0] == 0x50 && raw[1] == 0x4B) {
        return extractQgsXmlFromQgzBytes(raw);
      }
      return utf8.decode(raw, allowMalformed: true);
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('<')) return trimmed;
      // QGIS は `.qgz` の ZIP バイナリを 16 進文字列（`504b0304...`）として TEXT 列に格納する
      if (trimmed.length >= 8 && trimmed.substring(0, 4).toLowerCase() == '504b' && trimmed.length.isEven) {
        final bytes = Uint8List(trimmed.length ~/ 2);
        for (var i = 0; i < bytes.length; i++) {
          final byte = int.tryParse(trimmed.substring(i * 2, i * 2 + 2), radix: 16);
          if (byte == null) return null;
          bytes[i] = byte;
        }
        return extractQgsXmlFromQgzBytes(bytes);
      }
    }
    return null;
  }

  /// スタイル未設定のレイヤに対し、GeoPackage 内 `layer_styles` テーブル（既定 QML）または
  /// 横置き `.qml` ファイルがあれば初期スタイルとして読み込む。適用したレイヤ数を返す。
  ///
  /// 既にフォルダ設定（`.qgs` / `KMeta`）にスタイルを持つレイヤは上書きしない。
  static Future<int> applyFallbackLayerStyles(FolderNode root) async {
    var applied = 0;
    final rootPath = root.getAbsoluteFilePath();
    Future<void> walkFolder(FolderNode folder) async {
      final dirPath = folder.getAbsoluteFilePath();
      Set<String>? dirFiles;
      if (dirPath != null) {
        try {
          dirFiles = {
            for (final e in await fs.list(dirPath))
              if (!e.isDirectory) p.basename(e.path),
          };
        } on Object {
          dirFiles = null;
        }
      }

      final meta = dirPath != null ? await KMetaService.instance.getMeta(dirPath) : null;

      for (final gpkg in folder.children.whereType<GeoPackageNode>()) {
        Map<String, String>? dbStyles;
        final layers = gpkg.children.whereType<LayerNode>().toList();
        for (final layer in layers) {
          if (meta != null && meta.styles.layers.containsKey(layer.layerKey)) continue;

          dbStyles ??= await _readGpkgLayerStyles(gpkg);
          var qmlText = dbStyles[layer.layerName.toLowerCase()];

          if (qmlText == null && dirPath != null && dirFiles != null) {
            qmlText = await _readSidecarQml(
              dirPath: dirPath,
              dirFiles: dirFiles,
              gpkgFileName: gpkg.name,
              layerName: layer.layerName,
              singleLayerInGpkg: layers.length == 1,
            );
          }
          if (qmlText == null) continue;

          final parsed = await _parseQmlStyleWithLocalSvgs(
            qmlText,
            baseDir: dirPath,
            rootDir: rootPath,
          );
          if (parsed == null || parsed.isEmpty) continue;
          await QgsStyleReader.applyImportedLayerStyle(layer, parsed);
          await layer.refreshStyleGroups();
          applied++;
        }
      }

      for (final sub in folder.children.whereType<FolderNode>()) {
        await walkFolder(sub);
      }
    }

    await walkFolder(root);
    if (applied > 0) {
      AppLogger.debug('[QgsEmbeddedStyleLoader] 埋め込み / .qml スタイルを $applied レイヤに初期適用');
    }
    return applied;
  }

  /// QGIS の `.qml`（`<qgis>` ルート）からスタイル＋ラベル＋縮尺制限を読み取る
  static KMetaLayerStyle? parseQmlStyle(
    String qmlXml, {
    QgsSvgFileReader? svgFileReader,
  }) {
    try {
      final doc = XmlDocument.parse(qmlXml);
      return QgsStyleReader.readStyleWithLabel(doc.rootElement, svgFileReader: svgFileReader);
    } on Object catch (e) {
      AppLogger.debug('[QgsEmbeddedStyleLoader] QML パース失敗: $e');
      return null;
    }
  }

  static Future<KMetaLayerStyle?> _parseQmlStyleWithLocalSvgs(
    String qmlXml, {
    required String? baseDir,
    required String? rootDir,
  }) async {
    try {
      final doc = XmlDocument.parse(qmlXml);
      final svgFiles = await QgsStyleReader.preloadLocalSvgFiles(
        doc,
        baseDir: baseDir,
        rootDir: rootDir,
      );
      return QgsStyleReader.readStyleWithLabel(
        doc.rootElement,
        svgFileReader: svgFiles.isEmpty ? null : (raw) => svgFiles[raw],
      );
    } on Object catch (e) {
      AppLogger.debug('[QgsEmbeddedStyleLoader] QML パース失敗: $e');
      return null;
    }
  }

  static Future<Map<String, String>> _readGpkgLayerStyles(GeoPackageNode gpkg) async {
    final out = <String, String>{};
    try {
      final db = await gpkg.geoPackageFile.getDatabase();
      final exists = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='layer_styles' LIMIT 1",
      );
      if (exists.isEmpty) return out;
      final rows = await db.rawQuery(
        'SELECT f_table_name, styleQML, useAsDefault FROM layer_styles ORDER BY useAsDefault DESC, id DESC',
      );
      for (final row in rows) {
        final table = (row['f_table_name'] as String?)?.trim().toLowerCase();
        final qml = row['styleQML'] as String?;
        if (table != null && table.isNotEmpty && qml != null && qml.isNotEmpty) {
          out.putIfAbsent(table, () => qml);
        }
      }
    } on Object catch (e) {
      AppLogger.debug('[QgsEmbeddedStyleLoader] layer_styles 読み取り失敗 (${gpkg.name}): $e');
    }
    return out;
  }

  static Future<String?> _readSidecarQml({
    required String dirPath,
    required Set<String> dirFiles,
    required String gpkgFileName,
    required String layerName,
    required bool singleLayerInGpkg,
  }) async {
    final gpkgBase = p.basenameWithoutExtension(gpkgFileName);
    final candidates = <String>[
      '$layerName.qml',
      '${gpkgBase}_$layerName.qml',
      if (singleLayerInGpkg) '$gpkgBase.qml',
    ];
    final lowerMap = {for (final f in dirFiles) f.toLowerCase(): f};
    for (final c in candidates) {
      final actual = lowerMap[c.toLowerCase()];
      if (actual == null) continue;
      try {
        return await fs.readAsString(p.join(dirPath, actual));
      } on Object {
        continue;
      }
    }
    return null;
  }
}
