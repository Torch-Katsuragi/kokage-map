// 中身が変わらないなら .qgs（レイヤの部分もフォルダ設定の部分も）を書かない。
// 書くと更新時刻が進み、Drive 同期（更新時刻と最後の同期時刻を比べる）が 5 分ごとに
// アップロードし続けていた（2026-09-24、Fold と本物の Drive で見つけた）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/kmeta.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/services/qgis/qgs_meta_store.dart';
import 'package:root_maps/services/qgis/qgs_project_builder.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('noop_write_');
    ProjectPathResolver.instance.setRootPathGetter(() => tmp.path);
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<DateTime> mtime(String path) async => (await File(path).stat()).modified;

  test('.qgs は保存時刻しか変わらないなら書き直さない', () async {
    final root = FolderNode('root', children: []);
    final first = await const QgsProjectBuilder().writeTo(root);
    expect(first, isNotNull);
    final before = await File(first!.path).readAsString();
    final t0 = await mtime(first.path);
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // 保存時刻は秒単位

    await const QgsProjectBuilder().writeTo(root);
    expect(await File(first.path).readAsString(), before);
    expect(await mtime(first.path), t0);
  });

  test('フォルダ設定は中身が同じなら書き直さない', () async {
    final dir = tmp.path;
    const meta = KMeta();
    expect(await QgsMetaStore.write(dir, meta), isTrue);
    final path = QgsProjectFile.pathFor(dir);
    final t0 = await mtime(path);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(await QgsMetaStore.write(dir, meta), isTrue);
    expect(await mtime(path), t0);
    expect(File(p.join(dir, kMetaFileName)).existsSync(), isFalse);
  });
}
