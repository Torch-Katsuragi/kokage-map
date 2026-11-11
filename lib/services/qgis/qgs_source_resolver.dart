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
/// `.qgs` の `<maplayer>` データソース解決（GeoPackage・外部レイヤ・表・GeoTIFF・XYZ/WMS 背景地図）。
library;

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../models/basemap_provider.dart';
import '../../models/nodes/external_layer_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/image_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../models/nodes/table_node.dart';
import '../external/external_source.dart';
import '../gdal_raster_overlay.dart';
import 'qgs_raster_source.dart';
import 'qgs_xml.dart';

/// QGISのデータソース文字列から取り出したもの。
class QgsDataSource {
  const QgsDataSource({required this.path, this.layerName, this.subset, this.geometryType});

  /// `.qgs` からの相対、または絶対パス
  final String path;

  /// GeoPackage内のテーブル名
  final String? layerName;

  /// subset string（SQLのWHERE句）
  final String? subset;

  /// `geometrytype=`（QGIS が型の混ざったファイルの型ごとのサブレイヤに付ける。例 `Point`）
  final String? geometryType;

  /// OGRのデータソース文字列を分解する。
  ///
  /// `path|layername=foo|subset=bar` の形。`|` で区切られ、`key=value` が続く。
  /// ⚠ subset にも `|` が入りうるので、**subset は最後まで丸ごと**取る。
  static QgsDataSource? parse(String raw) {
    if (raw.trim().isEmpty) return null;

    // subset は残り全部。先に切り出しておかないと `|` で壊れる
    String rest = raw;
    String? subset;
    final subsetAt = rest.indexOf('|subset=');
    if (subsetAt >= 0) {
      subset = rest.substring(subsetAt + '|subset='.length);
      rest = rest.substring(0, subsetAt);
    }

    final parts = rest.split('|');
    final path = parts.first.trim();
    String? layerName;
    String? geometryType;
    for (final part in parts.skip(1)) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      final value = part.substring(eq + 1).trim();
      if (key == 'layername') layerName = value;
      if (key == 'geometrytype') geometryType = value;
      // layerid / table 等は使わない
    }
    if (path.isEmpty) return null;
    return QgsDataSource(path: path, layerName: layerName, subset: subset, geometryType: geometryType);
  }
}

/// 解決できたベクタ `<maplayer>` とツリー上のレイヤの組。
typedef QgsResolvedLayer = ({String name, QgsDataSource source, LayerNode layer, GeoPackageNode gpkg});

/// `<maplayer>` のデータソースを、ツリーのレイヤ・表・オーバーレイ画像・背景地図に結びつける。
class QgsSourceResolver {
  QgsSourceResolver(this.qgsDir, this.rootPath, this.gpkgIndex, this.imageIndex, [this.tableIndex = const {}]);

  factory QgsSourceResolver.fromRoot(String qgsDir, FolderNode root, {bool includeTables = true}) => QgsSourceResolver(
    qgsDir,
    root.getAbsoluteFilePath(),
    _indexGeoPackages(root),
    _indexImages(root),
    includeTables ? _indexTables(root) : const {},
  );

  /// `.qgs` のある dir（相対パスの基準）
  final String qgsDir;
  final String? rootPath;

  /// 正規化した絶対パス → GeoPackage
  final Map<String, GeoPackageNode> gpkgIndex;

  /// 正規化した絶対パス → 画像（写真・オーバーレイ）
  final Map<String, ImageNode> imageIndex;

  /// 正規化した絶対パス → 表（座標の無い CSV）
  final Map<String, TableNode> tableIndex;

  /// 表の maplayer の id → 表のノード（結合先を読み替える）
  final tables = <String, TableNode>{};

  /// gdal のラスタのうち、dir にあるオーバーレイ画像に当たったもの（maplayer の id つき）
  final overlays = <({OverlayImageNode node, String id})>[];

  /// wms の XYZ タイル・WMS（一覧に無い URL は利用者の地図の定義 `custom` つき）
  final baseMaps = <({String providerId, String name, String id, int opacity, BaseMapProvider? custom})>[];

  /// gpkg（相当）のノードを引くときのパス（[_indexGeoPackages] と同じ決まり）
  static String? gpkgIndexPath(GeoPackageNode n) {
    final abs = n is ExternalLayerNode ? n.sourcePath : n.geoPackageFile.getAbsolutePath();
    return abs == null ? null : p.normalize(abs);
  }

  /// ルート以下の GeoPackage を、正規化した絶対パスで引けるようにする
  static Map<String, GeoPackageNode> _indexGeoPackages(LayerTreeNode node) {
    final result = <String, GeoPackageNode>{};
    void walk(LayerTreeNode n) {
      if (n is GeoPackageNode) {
        // 読み取り専用レイヤは元のファイルのパスで引く（キャッシュのパスは .qgs に出てこない）
        final abs = gpkgIndexPath(n);
        if (abs != null) result[abs] = n;
      }
      for (final child in n.children) {
        walk(child);
      }
    }

    walk(node);
    return result;
  }

