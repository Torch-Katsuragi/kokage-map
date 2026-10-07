import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/services/import_export/exporters/shapefile_writer.dart';
import 'package:root_maps/services/import_export/parsers/dbf_reader.dart';
import 'package:root_maps/services/import_export/parsers/shapefile_binary_parser.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('shp_writer_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<List<(int, dynamic)>> readBack(int type, List<ShpShape> shapes) async {
    final r = encodeShpShx(type, shapes);
    final path = '${dir.path}/t.shp';
    File(path).writeAsBytesSync(r.shp);
    // .shx は 1 レコード 8 バイト
    expect(r.shx.length, 100 + 8 * shapes.length);
    final out = <(int, dynamic)>[];
    await ShapefileBinaryParser.parseRecords(
      path,
      onRecord: (i, t, g) async => out.add((t, g)),
    );
    return out;
  }

  test('点を読み戻せる', () async {
    final got = await readBack(ShapeType.point, [
      [
        [[135.9, 34.0]]
      ],
      [
        [[136.0, 34.1]]
      ],
    ]);
    expect(got.map((e) => e.$1), [ShapeType.point, ShapeType.point]);
    expect(got[1].$2, const LatLng(34.1, 136.0));
  });

  test('線と面を件数どおり読み戻せる', () async {
    final line = await readBack(ShapeType.polyLine, [
      [
        [[135.9, 34.0], [135.95, 34.05], [136.0, 34.1]]
      ],
    ]);
    expect(line.single.$1, ShapeType.polyLine);

    final ring = [[135.9, 34.0], [136.0, 34.0], [136.0, 34.1], [135.9, 34.0]];
    final hole = [[135.95, 34.02], [135.96, 34.02], [135.96, 34.03], [135.95, 34.02]];
    final poly = await readBack(ShapeType.polygon, [
      [ring, hole],
      [ring],
    ]);
    expect(poly.map((e) => e.$1), [ShapeType.polygon, ShapeType.polygon]);
  });

  test('面のリングは外周を時計回り・穴を反時計回りにそろえて書く', () {
    // 外周を反時計回り、穴を時計回り（どちらも逆向き）で渡す
    final outer = [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0], [0.0, 0.0]];
    final hole = [[2.0, 2.0], [2.0, 4.0], [4.0, 4.0], [4.0, 2.0], [2.0, 2.0]];
    final shp = encodeShpShx(ShapeType.polygon, [
      [outer, hole],
    ]).shp;
    final d = ByteData.sublistView(shp);
    // レコード頭 8 + 型 4 + 範囲 32 + 部分数 4 + 点数 4 + 部分の始点 2×4 = 60
    List<double> pt(int i) => [
          d.getFloat64(100 + 60 + i * 16, Endian.little),
          d.getFloat64(100 + 60 + i * 16 + 8, Endian.little),
        ];
    double area(int from) {
      var sum = 0.0;
      for (var i = from; i < from + 4; i++) {
        final a = pt(i), b = pt(i + 1);
        sum += a[0] * b[1] - b[0] * a[1];
      }
      return sum;
    }

    expect(area(0), lessThan(0), reason: '外周は時計回り');
    expect(area(5), greaterThan(0), reason: '穴は反時計回り');
  });

  // 読み手の CP932 変換はプラグイン頼みでテストでは動かないので ASCII で
  test('DBF: 10 文字を超える列名でも値が入る・行番号', () async {
    final path = '${dir.path}/t.dbf';
    File(path).writeAsBytesSync(encodeDbf([
      {'name': 'sugi', 'compartment_no': 12},
      {'name': 'hinoki', 'compartment_no': 13},
    ], includeRowNumber: true));
    final data = await DbfReader.read(path);
    expect(data!['ROW_NUM'], [1, 2]);
    expect(data['NAME'], ['sugi', 'hinoki']);
    expect(data['COMPARTMEN'], [12, 13]);
  });
}
