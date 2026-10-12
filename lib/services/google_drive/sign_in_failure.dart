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
/// サインインの失敗を「圏外」「本当のキャンセル」「その他」に分ける（純 Dart）。
///
/// ⚠ 圏外の Pixel 9 では google_sign_in が
/// `canceled: [16] Account reauth failed.` を返し、それが生のまま出ていた（2026-10）。
/// 林業の現場は圏外が多いので、通信できないときは何のエラーでも「圏外」にまとめる。
library;

import 'package:google_sign_in/google_sign_in.dart';

import 'network_error.dart';

/// サインイン失敗の種類
enum SignInFailureKind {
  /// 通信できない（圏外・機内モードなど）
  offline,

  /// ユーザーが自分で閉じた。エラーは出さない
  cancelled,

  /// それ以外。短い文言に、サポート用のコードを添える
  other,
}

/// 分類の結果。[detail] はサポート用（code と description）
class SignInFailure {
  final SignInFailureKind kind;
  final String? detail;

  const SignInFailure(this.kind, [this.detail]);
}

/// `GoogleSignInException` を表示用に整形する（code と description を必ず残す）
String formatSignInException(GoogleSignInException e) {
  final desc = e.description;
  if (desc == null || desc.isEmpty) return e.code.name;
  return '${e.code.name}: $desc';
}

/// `GoogleSignInException` が「本当のユーザーキャンセル」かどうか
///
/// ⚠ google_sign_in v7（Credential Manager）は**設定系のエラーを
/// `code=canceled` で返すことがある**（無効な serverClientId、SHA-1 未登録、
/// OAuth クライアント削除など）。コードだけ見て黙って握り潰すと、
/// 2026-07 の「Drive 同期サインイン不能」のように原因が何も残らない。
/// description に設定エラーの兆候があるものはエラーとして扱う。
bool isUserCancellation(GoogleSignInException e) {
  if (e.code != GoogleSignInExceptionCode.canceled) return false;

  final desc = e.description?.toLowerCase() ?? '';
  if (desc.isEmpty) return true;

  // 設定エラー・認証情報なしを示す語（黙らせない）
  const configErrorMarkers = [
    'developer console', // 例: [28444] Developer console is not set up correctly
    'deleted_client', // OAuth クライアント削除
    'invalid_client',
    'unregistered',
    'client id',
    'clientid', // serverClientId など
    'sha-1',
    'sha1',
    'certificate',
    'api exception',
    'apiexception',
    'no credential', // 認証情報なし系
    'credential is unavailable',
    'reauth',
  ];
  if (configErrorMarkers.any(desc.contains)) return false;

  // GMS/GIS のステータスコード付きメッセージ
  // （10: DEVELOPER_ERROR、16: 内部エラー/ブロック、28444: コンソール未設定）
  if (RegExp(r'\[?(10|16|28444)[\]:]').hasMatch(desc)) return false;

  return true;
}

/// GMS の NETWORK_ERROR（7）
final _networkStatusCode = RegExp(r'(^|[\[\s])7[\]:]');

/// [error] を分類する。[online] はエラーが来た時点で通信できたか
SignInFailure classifySignInFailure(Object error, {required bool online}) {
  final detail = error is GoogleSignInException
      ? formatSignInException(error)
      : error.toString();

  if (!online) return SignInFailure(SignInFailureKind.offline, detail);

  final text = detail.toLowerCase();
  // 通信の失敗そのものを示すものは、接続の確認が「繋がっている」と言っても圏外扱いにする
  // （電波が弱いとインターフェイスは上がったまま届かないことがある）
  if (isNetworkError(error) || isNetworkError(detail) || _networkStatusCode.hasMatch(text)) {
    return SignInFailure(SignInFailureKind.offline, detail);
  }

  if (error is GoogleSignInException && isUserCancellation(error)) {
    return SignInFailure(SignInFailureKind.cancelled, detail);
  }
  return SignInFailure(SignInFailureKind.other, detail);
}
