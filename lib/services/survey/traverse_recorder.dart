// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
/// 導線測量の1回の計測を点に記録する（前視で点を作る／後視で測線を平均する）
///
/// TruPulse の道具から呼ぶ。端末や音・通知には触らないので、GeoPackage だけでテストできる。
/// 後視の流れは2通りあり、どちらも切り替えなしで見分ける。
/// - 振り返り: 器械点 Pk で後ろの Pk-1 を測る → 測線 k を平均、器械点はそのまま
/// - 戻り: 前視を Pn まで済ませてから Pn → P0 へ戻りながら1本ずつ測る。
///   測線 k を後視した直後の計測は、Pk-1 に立って Pk-2 を測ったものとしても試し、
///   合えば測線 k-1 を平均して器械点を Pk-1 へ戻す。Pk 以降の点は平行移動でついてくる
/// docs/devices/trupulse-360r.md「後視補正」
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../models/nodes/feature_node.dart';
import '../../utils/geodesic.dart';
import 'survey_chain_resolver.dart';

/// 磁北基準の方位角を [at] での真北基準に直す関数（TruPulseTool.trueAzimuth）
typedef TrueAzimuthFn = double Function(double magneticAz, LatLng at);

/// 1回の計測値。方位角は本体の値（磁北基準）
class TraverseReading {
  final double az;
  final double inc;
  final double hd;
  final double sd;
  final double vd;
  final DateTime timestamp;

  const TraverseReading({
    required this.az,
    required this.inc,
    required this.hd,
    required this.sd,
    required this.vd,
    required this.timestamp,
  });
}

/// 前視と後視から採る値。方位角は前視の向き・磁北基準
class BacksightAdoption {
  final double az;
  final double inc;
  final double hd;
  final double sd;
  final double vd;

  const BacksightAdoption({
    required this.az,
    required this.inc,
    required this.hd,
    required this.sd,
    required this.vd,
  });

  /// 前視 [fs] と後視 [bs] の平均。後視は向きが逆なので、方位角は 180° 回し、傾斜角は符号を反転して平均する
  factory BacksightAdoption.of(
    ({double az, double inc, double hd, double sd}) fs,
    ({double az, double inc, double hd, double sd}) bs,
  ) {
    final az = circularMeanDeg(fs.az, (bs.az + 180) % 360);
    final inc = (fs.inc - bs.inc) / 2;
    final hd = (fs.hd + bs.hd) / 2;
    final sd = (fs.sd + bs.sd) / 2;
    return BacksightAdoption(az: az, inc: inc, hd: hd, sd: sd, vd: hd * math.tan(inc * math.pi / 180));
  }

  /// 2つの角度（度）の円周平均。0〜360
  static double circularMeanDeg(double a, double b) {
    final aRad = a * math.pi / 180;
    final bRad = b * math.pi / 180;
    final mean = math.atan2(math.sin(aRad) + math.sin(bRad), math.cos(aRad) + math.cos(bRad)) * 180 / math.pi;
    return mean < 0 ? mean + 360 : mean;
  }
}

enum TraverseShotKind {
  /// 新しい点を作った
  forward,

  /// 器械点で後ろを測り、器械点自身の測線を平均した（振り返り）
  backsight,

  /// 器械点の1つ手前に戻って、その点の測線を平均した（戻り）。器械点はその点へ移る
  reverseBacksight,
}

/// [TraverseRecorder.record] の結果
class TraverseShot {
  final TraverseShotKind kind;

  /// 作った点、または測線を平均した点
  final PointFeatureNode point;

  /// 次の計測の器械点
  final PointFeatureNode station;

  /// 後視のとき: 平均する前の前視の方位角・水平距離と、採った値
  final double? forwardAz;
  final double? forwardHd;
  final BacksightAdoption? adopted;

  /// 後視のとき: 平均した測線の器械点（戻りなら次に向かう点）
  final PointFeatureNode? legStation;

  /// 後視で一緒に平行移動した先の点の数
  final int shifted;

  const TraverseShot({
    required this.kind,
    required this.point,
    required this.station,
    this.forwardAz,
    this.forwardHd,
    this.adopted,
    this.legStation,
    this.shifted = 0,
  });
}

class TraverseRecorder {
  /// 後視とみなす距離（前視 HD の 15%、1〜5 m）
  static double backsightThreshold(double forwardHd) => (forwardHd * 0.15).clamp(1.0, 5.0);

  /// 後視補正済みか（GeoPackage の TEXT 列から読み戻すと文字列になる）
  static bool isBacksighted(PointFeatureNode p) {
    final v = p.turfFeature.properties?['survey_backsight'];
    return v == true || v == 'true' || v == 1 || v == '1';
  }

