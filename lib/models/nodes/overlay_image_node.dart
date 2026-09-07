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
// Root Maps: オーバーレイ画像ノード
// ImageNodeを継承し、地図上にラスタ画像をオーバーレイ表示するノード
// 変換パラメータ（位置・スケール・回転・透明度）はKMetaに永続化

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

import '../../services/geotiff_write_scheduler.dart';
import '../../services/kmeta_service.dart';
import '../../utils/app_logger.dart';
import '../kmeta.dart';
import 'image_node.dart';


/// オーバーレイ画像ノード
/// ImageNodeを継承し、地図上にラスタ画像を表示する
class OverlayImageNode extends ImageNode {
  /// オーバーレイ変換パラメータ
  KMetaImageOverlay overlayParams;

  OverlayImageNode(
    super.filePath,
    super.location,
    super.metadata, {
    required this.overlayParams,
    super.takenAt,
    super.direction,
    super.visible,
    super.parent,
  });

  /// 変換パラメータの中心座標をlocationとして返す
  @override
  LatLng? get location =>
      LatLng(overlayParams.centerLat, overlayParams.centerLng);

  @override
  bool get hasLocation => true;

  /// MapLibreソースID（ユニーク）
  String get overlaySourceId => 'overlay-src-${filePath.hashCode.abs()}';

  /// MapLibreレイヤID（ユニーク）
  String get overlayLayerId => 'overlay-lyr-${filePath.hashCode.abs()}';

  /// ensurePngCacheで解決されたPNGキャッシュのパス
  String? _cachedPngPath;

  /// PNGキャッシュパスを設定（ensurePngCache後に呼ばれる）
  set cachedPngPath(String path) => _cachedPngPath = path;

  /// 画像URLを取得（file://プロトコル）
  /// TIFFの場合はPNGキャッシュ（アプリキャッシュ領域）を参照
  String get imageUrl {
    // TIFFでPNGキャッシュが解決済みならそちらを使用
    if (_cachedPngPath != null) {
      final normalized = _cachedPngPath!.replaceAll('\\', '/');
      return 'file:///$normalized';
    }
    // JPG/PNGなど直接読めるファイル
    final absPath = getAbsoluteFilePath();
    if (absPath != null) {
      final normalized = absPath.replaceAll('\\', '/');
      return 'file:///$normalized';
    }
    return filePath;
  }

  /// 4頂点座標を計算（MapLibre ImageSource用）
  /// center + scale + rotation + imageSize から
  /// topLeft, topRight, bottomRight, bottomLeft の順で返す
  List<LatLng> get cornerCoordinates {
    final halfWidthMeters = overlayParams.imageWidth * overlayParams.scale / 2;
    final halfHeightMeters = overlayParams.imageHeight * overlayParams.scale / 2;

    // 回転角度をラジアンに変換（時計回り）
    final rotRad = overlayParams.rotation * math.pi / 180.0;
    final cosR = math.cos(rotRad);
    final sinR = math.sin(rotRad);

    // 4頂点のローカルオフセット（メートル、回転前）
    // topLeft(-w, +h), topRight(+w, +h), bottomRight(+w, -h), bottomLeft(-w, -h)
    final offsets = [
      [-halfWidthMeters, halfHeightMeters], // topLeft
      [halfWidthMeters, halfHeightMeters], // topRight
      [halfWidthMeters, -halfHeightMeters], // bottomRight
      [-halfWidthMeters, -halfHeightMeters], // bottomLeft
    ];

    return offsets.map((offset) {
      // 回転を適用
      final rotX = offset[0] * cosR - offset[1] * sinR;
      final rotY = offset[0] * sinR + offset[1] * cosR;

      // メートル→緯度経度変換（近似）
      final dLat = rotY / 111320.0;
      final dLng =
          rotX / (111320.0 * math.cos(overlayParams.centerLat * math.pi / 180));

      return LatLng(
        overlayParams.centerLat + dLat,
        overlayParams.centerLng + dLng,
      );
    }).toList();
  }

  /// GeoTIFFデバウンス書き込みスケジューラ（全OverlayImageNodeで共有）
  static final geoTiffScheduler = GeoTiffWriteScheduler();

  /// 変換パラメータをKMetaに永続化し、GeoTIFFタグ更新をスケジュール
  Future<void> saveOverlayParams() async {
    final absPath = getAbsoluteFilePath();
    if (absPath == null) return;

    final folderPath = p.dirname(absPath);
    final imageName = p.basename(absPath);

    // kmeta は即時保存
    final success = await KMetaService.instance.setImageOverlay(
      folderPath,
      imageName,
      overlayParams,
    );
    if (success) {
      AppLogger.debug('[OverlayImageNode] Saved overlay params for $imageName');
    }

    // GeoTIFFタグ更新をデバウンススケジュール（.tifファイルのみ）
    geoTiffScheduler.scheduleWrite(this);
  }
}

