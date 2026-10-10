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
/// レイヤツリーを辿って [QgsProject] を組み立て、`.qgs` として書き出す。
///
/// > [!IMPORTANT] 書き出す単位は「dir」
/// > Drive連携は**プロジェクト単位ではなくフォルダ単位**なので、
/// > `.qgs` も連携dirごとに置く。そのdirを単体で渡された人が、
/// > そのdirだけで開けるべきだから。パスも相対で書く。
///
/// > [!WARNING] root外は書かない
/// > 相対パスで外に出るデータソースは、渡された相手の環境には無い。
/// > 対象は「このdirの下にある `.gpkg`」だけ。
library;

import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/geometry_type.dart';
import '../../models/kmeta.dart';
import '../../models/nodes/external_layer_node.dart';
import '../../models/nodes/folder_node.dart';
import '../../models/nodes/geopackage_node.dart';
import '../../models/nodes/layer_node.dart';
import '../../models/nodes/layer_tree_node.dart';
import '../../models/nodes/overlay_image_node.dart';
import '../../models/nodes/sys_node.dart';
import '../../models/nodes/view_node.dart';
import '../../utils/app_logger.dart';
import '../../utils/label_template.dart';
import '../../utils/stable_hash.dart';
import '../coordinate/gpkg_crs_resolver.dart';
import '../external/external_source.dart';
import '../kmeta_service.dart';
import 'qgs_document.dart';
import 'qgs_meta_store.dart';
import 'qgs_model.dart';
import 'qgs_writer.dart';
import 'qgs_xml.dart';

/// [QgsProjectBuilder.writeTo] の結果
class QgsWriteResult {
  const QgsWriteResult({
    required this.path,
    required this.project,
    required this.updatedInPlace,
    required this.removedLayers,
    required this.untouchedRenderers,
  });

  /// 書いたファイル
  final String path;

  /// 書いた内容
  final QgsProject project;

  /// 既存ファイルを DOM 保持型で更新したか（false なら新規作成）
  final bool updatedInPlace;

  /// 文書にあったがプロジェクトに無いので外したレイヤ名
  final List<String> removedLayers;

  /// 単一シンボル以外なので触らなかったレイヤ id
  final List<String> untouchedRenderers;
}

class QgsProjectBuilder {
  const QgsProjectBuilder();

  /// [root] 以下を `.qgs` の内容に組み立てる。子孫の dir のレイヤも平らに全部入れる。
  ///
  /// [root] 自身はグループにしない（プロジェクトのルートそのものなので）。
  ///
  /// > [!IMPORTANT] どの dir の `.qgs` にも子孫のレイヤを写す（2026-09-30）
  /// > どの dir も、あるときは根として開かれ、別のときは子になる。QGIS で開いた dir の下が
  /// > 全部直せるように、埋め込み（QGIS では読み取り専用）をやめて写しを持つ。
  /// > 持ち主はデータソースの置き場所で決まり、正典は持ち主の dir の設定（`kokage/meta`）。
  /// > 写しは毎回そこから作り直すだけなので食い違わない。QGIS で直された写しは
  /// > [QgsReadBack] が持ち主へ振り分ける。
  Future<QgsProject> build(FolderNode root, {Map<LayerNode, QgsCrs>? crsCache}) async {
    final rootPath = root.getAbsoluteFilePath();
    final skipped = <String>[];
    final crs = crsCache ?? <LayerNode, QgsCrs>{};

    final children = <QgsTreeNode>[];
    for (final child in root.children) {
      final node = await _convert(child, rootPath, skipped, crs);
      if (node != null) children.add(node);
    }

    return QgsProject(name: await _projectName(root, rootPath), root: children, skipped: skipped);
  }

