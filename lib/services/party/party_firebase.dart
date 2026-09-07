// Copyright (C) 2024-2026 Torch-Katsuragi
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
/// パーティ位置共有: Firebase の遅延初期化ゲート
///
/// 山岳=常時オフライン前提のため、Firebase 初期化を**起動クリティカルパスから
/// 外す**。main() では fire-and-forget で起動を温め（runApp をブロックしない）、
/// パーティ機能の入口（createRoom/joinRoom）でのみ完了を await する。これにより、
/// オフライン時でもアプリは地図画面まで確実に到達できる（Firebase未使用なら無関係）。
///
/// Android/iOS 限定（firebase_database / firebase_auth は Windows/desktop 未対応）。
library;


import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../../core/platform_capabilities.dart';
import '../../firebase_options.dart';
import '../../utils/app_logger.dart';

/// パーティ機能用 Firebase の初期化を一度だけ実行する遅延ゲート。
class PartyFirebase {
  PartyFirebase._();

  /// 進行中/完了済みの初期化 Future。初回呼び出しで生成し以降は共有する。
  static Future<bool>? _future;

  /// パーティ機能（Firebase）を利用できるプラットフォームか。
  static bool get isSupported => PlatformCapabilities.supportsPartySharing;

  /// Firebase 初期化を保証する。成功で true、未対応/失敗で false。
  ///
  /// 複数回呼んでも初回の Future を共有する（冪等）。失敗時のみ次回再試行できる
  /// よう Future を破棄する。
  static Future<bool> ensureInitialized() => _future ??= _initialize();

  static Future<bool> _initialize() async {
    if (!isSupported) return false;
    try {
      // 統合テストなど別経路で既に初期化済みなら再初期化しない（duplicate-app回避）。
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
      // App Check: 非正規クライアントからのRTDBアクセスを抑止する。
      // デバッグビルドは debug プロバイダ（起動時にlogcatへ出るデバッグトークンを
      // コンソールに登録して検証）、リリースは Play Integrity / App Attest。
      // コンソール側が monitor の間はブロックしないため、先に入れて段階導入する。
      //
      // ⚠ **web にはプロバイダを渡していない。**
      // web の App Check は reCAPTCHA のサイトキーが要り、それはコンソールで
      // 発行するもの。2026-08-27 時点で App Check API はプロジェクトで
      // 有効化されておらず、RTDB側も強制していないので、web はこのままで通る。
      // 強制に切り替えるときは `providerWeb: ReCaptchaV3Provider(<siteKey>)` を足すこと。
      if (!kIsWeb) {
        try {
          await FirebaseAppCheck.instance.activate(
            providerAndroid: kDebugMode
                ? const AndroidDebugProvider()
                : const AndroidPlayIntegrityProvider(),
            providerApple: kDebugMode
                ? const AppleDebugProvider()
                : const AppleAppAttestProvider(),
          );
        } catch (e) {
          AppLogger.debug('[Party] App Check activate をスキップ: $e');
        }
      }

      // 圏外中の書き込みをローカルに溜め、再接続時に自動フラッシュ（store-and-forward）。
      // DB初回利用前に呼ぶ必要があるが、失敗しても致命的でない（最適化）ので握りつぶす。
      //
      // ⚠ web には無い機能（`setPersistenceEnabled` は web 未対応）。
      // ブラウザのタブが生きている間しか保たないので、そもそも意味が薄い。
      if (!kIsWeb) {
        try {
          FirebaseDatabase.instance.setPersistenceEnabled(true);
        } catch (e) {
          AppLogger.debug('[Party] persistence設定をスキップ: $e');
        }
      }
      return true;
    } catch (e, st) {
      AppLogger.error('Firebase初期化に失敗しました', e, st);
      _future = null; // 次回の入口で再試行できるようにする
      return false;
    }
  }
}
