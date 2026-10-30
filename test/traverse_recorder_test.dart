// 導線測量の記録（前視で点を作る・後視で測線を平均する）
//
// 振り返り（器械点で後ろを測る）と戻り（前視を最後まで済ませてから戻りながら測る）の両方。
// 実物の GeoPackage を使う。方位角の真北補正は恒等にして、偏角に左右されないようにしている。
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/geopackage/geopackage_file.dart';
import 'package:root_maps/models/nodes/feature_node.dart';
import 'package:root_maps/models/nodes/geopackage_node.dart';
import 'package:root_maps/models/nodes/layer_node.dart';
import 'package:root_maps/services/survey/survey_chain_resolver.dart';
import 'package:root_maps/services/survey/traverse_recorder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

double _identityAz(double az, LatLng _) => az;

TraverseReading _shot(double az, double hd, {double inc = 0, int t = 0}) {
  final r = inc * math.pi / 180;
  return TraverseReading(
    az: az,
    inc: inc,
    hd: hd,
    sd: hd / math.cos(r),
    vd: hd * math.tan(r),
    timestamp: DateTime.utc(2026, 10, 13, 9, 0, t),
  );
}

Future<TraverseShot> _record(PointFeatureNode stn, TraverseReading m) async =>
    (await TraverseRecorder.record(stn, m, trueAz: _identityAz))!;

double _num(PointFeatureNode p, String key) => surveyNumber(p.turfFeature.properties?[key]);

/// 点の位置が、器械点（survey_stn）から採った方位角・水平距離で出した位置と合っているか
void _expectLegConsistent(PointFeatureNode p) {
  final stn = SurveyStation.parse(p.turfFeature.properties?['survey_stn'])!;
  final expected = const Distance().offset(stn, _num(p, 'survey_hd'), _num(p, 'survey_az'));
  expect(const Distance().distance(expected, p.point), lessThan(0.01), reason: '測線と位置がずれている');
}

