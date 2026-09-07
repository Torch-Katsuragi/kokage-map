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
// こかげマップ: 位置共有パーティの仲間を地図に描く（マーカーと圏外区間の軌跡）

import 'package:flutter/material.dart';
import 'package:geobase/geobase.dart' as geo;
import 'package:latlong2/latlong.dart';
import 'package:maplibre/maplibre.dart' as ml;

import '../../../i18n/strings.g.dart';
import '../../../models/party/party_room.dart';
import '../../../models/party/peer_position.dart';
import '../../../providers/party_providers.dart' show PartySessionState;
import '../../../utils/geo_converter.dart';

/// メンバー一覧に居ない peer はキック済みの残骸（live は host が消せない）。
/// 一覧ロード前（空）のときは描く
bool _isListedMember(PartySessionState session, String uid) =>
    session.members.isEmpty || session.members.any((m) => m.uid == uid);

/// パーティの仲間の現在位置マーカー
List<ml.Marker> buildPartyPeerMarkers(PartySessionState session) {
  if (session.peers.isEmpty) return const [];
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  return [
    for (final peer in session.peers.values)
      if (_isListedMember(session, peer.uid))
        ml.Marker(
          point: LatLng(peer.latitude, peer.longitude).toGeographic(),
          size: const Size(140, 70),
          child: PeerMarker(
            peer: peer,
            name: session.members
                .firstWhere(
                  (m) => m.uid == peer.uid,
                  orElse: () => PartyMember(
                    uid: peer.uid,
                    name: '',
                    role: PartyRole.guest,
                  ),
                )
                .name,
            nowMs: nowMs,
          ),
        ),
  ];
}

/// パーティの仲間の圏外区間軌跡（gap backfill の受信側）
///
/// 「ブラックアウト中どこを通ったか」をピアマーカーと同系色の細線で描く。
/// 揮発データ（ルーム退出で消える。GeoPackage には保存しない）
List<ml.PolylineLayer> buildPartyTrackPolylines(PartySessionState session) {
  if (session.tracks.isEmpty) return const [];
  return [
    for (final entry in session.tracks.entries)
      // キック済みメンバーの軌跡は描かない（マーカーと同じ判定）
      if (_isListedMember(session, entry.key))
        ml.PolylineLayer(
          polylines: [
            for (final track in entry.value)
              geo.Feature(
                geometry: geo.LineString.from(track.points.toGeographics()),
              ),
          ],
          color: Colors.deepOrange.withValues(alpha: 0.5),
          width: 3,
        ),
  ];
}

/// 他メンバー1人のマーカー（鮮度で淡色化＋経過時間ラベル）
class PeerMarker extends StatelessWidget {
  const PeerMarker({
    super.key,
    required this.peer,
    required this.name,
    required this.nowMs,
  });

  final PeerPosition peer;
  final String name;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final freshness = peer.freshnessAt(nowMs);
    final (opacity, color) = switch (freshness) {
      PeerFreshness.fresh => (1.0, Colors.deepOrange),
      PeerFreshness.stale => (0.6, Colors.deepOrange),
      PeerFreshness.lost => (0.4, Colors.blueGrey),
    };
    final displayName = name.isEmpty ? t.party.memberFallback : name;
    final label = freshness == PeerFreshness.fresh
        ? displayName
        : '$displayName・${_ageLabel(peer.ageAt(nowMs))}';
    return Opacity(
      opacity: opacity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  /// 経過時間の短いラベル
  static String _ageLabel(Duration age) {
    if (age.inMinutes >= 1) return t.party.minAgo(min: age.inMinutes);
    return t.party.secAgo(sec: age.inSeconds);
  }
}
