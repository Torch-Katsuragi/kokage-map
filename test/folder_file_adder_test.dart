// フォルダの「ファイルを追加」とドラッグ＆ドロップの写し方（2026-10-09）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:root_maps/services/folder_file_adder.dart';

void main() {
  group('stemOf', () {
    test('shp.xml は shp 一式と同じ名前', () {
      expect(FolderFileAdder.stemOf('林班.shp.xml'), '林班');
      expect(FolderFileAdder.stemOf('林班.SHP.XML'), '林班');
      expect(FolderFileAdder.stemOf('林班.dbf'), '林班');
      expect(FolderFileAdder.stemOf('a.b.geojson'), 'a.b');
      expect(FolderFileAdder.stemOf('README'), 'README');
    });
  });

  group('planNames', () {
    test('ぶつからなければそのまま', () {
      expect(FolderFileAdder.planNames(['a.csv', 'b.kml'], ['c.gpkg']), {'a.csv': 'a.csv', 'b.kml': 'b.kml'});
    });

    test('shp 一式は 1 つでもぶつかれば全部に同じ番号を振る', () {
      final plan = FolderFileAdder.planNames(
        ['林班.shp', '林班.dbf', '林班.shx', '林班.prj', '林班.shp.xml'],
        ['林班.prj', '林班_1.cpg'],
      );
      expect(plan, {
        '林班.shp': '林班_2.shp',
        '林班.dbf': '林班_2.dbf',
        '林班.shx': '林班_2.shx',
        '林班.prj': '林班_2.prj',
        '林班.shp.xml': '林班_2.shp.xml',
      });
    });

    test('付属ファイルだけなら既存の shp に加える（足りなかった分をあとから足す）', () {
      expect(
        FolderFileAdder.planNames(['林班.dbf', '林班.shx'], ['林班.shp']),
        {'林班.dbf': '林班.dbf', '林班.shx': '林班.shx'},
      );
    });

    test('大文字小文字だけ違う名前もぶつかるとみなす', () {
      expect(FolderFileAdder.planNames(['IMG.JPG'], ['img.jpg']), {'IMG.JPG': 'IMG_1.JPG'});
    });

    test('同じ名前が 2 度来たら後のものは捨てる', () {
      expect(FolderFileAdder.planNames(['a.csv', 'a.csv'], const []), {'a.csv': 'a.csv'});
    });
  });

  test('付属ファイルの足りない shp', () {
    expect(FolderFileAdder.shpMissingSidecars(['a.shp', 'a.dbf', 'a.shx', 'b.SHP', 'b.dbf', 'c.shp', 'x.csv']), ['b.SHP', 'c.shp']);
    expect(FolderFileAdder.shpMissingSidecars(['A.shp', 'a.DBF', 'a.shx']), isEmpty);
  });

  group('addTo', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('folder_file_adder_'));
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    IncomingFile file(String name, int n) => (name: name, read: () async => Uint8List.fromList([n]));

    test('写し、ぶつかる名前は付け替え、読めないものと危ない名前は失敗に数える', () async {
      File(p.join(tmp.path, '林班.shp')).writeAsBytesSync([0]);
      final r = await FolderFileAdder.addTo(tmp.path, [
        file('林班.shp', 1),
        file('林班.dbf', 2),
        file('../外.csv', 3),
        (name: 'broken.kml', read: () async => throw const FileSystemException('読めない')),
      ]);
      expect(r.added, ['林班_1.shp', '林班_1.dbf']);
      expect(r.failed.map((f) => f.name), ['../外.csv', 'broken.kml']);
      expect(File(p.join(tmp.path, '林班.shp')).readAsBytesSync(), [0]);
      expect(File(p.join(tmp.path, '林班_1.shp')).readAsBytesSync(), [1]);
      expect(File(p.join(tmp.path, '林班_1.dbf')).readAsBytesSync(), [2]);
      expect(File(p.join(tmp.parent.path, '外.csv')).existsSync(), isFalse);
    });
  });
}
