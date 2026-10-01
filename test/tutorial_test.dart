// チュートリアル: 練習プロジェクトの中身と、操作の知らせで手順が進むこと
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/tutorial/practice_project.dart';
import 'package:root_maps/tutorial/tutorial.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late PracticeProject proj;
  late GeoPackageFile gpkg;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tutorial_');
    proj = await PracticeProject.recreate(at: p.join(tmp.path, 'practice'));
    gpkg = GeoPackageFile([p.basename(proj.gpkgPath)], absolutePath: proj.gpkgPath);
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('練習プロジェクト: 小班 2・路網 1・調査点 0', () async {
    expect(await gpkg.getGeometryType(PracticeProject.standsLayer), GeometryType.polygon);
    expect(await gpkg.getGeometryType(PracticeProject.roadsLayer), GeometryType.linestring);
    expect(await gpkg.getGeometryType(PracticeProject.pointsLayer), GeometryType.point);
    final db = await gpkg.getDatabase();
    Future<int> count(String table) async =>
        (await db.rawQuery('SELECT COUNT(*) AS n FROM "$table"')).first['n']! as int;
    expect(await count(PracticeProject.standsLayer), 2);
    expect(await count(PracticeProject.roadsLayer), 1);
    expect(await count(PracticeProject.pointsLayer), 0);
  });

  test('作り直すと前の点は消える', () async {
    // 前回の接続を開いたまま作り直す（アプリでは地図を閉じても接続が残る）
    expect(await gpkg.addPoint(PracticeProject.pointsLayer, const LatLng(33.93, 135.97)), isNotNull);
    proj = await PracticeProject.recreate(at: proj.dir);
    gpkg = GeoPackageFile([p.basename(proj.gpkgPath)], absolutePath: proj.gpkgPath);
    final db = await gpkg.getDatabase();
    final n = (await db.rawQuery('SELECT COUNT(*) AS n FROM "${PracticeProject.pointsLayer}"')).first['n'];
    expect(n, 0);
    final stands = (await db.rawQuery('SELECT COUNT(*) AS n FROM "${PracticeProject.standsLayer}"')).first['n'];
    expect(stands, 2);
  });

  test('操作の知らせで手順が進む。合わない知らせでは進まない', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final tut = c.read(tutorialProvider.notifier);
    final node = GeoPackageNode(gpkg);
    final stands = PolygonLayerNode(gpkg, PracticeProject.standsLayer, parent: node);
    final points = PointLayerNode(gpkg, PracticeProject.pointsLayer, parent: node);
    // 別のプロジェクトの同名レイヤには反応しない
    final other = GeoPackageFile(const ['o.gpkg'], absolutePath: p.join(tmp.path, 'o.gpkg'));
    final otherPoints = PointLayerNode(other, PracticeProject.pointsLayer, parent: GeoPackageNode(other));

    tut.start();
    expect(c.read(tutorialProvider), TutorialStep.move);
    tut.report(const LayersPanelToggled(true)); // まだ地図を動かす番
    expect(c.read(tutorialProvider), TutorialStep.move);
    tut.report(const CameraMoved());
    tut.report(const LayersPanelToggled(true));
    expect(c.read(tutorialProvider), TutorialStep.hideStands);
    stands.visible = false;
    tut.report(LayerVisibilityToggled(stands));
    stands.visible = true;
    tut.report(LayerVisibilityToggled(stands));
    expect(c.read(tutorialProvider), TutorialStep.pickPoints);
    tut.report(LayerSelected(otherPoints));
    expect(c.read(tutorialProvider), TutorialStep.pickPoints);
    tut.report(LayerSelected(points));
    tut.report(const LayersPanelToggled(false));
    tut.report(const ToolChosen('Select'));
    expect(c.read(tutorialProvider), TutorialStep.pen);
    tut.report(const ToolChosen('Pen'));
    tut.report(PointPlaced(points));
    expect(c.read(tutorialProvider), TutorialStep.done);
    tut.next();
    expect(c.read(tutorialProvider), isNull);
  });
}
