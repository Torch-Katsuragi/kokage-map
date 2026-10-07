// レイヤツリーの子の作り直し（updateChildren）と改名が、ノードの種類ごとに今までどおり動くか。
//
// フォルダ・グローバルフォルダ・Drive 連携フォルダ・GeoPackage の子の作り直しを 1 か所（syncChildren と
// FolderNode のローダー）にまとめたので、種類ごとの違い（見せるもの・作るノードの型・外さない子）を押さえる。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/global_folder_node.dart';
import 'package:root_maps/models/nodes/image_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/models/nodes/sys_node.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late String projectDir;
  late String globalDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('layer_tree_sync_');
    projectDir = p.join(tmp.path, 'proj');
    globalDir = p.join(tmp.path, 'Global');
    await Directory(projectDir).create(recursive: true);
    ProjectPathResolver.instance.setRootPathGetter(() => projectDir);
    GlobalPathResolver.instance.setRootPathGetter(() => globalDir);
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  void touch(String path) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([0, 1, 2, 3]);
  }

  List<String> names(List<Object> nodes) => [for (final n in nodes) (n as dynamic).name as String];

  test('フォルダ: フォルダ・gpkg・画像を作り、点フォルダと .sync は見せず、消えたものは外す', () async {
    await Directory(p.join(projectDir, 'b')).create();
    await Directory(p.join(projectDir, 'a')).create();
    await Directory(p.join(projectDir, '.kokage')).create();
    await Directory(p.join(projectDir, '.sync')).create();
    touch(p.join(projectDir, 'm.gpkg'));
    touch(p.join(projectDir, 'photo.jpg'));
    touch(p.join(projectDir, 'anim.gif')); // 通常のフォルダでは gif を読まない
    touch(p.join(projectDir, 'memo.txt'));

    final root = FolderNode('Home', children: []);
    final sys = SysNode.ensureIn(root);
    await root.updateChildren();

    expect(names(root.children), ['<sys>', 'a', 'b', 'm.gpkg', 'photo.jpg']);
    expect(root.children[1], isA<FolderNode>());
    expect(root.children[3], isA<GeoPackageNode>());
    expect(root.children[4], isA<ImageNode>());
    final a = root.children[1];

    await Directory(p.join(projectDir, 'b')).delete();
    File(p.join(projectDir, 'photo.jpg')).deleteSync();
    await root.updateChildren();

    expect(names(root.children), ['<sys>', 'a', 'm.gpkg']);
    expect(root.children[0], same(sys), reason: 'sys はファイルシステムに無くても外さない');
    expect(root.children[1], same(a), reason: '残ったノードは使い回す');
  });

  test('グローバル: フォルダが無ければ作り、点フォルダと gif も見せ、Global* のノードで作る', () async {
    final global = GlobalFolderNode('Global', globalPath: globalDir, children: []);
    await global.updateChildren();
    expect(Directory(globalDir).existsSync(), isTrue);
    expect(global.children, isEmpty);

    await Directory(p.join(globalDir, 'shared', 'deep')).create(recursive: true);
    await Directory(p.join(globalDir, '.dot')).create();
    await Directory(p.join(globalDir, '.sync')).create();
    touch(p.join(globalDir, 'g.gpkg'));
    touch(p.join(globalDir, 'anim.gif'));
    await global.updateChildren();

    expect(names(global.children), ['.dot', 'shared', 'g.gpkg', 'anim.gif']);
    expect(global.children[1], isA<GlobalSubFolderNode>());
    expect(global.children[2], isA<GlobalGeoPackageNode>());
    expect(global.children[3], isA<GlobalImageNode>());

    final shared = global.children[1] as GlobalSubFolderNode;
    expect(shared.getAbsoluteFilePath(), p.join(globalDir, 'shared'));
    await shared.updateChildren();
    final deep = shared.children.single as GlobalSubFolderNode;
    expect(deep.getAbsoluteFilePath(), p.join(globalDir, 'shared', 'deep'));

    // 無くなったサブフォルダは外す（グローバルには残す子が無い）
    await Directory(p.join(globalDir, 'shared')).delete(recursive: true);
    await global.updateChildren();
    expect(names(global.children), ['.dot', 'g.gpkg', 'anim.gif']);

    // 実体が無くなったサブフォルダの更新は何もしない
    await deep.updateChildren();
    expect(deep.children, isEmpty);
  });

  test('Drive 連携: サブフォルダは DriveSubFolderNode で、根の同期情報を共有する', () async {
    await Directory(p.join(projectDir, 'd', 's1', 's2')).create(recursive: true);
    await Directory(p.join(projectDir, 'd', '.sync')).create();
    touch(p.join(projectDir, 'd', 'x.gpkg'));

    final root = FolderNode('Home', children: []);
    final drive = DriveFolderNode('d', driveId: 'ID', driveUrl: '', parent: root, children: []);
    root.children.add(drive);
    await drive.updateChildren();

    expect(names(drive.children), ['s1', 'x.gpkg']);
    final s1 = drive.children.first as DriveSubFolderNode;
    expect(s1.rootDriveNode, same(drive));
    await s1.updateChildren();
    final s2 = s1.children.single as DriveSubFolderNode;
    expect(s2.rootDriveNode, same(drive));
    expect(s2.getAbsoluteFilePath(), p.join(projectDir, 'd', 's1', 's2'));
  });

  test('GeoPackage: レイヤの増減に合わせ、残ったレイヤのノードは使い回す', () async {
    final path = p.join(projectDir, 'm.gpkg');
    final file = GeoPackageFile(const ['m.gpkg'], absolutePath: path);
    await file.addLayer('pts', GeometryType.point);
    await file.addLayer('lines', GeometryType.linestring);

    final root = FolderNode('Home', children: []);
    final node = GeoPackageNode(file, parent: root);
    root.children.add(node);
    await node.updateChildren();
    expect(names(node.children), ['pts', 'lines']);
    expect(node.children[0], isA<PointLayerNode>());
    expect(node.children[1], isA<LineLayerNode>());
    final pts = node.children[0];

    await file.removeLayer('lines');
    await file.addLayer('areas', GeometryType.polygon);
    await node.updateChildren();
    expect(names(node.children), ['pts', 'areas']);
    expect(node.children[0], same(pts));
    expect(node.children[1], isA<PolygonLayerNode>());
    await file.dispose();
  });

  test('改名: 拡張子を足し、同じ名前があれば投げる', () async {
    touch(p.join(projectDir, 'a.gpkg'));
    touch(p.join(projectDir, 'b.gpkg'));
    touch(p.join(projectDir, 'p.jpg'));
    final root = FolderNode('Home', children: []);
    await root.updateChildren();

    final gpkg = root.children.whereType<GeoPackageNode>().first;
    expect(await gpkg.rename('c', projectRootDir: projectDir), 'c.gpkg');
    expect(File(p.join(projectDir, 'c.gpkg')).existsSync(), isTrue);
    expect(File(p.join(projectDir, 'a.gpkg')).existsSync(), isFalse);
    await root.updateChildren();
    final c = root.children.whereType<GeoPackageNode>().firstWhere((n) => n.name == 'c.gpkg');
    await expectLater(c.rename('b.gpkg', projectRootDir: projectDir), throwsException);

    final image = root.children.whereType<ImageNode>().single;
    await image.rename('q');
    expect(File(p.join(projectDir, 'q.jpg')).existsSync(), isTrue);
    expect(names(root.children.whereType<ImageNode>().toList()), ['q.jpg']);
  });
}
