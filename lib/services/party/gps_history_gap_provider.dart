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
/// パーティ位置共有: 圏外区間の軌跡（gap backfill）を GPS 履歴から作る
///
/// [PartyLocationStore] は復帰時に圏外区間 [fromMs, toMs] の自分の軌跡を
/// publishTrack するが、その軌跡の出所がこの provider。常時記録している
/// [GpsHistoryRecorder] から該当区間の点列を取り出し、Douglas-Peucker で
/// 間引いて Google エンコード済みポリラインにする（電池・帯域に優しい）。
library;

import 'package:latlong2/latlong.dart';

import '../../models/gps_track.dart';
import '../../utils/app_logger.dart';
import '../../utils/feature_calc_utils.dart';
import '../gps_history_recorder.dart';
import 'party_location_store.dart';
import 'polyline_codec.dart';

/// 指定区間の GPS 点列を取得する関数（[GpsHistoryRecorder.getPointsInRange] 相当）。
typedef PointsInRangeFetcher = Future<List<GpsTrackPoint>> Function(
  String dateKey,
  DateTime start,
  DateTime end,
);

/// 点列フェッチャから [GapProvider] を組み立てる（テスト用に依存を最小化）。
///
/// [toleranceMeters] は Douglas-Peucker の許容誤差。
GapProvider makeGapProvider(
  PointsInRangeFetcher fetch, {
  double toleranceMeters = 5,
}) {
  return (int fromMs, int toMs) async {
    if (toMs <= fromMs) return null;
    final from = DateTime.fromMillisecondsSinceEpoch(fromMs);
    final to = DateTime.fromMillisecondsSinceEpoch(toMs);

    try {
      // 圏外区間が日付をまたぐ場合に備え、両端の日付キーを対象にする。
      final keys = <String>{GpsHistoryRecorder.dateKey(from), GpsHistoryRecorder.dateKey(to)};
      final points = <GpsTrackPoint>[];
      for (final key in keys) {
        points.addAll(await fetch(key, from, to));
      }
      if (points.length < 2) return null;

      points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final line = points.map((p) => LatLng(p.latitude, p.longitude)).toList();
      final simplified =
          LineSimplification.simplifyLineDouglasPeucker(line, toleranceMeters);
      final encoded = PolylineCodec.encode(simplified);
      if (encoded.isEmpty) return null;

      return GapTrack(encodedPolyline: encoded, fromMs: fromMs, toMs: toMs);
    } catch (e) {
      AppLogger.debug('[GpsHistoryGapProvider] gap生成失敗: $e');
      return null;
    }
  };
}

/// [GpsHistoryRecorder] を背後に持つ [GapProvider]。
GapProvider gpsHistoryGapProvider(
  GpsHistoryRecorder recorder, {
  double toleranceMeters = 5,
}) =>
    makeGapProvider(recorder.getPointsInRange, toleranceMeters: toleranceMeters);
