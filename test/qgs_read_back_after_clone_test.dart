// QGIS で作ったフォルダを Drive からクローンしたら、その場で `.qgs` を読み戻す（2026-10-12）。
//
// 読み戻しは地図を開いたときにしか走らなかったので、クローンした直後は View・凡例・背景地図が入らず、
// 地図を開き直すまで素のレイヤのままだった（その間 QgsProjectBuilder は `.qgs` を書かない）。
// 同期で QGIS 側の `.qgs` が届いたときも同じ取り込みを通す。開いた直後の自動同期などと重なっても
// 同じ `.qgs` を二度取り込まない。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/basemap_provider.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/services/google_drive/drive_sync_operations.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/layer_drawer_service.dart';
import 'package:root_maps/services/qgis/qgs_auto_refresh.dart';
import 'package:root_maps/services/qgis/qgs_document.dart';
import 'package:root_maps/services/qgis/qgs_read_back.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _folder = 'こかげ確認_2026-10-12';

/// QGIS 4.2.2 で保存した体の `.qgs`（印なし）: 同じ表の 2 エントリ（既定と「区分」）と XYZ 1 枚
String _qgisSaved({String saveDateTime = '2026-10-12T10:00:00'}) => '''
<!DOCTYPE qgis PUBLIC 'http://mrcc.com/qgis.dtd' 'SYSTEM'>
<qgis projectname="" version="4.2.2-Kokura" saveDateTime="$saveDateTime" saveUser="qgis">
  <layer-tree-group>
    <layer-tree-layer id="shoban_a" name="shoban" checked="Qt::Checked" source="./計画図.gpkg|layername=shoban" providerKey="ogr"/>
    <layer-tree-layer id="shoban_b" name="小班 区分" checked="Qt::Unchecked" source="./計画図.gpkg|layername=shoban" providerKey="ogr"/>
    <layer-tree-layer id="xyz_a" name="どこかのタイル" checked="Qt::Checked" providerKey="wms"/>
  </layer-tree-group>
  <projectlayers>
    <maplayer type="vector" geometry="Polygon">
      <id>shoban_a</id>
      <datasource>./計画図.gpkg|layername=shoban</datasource>
      <layername>shoban</layername>
      <provider encoding="UTF-8">ogr</provider>
    </maplayer>
    <maplayer type="vector" geometry="Polygon">
      <id>shoban_b</id>
      <datasource>./計画図.gpkg|layername=shoban</datasource>
      <layername>小班 区分</layername>
      <provider encoding="UTF-8">ogr</provider>
    </maplayer>
    <maplayer type="raster">
      <id>xyz_a</id>
      <datasource>type=xyz&amp;url=https%3A%2F%2Ftiles.example.com%2Fv1%2F%7Bz%7D%2F%7Bx%7D%2F%7By%7D.png&amp;zmax=18&amp;zmin=0</datasource>
      <layername>どこかのタイル</layername>
      <provider>wms</provider>
    </maplayer>
  </projectlayers>
</qgis>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String proj;
  late String cloneDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    QgsAutoRefresh.instance.enabled = false;
    // 背景地図のサービスはタイルキャッシュの置き場所を path_provider に聞く（無いと初期化に失敗して足さない）
    final docs = Directory.systemTemp.createTempSync('qgs_clone_docs_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => docs.path,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BaseMapProvider.customProviders = const [];
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('qgs_clone_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    // クローンで落ちてきた体: 計画図.gpkg と、QGIS が保存した `<フォルダ名>.qgs`
    cloneDir = (await Directory(p.join(proj, _folder)).create()).path;
    final g = GeoPackageFile(['計画図.gpkg'], absolutePath: p.join(cloneDir, '計画図.gpkg'));
    await g.addLayer('shoban', GeometryType.polygon);
    await g.dispose();
    File(p.join(cloneDir, '$_folder.qgs')).writeAsStringSync(_qgisSaved());
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 地図で開いている根（クローン前の中身だけ読んである）
  Future<FolderNode> openRoot() async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    root.children.removeWhere((c) => c.name == _folder);
    return root;
  }

  LayerNode shobanOf(LayerTreeNode folder) => folder.children
      .whereType<GeoPackageNode>()
      .single
      .children
      .whereType<LayerNode>()
      .single;

  /// 地図が描くときに読む View（フォルダ設定から作り直す）
  Future<List<String>> viewNamesOf(LayerNode layer) async => [for (final v in await layer.loadViews()) v.name];

  bool claimed() =>
      QgsDocument.parse(File(p.join(cloneDir, '$_folder.qgs')).readAsStringSync()).lastWrittenByKokage;

  test('クローンし終えたら、地図を開き直さなくても View と背景地図が入る（読み戻しは 1 回）', () async {
    final root = await openRoot();
    expect(claimed(), isFalse);

    final cloned = await LayerDrawerService.attachClonedFolder(
      parent: root,
      name: _folder,
      folderId: 'drive-id',
      url: 'https://drive.google.com/drive/folders/drive-id',
      isReadOnly: false,
    );

    expect(cloned.node, isA<DriveFolderNode>());
    expect(root.children, contains(cloned.node));
    final readBack = cloned.readBack;
    expect(readBack, isNotNull, reason: 'クローンの直後に読み戻す');
    expect(readBack!.fileName, '$_folder.qgs');
    expect(readBack.importedViewCount, 2);
    expect(claimed(), isTrue, reason: '取り込んだので印を付け、自動更新が書けるようになる');

    // ツリーはその場で View を持つ（開き直さない）
    final views = await viewNamesOf(shobanOf(cloned.node));
    expect(views, hasLength(2));
    expect(views, contains('小班 区分'));

    // 背景地図: XYZ が端末の背景地図に入った（読めなかった環境でも二度足さない印は付く）
    KMetaService.instance.clearCache();
    final meta = await KMetaService.instance.getMeta(cloneDir);
    expect(meta.views.keys, contains('計画図.gpkg/shoban'));
    final custom = BaseMapProvider.custom(
      name: 'どこかのタイル',
      urlTemplate: 'https://tiles.example.com/v1/{z}/{x}/{y}.png',
    );
    expect(readBack.baseMapsAdded, ['どこかのタイル']);
    expect(BaseMapProvider.getProviderById(custom.id), isNotNull);

    // あとで地図を開き直しても、同じ `.qgs` を二度取り込まない
    expect(await const QgsReadBack().run(cloned.node), isNull);
  });

  test('クローンの読み戻しと、地図を開いたとき・同期のあとの読み戻しが重なっても取り込みは 1 回', () async {
    final root = await openRoot();
    final node = DriveFolderNode(
      _folder,
      driveId: 'drive-id',
      driveUrl: 'https://drive.google.com/drive/folders/drive-id',
      visible: true,
      parent: root,
    );
    root.addChild(node);
    await node.updateChildren();
    await node.children.whereType<GeoPackageNode>().single.updateChildren();

    final results = await Future.wait([
      const QgsReadBack().run(node),
      const QgsReadBack().run(node),
      DriveSyncOperations.refreshAfterSync(node),
    ]);
    expect(results.whereType<QgsReadBackResult>(), hasLength(1));
    expect(claimed(), isTrue);
  });

  test('地図を開いている間に同期で QGIS の `.qgs` が届いたら、読み戻した結果を返す', () async {
    final root = await openRoot();
    final cloned = await LayerDrawerService.attachClonedFolder(
      parent: root,
      name: _folder,
      folderId: 'drive-id',
      url: 'https://drive.google.com/drive/folders/drive-id',
      isReadOnly: false,
    );
    expect(cloned.readBack, isNotNull);

    // 何も届いていなければ何もしない
    expect(await DriveSyncOperations.refreshAfterSync(cloned.node), isNull);

    // QGIS でまた直して保存したものが Drive 越しに届いた（印なしの新しい版）
    File(p.join(cloneDir, '$_folder.qgs')).writeAsStringSync(
      _qgisSaved(saveDateTime: KokageStamp.formatQgisDateTime(DateTime.now().add(const Duration(minutes: 5)))),
    );
    final r = await DriveSyncOperations.refreshAfterSync(cloned.node);
    expect(r, isNotNull);
    expect(r!.importedViewCount, 2);
    expect(claimed(), isTrue);
    expect(await viewNamesOf(shobanOf(cloned.node)), contains('小班 区分'));
  });
}
