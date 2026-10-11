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
// こかげマップ: 地物に写真を付ける・外す（ファイルの置き場所と属性の列）
//
// 写真は gpkg の隣の `photos/<レイヤ>/` に置き、属性の `photo`（2 枚目から `photo_2`…）に
// gpkg の dir からの相対パスを書く。列が無ければ作り、作った列はフォルダ設定に覚えて
// `.qgs` に写真の欄（ExternalResource）を書く印にする（[[docs/features/feature-photos]]）。

import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/nodes/feature_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../utils/app_logger.dart';
import '../kmeta_service.dart';
import 'exif_gps_writer.dart';
import 'feature_photo_paths.dart';

/// 地物に付いた写真 1 枚
class FeaturePhoto {
  const FeaturePhoto({required this.column, required this.value, required this.path});

  /// 属性の列（`photo`・`photo_2`…）
  final String column;

  /// 属性の値（gpkg の dir からの相対パス）
  final String value;

  /// 実際のパス
  final String path;
}

class FeaturePhotoService {
  FeaturePhotoService._();

  /// gpkg の dir。写真の置き場所と相対パスの起点
  static String? gpkgDirOf(FeatureNode f) {
    final abs = f.geoPackageFile.getAbsolutePath();
    return abs == null ? null : p.dirname(abs);
  }

  /// 地物に付いている写真（列の順）
  static List<FeaturePhoto> photosOf(FeatureNode f) {
    if (f.isDisposed) return const [];
    final dir = gpkgDirOf(f);
    if (dir == null) return const [];
    final props = f.turfFeature.properties;
    return [
      for (final l in FeaturePhotoPaths.linksOf(props))
        FeaturePhoto(column: l.column, value: l.path, path: FeaturePhotoPaths.resolve(dir, l.path)),
    ];
  }

  /// 写真のバイト列を置き場所に書いて地物に付ける。付けた写真を返す（書けなければ null）。
  ///
  /// [fix] を渡すと、EXIF に位置が無い JPEG に書き込む（カメラアプリの位置情報が切ってあるとき）。
  /// ギャラリーから選んだ写真には渡さない（別の場所で撮った写真に今の位置を入れてしまう）。
  /// [takenAt] はファイル名の日時（省略で今）
  static Future<FeaturePhoto?> attachBytes(
    FeatureNode f,
    Uint8List bytes, {
    String ext = '.jpg',
    LatLng? fix,
    double? altitude,
    DateTime? takenAt,
  }) async {
    final dir = gpkgDirOf(f);
    if (dir == null || f.isDisposed) return null;
    final time = takenAt ?? DateTime.now();
    final normalizedExt = ext.toLowerCase() == '.jpeg' ? '.jpg' : ext.toLowerCase();
    var rel = FeaturePhotoPaths.relativePath(f.layerName, FeaturePhotoPaths.fileName(time, f.rowId, ext: normalizedExt));
    // 同じ秒に 2 枚撮ったら `_1` を足す
    final taken = <String>{};
    while (await fs.exists(FeaturePhotoPaths.resolve(dir, rel))) {
      taken.add(rel);
      rel = FeaturePhotoPaths.uniqueRelative(rel, taken.contains);
    }
    final abs = FeaturePhotoPaths.resolve(dir, rel);

    var data = bytes;
    if (fix != null && normalizedExt == '.jpg') {
      try {
        data = ExifGpsWriter.addIfMissing(bytes, fix, altitude: altitude, time: time) ?? bytes;
      } on Object catch (e) {
        AppLogger.debug('[FeaturePhoto] EXIF に位置を書けない（元のまま置く）: $e');
      }
    }
    await fs.createDirectory(p.dirname(abs));
    await fs.writeAsBytes(abs, data);
    final column = await link(f, rel);
    return FeaturePhoto(column: column, value: rel, path: abs);
  }

  /// 地物に写真の相対パス [rel] を付ける。入れた列を返す。
  /// 空いている写真の列が無ければ `photo`・`photo_N` を作る（TEXT）
  static Future<String> link(FeatureNode f, String rel) async {
    final gpkg = f.geoPackageFile;
    final columns = await gpkg.getColumnNames(f.layerName, getAll: true);
    final next = FeaturePhotoPaths.nextColumn(columns, f.turfFeature.properties);
    await f.setAttributeValues({next.column: rel});
    await f.flushChanges();
    if (next.create) await _rememberCreatedColumn(f, next.column);
    return next.column;
  }

  /// 写真を外す（列を空にする）。[deleteFile] なら写真のファイルも消す
  static Future<void> unlink(FeatureNode f, FeaturePhoto photo, {bool deleteFile = false}) async {
    await f.setAttributeValue(photo.column, null);
    await f.flushChanges();
    if (!deleteFile) return;
    try {
      if (await fs.exists(photo.path)) await fs.delete(photo.path);
    } on Object catch (e) {
      AppLogger.debug('[FeaturePhoto] 写真のファイルを消せない: $e');
    }
  }

  /// アプリが作った写真の列をフォルダ設定に覚える（`.qgs` に写真の欄を書く印。設定の保存で `.qgs` も書き直る）
  static Future<void> _rememberCreatedColumn(FeatureNode f, String column) async {
    final folder = f.parent.folderNode;
    final folderPath = folder?.getAbsoluteFilePath();
    if (folder == null || folderPath == null) return;
    await KMetaService.instance.addPhotoField(folderPath, f.parent.layerKey, column);
    folder.invalidateMetaCache();
  }

  /// 写真を置いた dir をレイヤ一覧に出す（gpkg の dir → `photos` → `<レイヤ>` の順に読み直す）
  static Future<void> refreshTree(FeatureNode f) async {
    FolderNode? node = f.parent.folderNode;
    if (node == null) return;
    try {
      await node.updateChildren();
      for (final seg in [FeaturePhotoPaths.dirName, FeaturePhotoPaths.safeSegment(f.layerName)]) {
        final next = node!.children.whereType<FolderNode>().where((c) => c.name == seg).firstOrNull;
        if (next == null) return;
        await next.updateChildren();
        node = next;
      }
    } on Object catch (e) {
      AppLogger.debug('[FeaturePhoto] レイヤ一覧を読み直せない: $e');
    }
  }
}