void main() {
  late Directory tmp;
  late GeoPackageFile gpkg;
  late PointLayerNode layer;
  late PointFeatureNode p0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('traverse_recorder_');
    gpkg = GeoPackageFile(const ['t.gpkg'], absolutePath: '${tmp.path}/t.gpkg');
    layer = (await PointLayerNode.createIn(GeoPackageNode(gpkg), 'pts'))!;
    await gpkg.addAttributeColumns('pts', {'name': 'TEXT'});
    p0 = (await PointFeatureNode.createIn(layer, const LatLng(34.0, 136.0), 'P0', null))!;
  });

  tearDown(() async {
    await gpkg.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('前視は点を作って器械点を進める', () async {
    final s = await _record(p0, _shot(90, 50, inc: 5));
    expect(s.kind, TraverseShotKind.forward);
    expect(s.station, s.point);
    expect(s.point, isNot(p0));
    expect(_num(s.point, 'survey_az'), 90);
    expect(SurveyStation.parse(s.point.turfFeature.properties?['survey_stn']), p0.point);
    _expectLegConsistent(s.point);
  });

  test('振り返り: 器械点で後ろを測ると測線を平均し、次の前視は新しい点を作る', () async {
    final p1 = (await _record(p0, _shot(90, 50, inc: 4))).point;

    final bs = await _record(p1, _shot(271, 50.4, inc: -6, t: 1));
    expect(bs.kind, TraverseShotKind.backsight);
    expect(bs.point, p1);
    expect(bs.station, p1);
    expect(_num(p1, 'survey_az'), closeTo(90.5, 1e-9));
    expect(_num(p1, 'survey_hd'), closeTo(50.2, 1e-9));
    expect(_num(p1, 'survey_inc'), closeTo(5, 1e-9));
    expect(_num(p1, 'survey_vd'), closeTo(50.2 * math.tan(5 * math.pi / 180), 1e-9));
    expect(TraverseRecorder.isBacksighted(p1), isTrue);
    _expectLegConsistent(p1);

    final fwd = await _record(p1, _shot(0, 40, t: 2));
    expect(fwd.kind, TraverseShotKind.forward);
    expect(fwd.station, fwd.point);
    final p2 = fwd.point;

    final p1Before = p1.point;
    final bs2 = await _record(p2, _shot(180.4, 40.2, t: 3));
    expect(bs2.kind, TraverseShotKind.backsight);
    expect(bs2.station, p2);
    expect(p1.point, p1Before, reason: '振り返りでは手前の点は動かない');
    _expectLegConsistent(p2);
  });

  test('戻り: 前視を P3 まで済ませてから戻ると、各測線を平均して器械点が1つずつ戻る', () async {
    final p1 = (await _record(p0, _shot(90, 50, inc: 2, t: 0))).point;
    final p2 = (await _record(p1, _shot(0, 40, inc: -3, t: 1))).point;
    final s3 = await _record(p2, _shot(45, 30, inc: 1, t: 2));
    final p3 = s3.point;
    expect(s3.station, p3);

    // P3 に立って P2 を測る（振り返りと同じ）
    final b3 = await _record(p3, _shot(226, 30.4, inc: -1.4, t: 10));
    expect(b3.kind, TraverseShotKind.backsight);
    expect(b3.station, p3);

    // P2 に戻って P1 を測る（道具の器械点は P3 のまま）→ 測線2を平均、器械点は P2
    final p2Before = p2.point;
    final p3Before = p3.point;
    final b2 = await _record(b3.station, _shot(181, 39.6, inc: 2.6, t: 11));
    expect(b2.kind, TraverseShotKind.reverseBacksight);
    expect(b2.point, p2);
    expect(b2.station, p2);
    expect(b2.legStation, p1);
    expect(b2.shifted, 1);
    // P3 は P2 と同じだけ平行移動する
    final dLat = p2.point.latitude - p2Before.latitude;
    final dLon = p2.point.longitude - p2Before.longitude;
    expect(dLat.abs() + dLon.abs(), greaterThan(0));
    expect(p3.point.latitude - p3Before.latitude, closeTo(dLat, 1e-12));
    expect(p3.point.longitude - p3Before.longitude, closeTo(dLon, 1e-12));
    expect(SurveyStation.stationOf(p3), p2);

    // P1 に戻って P0 を測る → 測線1を平均、器械点は P1。P2・P3 もついてくる
    final b1 = await _record(b2.station, _shot(269, 50.2, inc: -2.2, t: 12));
    expect(b1.kind, TraverseShotKind.reverseBacksight);
    expect(b1.station, p1);
    expect(b1.legStation, p0);
    expect(b1.shifted, 2);
    expect(SurveyStation.stationOf(p2), p1);
    expect(SurveyStation.stationOf(p3), p2);

    // 各測線: 平均した値・生の値・位置の整合
    final expected = {
      p1: (fs: (az: 90.0, inc: 2.0, hd: 50.0), bs: (az: 269.0, inc: -2.2, hd: 50.2)),
      p2: (fs: (az: 0.0, inc: -3.0, hd: 40.0), bs: (az: 181.0, inc: 2.6, hd: 39.6)),
      p3: (fs: (az: 45.0, inc: 1.0, hd: 30.0), bs: (az: 226.0, inc: -1.4, hd: 30.4)),
    };
    for (final MapEntry(key: p, value: e) in expected.entries) {
      expect(TraverseRecorder.isBacksighted(p), isTrue);
      expect(_num(p, 'survey_fs_az'), e.fs.az);
      expect(_num(p, 'survey_fs_inc'), e.fs.inc);
      expect(_num(p, 'survey_fs_hd'), e.fs.hd);
      expect(_num(p, 'survey_bs_az'), e.bs.az);
      expect(_num(p, 'survey_bs_inc'), e.bs.inc);
      expect(_num(p, 'survey_bs_hd'), e.bs.hd);
      expect(p.turfFeature.properties?['survey_fs_timestamp'], isNotEmpty);
      expect(p.turfFeature.properties?['survey_bs_timestamp'], isNotEmpty);
      final adoptedAz = BacksightAdoption.circularMeanDeg(e.fs.az, (e.bs.az + 180) % 360);
      expect(_num(p, 'survey_az'), closeTo(adoptedAz, 1e-9));
      expect(_num(p, 'survey_hd'), closeTo((e.fs.hd + e.bs.hd) / 2, 1e-9));
      final inc = (e.fs.inc - e.bs.inc) / 2;
      expect(_num(p, 'survey_inc'), closeTo(inc, 1e-9));
      expect(_num(p, 'survey_vd'), closeTo(_num(p, 'survey_hd') * math.tan(inc * math.pi / 180), 1e-9));
      _expectLegConsistent(p);
    }
    // 測線1: 90° と 269°+180°=89° の平均
    expect(_num(p1, 'survey_az'), closeTo(89.5, 1e-9));

    // 列は書き込むときに足される
    final cols = await gpkg.getColumnNames('pts', getAll: true);
    expect(cols, containsAll(['survey_fs_az', 'survey_bs_az', 'survey_fs_timestamp', 'survey_bs_timestamp']));

    // 起点まで戻ったら、それ以上は戻らない（次は P1 からの前視）
    final f = await _record(b1.station, _shot(180, 20, t: 13));
    expect(f.kind, TraverseShotKind.forward);
    expect(SurveyStation.stationOf(f.point), p1);
  });

  test('後視のあとの前視は、戻りと取り違えず新しい点を作る', () async {
    final p1 = (await _record(p0, _shot(90, 50))).point;
    final p2 = (await _record(p1, _shot(0, 40, t: 1))).point;
    expect((await _record(p2, _shot(180, 40, t: 2))).kind, TraverseShotKind.backsight);

    final p1Before = p1.point;
    final f = await _record(p2, _shot(0, 40, t: 3));
    expect(f.kind, TraverseShotKind.forward);
    expect(f.station, f.point);
    expect(SurveyStation.stationOf(f.point), p2);
    expect(TraverseRecorder.isBacksighted(p1), isFalse);
    expect(p1.point, p1Before);
  });

  test('以前の後視補正済みの点（生の値なし）には触らない', () async {
    final p1 = (await _record(p0, _shot(90, 50))).point;
    await p1.setAttributeValues({'survey_backsight': 'true'});
    final before = p1.point;
    final s = await _record(p1, _shot(270, 50, t: 1));
    // 器械点も手前も後視済み → 前視として点を作る
    expect(s.kind, TraverseShotKind.forward);
    expect(p1.point, before);
    expect(p1.turfFeature.properties?.containsKey('survey_fs_az'), isFalse);
  });

  test('後視の生の値と補正済みの印は GeoPackage に残る（読み直しても消えない）', () async {
    final p1 = (await _record(p0, _shot(90, 50, inc: 4))).point;
    await _record(p1, _shot(271, 50.4, inc: -6, t: 1));
    await gpkg.flushChanges();

    await layer.updateChildren();
    final reloaded = layer.children.whereType<PointFeatureNode>().firstWhere((p) => p.rowId == p1.rowId);
    expect(TraverseRecorder.isBacksighted(reloaded), isTrue);
    expect(_num(reloaded, 'survey_fs_az'), 90);
    expect(_num(reloaded, 'survey_bs_az'), 271);
    expect(_num(reloaded, 'survey_inc'), closeTo(5, 1e-9));
    expect(reloaded.point.longitude, closeTo(p1.point.longitude, 1e-12));
  });

  test('後視とみなす距離は前視 HD の 15%（1〜5 m）', () {
    expect(TraverseRecorder.backsightThreshold(2), 1.0);
    expect(TraverseRecorder.backsightThreshold(20), closeTo(3.0, 1e-9));
    expect(TraverseRecorder.backsightThreshold(100), 5.0);
  });

  test('backsightDeltaOf が前視・後視の差（角度・距離・傾斜角）を返す', () async {
    // 起点 P0 は後視対象ではない
    expect(TraverseRecorder.backsightDeltaOf(p0), isNull);

    // P0 -> P1 を前視（AZ 90°, HD 50.0m, INC 4°）
    final p1 = (await _record(p0, _shot(90, 50, inc: 4))).point;
    expect(TraverseRecorder.backsightDeltaOf(p1), isNull);

    // P1 -> P0 を後視（AZ 271.2° → 逆向き 91.2°, HD 50.35m, INC -4.5°）
    await _record(p1, _shot(271.2, 50.35, inc: -4.5, t: 1));

    final delta = TraverseRecorder.backsightDeltaOf(p1);
    expect(delta, isNotNull);
    expect(delta!.azDeg, closeTo(1.2, 1e-9));
    expect(delta.hdM, closeTo(0.35, 1e-9));
    expect(delta.incDeg, closeTo(0.5, 1e-9));
  });
}
