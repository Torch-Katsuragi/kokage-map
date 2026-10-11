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
/// トラバース（導線）補正サービス
///
/// 生の測量データから座標を再計算し、閉合差を補正する。
/// 対応する補正手法:
/// - 磁気偏角補正（方位角にオフセット適用）
/// - Bowditch法（コンパス法則: 路線長比例配分）
/// - Transit法（緯距/経距比例配分）
library;

import 'package:latlong2/latlong.dart';

import '../../utils/geodesic.dart';
import 'survey_chain_resolver.dart';

/// 補正方式
enum AdjustmentMethod {
  /// 補正なし（生データのまま変換）
  none,

  /// コンパス法則（Bowditch法: 累積路線長に比例して閉合差を配分）
  bowditch,

  /// トランシット法則（緯距・経距の絶対値に比例して配分）
  transit,
}

/// 補正オプション
class TraverseAdjustmentOptions {
  /// 閉合差の補正方式
  final AdjustmentMethod method;

  /// 磁気偏角（度）。東偏: +、西偏: -
  final double declination;

  /// 器械高（メートル）
  final double instrumentHeight;

  /// 目標高（メートル）
  final double targetHeight;

  const TraverseAdjustmentOptions({
    this.method = AdjustmentMethod.none,
    this.declination = 0,
    this.instrumentHeight = 0,
    this.targetHeight = 0,
  });
}

/// 補正結果
class TraverseAdjustmentResult {
  /// 補正後の座標列（起点含む）
  final List<LatLng> adjustedPositions;

  /// 補正前の閉合差（メートル）
  final double closureError;

  /// 総路線長（メートル）
  final double totalDistance;

  /// 閉合比（1/N の N）
  final double closureRatioN;

  /// 各脚の補正済み方位角（偏角適用後）
  final List<double> correctedAzimuths;

  /// 各脚の補正済みVD（器械高・目標高適用後）
  final List<double> correctedVDs;

  const TraverseAdjustmentResult({
    required this.adjustedPositions,
    required this.closureError,
    required this.totalDistance,
    required this.closureRatioN,
    required this.correctedAzimuths,
    required this.correctedVDs,
  });
}

/// トラバース補正を実行する
class TraverseAdjuster {
  /// チェーンに補正を適用して座標を再計算する
  static TraverseAdjustmentResult adjust(
    TraverseChain chain,
    TraverseAdjustmentOptions options,
  ) {
    if (chain.isEmpty) {
      return TraverseAdjustmentResult(
        adjustedPositions: [chain.origin.point],
        closureError: 0,
        totalDistance: 0,
        closureRatioN: double.infinity,
        correctedAzimuths: [],
        correctedVDs: [],
      );
    }

    // Step 1: 偏角・高さ補正を適用して座標を再計算
    final recalculated = _recalculatePositions(chain, options);
    final positions = recalculated.positions;
    final correctedAz = recalculated.azimuths;
    final correctedVD = recalculated.vds;

    // Step 2: 閉合差を計算
    final origin = positions.first;
    final lastPos = positions.last;
    final closureError =
        Geodesic.distance(origin, lastPos);

    // Step 3: 総路線長を計算
    double totalDist = 0;
    for (final p in chain.points) {
      totalDist += p.hd;
    }

    final closureRatioN = closureError < 1e-6 ? double.infinity : totalDist / closureError;

    // Step 4: 閉合補正を適用
    final adjusted = switch (options.method) {
      AdjustmentMethod.none => positions,
      AdjustmentMethod.bowditch => _bowditchAdjust(positions, chain.points, origin),
      AdjustmentMethod.transit => _transitAdjust(positions, origin),
    };

    return TraverseAdjustmentResult(
      adjustedPositions: adjusted,
      closureError: closureError,
      totalDistance: totalDist,
      closureRatioN: closureRatioN,
      correctedAzimuths: correctedAz,
      correctedVDs: correctedVD,
    );
  }

