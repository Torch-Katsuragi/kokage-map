// ピアの圏外区間軌跡（gap backfill 受信側）の変換テスト
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/party/peer_track.dart';
import 'package:root_maps/services/party/polyline_codec.dart';

void main() {
  group('PeerTrack.fromMap', () {
    final points = [
      const LatLng(34.0, 135.9),
      const LatLng(34.001, 135.901),
      const LatLng(34.002, 135.903),
    ];

    test('エンコード済みポリラインをデコードして復元する', () {
      final track = PeerTrack.fromMap('u1', {
        'pts': PolylineCodec.encode(points),
        'from': 1000,
        'to': 2000,
      });
      expect(track, isNotNull);
      expect(track!.uid, 'u1');
      expect(track.fromMs, 1000);
      expect(track.toMs, 2000);
      expect(track.points, hasLength(3));
      expect(track.points.first.latitude, closeTo(34.0, 1e-4));
      expect(track.points.last.longitude, closeTo(135.903, 1e-4));
    });

    test('欠損・型不正は null（読むときは寛容に）', () {
      expect(PeerTrack.fromMap('u1', {'from': 1, 'to': 2}), isNull);
      expect(
        PeerTrack.fromMap('u1', {'pts': 123, 'from': 1, 'to': 2}),
        isNull,
      );
      expect(
        PeerTrack.fromMap('u1', {'pts': 'x', 'from': '1', 'to': 2}),
        isNull,
      );
    });

    test('1点しか無い軌跡は null（線にならない）', () {
      final track = PeerTrack.fromMap('u1', {
        'pts': PolylineCodec.encode([const LatLng(34, 135)]),
        'from': 1,
        'to': 2,
      });
      expect(track, isNull);
    });

    test('範囲外の座標を含む軌跡は null（他人が書いた値は描く前に篩う）', () {
      // LatLng は範囲外を作れないので、1e5 倍の整数から直接エンコードする
      final pts = _encodeRaw([
        [3400000, 13590000],
        [9500000, 13590000], // 緯度 95 度
      ]);
      expect(PeerTrack.fromMap('u1', {'pts': pts, 'from': 1, 'to': 2}), isNull);
    });

    test('点数・文字数が上限を超える軌跡は null', () {
      final many = List.generate(
        PeerTrack.maxPoints + 1,
        (i) => LatLng(34.0 + (i.isEven ? 0 : 1e-5), 135.9),
      );
      final pts = PolylineCodec.encode(many);
      expect(PeerTrack.fromMap('u1', {'pts': pts, 'from': 1, 'to': 2}), isNull);
      expect(
        PeerTrack.fromMap('u1', {
          'pts': '?' * (PeerTrack.maxEncodedLength + 2),
          'from': 1,
          'to': 2,
        }),
        isNull,
      );
    });
  });

  group('PeerTrack.limitPerMember', () {
    PeerTrack track(int from) => PeerTrack(
          uid: 'u1',
          points: const [LatLng(34, 135), LatLng(34.001, 135)],
          fromMs: from,
          toMs: from + 1,
        );

    test('新しいものから上限本数だけ残し、古い順に並べる', () {
      final tracks = [
        for (var i = PeerTrack.maxTracksPerMember + 10; i > 0; i--) track(i),
      ];
      final limited = PeerTrack.limitPerMember(tracks);
      expect(limited, hasLength(PeerTrack.maxTracksPerMember));
      expect(limited.first.fromMs, 11);
      expect(limited.last.fromMs, PeerTrack.maxTracksPerMember + 10);
    });

    test('上限以下ならそのまま（古い順）', () {
      final limited = PeerTrack.limitPerMember([track(3), track(1), track(2)]);
      expect(limited.map((t) => t.fromMs), [1, 2, 3]);
    });
  });

  group('isValidCoordinate', () {
    test('範囲内だけ true', () {
      expect(isValidCoordinate(34, 135), isTrue);
      expect(isValidCoordinate(-90, 180), isTrue);
      expect(isValidCoordinate(90.0001, 0), isFalse);
      expect(isValidCoordinate(0, -180.1), isFalse);
      expect(isValidCoordinate(double.nan, 0), isFalse);
      expect(isValidCoordinate(0, double.infinity), isFalse);
    });
  });
}

/// 1e5 倍の整数座標列を Google Encoded Polyline にする（範囲チェック無し）
String _encodeRaw(List<List<int>> coords) {
  final sb = StringBuffer();
  void enc(int value) {
    var v = value < 0 ? ~(value << 1) : (value << 1);
    while (v >= 0x20) {
      sb.writeCharCode((0x20 | (v & 0x1f)) + 63);
      v >>= 5;
    }
    sb.writeCharCode(v + 63);
  }

  var lastLat = 0;
  var lastLng = 0;
  for (final c in coords) {
    enc(c[0] - lastLat);
    enc(c[1] - lastLng);
    lastLat = c[0];
    lastLng = c[1];
  }
  return sb.toString();
}
