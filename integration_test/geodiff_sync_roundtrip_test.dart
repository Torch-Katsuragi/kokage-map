// 2 台の端末が同じ Drive フォルダを共有し、同じ gpkg を別々に直して同期する往復（実機、libgeodiff.so）。
//
// 実行: flutter test integration_test/geodiff_sync_roundtrip_test.dart -d <device>
// シナリオ本体は test/support/geodiff_roundtrip_scenarios.dart（ホスト VM 版と共有）。
// Drive はメモリ上の偽物で、端末の Drive やアプリの設定には触らない（SharedPreferences もモック）。
import 'package:integration_test/integration_test.dart';

import '../test/support/geodiff_roundtrip_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  defineGeodiffRoundtripTests();
}