  /// [root] の下の dir 全部（深さ優先）。
  ///
  /// sys 自体は dir でないので飛ばし、その下（global）を見る。global がルート直下に
  /// あった頃と同じく、global や global 配下の連携dirに自分の設定（`.qgs`）があれば
  /// そこに `.qgs` を書く（sys は根の `.qgs` には載らない）。
  static Iterable<FolderNode> _foldersBelow(FolderNode root) sync* {
    for (final child in root.children.whereType<FolderNode>()) {
      if (child is! SysNode) yield child;
      yield* _foldersBelow(child);
    }
  }

  /// プロジェクト名。Drive 連携していれば Drive のフォルダ名、していなければ dir 名
  /// （[QgsProjectFile.projectNameFor]。端末ごとに dir 名が違っても `.qgs` を同じにする）。
  ///
  /// ⚠ ルートの [FolderNode.name] は "Home" 固定なので使えない。
  Future<String> _projectName(FolderNode root, String? rootPath) async {
    if (rootPath == null) return root.name;
    if (p.basename(p.normalize(rootPath)).isEmpty) return root.name;
    return QgsProjectFile.projectNameFor(rootPath, await KMetaService.instance.getRawMeta(rootPath));
  }

  /// [root] のフォルダに `<dir名>.qgs` を書く。[project] を渡さなければ、自分の設定（`.qgs`）を
  /// 持つ子孫の dir の `.qgs` も書き直す（どれにも子孫の写しが入るので、[root] の下が変わると
  /// 途中の dir の `.qgs` も変わる）。
  ///
  /// [project] を渡さなければその場で組み立てる。
  /// 呼び出し側が除外リストを見たい場合は、先に [build] して渡すこと。
  ///
  /// > [!IMPORTANT] 既にあれば DOM 保持型で更新する（2026-09-06）
  /// > QGIS 側で足した設定（印刷レイアウト・フィールド設定・単一シンボルの細部…）を
  /// > 消さないため、[QgsDocument.apply] で自分の管轄だけ差し替える。
  /// > 旧名 `project.qgs` が残っていれば新名に改名してから同じ扱いにする。
  ///
  /// 戻り値は書いた結果。書けなければ null。
  Future<QgsWriteResult?> writeTo(FolderNode root, {QgsProject? project}) async {
    final rootPath = root.getAbsoluteFilePath();
    if (rootPath == null) {
      AppLogger.debug('[QgsProjectBuilder] ルートのパスを解決できない');
      return null;
    }

    if (project == null) {
      // CRS は gpkg を開いて引くので、祖先ごとに引き直さない
      final crsCache = <LayerNode, QgsCrs>{};
      for (final folder in _foldersBelow(root)) {
        final folderPath = folder.getAbsoluteFilePath();
        if (folderPath == null) continue;
        if (!await KMetaService.instance.hasMetaFile(folderPath)) continue;
        await _writeOne(folder, folderPath, await build(folder, crsCache: crsCache));
      }
      return _writeOne(root, rootPath, await build(root, crsCache: crsCache));
    }
    return _writeOne(root, rootPath, project);
  }

  Future<QgsWriteResult> _writeOne(FolderNode root, String rootPath, QgsProject built) async {
    final dirName = await _projectName(root, rootPath);
    // 旧名 `project.qgs`・Drive のフォルダ名・dir 改名前の名前のものも [QgsProjectFile.find] が探す
    final path = await QgsProjectFile.find(rootPath) ?? p.join(rootPath, qgsFileNameFor(dirName));
    // フォルダ設定（[QgsMetaStore]）も同じファイルを書くので順番に
    return QgsFileLock.run(path, () => _writeLocked(path, dirName, built));
  }

