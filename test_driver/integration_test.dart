// web版の統合テストを回すためのドライバ。
//
// `flutter test <file> -d chrome` は
// "Web devices are not supported for integration tests yet." で断られるため、
// web だけは `flutter drive` 経由になる。chromedriver を別途起動しておくこと。
//
//   chromedriver --port=4444
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/party_ui_test.dart \
//     -d web-server --browser-name=chrome
//
// Windows / Android は従来どおり `flutter test <file> -d <device>` で回す
// （`tool/test_matrix.ps1` はそちら）。
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
