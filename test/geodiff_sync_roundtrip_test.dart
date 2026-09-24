// 2 台の端末が同じ Drive フォルダを共有し、同じ gpkg を別々に直して同期する往復（ホスト VM、geodiff.dll）。
// シナリオ本体は test/support/geodiff_roundtrip_scenarios.dart（実機版と共有）。
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/geodiff_roundtrip_scenarios.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  defineGeodiffRoundtripTests();
}
