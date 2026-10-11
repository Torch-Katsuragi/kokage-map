// 地点への誘導の状態: 開始・終了・行き先の差し替え・到着の通知（1 回だけ、離れたらまた）
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:root_maps/models/app_notification.dart';
import 'package:root_maps/providers/guidance_providers.dart';
import 'package:root_maps/providers/notification_providers.dart';
import 'package:root_maps/providers/ui_state_providers.dart';

/// 北緯 35° で緯度を [m] メートルぶん北へ（0.001° ≒ 110.94 m）
LatLng _north(LatLng p, double m) => LatLng(p.latitude + m / 110940.6, p.longitude);

void main() {
  const target = LatLng(35, 135);
  const goal = GuidanceTarget(point: target, label: '境界点 3');

  late ProviderContainer c;
  Guidance g() => c.read(guidanceProvider.notifier);
  GuidanceState s() => c.read(guidanceProvider);
  List<AppNotification> notes() => c.read(notificationCenterProvider);

  setUp(() {
    c = ProviderContainer();
    addTearDown(c.dispose);
  });

  test('案内していない間は位置を覚えるだけで、状態は動かない', () {
    g().updatePosition(_north(target, 100), accuracy: 4);
    expect(s().active, isFalse);
    expect(s().here, isNull);
    expect(g().lastPosition, _north(target, 100));
  });

  test('始めると覚えていた位置から距離と方位が出て、地図にモードの切替を出す', () {
    g().updatePosition(_north(target, 100), accuracy: 4);
    final flashBefore = c.read(mapFlashProvider).$2;
    g().start(goal);
    expect(s().target, goal);
    expect(s().distance, closeTo(100, 0.1));
    expect(s().bearing, closeTo(180, 1e-6)); // 目標は真南
    expect(s().arrived, isFalse);
    expect(c.read(mapFlashProvider).$2, flashBefore + 1);
  });

  test('やめると行き先も位置も消え、もう一度やめても何も起きない', () {
    g()
      ..updatePosition(_north(target, 50))
      ..start(goal);
    final flash = c.read(mapFlashProvider).$2;
    g().stop();
    expect(s().active, isFalse);
    expect(s().here, isNull);
    expect(c.read(mapFlashProvider).$2, flash + 1);
    g().stop();
    expect(c.read(mapFlashProvider).$2, flash + 1);
  });

  test('案内中に行き先を変えると差し替わり、到着は振り出しに戻る', () {
    g()
      ..updatePosition(_north(target, 2))
      ..start(goal);
    expect(s().arrived, isTrue);
    final flash = c.read(mapFlashProvider).$2;
    const other = GuidanceTarget(point: LatLng(35.01, 135), label: 'プロット中心');
    g().start(other);
    expect(s().target, other);
    expect(s().arrived, isFalse);
    expect(c.read(mapFlashProvider).$2, flash); // 案内中の差し替えはモードの切替ではない
  });

  test('到着は max(5 m, 精度) で 1 回だけ知らせ、離れてから戻るとまた知らせる', () {
    g()
      ..updatePosition(_north(target, 30), accuracy: 3)
      ..start(goal);
    expect(notes(), isEmpty);

    g().updatePosition(_north(target, 6), accuracy: 3); // 5 m の外
    expect(s().arrived, isFalse);

    g().updatePosition(_north(target, 4), accuracy: 3);
    expect(s().arrived, isTrue);
    expect(notes(), hasLength(1));
    expect(notes().first.level, NotificationLevel.success);
    expect(notes().first.title, contains('境界点 3'));

    // 半径のすぐ外に出たり入ったりしても繰り返さない
    g()
      ..updatePosition(_north(target, 7), accuracy: 3)
      ..updatePosition(_north(target, 3), accuracy: 3);
    expect(notes(), hasLength(1));

    // 半径の 2 倍（10 m）より離れてから戻ると、もう一度
    g().updatePosition(_north(target, 15), accuracy: 3);
    expect(s().arrived, isFalse);
    g().updatePosition(_north(target, 2), accuracy: 3);
    expect(notes(), hasLength(2));
  });

  test('精度が悪いときは精度の値まで到着とみなす', () {
    g()
      ..updatePosition(_north(target, 8), accuracy: 12)
      ..start(goal);
    expect(s().arrived, isTrue);
    expect(notes(), hasLength(1));
  });

  test('メンバーへの案内は行き先が付いて動く', () {
    const peer = GuidanceTarget(point: LatLng(35.002, 135), label: '田中', peerUid: 'u1');
    g()
      ..updatePosition(target)
      ..start(peer);
    final before = s().distance!;
    g().moveTarget(const LatLng(35.003, 135));
    expect(s().target!.peerUid, 'u1');
    expect(s().target!.point, const LatLng(35.003, 135));
    expect(s().distance, greaterThan(before));
  });

  test('同じ位置の送り直しでは状態を変えない', () {
    g()
      ..updatePosition(_north(target, 50), accuracy: 4)
      ..start(goal);
    final before = s();
    g().updatePosition(_north(target, 50), accuracy: 4);
    expect(identical(s(), before), isTrue);
  });
}