  Future<QgsWriteResult> _writeLocked(String path, String dirName, QgsProject built) async {
    QgsDocument doc;
    var updatedInPlace = false;
    String? existing;
    if (await fs.exists(path)) {
      try {
        existing = await fs.readAsString(path);
        doc = QgsDocument.parse(existing);
        updatedInPlace = true;
      } on Object catch (e) {
        // 壊れていたら退避して作り直す（黙って上書きしない）
        AppLogger.debug('[QgsProjectBuilder] 既存の .qgs を読めないので退避: $e');
        await fs.rename(path, '$path.bak');
        doc = QgsDocument.create(projectName: built.name, projectCrs: built.projectCrs);
      }
    } else {
      doc = QgsDocument.create(projectName: built.name, projectCrs: built.projectCrs);
    }

    // QGIS が後から保存したもの（まだ読み戻していない）は書かない。書くとアプリの状態で上書きして
    // QGIS の変更が消える。読み戻しが取り込んで印を付け直したら（[QgsMetaStore.claim]）書ける。
    // 同期で届いた直後、帳簿の保存が呼んだ自動更新が、ツリーの読み直し（とその後の読み戻し）より
    // 先に走ることがある（2026-09-29）
    if (updatedInPlace && !doc.lastWrittenByKokage) {
      AppLogger.debug('[QgsProjectBuilder] $path は QGIS が後から保存したもの。読み戻すまで書かない');
      return QgsWriteResult(path: path, project: built, updatedInPlace: false, removedLayers: const [], untouchedRenderers: const []);
    }

    final report = doc.apply(built);
    doc.setStamp(await QgsMetaStore.newStamp(dirName));
    final xml = doc.toXmlString();
    // 保存時刻の印しか変わらないなら書かない。書くと更新時刻が進み、Drive 同期が毎回
    // 「端末で変更あり」と見てアップロードし続ける（2026-09-24、Fold で 5 分ごとに上げていた）
    if (existing != null && _withoutSaveTime(existing) == _withoutSaveTime(xml)) {
      AppLogger.debug('[QgsProjectBuilder] $path は変わらないので書かない');
    } else {
      await QgsFileWriter.write(path, xml);
      AppLogger.debug(
        '[QgsProjectBuilder] $path に ${built.layers.length} レイヤを書いた'
        '（除外 ${built.skipped.length} 件・${updatedInPlace ? "更新" : "新規"}・'
        '外した ${report.removedLayers.length} 件・触らなかったレンダラ ${report.untouchedRenderers.length} 件）',
      );
    }
    return QgsWriteResult(
      path: path,
      project: built,
      updatedInPlace: updatedInPlace,
      removedLayers: report.removedLayers,
      untouchedRenderers: report.untouchedRenderers,
    );
  }

  static final _saveTimePatterns = [
    RegExp('saveDateTime="[^"]*"'),
    RegExp('(<savedAt[^>]*>)[^<]*(</savedAt>)'),
  ];

  /// 保存時刻（root の `saveDateTime` と印の `savedAt`）を伏せた本文
  static String _withoutSaveTime(String xml) {
    var s = xml;
    for (final re in _saveTimePatterns) {
      s = s.replaceAll(re, '');
    }
    return s;
  }

  // =============================================
  // ノードの変換
  // =============================================

  Future<QgsTreeNode?> _convert(
    LayerTreeNode node,
    String? rootPath,
    List<String> skipped,
    Map<LayerNode, QgsCrs> crsCache,
  ) async {
    // 「System」（sys）はプロジェクトに属さない。.qgs に載せない（除外の報告にも出さない）
    if (node is SysNode) return null;
    if (node is FolderNode) {
      return _convertFolder(node, rootPath, skipped, crsCache);
    }
    // 読み取り専用レイヤは裏のキャッシュではなく元のファイルを指す（GeoPackageNode の派生なので先に見る）
    if (node is ExternalLayerNode) {
      return _convertExternal(node, rootPath, skipped, crsCache);
    }
    if (node is GeoPackageNode) {
      return _convertGeoPackage(node, rootPath, skipped, crsCache);
    }

    // オーバーレイ画像は GeoTIFF ならラスタレイヤとして参照を書く（位置は .tif のタグに焼き込み済み）。
    // ⚠ ImageNode（写真）はオーバーレイの親クラスなので、オーバーレイの判定を先にする
    if (node is OverlayImageNode) {
      return _convertOverlay(node, rootPath, skipped);
    }

    // 写真は点として扱うレイヤが無い（QGIS には写真の概念が無い）。黙って落とさず、必ず報告する。
    skipped.add('${node.name}（${node.nodeType.displayName}は未対応）');
    return null;
  }