  /// 生データから座標を再計算する（偏角・高さ補正込み）
  static _RecalcResult _recalculatePositions(
    TraverseChain chain,
    TraverseAdjustmentOptions options,
  ) {
    const dist = Distance();
    final positions = <LatLng>[chain.origin.point];
    final azimuths = <double>[];
    final vds = <double>[];

    var current = chain.origin.point;
    for (final p in chain.points) {
      final correctedAz = _normalizeAzimuth(p.az + options.declination);
      azimuths.add(correctedAz);

      final correctedVD = p.vd + options.instrumentHeight - options.targetHeight;
      vds.add(correctedVD);

      final target = dist.offset(current, p.hd, correctedAz);
      positions.add(target);
      current = target;
    }

    return _RecalcResult(positions: positions, azimuths: azimuths, vds: vds);
  }

  /// Bowditch法（コンパス法則）による閉合差配分
  ///
  /// 各点の補正量 = 閉合差 * (起点からの累積路線長 / 総路線長)
  static List<LatLng> _bowditchAdjust(
    List<LatLng> positions,
    List<TraversePoint> points,
    LatLng origin,
  ) {
    final n = positions.length;
    if (n < 2) return positions;

    final closureLat = positions.last.latitude - origin.latitude;
    final closureLon = positions.last.longitude - origin.longitude;

    double totalDist = 0;
    for (final p in points) {
      totalDist += p.hd;
    }
    if (totalDist < 1e-9) return positions;

    final adjusted = <LatLng>[origin];
    double cumDist = 0;

    for (int i = 0; i < points.length; i++) {
      cumDist += points[i].hd;
      final ratio = cumDist / totalDist;
      adjusted.add(LatLng(
        positions[i + 1].latitude - closureLat * ratio,
        positions[i + 1].longitude - closureLon * ratio,
      ));
    }

    return adjusted;
  }

  /// Transit法による閉合差配分
  ///
  /// 緯距補正: 各点の|Δlat| / Σ|Δlat| に比例
  /// 経距補正: 各点の|Δlon| / Σ|Δlon| に比例
  static List<LatLng> _transitAdjust(
    List<LatLng> positions,
    LatLng origin,
  ) {
    final n = positions.length;
    if (n < 2) return positions;

    final closureLat = positions.last.latitude - origin.latitude;
    final closureLon = positions.last.longitude - origin.longitude;

    // 各脚の緯距・経距の絶対値の総和
    double sumAbsDLat = 0;
    double sumAbsDLon = 0;
    for (int i = 1; i < n; i++) {
      sumAbsDLat += (positions[i].latitude - positions[i - 1].latitude).abs();
      sumAbsDLon += (positions[i].longitude - positions[i - 1].longitude).abs();
    }

    final adjusted = <LatLng>[origin];
    double cumCorrLat = 0;
    double cumCorrLon = 0;

    for (int i = 1; i < n; i++) {
      final dLat = (positions[i].latitude - positions[i - 1].latitude).abs();
      final dLon = (positions[i].longitude - positions[i - 1].longitude).abs();

      if (sumAbsDLat > 1e-12) {
        cumCorrLat += closureLat * dLat / sumAbsDLat;
      }
      if (sumAbsDLon > 1e-12) {
        cumCorrLon += closureLon * dLon / sumAbsDLon;
      }

      adjusted.add(LatLng(
        positions[i].latitude - cumCorrLat,
        positions[i].longitude - cumCorrLon,
      ));
    }

    return adjusted;
  }

  /// 方位角を0-360度に正規化
  static double _normalizeAzimuth(double az) {
    az %= 360;
    if (az < 0) az += 360;
    return az;
  }

  /// 閉合差を事前計算する（ダイアログでのプレビュー用）
  static ({double error, double distance, double ratioN}) previewClosure(
    TraverseChain chain, {
    double declination = 0,
  }) {
    if (chain.isEmpty) {
      return (error: 0, distance: 0, ratioN: double.infinity);
    }

    final opts = TraverseAdjustmentOptions(declination: declination);
    final recalc = _recalculatePositions(chain, opts);
    final origin = recalc.positions.first;
    final lastPos = recalc.positions.last;

    final error =
        Geodesic.distance(origin, lastPos);
    double totalDist = 0;
    for (final p in chain.points) {
      totalDist += p.hd;
    }
    final ratioN = error < 1e-6 ? double.infinity : totalDist / error;

    return (error: error, distance: totalDist, ratioN: ratioN);
  }
}

class _RecalcResult {
  final List<LatLng> positions;
  final List<double> azimuths;
  final List<double> vds;

  const _RecalcResult({
    required this.positions,
    required this.azimuths,
    required this.vds,
  });
}
