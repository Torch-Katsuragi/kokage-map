// 地物の編集: 頂点ごとの記録（sub_table）を、編集後の頂点の並びに合わせ直す
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/editing/edit_session.dart';

void main() {
  const a = LatLng(34, 135);
  const b = LatLng(34.001, 135.001);
  const c = LatLng(34.002, 135.002);
  const n = LatLng(34.0015, 135.0005);

  Map<String, Object?> f(int i) => {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [135 + i / 1000, 34 + i / 1000]},
        'properties': {'time': 't$i'},
      };

  test('FeatureCollection: 残した頂点は記録を引き継ぎ、足した頂点は空の記録', () {
    final json = jsonEncode({'type': 'FeatureCollection', 'features': [f(0), f(1), f(2)]});
    // 1 番目を消し、2 番目の手前に頂点を足した
    final out = remapSubTable(json, 3, [a, n, c], [0, null, 2]);
    final fs = ((jsonDecode(out!) as Map)['features'] as List).cast<Map>();
    expect(fs.map((e) => (e['properties'] as Map)['time']).toList(), ['t0', null, 't2']);
    // 位置は新しい頂点の場所
    expect((fs[1]['geometry'] as Map)['coordinates'], [n.longitude, n.latitude]);
  });

  test('旧形式 [見出し, 行…]: 足した頂点は空の行', () {
    final json = jsonEncode([
      ['time', 'acc'],
      ['t0', 1],
      ['t1', 2],
      ['t2', 3],
    ]);
    final out = jsonDecode(remapSubTable(json, 3, [a, b, n, c], [0, 1, null, 2])!) as List;
    expect(out, [
      ['time', 'acc'],
      ['t0', 1],
      ['t1', 2],
      ['', ''],
      ['t2', 3],
    ]);
  });

  test('面の閉じた記録（頂点数 + 1）は閉じたまま返す', () {
    final json = jsonEncode({'type': 'FeatureCollection', 'features': [f(0), f(1), f(2), f(0)]});
    final out = remapSubTable(json, 3, [a, c], [0, 2], closed: true);
    final fs = ((jsonDecode(out!) as Map)['features'] as List).cast<Map>();
    expect(fs.length, 3);
    expect((fs.last['properties'] as Map)['time'], 't0');
  });

  test('GPS 軌跡の抽出（間引く前の全点を持つ）は頂点と数が合わないので触らない', () {
    // track_extraction_dialog と同じ形: 見出し + 測った点すべて。線は間引いた頂点だけ
    final rows = [
      ['timestamp', 'latitude', 'longitude', 'altitude', 'accuracy', 'speed', 'bearing', 'source_type'],
      for (var i = 0; i < 120; i++) ['2026-09-08T10:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}', 34 + i / 1e4, 135 + i / 1e4, 300.0, 5.0, 1.2, 90.0, 'internal'],
    ];
    expect(remapSubTable(jsonEncode(rows), 3, [a, n, c], [0, null, 2]), isNull);
  });

  test('記録の数が頂点と合わなければ触らない', () {
    final json = jsonEncode({'type': 'FeatureCollection', 'features': [f(0), f(1)]});
    expect(remapSubTable(json, 3, [a, b, c], [0, 1, 2]), isNull);
  });
}
