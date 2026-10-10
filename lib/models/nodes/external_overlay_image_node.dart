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
// QGIS / GDAL で作ったラスタのオーバーレイ（読み取り専用）。
// 位置はファイル（GeoTIFF のタグ・ワールドファイル・.aux.xml）が正で、アプリは書き換えない。
// 表示は GDAL で EPSG:4326 にワープした PNG キャッシュ（[GdalRasterOverlay.render]）

import '../../core/fs/k_file_system.dart';
import '../../services/gdal_raster_overlay.dart';
import '../../utils/app_logger.dart';
import 'image_node.dart';
import 'layer_tree_node.dart';
import 'overlay_image_node.dart';

class ExternalOverlayImageNode extends OverlayImageNode {
  ExternalOverlayImageNode(
    String filePath,
    this.probe, {
    required int fileSize,
    super.visible,
    super.parent,
  }) : super(
          filePath,
          null,
          ImageMetadata(fileSize: fileSize),
          overlayParams: GdalRasterOverlay.initialParams(probe),
        );

  /// GDAL で位置と座標系が読めるラスタならノードを作る。[siblingNames] は同じフォルダのファイル名（小文字）。
  /// 写真（ワールドファイルの無い JPEG など）は GDAL を呼ばずに null
  static Future<ExternalOverlayImageNode?> tryCreate(
    String path,
    Set<String> siblingNames, {
    LayerTreeNode? parent,
  }) async {
    if (!GdalRasterOverlay.worthProbing(path, siblingNames)) return null;
    final probe = await GdalRasterOverlay.probe(path);
    if (probe == null) return null;
    return ExternalOverlayImageNode(
      path,
      probe,
      fileSize: await fs.length(path) ?? 0,
      visible: true,
      parent: parent,
    );
  }

  /// `gdalinfo -json` から読んだもの（元の座標系は `.qgs` への書き戻しに使う）
  final GdalRasterProbe probe;

  @override
  bool get isReadOnly => true;

  /// 元のファイル一式（.pgw・.aux.xml・.ovr・.tfw …、自分自身を含む）。削除の確認に並べる
  Future<List<String>> sourceFiles() => GdalRasterOverlay.sourceFiles(filePath);

  /// 利用者が消したとき: 元のファイル一式と PNG キャッシュを消す（読み取り専用のベクタレイヤと同じ扱い）
  @override
  Future<void> dispose() async {
    for (final path in await sourceFiles()) {
      try {
        if (await fs.exists(path)) await fs.delete(path);
      } catch (e) {
        AppLogger.debug('[ExternalOverlayImageNode] 消せない: $path - $e');
      }
    }
    try {
      await GdalRasterOverlay.discardCache(filePath);
    } catch (e) {
      AppLogger.debug('[ExternalOverlayImageNode] キャッシュを消せない: $e');
    }
    await super.dispose(); // 本体は消えているので、親から外れるだけ
  }

  /// PNG キャッシュを用意し、形をワープ後の範囲に合わせる（GDAL は別スレッド／web は worker で動く）
  Future<void> ensureRendered() async {
    final r = await GdalRasterOverlay.render(filePath, probe);
    cachedPngPath = r.pngPath;
    overlayParams = r.params;
  }
}
