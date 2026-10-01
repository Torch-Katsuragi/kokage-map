// チュートリアル: 練習プロジェクトの中身と、操作の知らせで手順が進むこと
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/i18n/strings.g.dart';
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

  test('練習プロジェクト: エリア 2・ルート 1・測点 0', () async {
    expect(await gpkg.getGeometryType(PracticeProject.areaLayer), GeometryType.polygon);
    expect(await gpkg.getGeometryType(PracticeProject.routeLayer), GeometryType.linestring);
    expect(await gpkg.getGeometryType(PracticeProject.pointsLayer), GeometryType.point);
    final db = await gpkg.getDatabase();
    Future<int> count(String table) async =>
        (await db.rawQuery('SELECT COUNT(*) AS n FROM "$table"')).first['n']! as int;
    expect(await count(PracticeProject.areaLayer), 2);
    expect(await count(PracticeProject.routeLayer), 1);
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
    final areas = (await db.rawQuery('SELECT COUNT(*) AS n FROM "${PracticeProject.areaLayer}"')).first['n'];
    expect(areas, 2);
  });

  test('操作の知らせで手順が進む。合わない知らせでは進まない。章の終わりで一覧に戻る', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final tut = c.read(tutorialProvider.notifier);
    TutorialState s() => c.read(tutorialProvider)!;
    final node = GeoPackageNode(gpkg);
    final points = PointLayerNode(gpkg, PracticeProject.pointsLayer, parent: node);
    final routes = LineLayerNode(gpkg, PracticeProject.routeLayer, parent: node);
    // 別のプロジェクトの同名レイヤには反応しない
    final other = GeoPackageFile(const ['o.gpkg'], absolutePath: p.join(tmp.path, 'o.gpkg'));
    final otherPoints = PointLayerNode(other, PracticeProject.pointsLayer, parent: GeoPackageNode(other));

    tut.start();
    expect(s().menu, isTrue);
    tut.openChapter(TutorialChapter.record);
    expect(s().step.id, 'open');
    tut.report(const CameraMoved()); // 関係ない操作
    expect(s().step.id, 'open');
    tut.report(const LayersPanelToggled(true));
    tut.report(LayerSelected(otherPoints));
    expect(s().step.id, 'pick');
    tut.report(LayerSelected(points));
    tut.report(const LayersPanelToggled(false));
    tut.report(const ToolChosen('Pen'));
    tut.report(PointPlaced(points));
    tut.report(FeatureSelected(points));
    tut.report(const AttributeTableToggled(true));
    tut.report(AttributeSaved(points));
    tut.report(const AttributeTableToggled(false));
    tut.report(LayerSelected(routes));
    expect(s().step.id, 'draw');
    tut.report(ShapeSaved(routes));
    expect(s().step.isInfo, isTrue); // 「エリアも同じ」は説明だけ
    tut.next();
    expect(s().menu, isTrue);
    expect(s().justFinished, isTrue);
    expect(s().finished, contains(TutorialChapter.record));
  });

  test('どの手順にも文がある（ja / en）', () async {
    for (final locale in AppLocale.values) {
      await LocaleSettings.setLocale(locale);
      for (final ch in TutorialChapter.values) {
        expect(t.tutorial.chapters[ch.name], isNotNull, reason: '${locale.name} ${ch.name}');
        for (final step in stepsOf(ch)) {
          final key = '${ch.name}_${step.id}';
          expect(t.tutorial.text['${key}_t'], isNotNull, reason: '${locale.name} $key');
          expect(t.tutorial.text['${key}_b'], isNotNull, reason: '${locale.name} $key');
        }
      }
    }
  });
}
