// hasInterfaceFrom の判定テスト
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:root_maps/services/party/connectivity_interface_monitor.dart';

void main() {
  group('hasInterfaceFrom', () {
    test('空リストは false', () {
      expect(hasInterfaceFrom([]), isFalse);
    });

    test('none のみは false', () {
      expect(hasInterfaceFrom([ConnectivityResult.none]), isFalse);
    });

    test('wifi は true', () {
      expect(hasInterfaceFrom([ConnectivityResult.wifi]), isTrue);
    });

    test('mobile は true', () {
      expect(hasInterfaceFrom([ConnectivityResult.mobile]), isTrue);
    });

    test('none と mobile の混在は true', () {
      expect(
        hasInterfaceFrom([ConnectivityResult.none, ConnectivityResult.mobile]),
        isTrue,
      );
    });
  });
}