  /// ルート以下の画像（写真・オーバーレイ）を、正規化した絶対パスで引けるようにする
  static Map<String, ImageNode> _indexImages(LayerTreeNode node) {
    final result = <String, ImageNode>{};
    void walk(LayerTreeNode n) {
      if (n is ImageNode) {
        final abs = n.getAbsoluteFilePath();
        if (abs != null) result[p.normalize(abs)] = n;
      }
      for (final child in n.children) {
        walk(child);
      }
    }

    walk(node);
    return result;
  }

  /// ルート以下の表（座標の無い CSV）を、正規化した絶対パスで引けるようにする
  static Map<String, TableNode> _indexTables(LayerTreeNode node) {
    final result = <String, TableNode>{};
    void walk(LayerTreeNode n) {
      if (n is TableNode) result[p.normalize(n.sourcePath)] = n;
      for (final child in n.children) {
        walk(child);
      }
    }

    walk(node);
    return result;
  }

  /// 取り込む先のレイヤ。取り込めなければ理由を [discarded] に足して null。
  /// 黙って飛ばすもの（埋め込みスタブ・ラスタ）も null
  QgsResolvedLayer? resolve(XmlElement maplayer, List<String> discarded) {
    // 埋め込みスタブ（別プロジェクトの管轄。2026-09-30 以前にこかげマップが書いたものか、手で足したもの）
    if (maplayer.getAttribute('embedded') == '1') return null;

    final name = childText(maplayer, 'layername') ?? '(名前なし)';
    final provider = childText(maplayer, 'provider')?.toLowerCase();

    // ラスタはレイヤ（View）にはならない。GeoTIFF はオーバーレイ画像、XYZ タイルは背景地図へ
    if (maplayer.getAttribute('type') == 'raster') {
      _resolveRaster(maplayer, name, provider, discarded);
      return null;
    }

    // 形の無い表（CSV）は View にならない。結合の先として表のノードに結びつける
    if (isQgsTableLayer(maplayer)) {
      _resolveTable(maplayer, name, discarded);
      return null;
    }

    if (provider != null && provider != 'ogr') {
      // PostGIS / WMS / メモリレイヤ等。ファイルとして持ち歩けない
      discarded.add('$name（$provider は取り込めません）');
      return null;
    }

    final source = QgsDataSource.parse(childText(maplayer, 'datasource') ?? '');
    // gpkg 以外（shp・GeoJSON など）は `|layername=` が無くてよい（読み取り専用レイヤに結びつける）
    if (source == null || (source.layerName == null && _isGeoPackagePath(source.path))) {
      discarded.add('$name（データソースを読み取れません）');
      return null;
    }

    final absPath = p.normalize(p.isAbsolute(source.path) ? source.path : p.join(qgsDir, source.path));
    final root = rootPath;
    if (root == null || relativeInside(root, absPath) == null) {
      // ⚠ 相対パスで root 外を指すケース（`../shared/kyoyu.gpkg`）もあるため、
      //    判定は正規化した絶対パスで行う
      discarded.add('$name（プロジェクトフォルダの外を参照している）');
      return null;
    }

    final gpkg = gpkgIndex[absPath];
    if (gpkg == null) {
      discarded.add('$name（${p.basename(absPath)} が見つかりません）');
      return null;
    }

    final layerName = gpkg is ExternalLayerNode ? _externalLayerName(gpkg, source) : source.layerName!;
    final layer = gpkg.children.whereType<LayerNode>().where((l) => l.layerName == layerName).firstOrNull;
    if (layer == null) {
      discarded.add('$name（${gpkg.name} に $layerName がありません）');
      return null;
    }
    return (name: name, source: source, layer: layer, gpkg: gpkg);
  }

  /// 表の `<maplayer>` を [tables] に入れる。dir に無い・座標のある CSV（点のレイヤになっている）なら報告
  void _resolveTable(XmlElement maplayer, String name, List<String> discarded) {
    final id = childText(maplayer, 'id');
    final path = qgsTableSourcePath(maplayer);
    if (id == null || path == null) {
      discarded.add('$name（${childText(maplayer, 'provider') ?? '不明なプロバイダ'} の表は取り込めません）');
      return;
    }
    final absPath = p.normalize(p.isAbsolute(path) ? path : p.join(qgsDir, path));
    final root = rootPath;
    if (root == null || relativeInside(root, absPath) == null) {
      discarded.add('$name（プロジェクトフォルダの外を参照している）');
      return;
    }
    final node = tableIndex[absPath];
    if (node == null) {
      discarded.add('$name（${p.basename(absPath)} を表として開けません）');
      return;
    }
    tables[id] = node;
  }