  /// オーバーレイ画像 → ラスタレイヤ。GeoTIFF 以外は QGIS に位置を伝えられないので報告して外す
  QgsTreeNode? _convertOverlay(OverlayImageNode node, String? rootPath, List<String> skipped) {
    final relPath = _relativeTo(rootPath, node.getAbsoluteFilePath());
    if (relPath == null) {
      skipped.add('${node.name}（プロジェクトフォルダの外を参照している）');
      return null;
    }
    final ext = p.extension(relPath).toLowerCase();
    if (ext != '.tif' && ext != '.tiff') {
      skipped.add('${node.name}（GeoTIFF ではないので QGIS では位置が付かない）');
      return null;
    }
    return QgsRasterLayer(
      id: rasterLayerIdForPath(relPath),
      name: p.basenameWithoutExtension(relPath),
      dataSourcePath: relPath,
      visible: node.visible,
    );
  }

  /// ラスタレイヤの決定的な id（相対パスのハッシュ。[layerIdForViewKey] と同じ考え）
  static String rasterLayerIdForPath(String relPath) =>
      'raster_${stableHashHex(relPath.replaceAll(r'\', '/'))}';

  Future<QgsTreeNode?> _convertFolder(
    FolderNode folder,
    String? rootPath,
    List<String> skipped,
    Map<LayerNode, QgsCrs> crsCache,
  ) async {
    final children = <QgsTreeNode>[];
    for (final child in folder.children) {
      final converted = await _convert(child, rootPath, skipped, crsCache);
      if (converted != null) children.add(converted);
    }
    if (children.isEmpty) return null;
    return QgsGroup(
      name: folder.name,
      children: children,
      visible: folder.visible,
      expanded: folder.expanded,
    );
  }

  Future<QgsTreeNode?> _convertGeoPackage(
    GeoPackageNode gpkg,
    String? rootPath,
    List<String> skipped,
    Map<LayerNode, QgsCrs> crsCache,
  ) async {
    final absPath = gpkg.geoPackageFile.getAbsolutePath();
    final relPath = _relativeTo(rootPath, absPath);
    if (relPath == null) {
      // root外を指すgpkg。渡された相手の環境には無いので書かない。
      skipped.add('${gpkg.name}（プロジェクトフォルダの外を参照している）');
      return null;
    }

    final groups = <QgsTreeNode>[];
    for (final layer in gpkg.children.whereType<LayerNode>()) {
      final group = await _convertLayer(layer, relPath, skipped, crsCache);
      if (group != null) groups.add(group);
    }
    if (groups.isEmpty) return null;

    return QgsGroup(
      name: gpkg.name,
      children: groups,
      visible: gpkg.visible,
    );
  }

  /// 読み取り専用レイヤ（GDAL で読む形式）→ `provider=ogr` で**元のファイル**を指す（キャッシュのパスは書かない）。
  ///
  /// 1 ファイル 1 レイヤなら `./林班.shp` だけ。ほかは [externalUriOptions]。
  /// CRS はキャッシュ gpkg のもの（ogr2ogr が元の CRS のまま書いている）、shp の文字コードは [externalProviderEncoding]
  Future<QgsTreeNode?> _convertExternal(
    ExternalLayerNode node,
    String? rootPath,
    List<String> skipped,
    Map<LayerNode, QgsCrs> crsCache,
  ) async {
    final relPath = _relativeTo(rootPath, node.sourcePath);
    if (relPath == null) {
      skipped.add('${node.name}（プロジェクトフォルダの外を参照している）');
      return null;
    }
    final layers = node.children.whereType<LayerNode>().toList();
    final encoding = await externalProviderEncoding(node);

    final groups = <QgsTreeNode>[];
    for (final layer in layers) {
      final group = await _convertLayer(
        layer,
        relPath,
        skipped,
        crsCache,
        uriOptions: externalUriOptions(node, layer.layerName, layerCount: layers.length),
        providerEncoding: encoding,
      );
      if (group != null) groups.add(group);
    }
    if (groups.isEmpty) return null;
    return QgsGroup(name: node.name, children: groups, visible: node.visible);
  }

