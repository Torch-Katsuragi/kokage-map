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

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../../core/fs/k_file_system.dart';
import '../../models/geometry_type.dart';
import '../../models/kmeta.dart';
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
import '../kmeta_service.dart';
import 'qgs_document.dart';
import 'qgs_model.dart';
import 'qgs_writer.dart';

/// アプリ側の `.qgs` の読み方の版。印（`kokage/schemaVersion`）に書く。
const int kQgsSchemaVersion = 1;

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

  /// [root] 以下を `.qgs` の内容に組み立てる。
  ///
  /// [root] 自身はグループにしない（プロジェクトのルートそのものなので）。
  ///
  /// [embedded] は「この dir の直下の子 dir → 埋め込みグループ」。
  /// [writeTo] が子 dir の `.qgs` を先に書いてから渡す。
  Future<QgsProject> build(
    FolderNode root, {
    Map<String, QgsEmbeddedGroup> embedded = const {},
  }) async {
    final rootPath = root.getAbsoluteFilePath();
    final skipped = <String>[];

    final children = <QgsTreeNode>[];
    for (final child in root.children) {
      final node = await _convert(child, rootPath, skipped, embedded);
      if (node != null) children.add(node);
    }

    return QgsProject(name: _projectName(root, rootPath), root: children, skipped: skipped);
  }

  /// 自分の `.qgs` を持ちうる子 dir。
  ///
  /// sys 自体は dir でないので飛ばし、その下（global）を見る。global がルート直下に
  /// あった頃と同じく、global や global 配下の連携dirに `.kmeta.json` があれば
  /// そこに `.qgs` を書く（相対パスが取れないので親には埋め込まれない）。
  static Iterable<FolderNode> _ownQgsCandidates(FolderNode root) sync* {
    for (final child in root.children.whereType<FolderNode>()) {
      if (child is SysNode) {
        yield* child.children.whereType<FolderNode>();
      } else {
        yield child;
      }
    }
  }

  /// プロジェクト名。
  ///
  /// ⚠ ルートの [FolderNode.name] は "Home" 固定なので使えない。
  /// 実際のフォルダ名（パスの末尾）を採る。
  String _projectName(FolderNode root, String? rootPath) {
    if (rootPath == null) return root.name;
    final base = p.basename(p.normalize(rootPath));
    return base.isEmpty ? root.name : base;
  }

  /// [root] のフォルダに `<dir名>.qgs` を書く。
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

    // 自分の `.kmeta.json` を持つ子 dir は独立した `<dir名>.qgs` を持ち、親には埋め込みで載せる
    // （dir 分散のまま「root を開けば全部見える」を1種類のファイルで両立する）
    final embedded = <String, QgsEmbeddedGroup>{};
    if (project == null) {
      for (final child in _ownQgsCandidates(root)) {
        final childPath = child.getAbsoluteFilePath();
        if (childPath == null) continue;
        if (!await KMetaService.instance.hasMetaFile(childPath)) continue;
        final childResult = await writeTo(child);
        if (childResult == null) continue;
        final rel = _relativeTo(rootPath, childResult.path);
        if (rel == null) continue;
        embedded[p.normalize(childPath)] = QgsEmbeddedGroup(
          name: child.name,
          projectPath: rel,
          layerIds: [for (final l in childResult.project.layers) l.id],
          visible: child.visible,
          expanded: child.expanded,
        );
      }
    }

    final built = project ?? await build(root, embedded: embedded);
    final dirName = _projectName(root, rootPath);
    final path = p.join(rootPath, qgsFileNameFor(dirName));

    // 旧名からの引き継ぎ
    final legacyPath = p.join(rootPath, kLegacyQgsFileName);
    if (!await fs.exists(path) && await fs.exists(legacyPath)) {
      await fs.rename(legacyPath, path);
      AppLogger.debug('[QgsProjectBuilder] $kLegacyQgsFileName を ${p.basename(path)} に改名');
    }

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

    final report = doc.apply(built);
    doc.setStamp(
      KokageStamp(
        schemaVersion: kQgsSchemaVersion,
        app: await _appLabel(),
        savedAt: DateTime.now(),
        dirName: dirName,
      ),
    );
    final xml = doc.toXmlString();
    // 保存時刻の印しか変わらないなら書かない。書くと更新時刻が進み、Drive 同期が毎回
    // 「端末で変更あり」と見てアップロードし続ける（2026-09-24、Fold で 5 分ごとに上げていた）
    if (existing != null && _withoutSaveTime(existing) == _withoutSaveTime(xml)) {
      AppLogger.debug('[QgsProjectBuilder] $path は変わらないので書かない');
    } else {
      await fs.writeAsString(path, xml);
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

  /// 印に書くアプリ名。`kokage-map <version>+<build>`
  Future<String> _appLabel() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return 'kokage-map ${info.version}+${info.buildNumber}';
    } on Object {
      return 'kokage-map';
    }
  }

  // =============================================
  // ノードの変換
  // =============================================

  Future<QgsTreeNode?> _convert(
    LayerTreeNode node,
    String? rootPath,
    List<String> skipped,
    Map<String, QgsEmbeddedGroup> embedded,
  ) async {
    // 「この端末」（sys）はプロジェクトに属さない。.qgs に載せない（除外の報告にも出さない）
    if (node is SysNode) return null;
    if (node is FolderNode) {
      final path = node.getAbsoluteFilePath();
      final emb = path == null ? null : embedded[p.normalize(path)];
      if (emb != null) return emb;
      return _convertFolder(node, rootPath, skipped, embedded);
    }
    if (node is GeoPackageNode) {
      return _convertGeoPackage(node, rootPath, skipped);
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
    Map<String, QgsEmbeddedGroup> embedded,
  ) async {
    final children = <QgsTreeNode>[];
    for (final child in folder.children) {
      final converted = await _convert(child, rootPath, skipped, embedded);
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
      final group = await _convertLayer(layer, relPath, skipped);
      if (group != null) groups.add(group);
    }
    if (groups.isEmpty) return null;

    return QgsGroup(
      name: gpkg.name,
      children: groups,
      visible: gpkg.visible,
    );
  }

  /// Layer は**グループ**になり、その下の View が QGIS のレイヤになる。
  Future<QgsTreeNode?> _convertLayer(
    LayerNode layer,
    String gpkgRelPath,
    List<String> skipped,
  ) async {
    final geometryType = _geometryTypeOf(layer);
    if (geometryType == null) {
      skipped.add('${layer.layerName}（ジオメトリ種別が分からない）');
      return null;
    }

    if (layer.views.isEmpty) await layer.loadViews();
    final crs = await _crsOf(layer);
    final layerStyle = await layer.getKmetaStyle();

    final qgsLayers = <QgsTreeNode>[
      for (final view in layer.views)
        QgsLayer(
          id: _layerId(view, gpkgRelPath),
          name: view.name,
          dataSourcePath: gpkgRelPath,
          tableName: layer.layerName,
          geometryType: geometryType,
          crs: crs,
          subset: view.filter,
          // View に指定が無ければレイヤのスタイルに落ちる
          style: _toQgsStyle(view.style == null ? layerStyle : view.style!.mergeWith(layerStyle)),
          visible: view.visible,
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

  /// `.qgs` から見た相対パス。root外を指していたら null。
  ///
  /// ⚠ 判定は**正規化した絶対パス**で行う。`../shared/kyoyu.gpkg` のように
  /// 相対で外に出るケースが林業では現実にありそうなので、素朴な文字列比較では足りない。
  String? _relativeTo(String? rootPath, String? absPath) {
    if (rootPath == null || absPath == null) return null;
    final root = p.normalize(rootPath);
    final target = p.normalize(absPath);
    final rel = p.relative(target, from: root);
    if (rel.startsWith('..') || p.isAbsolute(rel)) return null;
    // QGIS は `./` 始まりを相対パスとして扱う。区切りは常に `/`
    return './${rel.replaceAll(r'\', '/')}';
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
