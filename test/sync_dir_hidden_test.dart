// 3-way マージの base 置き場（.sync）をレイヤツリーに出さない。
// Drive 連携フォルダの読み込みだけ除外が漏れていて、base の gpkg が 2 つ目のレイヤとして
// 地図と .qgs に載っていた（2026-09-24、Fold と本物の Drive で見つけた）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/nodes/drive_folder_node.dart';
import 'package:root_maps/models/nodes/folder_node.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_hidden_');
    ProjectPathResolver.instance.setRootPathGetter(() => tmp.path);
    for (final d in ['proj/.sync/base', 'proj/sub/.sync/base']) {
      await Directory(p.join(tmp.path, d)).create(recursive: true);
    }
    for (final f in ['proj/.sync/base/a.gpkg', 'proj/sub/.sync/base/b.gpkg']) {
      await File(p.join(tmp.path, f)).writeAsBytes(const []);
    }
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('Drive 連携フォルダとそのサブフォルダで .sync を見せない', () async {
    final root = FolderNode('root', children: []);
    final drive = DriveFolderNode('proj', driveId: 'd', driveUrl: 'u', parent: root, children: []);
    root.children.add(drive);
    await drive.updateChildren();
    expect(drive.children.map((c) => c.name), ['sub']);

    final sub = drive.children.single as FolderNode;
    await sub.updateChildren();
    expect(sub.children, isEmpty);
  });
}