  /// 読み取り専用レイヤの `|` の後ろ（[QgsLayer.uriOptions]）。
  /// 元のファイルに GDAL のレイヤが複数あれば `layername=<GDAL のレイヤ名>`、
  /// 型の混ざったレイヤから分けたものは `geometrytype=Point` など（QGIS が型ごとのサブレイヤに付ける形）。
  /// CSV はアプリが開くときと同じオープンオプションを `option:` で添える（無いと QGIS では形の無い表になる。
  /// QGIS 4.2.2 で確認、2026-10-10）
  static List<String> externalUriOptions(ExternalLayerNode node, String layerName, {required int layerCount}) {
    final csv = [
      if (p.extension(node.sourcePath).toLowerCase() == '.csv')
        for (final option in csvOpenOptions) 'option:$option',
    ];
    final plan = node.sourcePlan;
    final layer = plan?.layers.where((l) => l.name == layerName).firstOrNull;
    if (plan == null || layer == null) return [if (layerCount > 1) 'layername=$layerName', ...csv];
    return [
      if (plan.sourceLayerCount > 1) 'layername=${layer.sourceLayer}',
      if (layer.qgisGeometryType != null) 'geometrytype=${layer.qgisGeometryType}',
      ...csv,
    ];
  }

  /// 読み取り専用レイヤの `<provider encoding>`。`.cpg` も DBF の LDID も無い shp はアプリと同じ CP932
  /// （[[gdal#Android の実装で決めたこと（2026-10-09）]]）。ほかは GDAL が自分で決めるので UTF-8
  static Future<String> externalProviderEncoding(ExternalLayerNode node) async =>
      await ExternalSource.needsFallbackEncoding(node.sourcePath) ? shapefileFallbackEncoding : 'UTF-8';

  /// Layer は**グループ**になり、その下の View が QGIS のレイヤになる。
  Future<QgsTreeNode?> _convertLayer(
    LayerNode layer,
    String gpkgRelPath,
    List<String> skipped,
    Map<LayerNode, QgsCrs> crsCache, {
    List<String>? uriOptions,
    String providerEncoding = 'UTF-8',
  }) async {
    final geometryType = _geometryTypeOf(layer);
    if (geometryType == null) {
      skipped.add('${layer.layerName}（ジオメトリ種別が分からない）');
      return null;
    }

    if (layer.views.isEmpty) await layer.loadViews();
    final crs = crsCache[layer] ??= await _crsOf(layer);
    final layerStyle = await layer.getKmetaStyle();

    final qgsLayers = <QgsTreeNode>[
      for (final view in layer.views)
        QgsLayer(
          id: _layerId(view, gpkgRelPath),
          name: view.displayName,
          dataSourcePath: gpkgRelPath,
          tableName: layer.layerName,
          geometryType: geometryType,
          crs: crs,
          subset: view.filter,
          // View に指定が無ければレイヤのスタイルに落ちる
          style: _toQgsStyle(view.style == null ? layerStyle : view.style!.mergeWith(layerStyle)),
          visible: view.visible,
          uriOptions: uriOptions,
          providerEncoding: providerEncoding,
        ),
    ];
    if (qgsLayers.isEmpty) return null;

    return QgsGroup(
      name: layer.layerName,
      children: qgsLayers,
      visible: layer.visible,
    );
  }

  // =============================================
  // 部品
  // =============================================

  /// `.qgs` から見た相対パス（[relativeInside]）。root外を指していたら null。
  /// QGIS は `./` 始まりを相対パスとして扱う。区切りは常に `/`
  String? _relativeTo(String? rootPath, String? absPath) {
    if (rootPath == null || absPath == null) return null;
    final rel = relativeInside(rootPath, absPath);
    return rel == null ? null : './${rel.replaceAll(r'\', '/')}';
  }

