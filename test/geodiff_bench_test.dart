// geodiff の行単位マージの速さ（ホスト VM）。実機版は integration_test/device/geodiff_bench_test.dart
// 時間がかかるので既定では飛ばす: BENCH=1 flutter test test/geodiff_bench_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/geodiff_bench.dart';

void main() {
  final enabled = Platform.environment['BENCH'] == '1';
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('2万筆の面データで base の写し・rebase・索引の焼き直し', () async {
    final tmp = await Directory.systemTemp.createTemp('geodiff_bench_');
    try {
      for (final n in [2000, 20000]) {
        final r = await runGeodiffBench(tmp.path, features: n);
        // ignore: avoid_print
        print('[bench host] $r');
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  }, skip: enabled ? false : 'BENCH=1 のときだけ', timeout: const Timeout(Duration(minutes: 10)));
}
