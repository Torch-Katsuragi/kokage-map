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
/// パーティ位置共有: ピアの圏外区間軌跡（gap backfill の受信側）
///
/// RTDBの `/rooms/{code}/tracks/{uid}/{pushId}` 1件に対応する。
/// 「ブラックアウト中どこを通ったか」を仲間の地図に描くための揮発データで、
/// GeoPackage には保存しない。
library;

import 'package:latlong2/latlong.dart';

import '../../services/party/polyline_codec.dart';

/// ピア1人の圏外区間軌跡1本
class PeerTrack {
  /// メンバーのuid
  final String uid;

  /// デコード済みの座標列
  final List<LatLng> points;

  /// 圏外区間の開始（epoch ms）
  final int fromMs;

  /// 圏外区間の終了（epoch ms）
  final int toMs;

  /// 1本あたりの点数の上限。
  ///
  /// RTDBルールの `pts` 長さ上限（8000文字）では1点に最低2文字かかるので、
  /// 正規のクライアントはこれを超えない。超えるものは壊れているか細工されたもの。
  static const int maxPoints = 4000;

  /// エンコード済み文字列の長さの上限（RTDBルールの `pts` と同じ）
  static const int maxEncodedLength = 8000;

  /// 1メンバーあたり保持する軌跡の本数の上限（新しいものから残す）
  static const int maxTracksPerMember = 50;

  const PeerTrack({
    required this.uid,
    required this.points,
    required this.fromMs,
    required this.toMs,
  });

  /// RTDBのMap（`/tracks/{uid}/{pushId}` の値）からの変換。
  ///
  /// 欠損・デコード不能・点数が上限超え・範囲外の座標を含むものは null
  /// （読むときは寛容に。ただし他人が書いた値なので描画に回す前に篩う）。
  static PeerTrack? fromMap(String uid, Map<dynamic, dynamic> map) {
    final pts = map['pts'];
    final from = map['from'];
    final to = map['to'];
    if (pts is! String || from is! num || to is! num) return null;
    // デコード前に長さで足切りする（ルールと同じ上限）
    if (pts.length > maxEncodedLength) return null;
    final List<LatLng> points;
    try {
      points = PolylineCodec.decode(pts);
    } catch (_) {
      return null;
    }
    if (points.length < 2 || points.length > maxPoints) return null;
    for (final p in points) {
      if (!isValidCoordinate(p.latitude, p.longitude)) return null;
    }
    return PeerTrack(
      uid: uid,
      points: points,
      fromMs: from.toInt(),
      toMs: to.toInt(),
    );
  }

  /// 1メンバー分の軌跡を、新しい順に [maxTracksPerMember] 本までに絞る。
  /// 戻り値は古い順（描画・backfill の並び）。
  static List<PeerTrack> limitPerMember(List<PeerTrack> tracks) {
    final sorted = List.of(tracks)..sort((a, b) => a.fromMs.compareTo(b.fromMs));
    if (sorted.length <= maxTracksPerMember) return sorted;
    return sorted.sublist(sorted.length - maxTracksPerMember);
  }
}

/// 緯度経度が有限かつ範囲内か
bool isValidCoordinate(double lat, double lng) =>
    lat.isFinite &&
    lng.isFinite &&
    lat >= -90 &&
    lat <= 90 &&
    lng >= -180 &&
    lng <= 180;