  /// View の一意ID。
  ///
  /// **決定的に作る。** 生成のたびに変わると `.qgs` の差分が毎回出て、
  /// Drive同期が無駄に動く。QGIS は中身を問わず「一意な文字列」としか見ない。
  ///
  /// ⚠ 以前は `String.hashCode` を使っていたが、VM と dart2js で値が違い
  /// **web と Android で同じ View に別の id が付いていた**（2026-09-06）。
  /// [stableHashHex] はプラットフォームを跨いで同じ値になる。
  ///
  /// ⚠ [ViewNode.viewKey] は `gpkg名/レイヤ名/View名` で **dir を含まない**。
  /// 同名の gpkg が root とサブ dir にあると id が衝突する（2026-09-06 に
  /// デモデータで実際に起きた。QGIS は同じ id のレイヤを1つに畳む）ので、
  /// gpkg の相対パスの dir 部分を混ぜる。
  String _layerId(ViewNode view, String gpkgRelPath) =>
      layerIdForViewKey(view.viewKey, dirPath: p.dirname(gpkgRelPath));

  /// [viewKey]（`gpkg名/レイヤ名/View名`）から決定的なレイヤ id を作る。
  ///
  /// [dirPath] は gpkg がある dir（root からの相対）。root 直下は `''` か `.`。
  static String layerIdForViewKey(String viewKey, {String dirPath = ''}) {
    final dir = dirPath.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');
    final key = (dir.isEmpty || dir == '.') ? viewKey : '$dir/$viewKey';
    final sanitized = viewKey.replaceAll(RegExp('[^A-Za-z0-9]'), '_');
    // 非ASCIIを潰すと衝突しうるので、元のキー（dir 込み）のハッシュを添える
    return '${sanitized}_${stableHashHex(key)}';
  }

  GeometryType? _geometryTypeOf(LayerNode layer) {
    if (layer is PointLayerNode) return GeometryType.point;
    if (layer is LineLayerNode) return GeometryType.linestring;
    if (layer is PolygonLayerNode) return GeometryType.polygon;
    return null;
  }

  Future<QgsCrs> _crsOf(LayerNode layer) async {
    try {
      final db = await layer.geoPackageFile.getDatabase();
      final crs = await GpkgCrsResolver.instance.resolveLayerCrs(
        db,
        layer.layerName,
      );
      return QgsCrs(
        authId: crs.epsgCode,
        srid: crs.srsId,
        description: crs.name,
        wkt: crs.definitionWkt,
        proj4: crs.proj4String,
        isGeographic: crs.isWgs84,
      );
    } catch (e) {
      // 解決できなければWGS84として書く。gpkg側に正しい定義があるので
      // QGIS は開いた時点で直せる（間違ったsrsidを書き込むよりまし）。
      AppLogger.debug('[QgsProjectBuilder] CRSを解決できない: $e');
      return QgsCrs.wgs84;
    }
  }

  QgsStyle? _toQgsStyle(KMetaLayerStyle? style) {
    if (style == null) return null;
    final converted = QgsStyle(
      labelEnabled: style.labelEnabled,
      labelField: normalizeLabelExpression(style.labelProperty),
      // こかげマップ のラベルは px、QGIS は pt。96dpi で 1px = 0.75pt
      labelFontSizePt: style.labelFontSize == null ? null : style.labelFontSize! * 0.75,
      labelColor: style.labelColor,
      labelHaloColor: style.labelHaloColor,
      pointColor: style.pointColor,
      pointSizePx: style.pointSize,
      lineColor: style.lineColor,
      lineWidthPx: style.lineWidth,
      fillColor: style.polygonFillColor,
      fillOpacity: style.polygonFillOpacity,
      strokeColor: style.polygonBorderColor,
      strokeWidthPx: style.polygonBorderWidth,
      strokeOpacity: style.polygonBorderOpacity,
    );
    return converted.isEmpty ? null : converted;
  }
}