  /// ラスタの `<maplayer>` を [overlays] か [baseMaps] に振り分ける。扱えなければ理由を [discarded] に足す。
  ///
  /// dir に置かれたファイルが正で、`.qgs` は表示の設定を運ぶだけ（[[docs/technical/external-formats]]）。
  /// GeoTIFF のノードは dir の中身から作られているので、ここでは突き合わせるだけで作らない
  void _resolveRaster(XmlElement maplayer, String name, String? provider, List<String> discarded) {
    final id = childText(maplayer, 'id') ?? '';
    final datasource = childText(maplayer, 'datasource') ?? '';
    switch (provider) {
      case 'gdal':
        if (datasource.trim().isEmpty || QgsRasterSource.isNonFileSource(datasource)) {
          discarded.add('$name（ファイルではないラスタは取り込めません）');
          return;
        }
        final path = datasource.split('|').first.trim();
        final absPath = p.normalize(p.isAbsolute(path) ? path : p.join(qgsDir, path));
        final root = rootPath;
        if (root == null || relativeInside(root, absPath) == null) {
          discarded.add('$name（プロジェクトフォルダの外を参照している）');
          return;
        }
        final ext = p.extension(absPath).toLowerCase();
        if (!GdalRasterOverlay.rasterExtensions.contains(ext)) {
          discarded.add('$name（${ext.isEmpty ? '拡張子の無い' : ext} ラスタは未対応）');
          return;
        }
        final node = imageIndex[absPath];
        if (node == null) {
          discarded.add('$name（${p.basename(absPath)} が見つかりません）');
        } else if (node is! OverlayImageNode) {
          // こかげマップの GeoTIFF でも、GDAL で位置と座標系が読めるラスタ（ExternalOverlayImageNode）でもない。
          // GDAL が無い環境（読み込みに失敗した web など）でもここに来る
          discarded.add('$name（${p.basename(absPath)} の位置か座標系を読めません）');
        } else {
          overlays.add((node: node, id: id));
        }
      case 'wms':
        // XYZ はその URL、本物の WMS は EPSG:3857 のタイルで引く GetMap の URL（どちらも利用者の地図になりうる）
        final xyz = QgsRasterSource.xyzUrl(datasource);
        final url = xyz ?? QgsRasterSource.wmsGetMapTemplate(datasource);
        if (url == null) {
          discarded.add('$name（WMTS は未対応）');
          return;
        }
        final opacity = QgsRasterSource.opacityPercent(maplayer);
        final known = BaseMapProvider.findByTileUrl(url);
        if (known != null) {
          baseMaps.add((providerId: known.id, name: name, id: id, opacity: opacity, custom: null));
          return;
        }
        final host = Uri.tryParse(url)?.host ?? '';
        // 配布アプリからの利用を規約で禁じているタイル（Google など）は持ち込まない
        if (BaseMapProvider.isForbiddenTileHost(url) || !BaseMapProvider.isValidTemplate(url)) {
          discarded.add('$name（${xyz == null ? 'WMS' : 'XYZ タイル'}を背景地図にできません${host.isEmpty ? '' : ': $host'}）');
          return;
        }
        final params = QgsRasterSource.parseWmsUri(datasource);
        final custom = BaseMapProvider.custom(
          name: name,
          urlTemplate: url,
          minZoom: int.tryParse(params['zmin'] ?? '') ?? 0,
          maxZoom: int.tryParse(params['zmax'] ?? '') ?? 18,
        );
        baseMaps.add((providerId: custom.id, name: name, id: id, opacity: opacity, custom: custom));
      default:
        discarded.add('$name（${provider ?? '不明なプロバイダ'} のラスタは取り込めません）');
    }
  }
}

bool _isGeoPackagePath(String path) => p.extension(path).toLowerCase() == '.gpkg';

/// 外部形式（読み取り専用レイヤ）のデータソースが指すキャッシュのレイヤ名。
///
/// `|layername=` は元のファイルの GDAL のレイヤ名、`|geometrytype=` は型の混ざったレイヤの点・線・面。
/// キャッシュを作ったときの割り当て（[ExternalLayerNode.sourcePlan]）で引く。
/// 割り当てが無ければ、1 レイヤならそれ、`geometrytype=` があれば `<名前>_point` など、なければファイル名（拡張子なし）
String _externalLayerName(GeoPackageNode node, QgsDataSource source) {
  final type = geometryTypeFromQgis(source.geometryType);
  final plan = node is ExternalLayerNode ? node.sourcePlan : null;
  if (plan != null) {
    final candidates = plan.layers.where(
      (l) =>
          (source.layerName == null || l.qgisLayerName == source.layerName) &&
          (type == null || !l.split || l.geometryType == type),
    );
    if (candidates.length == 1) return candidates.single.name;
    if (source.layerName != null && candidates.isNotEmpty) return candidates.first.name;
  }
  if (source.layerName != null) return source.layerName!;
  final layers = node.children.whereType<LayerNode>().toList();
  if (layers.length == 1) return layers.single.layerName;
  final stem = p.basenameWithoutExtension(source.path.replaceAll(r'\', '/'));
  return type == null ? stem : '$stem${externalSplitSuffix(type)}';
}
