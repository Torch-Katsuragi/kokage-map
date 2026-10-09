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
import 'package:flutter/foundation.dart';

/// アプリケーション全体のロギングを管理するクラス
///
/// > [!IMPORTANT] web でログを読む方法
/// > **画面のオーバーレイで読む**（[buffer] を `DebugLogOverlay` が表示する）。
/// > release で読むときは `--dart-define=K_LOG=true` を付けてビルドする（無いと控えも積まない）。
/// > ⚠ ブラウザのコンソールも、`window` への書き出しも、DOMへの書き出しも
/// > 当てにしないこと。2026-08-27〜28 に4通り試して全部読めず、丸一日溶かした。
/// > Flutterの外へ出そうとせず、Flutterの中で見るのが唯一確実だった。
class AppLogger {
  /// ログの控え（リングバッファ）。[enabled] のときだけ積む
  ///
  /// ⚠ 製品版（release で `K_LOG` 無し）では積まない。控えを読む `DebugLogOverlay` も
  /// 同じ条件でしか出ないので、溜めても誰も読まず、メモリを食うだけになる。
  static final List<String> buffer = <String>[];

  /// [buffer] の更新通知。`DebugLogOverlay` が監視する
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static const int _kMaxLines = 2000;

  /// リリースビルドでもログを出すか（`--dart-define=K_LOG=true`）
  ///
  /// ⚠ **web のリリースビルドは `kDebugMode` が false** なので、既定だと
  /// ログが1行も出ない。ブラウザでしか再現しない不具合を追うときは
  /// これを付けてビルドし、devtools のコンソールを読むこと。
  /// 2026-08-26 と 08-27 に、これが無くて2回とも当て推量で時間を溶かした。
  static const bool _forceLog = bool.fromEnvironment('K_LOG');

  /// ログを出す・控えを積む・オーバーレイを出す条件
  ///
  /// web のリリースでログを読みたいときは `--dart-define=K_LOG=true` を付けてビルドする
  /// （オーバーレイの `LOG n` チップもそれで出る）。
  static bool get enabled => kDebugMode || _forceLog;

  /// メールアドレスを伏せる（`ab***@example.com`）。ログにアドレスをそのまま残さないために使う
  static String maskEmail(String? email) {
    if (email == null || email.isEmpty) return '(なし)';
    final at = email.indexOf('@');
    if (at <= 0) return '***';
    final head = email.substring(0, at < 2 ? at : 2);
    return '$head***${email.substring(at)}';
  }

  /// 実際に書き出す
  ///
  /// ⚠ `debugPrint` はリリースのwebでコンソールに出なかった（2026-08-28）。
  /// `K_LOG` で焼き込んだときは `print` を使う。
  static void _emit(String line) {
    // ⚠ 製品版では何もしない（控えも積まない）。開発中に「何も見えない」に戻ったら
    //   K_LOG を付け忘れている
    if (!enabled) return;
    buffer.add(line);
    // 先頭を 1 件ずつ消すと 2000 件を毎回詰め直すので、溢れたら 200 件まとめて消す
    if (buffer.length > _kMaxLines + 200) buffer.removeRange(0, buffer.length - _kMaxLines);
    revision.value++;
    if (_forceLog) {
      // ignore: avoid_print
      print(line);
    } else {
      debugPrint(line);
    }
  }

  /// 一般的なログ出力
  static void log(Object? message) => _emit('[LOG] $message');

  /// エラーログ出力
  static void error(Object? message, [dynamic error, StackTrace? stackTrace]) {
    _emit('[ERROR] $message');
    if (error != null) _emit(error.toString());
    if (stackTrace != null) _emit(stackTrace.toString());
  }

  /// デバッグ用ログ出力
  static void debug(Object? message) => _emit('[DEBUG] $message');
}
