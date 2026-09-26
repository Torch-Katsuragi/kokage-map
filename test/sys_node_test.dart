// 「System」（sys）: グローバルフォルダをルート直下から sys の下へ移した（2026-09-25）。
// パス解決・保存済みの可視性・ツリー更新・.qgs 書き出しが sys を挟んでも崩れないこと。
// 仕様は docs/features/layer-management.md の「System（sys）」
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/global_folder_node.dart';
import 'package:root_maps/models/nodes/layer_tree_node.dart';
import 'package:root_maps/models/nodes/sys_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';

void main() {
  late Directory tmp;
  late String projectDir;
  late String globalDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sys_node_');
    projectDir = p.join(tmp.path, 'proj');
    globalDir = p.join(tmp.path, 'Global');
    await Directory(p.join(projectDir, 'a')).create(recursive: true);
    await Directory(p.join(globalDir, 'shared')).create(recursive: true);
    ProjectPathResolver.instance.setRootPathGetter(() => projectDir);
    GlobalPathResolver.instance.setRootPathGetter(() => globalDir);
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// home_screen と同じ組み立て
  (FolderNode, SysNode, GlobalFolderNode) build() {
    final root = FolderNode('Home', children: []);
    final global = GlobalFolderNode('Global', globalPath: globalDir, children: []);
    final sys = SysNode.attachGlobalFolder(root, global);
    return (root, sys, global);
  }

  test('sys はルート直下の先頭に 1 つだけ、global はその下', () {
    final (root, sys, global) = build();
    expect(root.children.first, same(sys));
    expect(sys.children, [same(global)]);
    expect(global.parent, same(sys));
    expect(sys.getAbsoluteFilePath(), isNull);

    // もう一度差し込んでも増えない（グローバルフォルダの再初期化）
    final again = GlobalFolderNode('Global', globalPath: globalDir, children: []);
    SysNode.attachGlobalFolder(root, again);
    expect(root.children.whereType<SysNode>(), hasLength(1));
    expect(sys.children, [same(again)]);
    expect(global.parent, isNull);
  });

  test('旧配置（ルート直下の Global）は外して sys の下へ', () {
    final root = FolderNode('Home', children: []);
    final old = GlobalFolderNode('Global', globalPath: globalDir, parent: root, children: []);
    root.children.insert(0, old);

    final global = GlobalFolderNode('Global', globalPath: globalDir, children: []);
    SysNode.attachGlobalFolder(root, global);
    expect(root.children.whereType<GlobalFolderNode>(), isEmpty);
    expect(root.children.whereType<SysNode>().single.globalFolder, same(global));
  });

  group('パス解決', () {
    test('global 配下は sys の有無に関係なくグローバルの実体から解決する', () {
      final (root, _, global) = build();
      final sub = FolderNode('shared', parent: global, children: []);
      global.children.add(sub);
      final deeper = FolderNode('x', parent: sub, children: []);
      sub.children.add(deeper);
      final gsub = GlobalSubFolderNode('shared', basePath: globalDir, parent: global, children: []);
      final gpkg = GeoPackageNode(
        GeoPackageFile(['g.gpkg'], absolutePath: p.join(globalDir, 'g.gpkg')),
        parent: global,
      );

      expect(global.getAbsoluteFilePath(), globalDir);
      expect(sub.getAbsoluteFilePath(), p.join(globalDir, 'shared'));
      expect(deeper.getAbsoluteFilePath(), p.join(globalDir, 'shared', 'x'));
      expect(gsub.getAbsoluteFilePath(), p.join(globalDir, 'shared'));
      expect(gpkg.getAbsoluteFilePath(), p.join(globalDir, 'g.gpkg'));
      expect(deeper.getAbsolutePathSegments(), ['shared', 'x']);
      expect(root.getAbsoluteFilePath(), projectDir);
    });

    test('global 配下の Drive 連携dirも実体から解決する', () {
      final (_, _, global) = build();
      final drive = DriveFolderNode('shared', driveId: 'd', driveUrl: 'u', parent: global, children: []);
      global.children.add(drive);
      final inner = FolderNode('in', parent: drive, children: []);
      drive.children.add(inner);
      expect(drive.getAbsoluteFilePath(), p.join(globalDir, 'shared'));
      expect(inner.getAbsoluteFilePath(), p.join(globalDir, 'shared', 'in'));
    });

    test('プロジェクト側は従来どおり（ルート名を落とす）', () {
      final (root, _, _) = build();
      final a = FolderNode('a', parent: root, children: []);
      root.children.add(a);
      final b = FolderNode('b', parent: a, children: []);
      a.children.add(b);
      expect(b.getAbsolutePathSegments(), ['a', 'b']);
      expect(b.getAbsoluteFilePath(), p.join(projectDir, 'a', 'b'));
    });

    test('GlobalPathResolver は渡されたセグメントを削らない', () {
      final r = GlobalPathResolver(customRootPath: globalDir);
      expect(r.resolvePath(const []), globalDir);
      expect(r.resolvePath(const ['a', 'b.gpkg']), p.join(globalDir, 'a', 'b.gpkg'));
    });
  });

  group('ツリー更新', () {
    test('ルートの更新で sys は消えず、同名に見える実フォルダとも取り違えない', () async {
      await Directory(p.join(projectDir, 'sys')).create();
      final (root, sys, _) = build();
      await root.updateChildren();
      expect(root.children.whereType<SysNode>().single, same(sys));
      final names = root.children.where((c) => c is! SysNode).map((c) => c.name).toSet();
      expect(names, {'a', 'sys'});
    });

    test('Drive 連携ルートでも sys は消えない', () async {
      final root = DriveFolderNode('Home', driveId: 'd', driveUrl: 'u', children: []);
      final global = GlobalFolderNode('Global', globalPath: globalDir, children: []);
      final sys = SysNode.attachGlobalFolder(root, global);
      await root.updateChildren();
      expect(root.children.whereType<SysNode>().single, same(sys));
    });
  });

  group('保存済みの可視性', () {
    test('ルート直下にあった頃の Global の可視性（folders[Global]）を引き継ぐ', () async {
      // 旧配置で保存された値
      await KMetaService.instance.setFolderVisibility(projectDir, 'Global', false);

      final (root, sys, global) = build();
      await root.updateChildren();
      await sys.updateChildren();
      expect(global.visible, isFalse);
    });

    test('global の可視性はプロジェクトルートの folders[Global] に書く', () async {
      final (root, sys, global) = build();
      await root.updateChildren();
      await sys.updateChildren();

      global.visible = false;
      await global.persistVisibility();
      KMetaService.instance.invalidateCache(projectDir);
      final meta = await KMetaService.instance.getMeta(projectDir);
      expect(meta.visibility.folders['Global'], isFalse);

      // 読み直しても戻る
      global.visible = true;
      await sys.updateChildren();
      expect(global.visible, isFalse);
    });

    test('sys 自身の可視性はプロジェクトルートの folders[<sys>] に書き、ルートの更新で戻る', () async {
      final (root, sys, global) = build();
      sys.visible = false;
      await sys.persistVisibility();

      sys.visible = true;
      await root.updateChildren();
      expect(sys.visible, isFalse);
      // sys を隠せば配下も隠れる
      expect(global.isVisibleRecursive(), isFalse);
    });

    test('sys はルートの Drive 連携メタを自分のものとして見せない', () async {
      await KMetaService.instance.setDriveSync(projectDir, driveId: 'd');
      final (_, sys, _) = build();
      expect(await sys.getRawMeta(), isNull);
    });
  });

  test('.qgs に sys（global の中身）を載せず、除外の報告にも出さない', () async {
    final (root, _, global) = build();
    final gpkg = GeoPackageNode(
      GeoPackageFile(['g.gpkg'], absolutePath: p.join(globalDir, 'g.gpkg')),
      parent: global,
    );
    global.children.add(gpkg);

    final project = await const QgsProjectBuilder().build(root);
    expect(project.root, isEmpty);
    expect(project.skipped, isEmpty);
  });

  test('sys は FolderNode として辿れる（可視性の連鎖・再帰更新が通る）', () {
    final (root, sys, _) = build();
    final LayerTreeNode node = sys;
    expect(node, isA<FolderNode>());
    expect(root.children.whereType<FolderNode>(), contains(sys));
  });
}
