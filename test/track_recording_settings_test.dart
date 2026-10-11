// GPS 軌跡の記録の間引き（間隔・距離・精度・飛び）の判定と、設定の保存形式
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/track_recording_settings.dart';

final _t0 = DateTime.utc(2026, 10, 12, 9);
const _p0 = LatLng(34.0, 135.0);

/// [_p0] から北へ [meters] 進んだ点（緯度 1 度 ≒ 110.9 km）
LatLng _north(double meters) => LatLng(_p0.latitude + meters / 110900, _p0.longitude);

void main() {
  group('TrackPointFilter', () {
    TrackFixVerdict judge(
      TrackPointFilter f, {
      required LatLng to,
      required int afterSeconds,
      double? accuracy = 5,
      LatLng from = _p0,
      bool newSegment = false,
    }) =>
        f.judge(
          position: to,
          time: _t0.add(Duration(seconds: afterSeconds)),
          accuracy: accuracy,
          lastTime: _t0,
          lastPosition: from,
          newSegment: newSegment,
        );

    test('既定は以前どおり 1 秒ごと・同じ座標だけ捨てる', () {
      final f = TrackPointFilter();
      expect(f.judge(position: _p0, time: _t0, accuracy: 5), TrackFixVerdict.accept, reason: '最初の点');
      expect(
        f.judge(position: _north(1), time: _t0.add(const Duration(milliseconds: 500)), lastTime: _t0, lastPosition: _p0),
        TrackFixVerdict.tooSoon,
      );
      expect(judge(f, to: _p0, afterSeconds: 1), TrackFixVerdict.duplicate);
      expect(judge(f, to: _north(0.3), afterSeconds: 1), TrackFixVerdict.accept, reason: '距離の下限 0 なら少しでも動けば入れる');
    });

    test('記録の間隔', () {
      final f = TrackPointFilter(const TrackRecordingSettings(intervalSeconds: 10));
      expect(judge(f, to: _north(20), afterSeconds: 9), TrackFixVerdict.tooSoon);
      expect(judge(f, to: _north(20), afterSeconds: 10), TrackFixVerdict.accept);
    });

    test('距離の下限。止まっていても 5 分に 1 点は残す（10 分で区間が切れないように）', () {
      final f = TrackPointFilter(const TrackRecordingSettings(minDistance: 5));
      expect(judge(f, to: _north(3), afterSeconds: 2), TrackFixVerdict.tooClose);
      expect(judge(f, to: _north(6), afterSeconds: 2), TrackFixVerdict.accept);
      expect(judge(f, to: _north(1), afterSeconds: TrackPointFilter.keepAlive.inSeconds - 1), TrackFixVerdict.tooClose);
      expect(judge(f, to: _north(1), afterSeconds: TrackPointFilter.keepAlive.inSeconds), TrackFixVerdict.accept);
    });

    test('精度の上限（既定 100 m）。精度が分からない測位は通す', () {
      final f = TrackPointFilter();
      expect(judge(f, to: _north(10), afterSeconds: 1, accuracy: 150), TrackFixVerdict.inaccurate);
      expect(judge(f, to: _north(10), afterSeconds: 1, accuracy: 100), TrackFixVerdict.accept);
      expect(judge(f, to: _north(10), afterSeconds: 1, accuracy: null), TrackFixVerdict.accept);
      expect(
        f.judge(position: _p0, time: _t0, accuracy: 900),
        TrackFixVerdict.inaccurate,
        reason: '最初の点でも精度は見る',
      );
      final off = TrackPointFilter(const TrackRecordingSettings(maxAccuracy: null));
      expect(judge(off, to: _north(10), afterSeconds: 1, accuracy: 900), TrackFixVerdict.accept);
    });

    test('飛び（既定 200 km/h）。車の速さは通し、1 秒で 100 m 跳ぶ点は捨てる', () {
      final f = TrackPointFilter();
      expect(judge(f, to: _north(28), afterSeconds: 1), TrackFixVerdict.accept, reason: '約 100 km/h');
      expect(judge(f, to: _north(100), afterSeconds: 1), TrackFixVerdict.jump, reason: '約 360 km/h');
      final off = TrackPointFilter(const TrackRecordingSettings(maxSpeedKmh: null));
      expect(judge(off, to: _north(100), afterSeconds: 1), TrackFixVerdict.accept);
    });

    test('飛びが続いたら前の点のほうを疑って受け入れる（ずっと弾き続けない）', () {
      final f = TrackPointFilter();
      for (var i = 0; i < TrackPointFilter.maxConsecutiveJumps; i++) {
        expect(judge(f, to: _north(500), afterSeconds: 1 + i), TrackFixVerdict.jump);
      }
      expect(judge(f, to: _north(500), afterSeconds: 4), TrackFixVerdict.accept);
      expect(f.consecutiveJumps, 0);
    });

    test('飛びの間に普通の点が入れば数え直す', () {
      final f = TrackPointFilter();
      expect(judge(f, to: _north(500), afterSeconds: 1), TrackFixVerdict.jump);
      expect(judge(f, to: _north(500), afterSeconds: 2), TrackFixVerdict.jump);
      expect(judge(f, to: _north(10), afterSeconds: 3), TrackFixVerdict.accept);
      expect(f.consecutiveJumps, 0);
    });

    test('区間の切れ目では前の点と比べない（閉じていた間の移動を飛びとみなさない）', () {
      final f = TrackPointFilter(const TrackRecordingSettings(minDistance: 20, intervalSeconds: 30));
      expect(judge(f, to: _north(50000), afterSeconds: 1, newSegment: true), TrackFixVerdict.accept);
    });
  });

  group('TrackRecordingSettings の保存形式', () {
    test('往復する', () {
      const s = TrackRecordingSettings(intervalSeconds: 5, minDistance: 2, maxSpeedKmh: 100, maxAccuracy: 20);
      expect(TrackRecordingSettings.fromJson(s.toJson()), s);
    });

    test('「見ない」も往復する（既定に戻らない）', () {
      const s = TrackRecordingSettings(maxSpeedKmh: null, maxAccuracy: null);
      expect(TrackRecordingSettings.fromJson(s.toJson()), s);
    });

    test('空・壊れた値は既定', () {
      expect(TrackRecordingSettings.fromJson({}), TrackRecordingSettings.defaults);
      expect(TrackRecordingSettings.fromJson({'intervalSeconds': 0, 'minDistance': -3}), TrackRecordingSettings.defaults);
    });
  });
}
