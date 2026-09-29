// サブフォルダの GeoPackage を改名できる（2026-09-29 まで「ファイルが存在しません」で失敗していた）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/core/path_resolver.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/folder_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/services/kmeta_service.dart';
import 'package:root_maps/services/layer_drawer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late String proj;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    KMetaService.instance.clearCache();
    tmp = await Directory.systemTemp.createTemp('gpkg_rename_');
    proj = (await Directory(p.join(tmp.path, 'proj')).create()).path;
    await Directory(p.join(proj, 'sub')).create();
    ProjectPathResolver.instance.setRootPathGetter(() => proj);
    final g = GeoPackageFile(const ['b.gpkg'], absolutePath: p.join(proj, 'sub', 'b.gpkg'));
    await g.addLayer('trees', GeometryType.point);
    await g.dispose();
  });

  tearDown(() async {
    KMetaService.instance.clearCache();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('サブフォルダの gpkg を改名すると、そのフォルダの中で名前が変わる', () async {
    final root = FolderNode('Home', children: []);
    await root.updateChildren();
    final sub = root.children.whereType<FolderNode>().single;
    await sub.updateChildren();
    final gpkg = sub.children.whereType<GeoPackageNode>().single;
    File(p.join(proj, 'sub', 'b.gpkg-journal')).writeAsBytesSync(const []);

    final newName = await LayerDrawerService.renameGeoPackage(gpkg, 'c', projectRootDir: proj);
    expect(newName, 'c.gpkg');
    expect(File(p.join(proj, 'sub', 'c.gpkg')).existsSync(), isTrue);
    expect(File(p.join(proj, 'sub', 'b.gpkg')).existsSync(), isFalse);
    expect(File(p.join(proj, 'sub', 'b.gpkg-journal')).existsSync(), isFalse, reason: '付属ファイルも連れていく');
    expect(File(p.join(proj, 'sub', 'c.gpkg-journal')).existsSync(), isTrue);
  });
}
