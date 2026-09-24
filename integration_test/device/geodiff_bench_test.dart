// geodiff の行単位マージの速さ（実機）。ホスト VM 版は test/geodiff_bench_test.dart
// 実行: flutter test integration_test/device/geodiff_bench_test.dart -d <device>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../test/support/geodiff_bench.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('2万筆の面データで base の写し・rebase・索引の焼き直し', () async {
    final tmp = await Directory.systemTemp.createTemp('geodiff_bench_');
    try {
      for (final n in [2000, 20000]) {
        final r = await runGeodiffBench(tmp.path, features: n);
        // ignore: avoid_print
        print('[bench device] $r');
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
