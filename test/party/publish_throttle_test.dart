// PublishThrottle の送信判定テスト
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/services/party/publish_throttle.dart';

void main() {
  group('PublishThrottle', () {
    const throttle = PublishThrottle();
    final t0 = DateTime(2026, 6, 23, 12, 0, 0);
    const origin = LatLng(35.0, 139.0);

    test('初回（last==null）は必ず送信', () {
      expect(
        throttle.shouldPublish(current: origin, now: t0),
        isTrue,
      );
    });

    test('距離しきい値未満かつハートビート未満は送信しない', () {
      // ほぼ同一地点・3秒後
      const near = LatLng(35.00001, 139.00001); // 約1.5m
      expect(
        throttle.shouldPublish(
          current: near,
          now: t0.add(const Duration(seconds: 3)),
          last: origin,
          lastSentAt: t0,
          moving: true,
        ),
        isFalse,
      );
    });

    test('距離しきい値を超えたら送信', () {
      // 約50m北
      const far = LatLng(35.00045, 139.0);
      expect(
        throttle.shouldPublish(
          current: far,
          now: t0.add(const Duration(seconds: 1)),
          last: origin,
          lastSentAt: t0,
          moving: true,
        ),
        isTrue,
      );
    });

    test('移動中ハートビート超過で送信', () {
      expect(
        throttle.shouldPublish(
          current: origin,
          now: t0.add(const Duration(seconds: 80)),
          last: origin,
          lastSentAt: t0,
          moving: true,
        ),
        isTrue,
      );
    });

    test('停止中はハートビートが長い（80秒では送信しない）', () {
      expect(
        throttle.shouldPublish(
          current: origin,
          now: t0.add(const Duration(seconds: 80)),
          last: origin,
          lastSentAt: t0,
          moving: false,
        ),
        isFalse,
      );
    });

    test('低バッテリーは距離しきい値を広げる', () {
      // 約30m（通常なら送信、低電池では倍の50m未満なので送信しない）
      const mid = LatLng(35.00027, 139.0);
      expect(
        throttle.shouldPublish(
          current: mid,
          now: t0.add(const Duration(seconds: 5)),
          last: origin,
          lastSentAt: t0,
          moving: true,
          battery: 10,
        ),
        isFalse,
      );
    });
  });
}