  /// [station] に立って測った [m] を記録する。書けなかったときは null
  ///
  /// 後視に当たればその測線を平均し、当たらなければ [m] の先に点を作ってそれを次の器械点にする。
  static Future<TraverseShot?> record(
    PointFeatureNode station,
    TraverseReading m, {
    required TrueAzimuthFn trueAz,
  }) async {
    final backsight = await _tryBacksight(station, m, trueAz);
    if (backsight != null) return backsight;

    final stnPos = station.point;
    final target = const Distance().offset(stnPos, m.hd, trueAz(m.az, stnPos));
    final newPoint = await PointFeatureNode.createIn(station.parent, target, '', '');
    if (newPoint == null) return null;
    await newPoint.setAttributeValues({
      'survey_az': m.az,
      'survey_inc': m.inc,
      'survey_hd': m.hd,
      'survey_sd': m.sd,
      'survey_vd': m.vd,
      'survey_stn': SurveyStation.encode(stnPos),
      'survey_timestamp': m.timestamp.toIso8601String(),
    });
    return TraverseShot(kind: TraverseShotKind.forward, point: newPoint, station: newPoint);
  }

  /// 後視として試す測線。器械点がまだ後視されていなければ器械点自身の測線（振り返り）、
  /// 後視済みなら1つ手前の点の測線（戻り）
  static Future<TraverseShot?> _tryBacksight(
    PointFeatureNode station,
    TraverseReading m,
    TrueAzimuthFn trueAz,
  ) async {
    final PointFeatureNode leg;
    final TraverseShotKind kind;
    if (!isBacksighted(station)) {
      leg = station;
      kind = TraverseShotKind.backsight;
    } else {
      final prev = SurveyStation.stationOf(station);
      if (prev == null) return null;
      leg = prev;
      kind = TraverseShotKind.reverseBacksight;
    }
    if (isBacksighted(leg)) return null;

    final props = leg.turfFeature.properties;
    if (props == null) return null;
    final from = SurveyStation.parse(props['survey_stn']);
    if (from == null) return null; // 起点
    final fsHd = surveyNumber(props['survey_hd']);
    if (fsHd <= 0) return null;

    // 測線の先（leg）に立って後ろ（from）を測った計測か
    final target = const Distance().offset(leg.point, m.hd, trueAz(m.az, leg.point));
    if (Geodesic.distance(target, from) > backsightThreshold(fsHd)) return null;

    final fs = (
      az: surveyNumber(props['survey_az']),
      inc: surveyNumber(props['survey_inc']),
      hd: fsHd,
      sd: surveyNumber(props['survey_sd']),
    );
    final adopted = BacksightAdoption.of(fs, (az: m.az, inc: m.inc, hd: m.hd, sd: m.sd));
    final newPos = const Distance().offset(from, adopted.hd, trueAz(adopted.az, from));

    // 先の点は動かす前に集める（座標の一致でつないでいるので、動かすと引けなくなる）
    final downstream = SurveyStation.downstreamOf(leg);
    final dLat = newPos.latitude - leg.point.latitude;
    final dLon = newPos.longitude - leg.point.longitude;

    // survey_az などは採った値に置き換え、平均の元になった前視・後視の生の値を残す
    await leg.setAttributeValues({
      'survey_fs_az': fs.az,
      'survey_fs_inc': fs.inc,
      'survey_fs_hd': fs.hd,
      'survey_fs_sd': fs.sd,
      'survey_fs_timestamp': props['survey_timestamp']?.toString() ?? '',
      'survey_bs_az': m.az,
      'survey_bs_inc': m.inc,
      'survey_bs_hd': m.hd,
      'survey_bs_sd': m.sd,
      'survey_bs_timestamp': m.timestamp.toIso8601String(),
      'survey_az': adopted.az,
      'survey_inc': adopted.inc,
      'survey_hd': adopted.hd,
      'survey_sd': adopted.sd,
      'survey_vd': adopted.vd,
      // TEXT 列。bool は sqflite が受け付けない
      'survey_backsight': 'true',
    });
    await leg.updateLocation(newPos);
    await SurveyStation.translate(downstream, dLat, dLon);

    return TraverseShot(
      kind: kind,
      point: leg,
      station: kind == TraverseShotKind.reverseBacksight ? leg : station,
      forwardAz: fs.az,
      forwardHd: fs.hd,
      adopted: adopted,
      legStation: SurveyStation.findAt(from, leg.parent),
      shifted: downstream.length,
    );
  }
}
