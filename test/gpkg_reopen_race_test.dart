// 同じ gpkg を別の GeoPackageFile で開き直す最中に、前のものの dispose（await されない）が
// 共有の Database（sqflite の singleInstance）を閉じても、開き直した側は閉じた Database を掴まない（ホスト VM）。
//
// 以前は dispose が他の接続の有無を見ずに閉じていて、開き直した側の初期化が `database_closed` で落ちた
// （gps_history_recorder_test の「落ちて raw に残った点」がこの間合いに乗っていた）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geometry_type.dart';
import 'package:root_maps/models/geopackage/geopackage_connection.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late String path;

  GeoPackageFile open() => GeoPackageFile(const ['r.gpkg'], absolutePath: path);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gpkg_reopen_');
    path = '${tmp.path}/r.gpkg';
    final g = open();
    await g.addLayer('pts', GeometryType.point);
    await g.addPointWithAttributes('pts', const LatLng(33.93, 135.96), {});
    await g.addPointWithAttributes('pts', const LatLng(33.94, 135.97), {});
    await g.dispose();
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // 前の dispose のどの段階で開き直しが始まっても落ちない（間合いをずらして何度も）
  for (final turns in [0, 1, 2, 5, 10, 20, 50]) {
    test('前の dispose を待たずに開き直す（$turns ターン後）', () async {
      final a = open();
      expect(await a.getFeaturesWithGeometry('pts'), hasLength(2));
      final closing = a.dispose(); // await しない（アプリでは画面の破棄などから呼ばれる）
      for (var i = 0; i < turns; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final b = open();
      expect(await b.getFeaturesWithGeometry('pts'), hasLength(2));
      await closing;
      // 前のものが閉じ終わったあとも、開き直した側の Database は開いたまま
      final db = await b.getDatabase();
      expect(db.isOpen, isTrue);
      expect(await b.addPointWithAttributes('pts', const LatLng(33.95, 135.98), {}), 3);
      await b.dispose();
      expect(GeoPackageConnection.openCountFor(path), 0);
      expect(GeoPackageConnection.isInUse(path), isFalse);
    });
  }

  test('最後の 1 本が閉じたら Database を閉じる（残っている間は閉じない）', () async {
    final a = open();
    final b = open();
    final dbA = await a.getDatabase();
    final dbB = await b.getDatabase();
    expect(identical(dbA, dbB), isTrue, reason: 'singleInstance で同じ Database を共有している');
    await a.dispose();
    expect(dbB.isOpen, isTrue);
    expect(await b.getFeaturesWithGeometry('pts'), hasLength(2));
    await b.dispose();
    expect(dbB.isOpen, isFalse);
  });

  test('closeAllFor は残っていても閉じ、閉じられた側は次に使うとき開き直す', () async {
    final a = open();
    final b = open();
    final db = await a.getDatabase();
    await b.getDatabase();
    expect(await GeoPackageConnection.closeAllFor(path), 2);
    expect(db.isOpen, isFalse);
    expect(await b.getFeaturesWithGeometry('pts'), hasLength(2));
    await a.dispose();
    await b.dispose();
    expect(GeoPackageConnection.isInUse(path), isFalse);
  });
}
