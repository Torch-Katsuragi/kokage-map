/// 統合テストの共通ヘルパ。
///
/// プラットフォーム固有の前提が揃っていない項目を、ここで明示的に宣言して
/// スキップする（暗黙に落とさない）。
///
/// 2026-08-25 にデスクトップ版を撤去。対象は Android と web。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

/// 現在のプラットフォーム名（テスト出力のラベル用）
///
/// ⚠ `Platform` は web では**呼んだ瞬間に** `UnsupportedError` を投げるので、
/// 必ず `kIsWeb` を先に見ること（`lib/core/platform_capabilities.dart` と同じ規約）。
String get platformName {
  if (kIsWeb) return 'web';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

/// Firebase の設定が存在するプラットフォームか。
///
/// `lib/firebase_options.dart` に定義があるものだけ true。
/// 2026-08-27 に web を追加した（`firebase apps:create WEB` で登録）。
bool get hasFirebaseConfig =>
    kIsWeb || Platform.isAndroid || Platform.isIOS;

/// スキップ理由つきの `skip` 値を作る。
///
/// `testWidgets(..., skip: skipUnless(hasFirebaseConfig, 'Firebase 未設定'))`
/// のように使う。false（＝スキップしない）か、理由文字列を返す。
Object? skipUnless(bool supported, String reason) =>
    supported ? false : '[$platformName] $reason';

/// [condition] が真になるまで pump を繰り返す。
///
/// `pumpAndSettle` はプラットフォームビュー（地図）や常時アニメーションが
/// あると永久に settle しないため、地図まわりでは常にこちらを使う。
///
/// [timeout] 内に真にならなければ [reason] を添えて失敗する。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 100),
  String reason = 'condition never became true',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await tester.pump(step);
  }
  fail('[$platformName] pumpUntil timeout (${timeout.inSeconds}s): $reason');
}
